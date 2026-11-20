// The modes of the fuzzers that read a FILE of lines, one case a line, as
// the Go runner's (fuzz/go):
//
//   swift-runner --time FILE          `TYPE HEX`: `ok` if the text is a valid value of the
//                                     std/time type (checkTime), `no` if not
//   swift-runner --schema FILE        `SUITE TYPE HEX` (haus text): decode with the type of the
//                                     schema file SUITE, encode what was decoded: `ok <canonical form>`
//   swift-runner --schema-check FILE  `HEX` (a schema file): `ok`, or `err <line> <column> <code> <reason>`
//   swift-runner --json MODE FILE     the JSON mappings: write, read, haus-json-write,
//                                     haus-json-read, import (fuzz/src/json-runners.ts)
//
// Errors of a value are `err <place> <code> <reason>`: the place in the value
// (`$.items[2].price`, `$` for an error in the text) and the code (spec §17;
// `-` for an input that isn't one value).
import Foundation
import Haus

/// The checkout this program was built from: the schema files are there.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The mode of the arguments if it reads a FILE of lines: the file, and the
/// result of a line. Nil for the other modes.
func lineMode(_ args: ArraySlice<String>) -> (file: String, one: (String) -> String)? {
    let flags = Array(args)
    switch flags.first {
    case "--time" where flags.count == 2: return (flags[1], timeLine)
    case "--schema-check" where flags.count == 2: return (flags[1], checkLine)
    case "--schema" where flags.count == 2:
        let suites = schemas(["test-suite/schema", "fuzz/schema"])
        return (flags[1], { line in typed(line, suites, roundtrip) })
    case "--json" where flags.count == 3:
        return (flags[2], jsonLine(flags[1]))
    default: return nil
    }
}

/// Prints the result of each non-empty line of `file`, a line each.
func runLines(_ file: String, _ one: (String) -> String) {
    guard let data = FileManager.default.contents(atPath: file) else { fail("can't read \(file)") }
    var out = ""
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        out +=
            one(String(line)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\n"
        if out.utf8.count > 1 << 20 {
            FileHandle.standardOutput.write(Data(out.utf8))
            out = ""
        }
    }
    FileHandle.standardOutput.write(Data(out.utf8))
}

/// A case's text: hex-encoded bytes.
func unhex(_ s: Substring) -> [UInt8] {
    let digits = Array(s.utf8)
    return stride(from: 0, to: digits.count - 1, by: 2).compactMap {
        UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)
    }
}

/// An error as `err <place> <code> <reason>`.
func placed(_ error: HausError) -> String {
    "err \(error.path ?? "$") \(error.code.rawValue) \(error.message)"
}

/// The result of `body`, or its error placed.
func okOr(_ body: () throws(HausError) -> String) -> String {
    do throws(HausError) {
        return "ok " + (try body())
    } catch {
        return placed(error)
    }
}

/// The line to print instead of a result.
struct Line: Error {
    let text: String
}

/// The one value of a case's text, or the line reporting that it isn't one value.
func single(_ bytes: [UInt8]) -> Result<HausValue, Line> {
    do throws(HausError) {
        let values = try parseAll(bytes: bytes)
        return values.count == 1 ? .success(values[0]) : .failure(Line(text: "err $ - not a single value"))
    } catch {
        return .failure(Line(text: "err $ - not a single value: \(error)"))
    }
}

// ── std/time ────────────────────────────────────────────────────

func timeLine(_ line: String) -> String {
    let parts = line.split(separator: " ", maxSplits: 1)
    let bytes = parts.count == 2 ? unhex(parts[1]) : []
    guard let text = String(bytes: bytes, encoding: .utf8) else { return "err invalid UTF-8" }
    return (try? checkTime(String(parts[0]), text)) != nil ? "ok" : "no"
}

// ── schema files ────────────────────────────────────────────────

