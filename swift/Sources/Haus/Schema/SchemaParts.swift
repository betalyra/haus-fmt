/// The parts of a container that decode one level deeper, each at a step of
/// the path, and how the decoded parts make the container's value. A class,
/// so that the frames of the recursion that pass it on hold a reference.
final class Parts {
    /// Where the parts are.
    enum Source {
        /// Elements or arguments, at `[i]`.
        case items([HausValue])
        /// The fields of a record (or JSON object), at `.key`.
        case fields(HausRecord)
    }

    /// The type of each part.
    enum Types {
        /// One type for all: the elements of an array, the entries of a map.
        case all(SchemaNode)
        /// A type per part: the arguments of a case.
        case each([SchemaNode])
        /// The fields of a record: a closed one fails for a field it doesn't
        /// list, an open one drops it. Of a payload read from JSON, `"_tag"`
        /// is no field.
        case shape(RecordShape, payload: Bool)
    }

    /// What the decoded parts make.
    enum Result {
        case array
        /// A record of the fields kept.
        case record
        /// The variant `tag` with the parts as its arguments.
        case variant(HausTag)
        /// The variant `tag` with the fields kept as its record payload.
        case payload(HausTag)
    }

    /// The steps of the parts in the path.
    enum Steps {
        /// `[i]` for items, `.key` for fields.
        case natural
        /// The one part's step instead: `"value"` in JSON.
        case member(PathStep)
        /// No step for the one part: the JSON of a `Maybe` that writes `None` as `null`.
        case none
    }

    let source: Source
    let types: Types
    let result: Result
    let steps: Steps
    /// A step before the parts' own: the `"values"` of a payload in JSON.
    let prefix: PathStep?
    /// Whether the keys are checked against the string limit: a `Map`'s, and
    /// a record's listed fields', read from JSON (§16, "Limits").
    let checkKeys: Bool

    init(
        _ source: Source, _ types: Types, _ result: Result, steps: Steps = .natural, prefix: PathStep? = nil,
        checkKeys: Bool = false
    ) {
        self.source = source
        self.types = types
        self.result = result
        self.steps = steps
        self.prefix = prefix
        self.checkKeys = checkKeys
    }

    var count: Int {
        switch source {
        case .items(let items): items.count
        case .fields(let r): r.count
        }
    }

    func step(_ i: Int) -> PathStep? {
        switch (steps, source) {
        case (.member(let step), _): step
        case (.none, _): nil
        case (.natural, .items): .index(i)
        case (.natural, .fields(let r)): .key(r[i].key)
        }
    }

    func item(_ i: Int) -> HausValue {
        switch source {
        case .items(let items): items[i]
        case .fields(let r): r[i].value
        }
    }

    /// The parts' values as given.
    var values: [HausValue] {
        switch source {
        case .items(let items): items
        case .fields(let r): r.fields.map(\.value)
        }
    }

    /// Sets the result of part `i`, starting the results as the parts' values.
    @inline(never)
    func set(_ results: inout [HausValue]?, _ i: Int, _ y: HausValue) {
        if results == nil { results = values }
        results![i] = y
    }

    /// Whether field `key` is dropped: one an open record doesn't list.
    func drops(_ key: String) -> Bool {
        guard case .shape(let shape, let payload) = types else { return false }
        return (payload && sameCodePoints(key, "_tag")) || shape.field(key) == nil
    }

    /// The container's value from the decoded parts (nil where a part is
    /// unchanged), or nil if it is the input, unchanged: nothing decoded to
    /// another value, nothing dropped, and not `fresh` (read from JSON).
    @inline(never)
    func assemble(_ results: [HausValue]?, fresh: Bool) -> HausValue? {
        var record: HausRecord?
        if case .fields(let r) = source {
            let dropped = r.contains { drops($0.key) }
            if results == nil && !dropped && !fresh { return nil }
            let values = results ?? self.values
            record =
                dropped
                ? HausRecord(distinct: r.indices.filter { !drops(r[$0].key) }.map { (r[$0].key, values[$0]) })
                : HausRecord(keysOf: r, values: values)
        } else if results == nil && !fresh {
            return nil
        }
        switch result {
        case .array: return .array(results ?? values)
        case .record: return .record(record!)
        case .variant(let tag): return .variant(tag, results ?? values)
        case .payload(let tag): return .variant(tag, [.record(record!)])
        }
    }
}
