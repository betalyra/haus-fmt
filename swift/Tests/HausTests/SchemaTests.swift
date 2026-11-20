import Foundation
import Testing

@testable import Haus

/// The schema suite (test-suite/schema): every case on each schema file as
/// written and without its attributes, which must not change any result.
struct SchemaSuiteTests {
    static let dir = suite.appendingPathComponent("schema")

    static func schema(_ name: String, withoutAttributes: Bool) throws -> HausSchema {
        try HausSchema(
            bytes: read(dir.appendingPathComponent(name + ".schema.haus")),
            options: HausSchema.Options(withoutAttributes: withoutAttributes))
    }

    @Test(arguments: files(dir, ".schema.haus"), [false, true])
    func cases(_ name: String, withoutAttributes: Bool) throws {
        let schema = try Self.schema(name, withoutAttributes: withoutAttributes)
        let cases = SuiteCase.cases(in: Self.dir.appendingPathComponent(name + ".cases.haus"))
        #expect(!cases.isEmpty)
        for c in cases {
            let type = try schema.type(try #require(c.string("type")))
            let input = try #require(c.fields["input"])
            switch c.tag {
            case "Ok":
                let decoded = try type.decode(input)
                #expect(try canonical(decoded) == canonical(c.fields["output"] ?? input), "\(c.testDescription)")
                // Encoding the result gives it back, and it can be written.
                #expect(try canonical(type.encode(decoded)) == canonical(decoded), "\(c.testDescription)")
                #expect(throws: Never.self) { try stringify(decoded) }
            case "Err":
                let error = #expect(throws: HausError.self, "\(c.testDescription)") { try type.decode(input) }
                c.check(error)
                // Encoding fails alike.
                let encoding = #expect(throws: HausError.self, "\(c.testDescription)") { try type.encode(input) }
                #expect(encoding?.code == error?.code && encoding?.path == error?.path, "\(c.testDescription)")
            default:
                Issue.record("unknown case \(c.tag)")
            }
        }
    }

    /// Every schema in test-suite/schema/invalid is rejected with the code in its .error file.
    @Test(arguments: files(dir.appendingPathComponent("invalid"), ".schema.haus"))
    func invalid(_ name: String) throws {
        let file = Self.dir.appendingPathComponent("invalid").appendingPathComponent(name)
        let code = readText(file.appendingPathExtension("error")).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = #expect(throws: HausError.self) {
            try HausSchema(bytes: read(file.appendingPathExtension("schema.haus")))
        }
        #expect(error?.code.rawValue == code, "\(String(describing: error))")
        #expect(error?.position != nil)
    }
}

/// The schema-based JSON suite (test-suite/json/schema-based.*), on the
/// schema as written and without its attributes.
struct SchemaJSONSuiteTests {
    static let dir = suite.appendingPathComponent("json")