func checkLine(_ line: String) -> String {
    do throws(HausError) {
        _ = try HausSchema(bytes: unhex(line[...]))
        return "ok"
    } catch {
        return "err \(error.position?.line ?? 0) \(error.position?.column ?? 0) \(error.code.rawValue) \(error.message)"
    }
}

/// Every schema file of the directories (relative to the checkout), by
/// suite name, the file's name without `.schema.haus`: the schema, or why it
/// is rejected.
func schemas(_ dirs: [String]) -> [String: Result<HausSchema, HausError>] {
    var out: [String: Result<HausSchema, HausError>] = [:]
    for dir in dirs {
        let url = root.appendingPathComponent(dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where name.hasSuffix(".schema.haus") {
            guard let data = FileManager.default.contents(atPath: url.appendingPathComponent(name).path) else {
                fail("can't read \(dir)/\(name)")
            }
            out[String(name.dropLast(".schema.haus".count))] = Result { () throws(HausError) in
                try HausSchema(bytes: [UInt8](data))
            }
        }
    }
    return out
}

/// The result of a line `SUITE TYPE HEX`: `one` with the type it names and
/// the case's bytes, or the line to print instead.
func typed(
    _ line: String, _ suites: [String: Result<HausSchema, HausError>], _ one: (SchemaType, [UInt8]) -> String
) -> String {
    let parts = line.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return "crash bad line" }
    switch suites[String(parts[0])] {
    case nil: return "crash no schema \(parts[0])"
    case .failure(let error)?: return "err $ - the schema is rejected: \(error)"
    case .success(let schema)?:
        guard let type = try? schema.type(String(parts[1])) else { return "crash no type \(parts[0]).\(parts[1])" }
        return one(type, unhex(parts[2]))
    }
}

/// Decodes the case's value, and encodes what was decoded: its canonical form.
func roundtrip(_ type: SchemaType, _ bytes: [UInt8]) -> String {
    switch single(bytes) {
    case .failure(let line): return line.text
    case .success(let v):
        let decoded: HausValue
        do throws(HausError) {
            decoded = try type.decode(v)
        } catch {
            return placed(error)
        }
        do throws(HausError) {
            return "ok " + (try canonical(type.encode(decoded)))
        } catch {
            return "crash encoding failed: \(error)"
        }
    }
}

// ── JSON ────────────────────────────────────────────────────────

func jsonLine(_ mode: String) -> (String) -> String {
    let suites = schemas(["test-suite/schema", "fuzz/schema", "test-suite/json", "fuzz/json"])
    switch mode {
    case "write":
        return { line in typed(line, suites, writeJSON) }
    case "read":
        return { line in typed(line, suites, readJSON) }
    case "haus-json-write":
        return { line in
            switch single(unhex(line[...])) {
            case .failure(let line): line.text
            case .success(let v): okOr { () throws(HausError) in try toHausJSON(v) }
            }
        }
    case "haus-json-read":
        return { line in okOr { () throws(HausError) in try canonical(fromHausJSON(bytes: unhex(line[...]))) } }
    case "import":
        return { line in okOr { () throws(HausError) in try canonical(importJSON(bytes: unhex(line[...]))) } }
    default:
        fail("unknown JSON mode \(mode): write, read, haus-json-write, haus-json-read or import")
    }
}

/// Decodes the case's haus text with the type, and writes its schema-based JSON.
func writeJSON(_ type: SchemaType, _ bytes: [UInt8]) -> String {
    switch single(bytes) {
    case .failure(let line): line.text
    case .success(let v): okOr { () throws(HausError) in try type.toJSON(type.decode(v)) }
    }
}

/// Reads the case's schema-based JSON with the type, and encodes what was read.
func readJSON(_ type: SchemaType, _ bytes: [UInt8]) -> String {
    let read: HausValue
    do throws(HausError) {
        read = try type.fromJSON(bytes: bytes)
    } catch {
        return placed(error)
    }
    do throws(HausError) {
        return "ok " + (try canonical(type.encode(read)))
    } catch {
        return "crash encoding what was read failed: \(error)"
    }
}
