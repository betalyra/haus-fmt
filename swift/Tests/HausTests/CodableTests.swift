import Foundation
import Testing

@testable import Haus

/// Swift's `Codable` types decoded from and encoded to haus values with a
/// schema type (Sources/Haus/Codable).
struct CodableTests {
    static let schema = try! HausSchema(
        parsing: """
            import std/time (Date, Instant)

            type Order = {
              id: Int,
              placed: Date,
              total: Decimal,
              weight: Float64,
              ratio: Float32,
              small: Int8,
              note?: String,
              gift: Maybe String,
              tags: Array String,
              stock: Map Int,
              raw: Bytes,
              extra: Any,
              status: Status,
              shape: Shape,
              key: Secret String,
              level: Level,
            }
            type Status = closed < Pending | Shipped { tracking: String } | Cancelled >
            type Shape = < Circle Float64 | Rect { w: Float64, h: Float64 } | Dot Disc >
            type Disc = { r: Float64 }
            type Level = closed < Debug | Info >
            type UserId = closed < UserId String >
            type Comment = closed < Comment { author: String, replies: Array Comment } >
            type Twice = { m: Maybe (Maybe Int) }
            type List = < Cons Int List | Nil >
            type Floats = Array Float64
            type Events = Stream Status
            """)

    struct Order: Codable, Equatable {
        let id: Int
        let placed: String
        let total: HausNumber
        let weight: Double
        let ratio: Float
        let small: Int8
        let note: String?
        let gift: String?
        let tags: [String]
        let stock: [String: Int]
        let raw: [UInt8]
        let extra: HausValue
        let status: Status
        let shape: Shape
        let key: Secret<String>
        let level: Level
    }

    enum Status: Codable, Equatable {
        case pending
        case shipped(tracking: String)
        case cancelled
    }

    struct Disc: Codable, Equatable { let r: Double }

    enum Shape: Codable, Equatable {
        case circle(Double)
        case rect(w: Double, h: Double)
        case dot(Disc)
        case unknown(HausValue)
    }

    enum Level: String, Codable { case debug = "Debug", info = "Info" }

    static let orderText = """
        { id: 0x10, placed: Date("2026-11-13"), total: 19.90, weight: 0.10, ratio: 0.1, small: -5,
          gift: Some("card"), tags: ["a"], stock: { "pt-BR": 2 }, raw: x"0bff", extra: [Any, 1],
          status: Shipped { tracking: "DE-4711" }, shape: Dot { r: 1 }, key: "hunter2", level: Debug,
          ignored: 1 }
        """

    @Test func decodesAndEncodesBack() throws {
        let type = try Self.schema.type("Order")
        let order = try type.decode(Order.self, fromText: Self.orderText)
        #expect(order.id == 16)
        #expect(order.placed == "2026-11-13")
        #expect(order.total.literal == "19.90")
        #expect(order.weight == 0.1)
        #expect(order.ratio == 0.1)
        #expect(order.note == nil && order.gift == "card")
        #expect(order.stock == ["pt-BR": 2] && order.raw == [0x0B, 0xFF])
        #expect(order.extra == [.tag("Any"), 1])
        #expect(order.status == .shipped(tracking: "DE-4711"))
        #expect(order.shape == .dot(Disc(r: 1)))
        #expect(order.key.reveal() == "hunter2" && "\(order.key)" == "<redacted>")
        #expect(order.level == .debug)
        // What the schema decodes, written back.
        #expect(try type.encode(order) == revealed(type.decode(parse(Self.orderText))))
        #expect(try type.decode(Order.self, fromJSON: type.toJSON(order)) == order)
    }

    @Test func variants() throws {
        let shape = try Self.schema.type("Shape")
        for (text, swift) in [
            ("Circle(1.5)", Shape.circle(1.5)), ("Rect { w: 1, h: 2 }", .rect(w: 1, h: 2)),
            ("Rect({ h: 2, w: 1 })", .rect(w: 1, h: 2)),
            ("Hexagon { sides: 6 }", .unknown(try parse("Hexagon { sides: 6 }"))),
        ] {
            #expect(try shape.decode(Shape.self, fromText: text) == swift)
            #expect(try shape.encode(swift) == shape.decode(parse(text)))
        }
        // Without `case unknown`, an unknown tag can't be kept.
        let status = try Self.schema.type("Shape")
        let error = #expect(throws: HausError.self) { try status.decode(Status.self, fromText: "Hexagon") }
        #expect(error?.code == .unknownTag)
        let missing = #expect(throws: HausError.self) { try status.decode(Status.self, fromText: "Circle(1)") }
        #expect(missing?.code == .typeMismatch)
    }

