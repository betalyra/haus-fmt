import Foundation
import Haus
import Testing

/// The equality suite (test-suite/equality, spec §2, §12): haus equality
/// (`HausValue`'s `==`) both ways, and equal hashes for equal values.
///
/// `order` (the sign of `compare(a, b)`) is not checked: the Swift binding
/// has no `compare` (spec §12 makes it optional, MAY).
struct EqualitySuiteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let a: HausValue
        let b: HausValue
        let equal: Bool
        var testDescription: String { "\((try? canonical(a)) ?? "?") \((try? canonical(b)) ?? "?")" }
    }

    static let cases: [Case] = {
        let values = try! parseAll(readText(suite.appendingPathComponent("equality/cases.haus")))
        return values.map { v in
            guard let a = v["a"], let b = v["b"], case .variant(let equal, [])? = v["equal"], v["order"] != nil else {
                fatalError("not a case: \(v)")
            }
            return Case(a: a, b: b, equal: equal == "True")
        }
    }()

    @Test func hasCases() {
        #expect(!Self.cases.isEmpty)
    }

    @Test(arguments: cases)
    func equality(_ c: Case) {
        #expect((c.a == c.b) == c.equal)
        #expect((c.b == c.a) == c.equal)
        if c.equal {
            #expect(c.a.hashValue == c.b.hashValue)
        }
    }
}
