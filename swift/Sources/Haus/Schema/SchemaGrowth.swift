/// The parameter graph of §9.10 for one file. It has a node per type
/// parameter of every definition, and for each reference `B t₁ … tₙ` in the
/// body of a definition `A` to a definition `B` of the file (not one of the
/// prelude's), an edge from each parameter `a` of `A` occurring in `tᵢ` to
/// the i-th parameter of `B`: expanding unless `tᵢ` is `a` itself. A schema
/// in which an expanding edge lies on a cycle could have instances that
/// grow without bound (`type T a = < X (T (Pair a a)) >`).
///
/// It is built in linear time: rather than an edge per occurrence of a
/// parameter, an argument with several parameters gets a node of its own
/// that they flow into, so that the node of `tᵢ` reaches exactly the
/// parameters occurring in it, and the edge from it stands for the edges of
/// all of them. Paths between parameters, and so cycles, are those of the
/// parameter graph.
struct GrowthGraph {
    /// An argument other than a bare parameter passed to a definition of the
    /// file: the `P a a` of `B (P a a)`.
    struct Pass {
        /// The definition the reference is in, and where.
        let def: Int
        let pos: Int
        /// The definition referred to, and which of its parameters the argument is for.
        let to: Int
        let index: Int
        let arg: TypeExpr
        /// The node of the argument's parameters; nil if it has none.
        var from: Int?
    }

    let types: [TypeDef]
    let own: [String: Int]
    /// Node `first[d] + p` is parameter `p` of definition `d`.
    var first: [Int] = []
    /// Per parameter node: its definition.
    var owner: [Int] = []
    /// The parameter nodes, then the nodes of arguments with several parameters.
    var edges: [[Int]] = []
    /// The arguments other than a bare parameter, each passed to a definition
    /// of the file, in the order they are checked.
    var passes: [Pass] = []

    init(_ types: [TypeDef], own: [String: Int]) {
        self.types = types
        self.own = own
        for def in types {
            first.append(owner.count)
            owner += Array(repeating: first.count - 1, count: def.params.count)
        }
        edges = Array(repeating: [], count: owner.count)
        for (d, def) in types.enumerated() { _ = flow(d, def.type) }
    }

    /// The definition of the file `name` refers to; nil if it isn't one
    /// (the prelude's generic types come first).
    func callee(_ name: String) -> Int? { genericTypes[name] == nil ? own[name] : nil }

    /// The node of parameter `name` of definition `d`; nil if it has none.
    func param(_ d: Int, _ name: String) -> Int? { types[d].params.firstIndex(of: name).map { first[d] + $0 } }

    /// Adds the edges of the references in `t`, in definition `d`, and
    /// returns the node that the parameters occurring in `t` flow into; nil
    /// if none do.
    mutating func flow(_ d: Int, _ t: TypeExpr) -> Int? {
        switch t.form {
        case .param(let name):
            return param(d, name)
        case .name(let name):
            let to = callee(name)
            let n = to.map { min(t.args.count, types[$0].params.count) } ?? 0
            // This reference's arguments are checked before those of the references inside them.
            let start = passes.count
            let nested = t.args.prefix(n).indices.filter { if case .param = t.args[$0].form { false } else { true } }
            for i in nested {
                passes.append(Pass(def: d, pos: t.pos, to: to!, index: i, arg: t.args[i], from: nil))
            }
            let argNodes = t.args.map { flow(d, $0) }
            for (i, node) in argNodes.prefix(n).enumerated() {
                if let node { edges[node].append(first[to!] + i) }
            }
            for (k, i) in nested.enumerated() { passes[start + k].from = argNodes[i] }
            return join(argNodes.compactMap { $0 })
        case .record:
            return join(t.fields.compactMap { flow(d, $0.type) })
        case .variant:
            return join(t.cases.flatMap(\.payload).compactMap { flow(d, $0) })
        }
    }

    /// One node for `nodes`: nil for none, the node for one (or the same one
    /// again), otherwise a new node they all flow into.
    mutating func join(_ nodes: [Int]) -> Int? {
        guard let one = nodes.first else { return nil }
        if nodes.allSatisfy({ $0 == one }) { return one }
        let joined = edges.count
        edges.append([])
        for n in nodes { edges[n].append(joined) }
        return joined
    }

