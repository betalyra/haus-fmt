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
}
