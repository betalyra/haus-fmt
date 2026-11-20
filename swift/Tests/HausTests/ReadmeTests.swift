import Haus
import Testing

/// The examples of README.md, as written there.
struct ReadmeTests {
    @Test func quickstart() throws {
        let order = try parse(#"{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }"#)
        var shipped: String?
        if case .variant("Shipped", _)? = order["status"], case .string(let tracking)? = order["status"]?["tracking"] {
            shipped = tracking
        }
        #expect(shipped == "DE-4711")

        guard case .number(let n) = try parse("19.90") else { Issue.record("not a number"); return }
        #expect(n.description == "19.90")

        #expect(try parseAll("Log { a: 1 },\nHeartbeat,\n").count == 2)
        let built: HausValue = ["id": 7, "tags": ["a"], "status": .tag("Shipped")]
        #expect(built == (try parse(#"{ id: 7, tags: ["a"], status: Shipped }"#)))
    }

    @Test func equality() throws {
        let nfc = "caf\u{E9}"
        let nfd = "cafe\u{301}"
        #expect(nfc == nfd)
        #expect(HausValue.string(nfc) != .string(nfd))
        guard case .record(let r) = try parse(#"{ "\#(nfc)": 1, "\#(nfd)": 2 }"#) else {
            Issue.record("not a record"); return
        }
        #expect(r.count == 2)
    }

    @Test func canonicalForm() throws {
        let v = try parse(#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#)
        #expect(try canonical(v) == #"Order{id:255,total:19.90,"x-y":1e5}"#)
    }

    @Test func json() throws {
        let v = try importJSON(#"{"total": 19.90, "paid": true}"#)
        #expect(v == ["total": .number(try HausNumber("19.90")), "paid": .tag("True")])
        let text = try toHausJSON(v)
        #expect(text.hasPrefix(#"{"_haus":1,"_value":{"_rec":{"#))
        #expect(try fromHausJSON(text) == v)
    }

    struct UserId: Codable { let id: String }
    enum Status: Codable { case pending, shipped(tracking: String), cancelled }
    struct Order: Codable {
        let id: Int
        let customer: UserId
        let status: Status
    }

    @Test func swiftTypes() throws {
        let schema = try HausSchema(
            parsing: """
                type Order = { id: Int, customer: UserId, status: Status }
                type UserId = closed < UserId String >
                type Status = closed < Pending | Shipped { tracking: String } | Cancelled >
                """)
        let text = #"{ id: 7, customer: UserId("usr_ada"), status: Shipped { tracking: "DE-4711" } }"#
        let order = try schema.type("Order").decode(Order.self, fromText: text)
        #expect(order.customer.id == "usr_ada")
        guard case .shipped(let tracking) = order.status else { Issue.record("not shipped"); return }
        #expect(tracking == "DE-4711")
        #expect(try schema.type("Order").encode(order) == parse(text))
    }
}