    /// The first expanding edge on a cycle, at its reference: definitions in
    /// order, references in body order (outermost first), then by argument.
    func firstGrowing() -> SchemaFailure? {
        let component = components(edges)
        for p in passes {
            let to = first[p.to] + p.index
            guard let from = p.from, component[from] == component[to] else { continue }
            // The first parameter in the argument that the cycle comes back to.
            var back: Int?
            p.arg.walk { t in
                guard back == nil, case .param(let name) = t.form, let a = param(p.def, name),
                    component[a] == component[to]
                else { return }
                back = a
            }
            if let back { return SchemaFailure(p.pos, .growingRecursion, growing(back, to, component)) }
        }
        return nil
    }

    /// The message for parameter node `a` passed, inside a bigger type, to
    /// parameter node `to`, from where it comes back to `a`.
    func growing(_ a: Int, _ to: Int, _ component: [Int]) -> String {
        let def = owner[a]
        let b = owner[to]
        let name = types[def].name
        let param = types[def].params[a - first[def]]
        if a == to {
            return
                "\(name) passes its parameter \(param) to itself inside a bigger type: instances could grow without bound"
        }
        let target = b == def ? "itself" : types[b].name
        let names = [name, types[b].name] + way(to, a, component).map { types[owner[$0]].name }
        return
            "\(name) passes its parameter \(param) to \(target) inside a bigger type, and it comes back (\(names.joined(separator: " → "))): instances could grow without bound"
    }

    /// A shortest way along the parameter graph's edges from parameter node
    /// `from` to `to` in the same component: the nodes after `from`. It is
    /// only for a message, so it builds the edges between parameters itself.
    func way(_ from: Int, _ to: Int, _ component: [Int]) -> [Int] {
        var direct = Array(repeating: [Int](), count: owner.count)
        for (d, def) in types.enumerated() {
            def.type.walk { t in
                guard let name = t.name, let b = callee(name) else { return }
                for (i, arg) in t.args.prefix(types[b].params.count).enumerated() {
                    arg.walk { x in
                        if case .param(let p) = x.form, let node = param(d, p) { direct[node].append(first[b] + i) }
                    }
                }
            }
        }
        var before = Array(repeating: -1, count: direct.count)
        var queue = [from]
        var head = 0
        while head < queue.count {
            let n = queue[head]
            head += 1
            if n == to { break }
            for m in direct[n] where m != from && before[m] < 0 && component[m] == component[from] {
                before[m] = n
                queue.append(m)
            }
        }
        var way: [Int] = []
        var n = to
        while before[n] >= 0 {
            way.append(n)
            n = before[n]
        }
        return way.reversed()
    }
}

/// The strongly connected component of each node of a graph, the edges of
/// node `n` in `edges[n]` (Tarjan's algorithm, with a stack of its own
/// rather than recursion).
func components(_ edges: [[Int]]) -> [Int] {
    let n = edges.count
    var index = Array(repeating: -1, count: n)
    var low = Array(repeating: 0, count: n)
    var component = Array(repeating: -1, count: n)
    var stack: [Int] = []
    var work: [(node: Int, next: Int)] = []
    var visited = 0
    var count = 0
    func visit(_ v: Int) {
        index[v] = visited
        low[v] = visited
        visited += 1
        stack.append(v)
        work.append((v, 0))
    }
    for start in 0..<n where index[start] < 0 {
        visit(start)
        while let (v, next) = work.last {
            if next < edges[v].count {
                let w = edges[v][next]
                work[work.count - 1].next += 1
                if index[w] < 0 {
                    visit(w)
                } else if component[w] < 0 {
                    low[v] = min(low[v], index[w])
                }
                continue
            }
            work.removeLast()
            if let parent = work.last?.node { low[parent] = min(low[parent], low[v]) }
            if low[v] == index[v] {
                while let w = stack.popLast() {
                    component[w] = count
                    if w == v { break }
                }
                count += 1
            }
        }
    }
    return component
}
