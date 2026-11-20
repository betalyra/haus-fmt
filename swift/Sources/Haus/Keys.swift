/// The keys of a record by their place in its fields: finding a key, and a
/// repeated key while the record is read, in linear time whatever the keys
/// (spec §7, §9.8).
///
/// The keys of a small record are compared with each other, and only when a
/// key may repeat one: when a key before it has the same ``keySketch(_:)``
/// (its length and first and last byte, a bit of a word). The keys of a
/// larger one are chained by ``cheapHash(_:)`` (the length and first and last
/// eight bytes), and a key is compared only with the keys of its chain. When
/// a chain grows long, which ordinary keys don't do but keys made to collide
/// do, the chains are rebuilt with Swift's `Hasher`, seeded at random per
/// process. Every key is compared with at most ``few`` or ``maxChain`` keys
/// before that, so the work stays linear in the size of the keys.
///
/// It takes two words, so that a record, and so a ``HausValue``, stays small.
struct KeyIndex: Sendable {
    /// Records with at most this many keys compare a key with the ones before it.
    static let few = 32
    /// The longest chain walked with the cheap hash before switching to the seeded one.
    static let maxChain = 8
    /// The fewest chains.
    static let minChains = 64
    private static let end = UInt32.max

    /// While there are few keys (`table` is empty): a bit for the sketch of
    /// each key so far. Once they are chained: the seeded flag (bit 0) and
    /// the number of chains as a power of two (the bits above it).
    private var word: UInt64 = 0
    /// Once the keys are chained: the last key of each chain (``end`` for
    /// none), then for each key the key before it in its chain.
    private var table: [UInt32] = []

    private var chained: Bool { !table.isEmpty }
    private var seeded: Bool { word & 1 != 0 }
    private var chains: Int { chained ? 1 << (word >> 1) : 0 }

    /// Adds `key`, the key of the field after `fields` (whose keys were added
    /// before it), if none of them is the same: whether it is new.
    mutating func insert(_ key: String, after fields: [HausRecord.Field]) -> Bool {
        let count = fields.count + 1
        if !chained && count <= Self.few {
            let bit: UInt64 = 1 << withUTF8(key, keySketch)
            let maybe = word & bit != 0
            word |= bit
            return !(maybe && fields.contains { sameCodePoints($0.key, key) })
        }
        if 2 * count > chains { rebuild(fields, chains: 4 * count, seeded: seeded) }
        let (found, walked) = search(key, fields)
        guard found == nil else { return false }
        if walked > Self.maxChain && !seeded { rebuild(fields, chains: chains, seeded: true) }
        add(key, at: fields.count)
        return true
    }

    /// Where `key` is in `fields`, the fields whose keys were added.
    func find(_ key: String, in fields: [HausRecord.Field]) -> Int? {
        guard !chained else { return search(key, fields).found }
        guard word & 1 << withUTF8(key, keySketch) != 0 else { return nil }
        return fields.firstIndex { sameCodePoints($0.key, key) }
    }

    /// The place of `key` in its chain, if it is there, and how many keys
    /// were compared.
    private func search(_ key: String, _ fields: [HausRecord.Field]) -> (found: Int?, walked: Int) {
        let next = chains
        var at = table[bucket(key)]
        var walked = 0
        while at != Self.end {
            if sameCodePoints(fields[Int(at)].key, key) { return (Int(at), walked) }
            at = table[next + Int(at)]
            walked += 1
        }
        return (nil, walked)
    }

    /// Chains the keys of `fields` again, in at least `chains` chains.
    private mutating func rebuild(_ fields: [HausRecord.Field], chains: Int, seeded: Bool) {
        // The smallest power of two of at least `chains` chains.
        let power = Int.bitWidth - (max(Self.minChains, chains) - 1).leadingZeroBitCount
        word = UInt64(power) << 1 | (seeded ? 1 : 0)
        table = Array(repeating: Self.end, count: 1 << power)
        table.reserveCapacity((1 << power) + fields.count * 2)
        for (i, field) in fields.enumerated() { add(field.key, at: i) }
    }

    /// Chains the key of the field at `i`, after the ones before it.
    private mutating func add(_ key: String, at i: Int) {
        let b = bucket(key)
        table.append(table[b])
        table[b] = UInt32(i)
    }

    /// The chain of `key`: the top bits of its hash, as many as select a chain.
    private func bucket(_ key: String) -> Int {
        let hash = seeded ? UInt64(UInt(bitPattern: seededHash(key))) : withUTF8(key, cheapHash)
        return Int(truncatingIfNeeded: hash >> (64 - (word >> 1)))
    }
}

/// The hash of a key's code points by Swift's `Hasher`, seeded at random per process.
func seededHash(_ key: String) -> Int {
    var hasher = Hasher()
    hashCodePoints(key, into: &hasher)
    return hasher.finalize()
}