    /// A variant of one tag with one argument, or one record case, is a struct too.
    @Test func structsForOneCase() throws {
        struct UserId: Codable, Equatable { let value: String }
        struct Comment: Codable, Equatable {
            let author: String
            let replies: [Comment]
        }
        let id = try Self.schema.type("UserId")
        #expect(try id.decode(UserId.self, fromText: #"UserId("u1")"#) == UserId(value: "u1"))
        #expect(try id.encode(UserId(value: "u1")) == parse(#"UserId("u1")"#))
        let comment = try Self.schema.type("Comment")
        let text = #"Comment { author: "a", replies: [Comment { author: "b", replies: [] }] }"#
        let c = try comment.decode(Comment.self, fromText: text)
        #expect(c.replies[0].author == "b")
        #expect(try comment.stringify(c, FormatOptions(layout: .compact)) == text + "\n")
    }

    @Test func maybes() throws {
        struct Twice: Codable, Equatable { let m: Int?? }
        let type = try Self.schema.type("Twice")
        for (text, swift) in [
            ("{ m: None }", Twice(m: .none)), ("{ m: Some(None) }", Twice(m: .some(.none))),
            ("{ m: Some(Some(5)) }", Twice(m: 5)),
        ] {
            #expect(try type.decode(Twice.self, fromText: text) == swift)
            #expect(try type.encode(swift) == parse(text))
        }
    }

