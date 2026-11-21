import Foundation
import Haus
import Testing

/// The checker suite (test-suite/check, spec §14, §15, §16): the warnings
/// of schema files (`HausSchema.warnings`, in the order of their places).
///
/// Only the `Schema` cases run: the Swift binding has no data checker (no
/// hints for unlisted fields and tags or deprecated uses in data; decoding
/// only fails), so the `Data` cases are skipped.
struct CheckSuiteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let schema: String
        /// Each warning as `code line:column`.
        let warnings: [String]
        var testDescription: String { schema.debugDescription }
    }

    static let all: [SuiteCase] = SuiteCase.cases(in: suite.appendingPathComponent("check/cases.haus"))

    static let schemaCases: [Case] = all.filter { $0.tag == "Schema" }.map { c in
        guard let schema = c.string("schema"), case .array(let warnings)? = c.fields["warnings"] else {
            fatalError("not a case: \(c.testDescription)")
        }
        return Case(
            schema: schema,
            warnings: warnings.map { w in
                guard case .variant("Warning", let args) = w, args.count == 3, case .string(let code) = args[0],
                    case .number(let line) = args[1], let line = line.integer(),
                    case .number(let column) = args[2], let column = column.integer()
                else { fatalError("not a warning: \(w)") }
                return "\(code) \(line):\(column)"
            })
    }

    @Test func hasCases() {
        #expect(!Self.schemaCases.isEmpty)
        #expect(Self.all.allSatisfy { $0.tag == "Schema" || $0.tag == "Data" })
    }

    @Test(arguments: schemaCases)
    func warnings(_ c: Case) throws {
        let schema = try HausSchema(parsing: c.schema)
        let byPlace = schema.warnings.sorted {
            ($0.position?.line ?? 0, $0.position?.column ?? 0) < ($1.position?.line ?? 0, $1.position?.column ?? 0)
        }
        let got = byPlace.map { w in
            "\(w.code.rawValue) \(w.position.map { "\($0.line):\($0.column)" } ?? "no position")"
        }
        #expect(got == c.warnings)
    }
}
