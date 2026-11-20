// What a schema decides about schema-based JSON (spec §16.3) when it loads:
// which Maybes write None as null, and which record cases have no JSON form.

/// Decides, for every `Maybe` of the schema, whether its JSON writes `None`
/// as `null`: when its item's JSON can't be null, and it doesn't reach
/// itself through `Maybe`, `Secret` and names only (`type T = Maybe T`). A
/// `Maybe` is identified by where it is written: each `.maybe` node of an
/// instance is one.
func markJSONNull(_ instances: [Instance]) {
    var maybes: [SchemaNode] = []
    var seen = Set<ObjectIdentifier>()
    func walk(_ t: SchemaNode) {
        guard seen.insert(ObjectIdentifier(t)).inserted else { return }
        switch t.kind {
        case .array(let e), .map(let e), .secret(let e):
            walk(e)
        case .maybe(let e):
            maybes.append(t)
            walk(e)
        case .record(let r):
            r.fields.forEach { walk($0.type) }
        case .variant(let v):
            for c in v.cases {
                switch c.payload {
                case .record(let r): r.fields.forEach { walk($0.type) }
                case .named(let t): walk(t)
                case .positional(let items): items.forEach(walk)
                case .none: break
                }
            }
        case .builtin, .time, .ref, .param:
            break
        }
    }
    instances.forEach { walk($0.body) }
    var memo: [ObjectIdentifier: Bool] = [:]
    for m in maybes { m.jsonNull = usesNull(m, &memo) }
}

func usesNull(_ m: SchemaNode, _ memo: inout [ObjectIdentifier: Bool]) -> Bool {
    if let known = memo[ObjectIdentifier(m)] { return known }
    memo[ObjectIdentifier(m)] = false  // a cycle back here is a Maybe that reaches itself
    let uses = !reachesItself(m) && !jsonNullable(m.element!, &memo)
    memo[ObjectIdentifier(m)] = uses
    return uses
}

/// Whether the `Maybe` `m` reaches itself through `Maybe`, `Secret` and names only.
func reachesItself(_ m: SchemaNode) -> Bool {
    var seen = Set<ObjectIdentifier>()
    var t = m.element!
    while true {
        switch t.kind {
        case .ref(let inst):
            t = inst.body
        case .maybe(let e), .secret(let e):
            if t === m { return true }
            guard seen.insert(ObjectIdentifier(t)).inserted else { return false }
            t = e
        default:
            return false
        }
    }
}

/// Whether a type's JSON can be `null`: a `Maybe` that uses null, directly
/// or through names and `Secret`.
func jsonNullable(_ t: SchemaNode, _ memo: inout [ObjectIdentifier: Bool]) -> Bool {
    var t = t
    while true {
        switch t.kind {
        case .ref(let inst): t = inst.body
        case .secret(let e): t = e
        case .maybe: return usesNull(t, &memo)
        default: return false
        }
    }
}

extension SchemaLoader {
    /// The record cases written in the file with a field named `_tag` or
    /// `_args`, which have no schema-based JSON form (spec §16.3): the
    /// schema is valid, converters fail on values of such a case, and
    /// checkers warn about it (`no-json-form`), at the case.
    func noJSONForms() -> [SchemaFailure] {
        var all: [SchemaFailure] = []
        func fields(_ defs: [FieldDef], _ r: RecordShape) {
            for f in defs {
                if let x = r.field(f.key) { cases(f.type, x.type) }
            }
        }
        func cases(_ t: TypeExpr, _ node: SchemaNode) {
            switch (t.form, node.kind) {
            case (.name("Result"), .variant(let v)):
                for (i, tag) in ["Err", "Ok"].enumerated() where i < t.args.count {
                    if case .positional(let items)? = v.caseOf(tag)?.payload { cases(t.args[i], items[0]) }
                }
            case (.name, .array(let e)), (.name, .map(let e)), (.name, .maybe(let e)), (.name, .secret(let e)):
                t.args.forEach { cases($0, e) }
            case (.record, .record(let r)):
                fields(t.fields, r)
            case (.variant, .variant(let v)):
                for cd in t.cases {
                    guard let c = v.caseOf(cd.tag) else { continue }
                    if let f = c.reservedField {
                        all.append(
                            SchemaFailure(
                                cd.pos, .noJsonForm,
                                "\(cd.tag) has a field named \(f), so it has no schema-based JSON form"))
                    }
                    switch c.payload {
                    case .record(let r) where cd.payload.count == 1 && cd.payload[0].form == .record:
                        fields(cd.payload[0].fields, r)
                    case .named(let n) where cd.payload.count == 1:
                        cases(cd.payload[0], n)
                    case .positional(let items) where cd.payload.count == items.count:
                        for (p, item) in zip(cd.payload, items) { cases(p, item) }
                    default:
                        break
                    }
                }
            default:
                // Named types are checked where they are defined; parameters and scalars have no cases.
                break
            }
        }
        for (d, def) in file.types.enumerated() {
            let inst = instances[byKey[templateKey(d)]!]
            let t = def.type.name == "Stream" && inst.stream && def.type.args.count == 1 ? def.type.args[0] : def.type
            cases(t, inst.body)
        }
        var seenAt = Set<Int>()
        return all.sorted { $0.pos < $1.pos }.filter { seenAt.insert($0.pos).inserted }
    }
}
