import Testing

@testable import Haus

/// One schema, its types and the inputs, shared by many tasks doing
/// everything at once: each must get what one task alone gets. That they
/// can be shared at all is checked by the compiler (the package builds in
/// the Swift 6 language mode, and the tasks capture them); this runs the
/// parts it takes on trust (`@unchecked Sendable` on the schema's nodes).
struct ConcurrencyTests {
    static let schema = try! HausSchema(
        parsing: """
            import std/time (Instant, Date)
            type Order = { id: Int, total: Decimal, placed: Instant, due?: Date, items: Array Item, status: Status, note: Maybe String, tags: Map Int, key: Secret String }
            type Item = { sku: String, price: Float64, qty: Int }
            type Status = < Open | Shipped Date | Cancelled { reason: String } >
            type Orders = Stream Order
            """)

    static let text = """
        // two orders
        { id: 0x10, total: 19.90, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: 0.10, qty: 2 }], status: Shipped(Date("2026-01-03")), note: Some("leave at door"), tags: { a: 1, b: 2 }, key: "k1", extra: "ignored" },
        { id: 17, total: 1, placed: Instant("2026-01-02T03:04:05+01:00"), due: Date("2026-02-01"), items: [], status: Cancelled { reason: "late" }, note: None, tags: {}, key: "k2" },

        """

    /// Texts every path fails on, so that errors are compared too.
    static let bad = [
        #"{ id: 1, total: 1, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: "0.10", qty: 1 }], status: Open, note: None, tags: {}, key: "k" }"#,
        #"{ id: 1, total: 1, placed: Instant("2026-02-30T00:00:00Z"), items: [], status: Open, note: None, tags: {}, key: "k" }"#,
        "[1, 2, { a: }]",
        "{ a: 1, a: 2 }",
    ]

    struct Item: Codable, Equatable {
        let sku: String
        let price: Double
        let qty: Int
    }

    enum Status: Codable, Equatable {
        case open
        case shipped(String)
        case cancelled(reason: String)
    }

    struct Order: Codable, Equatable {
        let id: Int
        let total: HausNumber
        let placed: String
        let due: String?
        let items: [Item]
        let status: Status
        let note: String?
        let tags: [String: Int]
        let key: Secret<String>
    }

    /// Every operation once, with the shared schema and inputs: what each
    /// gave, in order.
    static func run(_ schema: HausSchema) -> [String] {
        var out: [String] = []
        func add(_ label: String, _ body: () throws -> Any) {
            do { out.append("\(label): \(try body())") } catch { out.append("\(label): error \(error)") }
        }
        let layouts: [Layout] = [.pretty, .compact, .minimised]
        add("type") { try schema.type("Order").name }
        add("parse") { try parseAll(text).count }
        let values = (try? parseAll(text)) ?? []
        for layout in layouts {
            add("format \(layout)") { try format(text, FormatOptions(layout: layout, width: 40)) }
            add("stringify \(layout)") { try stringifyAll(values, FormatOptions(layout: layout, width: 40)) }
        }
        add("has comments") { try hasComments(text) }
        add("stream") {
            var reader = StreamReader()
            reader.push(text)
            reader.finish()
            var read: [String] = []
            while let v = try reader.next() { read.append(try canonical(v)) }
            return read
        }
        for (i, v) in values.enumerated() {
            add("canonical") { try canonical(v) }
            #if canImport(CryptoKit)
                add("hash") { try hash(v) }
            #endif
            add("equals") { v == values[0] }
            add("hash value") { v.hashValue == values[0].hashValue }
            add("check") { try checkValue(v, limits: Limits(maxDepth: 3)) }
            add("haus json") { try fromHausJSON(toHausJSON(v)) == v }
            add("import json") { try canonical(importJSON(toHausJSON(v))) }
            let order = try? schema.type("Order")
            add("decode") { try canonical(order!.decode(v)) }
            add("encode") { try canonical(order!.encode(order!.decode(v))) }
            add("to json") { try order!.toJSON(order!.decode(v)) }
            add("from json") { try canonical(order!.fromJSON(order!.toJSON(order!.decode(v)))) }
            add("typed decode") { try order!.decode(Order.self, from: v).items }
            add("typed encode") { try canonical(order!.encode(order!.decode(Order.self, from: v))) }
            add("typed json") {
                try order!.decode(Order.self, fromJSON: order!.toJSON(order!.decode(Order.self, from: v)))
                    == order!.decode(Order.self, from: v)
            }
            for layout in layouts {
                // Read back: a Swift dictionary's order is its own (seeded
                // per instance), so the text's order of a Map's keys isn't
                // fixed.
                add("typed stringify \(layout) \(i)") {
                    try canonical(
                        parse(order!.stringify(order!.decode(Order.self, from: v), FormatOptions(layout: layout))))
                }
            }
        }
        add("decode all") { try schema.type("Orders").decodeAll(Order.self, from: values).count }
        add("json lines") {
            let orders = try schema.type("Orders")
            return try orders.fromJSONLines(orders.toJSONLines(orders.decodeAll(values))).map { try canonical($0) }
        }
        for text in bad {
            add("parse bad") { try canonical(parse(text)) }
            add("format bad") { try format(text) }
            add("decode bad") { try canonical(schema.type("Order").decode(parse(text))) }
            add("typed bad") { try schema.type("Order").decode(Order.self, fromText: text) }
        }
        return out
    }

    @Test func sharedSchemaAndInputs() async {
        let schema = Self.schema
        let want = Self.run(schema)
        #expect(want.count > 50)
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<16 {
                group.addTask { (0..<4).map { _ in Self.run(schema) }.first { $0 != want } ?? want }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 16)
        for got in results {
            let differs = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }
            #expect(differs == nil && got.count == want.count, "\(differs.map { "\($0.offset): \($0.element)" } ?? "")")
        }
    }
}