    @Test func errorsArePlaced() throws {
        let type = try Self.schema.type("Order")
        // The schema's own errors, as without Swift types.
        let schemaError = #expect(throws: HausError.self) {
            try type.decode(Order.self, fromText: Self.orderText.replacingOccurrences(of: "-5", with: "300"))
        }
        #expect(schemaError?.code == .outOfRange)
        #expect(schemaError?.path == "$.small")
        // A Swift type that doesn't fit.
        struct Narrow: Codable { let tags: [Int] }
        let mismatch = #expect(throws: HausError.self) { try type.decode(Narrow.self, fromText: Self.orderText) }
        #expect(mismatch?.code == .typeMismatch)
        #expect(mismatch?.path == "$.tags[0]")
        struct NeedsNote: Codable { let note: String }
        let missing = #expect(throws: HausError.self) { try type.decode(NeedsNote.self, fromText: Self.orderText) }
        #expect(missing?.code == .missingField)
        #expect(missing?.path == "$")
        struct Plain: Codable { let key: String }
        let secret = #expect(throws: HausError.self) { try type.decode(Plain.self, fromText: Self.orderText) }
        #expect(secret?.code == .typeMismatch)
        #expect(secret?.path == "$.key")
        struct Wrong: Codable { let key: Secret<Int> }
        let inside = #expect(throws: HausError.self) { try type.decode(Wrong.self, fromText: Self.orderText) }
        #expect(inside?.code == .invalidSecret)
        #expect(inside?.path == "$.key")
        #expect(!(inside?.json.contains("hunter2") ?? true))
    }

    @Test func floats() throws {
        let type = try Self.schema.type("Floats")
        #expect(
            #expect(throws: HausError.self) { try type.decode([Double].self, fromText: "[1e400]") }?.code == .outOfRange
        )
        let values = try type.decode([Double].self, fromText: "[NaN, NegInfinity, 0.1, -0]")
        #expect(values[0].isNaN && values[1] == -.infinity && values[2] == 0.1 && values[3].sign == .minus)
        #expect(try type.encode([.nan, .infinity, 0.1, 1e21]) == parse("[NaN, Infinity, 0.1, 1e21]"))
    }

    /// A codec (spec §13.4): a Swift type of the application's for a named type.
    @Test func codecs() throws {
        struct Cents: HausCodec, Equatable {
            static let hausTypeID = "Money"
            enum Base: Codable { case money(HausNumber, String) }
            let cents: Int
            init(cents: Int) { self.cents = cents }
            init(hausBase: Base) throws {
                guard case .money(let amount, _) = hausBase,
                    let cents = Int(amount.literal.replacingOccurrences(of: ".", with: "")),
                    amount.literal.split(separator: ".").last?.count == 2
                else { throw HausCodecError("not two decimal places") }
                self.cents = cents
            }
            var hausBase: Base {
                .money(try! HausNumber("\(cents / 100).\(cents % 100 < 10 ? "0" : "")\(cents % 100)"), "EUR")
            }
        }
        struct Bill: Codable, Equatable { let total: Cents }
        let schema = try HausSchema(
            parsing: "type Money = closed < Money Decimal Currency >\ntype Currency = < >\ntype Bill = { total: Money }"
        )
        let bill = try schema.type("Bill")
        #expect(try bill.decode(Bill.self, fromText: "{ total: Money(44.40, EUR) }") == Bill(total: Cents(cents: 4440)))
        #expect(try bill.encode(Bill(total: Cents(cents: 4440))) == parse("{ total: Money(44.40, EUR) }"))
        let rejected = #expect(throws: HausError.self) {
            try bill.decode(Bill.self, fromText: "{ total: Money(44.405, EUR) }")
        }
        #expect(rejected?.code == .codecRejected)
        #expect(rejected?.path == "$.total")
        #expect(rejected?.message == "Money rejects the value: not two decimal places")
        let elsewhere = #expect(throws: HausError.self) {
            try schema.type("Money").decode(Cents.Base.self, fromText: "1")
        }
        #expect(elsewhere?.code == .typeMismatch)
    }

    /// A codec's error when encoding is `cannot-encode`, at the place of
    /// the codec's type (spec §13.4).
    @Test func codecEncodeRejection() throws {
        struct Strict: HausCodec {
            static let hausTypeID = "prelude#Decimal"
            let value: HausNumber
            init(hausBase: HausNumber) { value = hausBase }
            var hausBase: HausNumber { get throws { throw HausCodecError("not this one") } }
        }
        struct Bill: Codable { let total: Strict }
        let schema = try HausSchema(parsing: "type Bill = { total: Decimal }")
        let error = #expect(throws: HausError.self) {
            try schema.type("Bill").encode(Bill(total: Strict(hausBase: HausNumber(1))))
        }
        #expect(error?.code == HausError.Code.cannotEncode && error?.path == "$.total", "\(String(describing: error))")
    }

    /// Secrets stay hidden (spec §15): the generic decoder gives
    /// `HausValue.secret`, which the writers refuse and the schema writes in
    /// full; a `Secret` can't be written by Foundation's `JSONEncoder`.
    @Test func secretsStayHidden() throws {
        let schema = try HausSchema(parsing: "type Config = { name: String, key: Secret String }")
        let type = try schema.type("Config")
        let decoded = try type.decode(parse(#"{ name: "a", key: "hunter2" }"#))
        guard case .secret(let key)? = decoded["key"] else {
            Issue.record("not hidden: \(String(describing: decoded["key"]))")
            return
        }
        #expect(key.reveal() == "hunter2")
        var dumped = ""
        dump(decoded, to: &dumped)
        for shown in ["\(decoded)", String(reflecting: decoded), dumped] {
            #expect(!shown.contains("hunter2"), "\(shown)")
        }
        let written = #expect(throws: HausError.self) { try stringify(decoded) }
        let inCanonical = #expect(throws: HausError.self) { try canonical(decoded) }
        for error in [written, inCanonical] {
            #expect(error?.code == HausError.Code.cannotEncode && error?.message.contains("hunter2") == false)
        }
        #expect(decoded != decoded)
        #expect(try type.encode(decoded) == parse(#"{ name: "a", key: "hunter2" }"#))
        #expect(try stringify(type.encode(decoded)).contains(#""hunter2""#))
        #expect(try type.toJSON(decoded) == #"{"name":"a","key":"hunter2"}"#)
        #expect(try revealed(type.decode(type.encode(decoded))) == revealed(decoded))
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(["key": Secret("hunter2")]) }
    }

    @Test func streams() throws {
        let events = try Self.schema.type("Events")
        #expect(try events.decodeAll(Status.self, from: parseAll("Pending, Cancelled,")) == [.pending, .cancelled])
        let error = #expect(throws: HausError.self) {
            try events.decodeAll(Level.self, from: parseAll("Pending, Shipped { tracking: \"x\" },"))
        }
        #expect(error?.path?.hasPrefix("$[") == true)
    }

    @Test func caseNames() {
        #expect(
            ["Shipped", "URL", "HTTPError", "NaN", "A", "UserId", "ID2"].map(caseName) == [
                "shipped", "url", "httpError", "naN", "a", "userId", "id2",
            ])
    }
}

/// A codec's rejection, with its reason.
struct HausCodecError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
