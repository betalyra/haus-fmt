import Haus
import Testing

/// Haus equality (spec §2) and the value API.
struct ValueTests {
    /// "café" with a precomposed é (NFC) and with e and a combining acute accent (NFD).
    let nfc = "caf\u{E9}"
    let nfd = "cafe\u{301}"

    @Test func swiftEqualsNFCAndNFD() {
        // The reason for the tests below: Swift compares strings by canonical equivalence.
        #expect(nfc == nfd)
    }

    @Test func stringsCompareByCodePoint() throws {
        #expect(HausValue.string(nfc) != .string(nfd))
        #expect(try parse("\"caf\\u{E9}\"") == .string(nfc))
        #expect(try parse("\"cafe\\u{301}\"") == .string(nfd))
        #expect(Set<HausValue>([.string(nfc), .string(nfd)]).count == 2)
        // Different bytes, though Swift's `==` calls the two texts equal.
        #expect(try !canonical(.string(nfc)).utf8.elementsEqual(canonical(.string(nfd)).utf8))
    }

    @Test func keysCompareByCodePoint() throws {
        // Two keys, not a duplicate (spec §4).
        let r = try parse("{ \"\(nfc)\": 1, \"\(nfd)\": 2 }")
        #expect(r[nfc] == 1)
        #expect(r[nfd] == 2)
        #expect(try HausRecord([(nfc, 1), (nfd, 2)]).count == 2)
        #expect(throws: HausError.self) { try HausRecord([(nfc, 1), (nfc, 2)]) }
        // A record with an NFC key isn't one with the NFD key.
        #expect(HausValue.record(try HausRecord([(nfc, 1)])) != .record(try HausRecord([(nfd, 1)])))
    }

    @Test func keysCompareByCodePointInLargeRecords() throws {
        // From KeyIndex.few fields on, keys are chained by a hash.
        let many = (0..<40).map { (key: "k\($0)", value: HausValue(integerLiteral: $0)) }
        let r = try HausRecord(many + [(nfc, 1), (nfd, 2)])
        #expect(r[nfc] == 1 && r[nfd] == 2 && r["k39"] == 39 && r["k40"] == nil)
        #expect(throws: HausError.self) { try HausRecord(many + [("k3", 0)]) }
        let text =
            "{" + many.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ", \"\(nfc)\": 1, \"\(nfd)\": 2 }"
        #expect(try parse(text) == .record(r))
        let error = #expect(throws: HausError.self) {
            try parse("{" + many.map { "\($0.key): 1" }.joined(separator: ", ") + ", k7: 2 }")
        }
        #expect(error?.code == .duplicateKey)
    }

    /// Keys made to collide in the cheap hash (same length, same first and
    /// last eight bytes) switch the index to the seeded one.
    @Test func collidingKeys() throws {
        let keys = (0..<3000).map { "aaaaaaaa" + String(1_000_000 + $0).dropFirst() + "zzzzzzzz" }
        let fields = keys.map { (key: $0, value: HausValue(integerLiteral: 1)) }
        let r = try HausRecord(fields)
        #expect(keys.allSatisfy { r[$0] == 1 } && r["aaaaaaaa999999zzzzzzzz"] == nil)
        let error = #expect(throws: HausError.self) { try HausRecord(fields + [(keys[1234], 2)]) }
        #expect(error?.code == .duplicateKey)
    }

    @Test func recordsIgnoreFieldOrder() throws {
        let a = try parse("{ a: 1, b: [2, 3] }")
        let b = try parse("{ b: [2, 3], a: 1 }")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(try canonical(a) == "{a:1,b:[2,3]}")
    }

    @Test func numbersCompareByNormalizedLiteral() throws {
        #expect(try parse("1_000") == parse("1000"))
        #expect(try parse("0xFF") == 255)
        #expect(try parse("1E+05") == parse("1e5"))
        #expect(try parse("-0x0") == parse("-0"))
        #expect(try parse("1.0") != 1)
        #expect(try parse("1e2") != 100)
    }

    @Test func recordPayloadsAreOneRecordArgument() throws {
        let braces = try parse("Circle { r: 1 }")
        #expect(braces == (try parse("Circle({ r: 1 })")))
        #expect(braces == .tag("Circle", ["r": 1]))
        #expect(braces["r"] == 1)
    }

    @Test func kindsDiffer() throws {
        #expect(try parse("x\"61\"") != "a")
        #expect(try parse("x\"01\"") != [1])
        #expect(try parse("None") != .tag("Some"))
    }

    @Test func numbers() throws {
        let n = try HausNumber("-1_234")
        #expect(n.literal == "-1234")
        #expect(n.integer() == -1234)
        #expect(n.integer(as: UInt8.self) == nil)
        #expect(try HausNumber("0x10").literal == "16")
        #expect(try HausNumber("12.50").literal == "12.50")
        #expect(try HausNumber("12.50").integer() == nil)
        #expect(try HausNumber("1E+05").literal == "1e5")
        #expect(try HausNumber("1e-0").literal == "1e0")
        #expect(HausNumber(Int64.min).literal == "-9223372036854775808")
        for bad in ["", "01", "1.", "+1", ".5", "1_", "0X1", "1 ", "abc"] {
            let error = #expect(throws: HausError.self) { try HausNumber(bad) }
            #expect(error?.code == .invalidNumber, "\(bad)")
        }
        // A constructor applies no limit (spec §11): any length, any exponent.
        #expect(try HausNumber("1e6145").literal == "1e6145")
        #expect(try HausNumber("-1E+0012345678901").literal == "-1e12345678901")
        let hex = "0x" + String(repeating: "f", count: 829)
        #expect(try HausNumber(hex).literal.count == 999)
        #expect(try HausNumber(hex + "f").literal.count == 1000)
        let long = String(repeating: "9", count: 5000)
        #expect(try HausNumber(long).literal == long)
    }

    @Test func tags() throws {
        // Names in variables: `HausTag("…")` with a literal is the literal's init, which doesn't throw.
        let (some, shipped) = ("Some_1", "Shipped")
        #expect(try HausTag(some).name == "Some_1")
        for bad in ["", "lower", "_A", "1A", "A-B", "Ä", "A b"] {
            let error = #expect(throws: HausError.self) { try HausTag(bad) }
            #expect(error?.code == .invalidTag, "\(bad)")
        }
        let tag: HausTag = "Shipped"
        #expect(tag == (try HausTag(shipped)))
        #expect(tag.description == "Shipped")
        let (a, b, ba): (HausTag, HausTag, HausTag) = ("A", "B", "Ba")
        #expect(a < b && b < ba && !(ba < b))
        #expect(HausValue.variant(tag, []) == .tag("Shipped"))
        // A tag of any length is one; a writer applies the limit.
        let long = try HausTag("T" + String(repeating: "x", count: 100))
        #expect(try canonical(.tag(long)).count == 101)
    }

    @Test func description() throws {
        let v = try parse(#"Person { name: "Ada", tags: ["a"], id: 0xFF }"#)
        #expect(v.description == #"Person { name: "Ada", tags: ["a"], id: 255 }"#)
    }
}
