import Foundation
import Haus
import Testing

/// The positions suite (test-suite/positions, spec §8): parsing the whole
/// text fails with the code, line and column of each case (1-based, columns
/// in code points).
struct PositionsSuiteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let text: String
        /// `code line:column`.
        let want: String
        var testDescription: String { text.debugDescription }
    }

    static let cases: [Case] = {
        let values = try! parseAll(readText(suite.appendingPathComponent("positions/cases.haus")))
        return values.map { v in
            guard case .string(let text)? = v["text"], case .string(let code)? = v["code"],
                case .number(let line)? = v["line"], let line = line.integer(),
                case .number(let column)? = v["column"], let column = column.integer()
            else { fatalError("not a case: \(v)") }
            return Case(text: text, want: "\(code) \(line):\(column)")
        }
    }()

    @Test func hasCases() {
        #expect(!Self.cases.isEmpty)
    }

    @Test(arguments: cases)
    func position(_ c: Case) {
        let got: String
        do {
            _ = try parseAll(c.text)
            got = "parsed"
        } catch {
            got = "\(error.code.rawValue) \(error.position.map { "\($0.line):\($0.column)" } ?? "no position")"
        }
        #expect(got == c.want)
    }
}