    @Test(arguments: [false, true])
    func cases(withoutAttributes: Bool) throws {
        let schema = try HausSchema(
            bytes: read(Self.dir.appendingPathComponent("schema-based.schema.haus")),
            options: HausSchema.Options(withoutAttributes: withoutAttributes))
        let cases = SuiteCase.cases(in: Self.dir.appendingPathComponent("schema-based.cases.haus"))
        #expect(cases.count > 150)
        for c in cases {
            let type = try schema.type(try #require(c.string("type")))
            let text = try #require(c.string("json"))
            let read = Result { () throws(HausError) in try type.fromJSON(text) }
            switch c.tag {
            case "Ok":
                let input = try #require(c.fields["input"])
                let written = try type.toJSON(type.decode(input))
                #expect(sameJSON(written, text), "\(c.testDescription): wrote \(written)")
                try checkRead(c, type, read, c.fields["output"] ?? input)
            case "Read":
                try checkRead(c, type, read, try #require(c.fields["output"]))
            case "Err":
                guard case .failure(let error) = read else {
                    Issue.record("\(c.testDescription): read \(read)")
                    continue
                }
                c.check(error)
            default:
                Issue.record("unknown case \(c.tag)")
            }
        }
    }

    /// The value read is a decoded value: encoding gives it back.
    func checkRead(_ c: SuiteCase, _ type: SchemaType, _ read: Result<HausValue, HausError>, _ want: HausValue) throws {
        switch read {
        case .success(let v): #expect(try canonical(type.encode(v)) == canonical(want), "\(c.testDescription)")
        case .failure(let e): Issue.record("\(c.testDescription): \(e)")
        }
    }
}

struct SchemaTests {
    /// Schemas the spec rejects (§13.3, §14), each with its code.
    @Test(arguments: [
        ("type A = { x Int }", "schema-syntax"),
        ("type A = Strin", "unknown-type"),
        ("type A = Array", "wrong-arity"),
        ("type A = Int Int", "wrong-arity"),
        ("type A = { x: a }", "unknown-parameter"),
        ("type A a a = a", "invalid-parameter"),
        ("type A = _", "underscore-type"),
        ("type A = Int\ntype A = String", "duplicate-type"),
        ("type Int = String", "redefine-prelude"),
        ("type Stream = String", "redefine-prelude"),
        ("type A = { x: Int, x: String }", "duplicate-field"),
        ("type B = { x: Int }\ntype A = { x: String, ...B }", "duplicate-field"),
        ("type A = < X | X >", "duplicate-tag"),
        ("type B = < X >\ntype A = < ...B | X >", "duplicate-tag"),
        ("type B = { x: Int }\ntype A = < ...B >", "invalid-spread"),
        ("type B a = < X a >\ntype A = < ...B >", "invalid-spread"),
        ("type A = < ...String >", "invalid-spread"),
        ("type E = Stream Int\ntype A = < ...E >", "invalid-spread"),
        ("type A = < ...Nope >", "unknown-type"),
        ("type A = { ...A }", "spread-cycle"),
        ("type A = Array (Stream Int)", "misplaced-stream"),
        ("type E = Stream Int\ntype A = Array E", "misplaced-stream"),
        ("type A = Secret A", "unguarded-recursion"),
        ("type Id a = a\ntype A = Id A", "unguarded-recursion"),
        ("type L a = < Nil | Cons a (L (Array a)) >", "growing-recursion"),
        ("type A = { @deprecated(1) x: Int }", "attribute-arguments"),
        ("type A = { @deprecated() x: Int }", "attribute-arguments"),
        ("type A = { @deprecated(\"x\" x: Int }", "missing-comma"),
        ("@deprecated(\"a\"\ntype A = Int", "missing-comma"),
        ("type A = { @deprecated(\"\\q\") x: Int }", "invalid-escape"),
        ("/* never closed\ntype A = Int", "unterminated-comment"),
        ("// a \u{1b}[2J comment\ntype A = Int", "control-character"),
        ("// a \u{202e} comment\ntype A = Int", "bidi-control"),
        ("type A = Int\r", "lone-carriage-return"),
        ("type A = { \"x: Int }", "unterminated-string"),
        (
            "type A = " + String(repeating: "Array (", count: 200) + "Int" + String(repeating: ")", count: 200),
            "type-too-deep"
        ),
        ("import std/money (Money)\ntype A = Money", "unknown-module"),
        ("import std/geo (LatLng)\ntype A = LatLng", "unknown-module"),
        ("import std/time (Clock)\ntype A = Clock", "unknown-import"),
        ("import std/time (Date, Date)\ntype A = Date", "duplicate-import"),
        ("import std/time (Date)\ntype Date = Int", "duplicate-type"),
        ("import ./common (A)\ntype B = A", "import-unavailable"),
        ("import @acme/common (A)\ntype B = A", "import-unavailable"),
        ("import @Acme/common (A)\ntype B = A", "unknown-module"),
        ("import acme (A)\ntype B = A", "schema-syntax"),
        ("type A = { ...r }", "row-parameter"),
        ("type A = closed < >", "closed-empty-variant"),
    ])
    func rejects(_ text: String, _ code: String) {
        let error = #expect(throws: HausError.self) { try HausSchema(parsing: text) }
        #expect(error?.code.rawValue == code, "\(String(describing: error))")
        #expect(error?.position != nil)
    }

    @Test func invalidUTF8() {
        let error = #expect(throws: HausError.self) { try HausSchema(bytes: Array("type A = ".utf8) + [0xFF]) }
        #expect(error?.code == .invalidUtf8)
    }

    @Test func spreads() throws {
        let schema = try HausSchema(
            parsing: """
                type UserEvent = < UserCreated { id: Int } | UserRenamed { id: Int, to: String } >
                type AppEvent = closed < ...UserEvent | Heartbeat >
                type ServerEvent = < ...UserEvent >
                type Base = { id: Int }
                type Person = closed { ...Base, name: String }
                type Alias = Base
                type Again = { ...Alias, more?: Int }
                """)
        let app = try schema.type("AppEvent")
        for ok in ["Heartbeat", "UserCreated { id: 1 }", #"UserRenamed { id: 1, to: "x" }"#] {
            #expect(throws: Never.self) { try app.decode(parse(ok)) }
        }
        #expect(throws: HausError.self) { try app.decode(parse("Other")) }
        #expect(try canonical(schema.type("ServerEvent").decode(parse("Other(1)"))) == "Other(1)")
        #expect(throws: HausError.self) { try schema.type("Person").decode(parse(#"{ id: 1, name: "a", x: 1 }"#)) }
        #expect(try canonical(schema.type("Again").decode(parse("{ id: 1, more: 2, x: 1 }"))) == "{id:1,more:2}")
    }

    @Test func warnings() throws {
        let schema = try HausSchema(
            parsing: """
                @deprecated("use B")
                type A = Int
                @since("1.2")
                type B = { a: A, @deprecated n?: Int }
                """)
        let got = schema.warnings.map { "\($0.position!) \($0.code.rawValue)" }
        #expect(got == ["3:1 unknown-attribute", "4:15 deprecated"])
        #expect(schema.definitions[0].deprecated == "use B")
        #expect(schema.definitions[1].deprecated == nil)
    }

    @Test func docComments() throws {
        let schema = try HausSchema(
            parsing: "// An order.\r\n// Two lines.\ntype Order = { id: Int }\n\n// not this\n\ntype B = Int")
        #expect(schema.definitions.map(\.doc) == ["An order.\nTwo lines.", ""])
    }

    @Test func types() throws {
        let schema = try HausSchema(parsing: "type P a = { x: a }\ntype E = Stream Int")
        #expect(#expect(throws: HausError.self) { try schema.type("Nope") }?.code == .unknownType)
        #expect(#expect(throws: HausError.self) { try schema.type("P") }?.code == .wrongArity)
        let e = try schema.type("E")
        #expect(e.isStream)
        #expect(try e.decodeAll([1, try parse("0x10")]) == [1, 16])
        let error = #expect(throws: HausError.self) { try e.decodeAll([1, "x"]) }
        #expect(error?.path == "$[1]")
    }

    /// Values as deep as the depth limit decode on the 512 KiB stack of a
    /// test's thread, in a debug build too.
    @Test func deepestValues() throws {
        let schema = try HausSchema(
            parsing: """
                type List a = < Nil | Cons a (List a) >
                type Ints = List Int
                type Tree = { kids: Array Tree }
                type Opts = Maybe Opts
                """)
        var list: HausValue = .tag("Nil")
        var tree: HausValue = ["kids": []]
        for _ in 0..<255 { list = .tag("Cons", 1, list) }
        // Two levels each: the record and the array.
        for _ in 0..<127 { tree = ["kids": [tree]] }
        #expect(try schema.type("Ints").decode(list) == list)
        #expect(try schema.type("Ints").toJSON(list).count > 0)
        #expect(try schema.type("Tree").decode(tree) == tree)
        #expect(try schema.type("Tree").fromJSON(schema.type("Tree").toJSON(tree)) == tree)
    }

    @Test func deepValues() throws {
        let schema = try HausSchema(parsing: "type Tree = { name: String, children: Array Tree }")
        var deep: HausValue = []
        for _ in 0..<300 { deep = ["name": "n", "children": [deep]] }
        let error = #expect(throws: HausError.self) { try schema.type("Tree").encode(deep) }
        #expect(error?.code == .nestingTooDeep)
    }

    /// Nothing of a secret's value shows in an error (spec §15), also through
    /// the keys of a `Map` or an `Any` inside it.
    @Test func secrets() throws {
        let vault = try HausSchema(parsing: "type Vault = { keys: Secret (Map Int), raw: Secret Any }").type("Vault")
        let leaky: [HausValue] = [
            try parse(#"{ keys: { "sk-live-123": "hunter2" }, raw: 1 }"#),
            ["keys": [:], "raw": [.tag("sk-live-123 hunter2")]],
        ]
        for v in leaky {
            let error = #expect(throws: HausError.self) { try vault.decode(v) }
            #expect(error?.code == .invalidSecret)
            #expect(!(error?.json.contains("hunter2") ?? true) && !(error?.json.contains("sk-live") ?? true))
        }
        let secret = Secret("hunter2")
        var dumped = ""
        dump(secret, to: &dumped)
        for shown in ["\(secret)", String(describing: secret), String(reflecting: secret), dumped] {
            #expect(!shown.contains("hunter2") && shown.contains("redacted"), "\(shown)")
        }
        #expect(secret.reveal() == "hunter2")
    }

    @Test func floats() throws {
        let schema = try HausSchema(parsing: "type F = Float64\ntype G = Float32")
        let f = try schema.type("F")
        let g = try schema.type("G")
        let cases: [(SchemaType, String, String)] = [
            (f, "0.10", "0.1"), (f, "1e21", "1e21"), (f, "123456789012345678901", "123456789012345680000"),
            (f, "1e-7", "1e-7"), (f, "0.000001", "0.000001"), (f, "-0", "-0"), (f, "1e-400", "0"),
            (f, "5e-324", "5e-324"), (f, "2.5", "2.5"), (f, "100", "100"),
            (g, "2097152.25", "2097152.2"), (g, "0.1", "0.1"), (g, "16777217", "16777216"), (g, "1e-50", "0"),
        ]
        for (type, input, spelled) in cases {
            #expect(try canonical(type.decode(parse(input))) == spelled, "\(type.name) \(input)")
        }
        #expect(#expect(throws: HausError.self) { try f.decode(parse("1e400")) }?.code == .outOfRange)
        #expect(#expect(throws: HausError.self) { try g.decode(parse("1e39")) }?.code == .outOfRange)
    }

    /// The std/time profile, with the vectors of the other bindings' tests,
    /// which cover every row of spec/std/time.md.
    @Test func timeProfile() {
        let valid = [
            ("Date", "2026-11-09"), ("Date", "2024-02-29"), ("Date", "2000-02-29"), ("Date", "0000-01-01"),
            ("Date", "9999-12-31"), ("Time", "00:00:00"), ("Time", "23:59:59.999999999"),
            ("DateTime", "2026-11-09T14:30:00"), ("DateTime", "2026-11-09T14:30:00.25"),
            ("Instant", "2026-11-09T14:30:00Z"), ("Instant", "2026-11-09T14:30:00+01:00"),
            ("Instant", "2026-11-09T14:30:00.5-23:59"), ("ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon]"),
            ("ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Atlantis]"),
            ("ZonedDateTime", "2027-03-29T10:00:00+05:00[Europe/Lisbon]"),
            ("ZonedDateTime", "2026-11-09T14:30:00Z[+01:00]"),
            ("ZonedDateTime", "2026-11-09T14:30:00-05:00[America/Port-au-Prince]"),
            ("Duration", "PT30S"), ("Duration", "P1Y2M3W4DT5H6M7.5S"), ("Duration", "-PT1H"), ("Duration", "PT0S"),
            ("Duration", "PT0.000S"), ("Duration", "P1DT0.5S"), ("Duration", "PT0.5S"), ("Duration", "PT0.05S"),
            ("Duration", "-PT0.001S"), ("Duration", "-P10D"), ("Duration", "P4294967295Y"),
            ("Duration", "PT9007199254740991S"), ("Duration", "P104249991374D"), ("YearMonth", "2026-11"),
            ("TimeZone", "Europe/Lisbon"), ("TimeZone", "UTC"), ("TimeZone", "Etc/GMT+1"), ("TimeZone", "-03:30"),
        ]
        for (type, text) in valid {
            #expect(throws: Never.self, "\(type) \(text)") { try checkTime(type, text) }
        }
        let nines = String(repeating: "9", count: 400)
        let invalid = [
            ("Date", "2026-02-30", "2026-02 has no day 30"), ("Date", "2026-02-29", "2026 is not a leap year"),
            ("Date", "1900-02-29", "1900 is not a leap year"), ("Date", "2026-13-01", "month 13 doesn't exist"),
            ("Date", "2026-00-10", "month 00 doesn't exist"), ("Date", "20261109", "write it like 2026-11-09"),
            ("Date", "+12026-11-09", "write it like"), ("Date", "2026-W45-1", "write it like"),
            ("Date", "2026-313", "write it like"), ("Time", "14:30", "write it like 14:30:00"),
            ("Time", "24:00:00", "24:00 is not allowed"), ("Time", "23:59:60", "leap seconds (:60) are not allowed"),
            ("Time", "12:60:00", "minute 60 doesn't exist"), ("Time", "12:00:00.1234567890", "write it like"),
            ("DateTime", "2026-11-09t14:30:00", "write it like"), ("DateTime", "2026-11-09 14:30:00", "write it like"),
            ("DateTime", "2026-11-09T14:30:00Z", "write it like"),
            ("Instant", "2026-11-09T14:30:00", "write it like 2026-11-09T14:30:00Z"),
            ("Instant", "2026-11-09T14:30:00z", "write it like"),
            ("Instant", "2026-11-09T14:30:00-00:00", "-00:00 is not allowed; write Z"),
            ("Instant", "2026-11-09T14:30:00+24:00", "offset +24:00 is out of range"),
            ("Instant", "2016-12-31T23:59:60Z", "leap seconds"),
            ("ZonedDateTime", "2027-03-29T10:00:00[Europe/Lisbon]", "write it like"),
            ("ZonedDateTime", "2027-03-29T10:00:00+01:00", "write it like"),
            ("ZonedDateTime", "2027-03-29T10:00:00+01:00[!Europe/Lisbon]", "not an IANA zone name"),
            ("ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon][u-ca=iso8601]", "write it like"),
            ("ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/../etc]", "not an IANA zone name"),
            ("Duration", "P", "at least one component"), ("Duration", "PT", "at least one component"),
            ("Duration", "P1DT", "T must be followed"), ("Duration", "+PT1H", "write it like"),
            ("Duration", "PT1.5H", "write it like"), ("Duration", "p1d", "write it like"),
            ("Duration", "P4294967296Y", "too large"), ("Duration", "P104249991375D", "below 2^53 seconds"),
            ("Duration", "PT9007199254740992S", "below 2^53 seconds"), ("Duration", "P" + nines + "Y", "too large"),
            ("Duration", "PT" + nines + "S", "below 2^53 seconds"), ("Duration", "P01D", "leading zero"),
            ("Duration", "PT00S", "leading zero"), ("Duration", "PT01.5S", "leading zero"),
            ("Duration", "-P0D", "a duration leaves out components that are zero"),
            ("Duration", "-PT0S", "a zero duration has no sign"),
            ("Duration", "-PT0.000S", "a zero duration has no sign"),
            ("Duration", "-P0Y0M", "a duration leaves out components that are zero"),
            ("Duration", "P0D", "a duration leaves out components that are zero"),
            ("Duration", "P1DT0S", "a duration leaves out components that are zero"),
            ("Duration", "P0Y1D", "a duration leaves out components that are zero"),
            ("Duration", "PT1H0M", "a duration leaves out components that are zero"),
            ("Duration", "PT1M0.0S", "a duration leaves out components that are zero"),
            ("Duration", "P1DT0.00S", "a duration leaves out components that are zero"),
            ("Duration", "P1Y0W", "a duration leaves out components that are zero"),
            ("Duration", "PT0H1S", "a duration leaves out components that are zero"),
            ("Duration", "PT0M0S", "a duration leaves out components that are zero"),
            ("YearMonth", "2026-13", "month 13 doesn't exist"), ("YearMonth", "2026-1", "write it like"),
            ("TimeZone", "europe lisbon", "not an IANA zone name"), ("TimeZone", "/Lisbon", "not an IANA zone name"),
            ("TimeZone", String(repeating: "a", count: 256), "not an IANA zone name"),
            ("TimeZone", "Europe//Lisbon", "not an IANA zone name"),
        ]
        for (type, text, why) in invalid {
            let error = #expect(throws: HausError.self, "\(type) \(text)") { try checkTime(type, text) }
            #expect(
                error?.code == .invalidTime && error?.message.contains(why) == true,
                "\(type) \(text): \(String(describing: error))")
        }
    }

    @Test func base64() {
        for bytes: [UInt8] in [[], [0], [0, 1], [0, 1, 2], [0xFF, 0xEE, 0xDD, 0xCC]] {
            var text: [UInt8] = []
            appendBase64(bytes, to: &text)
            #expect(fromBase64(String(decoding: text, as: UTF8.self)) == bytes)
        }
        for bad in ["CzQ", "CzR=", "Cz==", "C===", "Cz Q=", "Cz-_", "===="] {
            #expect(fromBase64(bad) == nil, "\(bad)")
        }
        #expect(fromBase64("CzQ=") == [0x0B, 0x34])
    }

    @Test func jsonLines() throws {
        let type = try HausSchema(parsing: "type E = Stream { id: Int }").type("E")
        let text = try type.toJSONLines([["id": 1], ["id": 2]])
        #expect(text == "{\"id\":\"1\"}\n{\"id\":\"2\"}\n")
        #expect(try type.fromJSONLines(text) == [["id": 1], ["id": 2]])
        let error = #expect(throws: HausError.self) { try type.fromJSONLines("{\"id\":\"1\"}\n{\"id\":2}\n") }
        #expect(error?.path == "$[1].id")
    }
}
