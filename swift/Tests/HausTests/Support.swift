import Foundation
import Haus

/// The root of the repository: the conformance suite and the spec are there.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The shared conformance suite (test-suite/README.md).
let suite = repository.appendingPathComponent("test-suite")

/// The bytes of a file of the repository, byte for byte.
func read(_ url: URL) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: url.path) else { fatalError("can't read \(url.path)") }
    return [UInt8](data)
}

/// The text of a file of the repository.
func readText(_ url: URL) -> String { String(decoding: read(url), as: UTF8.self) }

/// The names (without extension) of the files `dir/*ext`, sorted.
func files(_ dir: URL, _ ext: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(ext) }.map { String($0.dropLast(ext.count)) }.sorted()
}

/// Whether the file exists.
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// ── a JSON reader for the suite's expected values ─────────────────

/// JSON, as read for the suite: objects keep their members in order, and
/// strings their code points (Foundation's reader keys a dictionary by
/// Swift strings, which equal NFC and NFD). Unlike `importJSON`, it has no
/// depth limit: the `.jsonl` of a value 256 levels deep has more JSON levels.
/// It recurses once per level, so deep JSON goes on a big stack
/// (``suiteStack``).
indirect enum JSON {
    case string(String)
    /// A number, or `true`, `false` or `null`, as written.
    case number(String)
    case array([JSON])
    case object([(String, JSON)])

    subscript(member: String) -> JSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0.utf8.elementsEqual(member.utf8) }?.1
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Reads JSON of strings, arrays and objects (all the suite has).
    static func parse(_ text: String) -> JSON {
        var reader = JSONReader(bytes: Array(text.utf8))
        return reader.value()
    }
}

private struct JSONReader {
    let bytes: [UInt8]
    var i = 0

    mutating func skipSpace() {
        while i < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    mutating func expect(_ c: Character) {
        skipSpace()
        precondition(bytes[i] == c.asciiValue!, "expected \(c) at \(i)")
        i += 1
    }

    mutating func value() -> JSON {
        skipSpace()
        switch bytes[i] {
        case UInt8(ascii: "\""): return .string(string())
        case UInt8(ascii: "["):
            i += 1
            var items: [JSON] = []
            skipSpace()
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(items)
            }
            while true {
                items.append(value())
                skipSpace()
                i += 1
                if bytes[i - 1] == UInt8(ascii: "]") { return .array(items) }
            }
        case UInt8(ascii: "{"):
            i += 1
            var members: [(String, JSON)] = []
            skipSpace()
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(members)
            }
            while true {
                skipSpace()
                let key = string()
                expect(":")
                members.append((key, value()))
                skipSpace()
                i += 1
                if bytes[i - 1] == UInt8(ascii: "}") { return .object(members) }
            }
        default:
            // Numbers: the suite writes the haus envelope's version, `1`.
            let start = i
            while i < bytes.count && !",]} \n".utf8.contains(bytes[i]) { i += 1 }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }
    }

    mutating func hex4() -> UInt32 {
        let digits = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
        i += 4
        return UInt32(digits, radix: 16)!
    }

    mutating func string() -> String {
        expect("\"")
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
            raw = []
        }
        while bytes[i] != UInt8(ascii: "\"") {
            guard bytes[i] == UInt8(ascii: "\\") else {
                raw.append(bytes[i])
                i += 1
                continue
            }
            flush()
            let c = bytes[i + 1]
            i += 2
            switch c {
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "b"): scalars.append("\u{8}")
            case UInt8(ascii: "f"): scalars.append("\u{C}")
            case UInt8(ascii: "u"):
                var code = hex4()
                if (0xD800...0xDBFF).contains(code) {
                    i += 2  // \u of the low surrogate
                    code = 0x10000 + (code - 0xD800) << 10 + (hex4() - 0xDC00)
                }
                scalars.append(Unicode.Scalar(code)!)
            default: scalars.append(Unicode.Scalar(c))
            }
        }
        flush()
        i += 1
        return String(scalars)
    }
}

/// Whether two JSON values are the same data: member order doesn't matter,
/// strings compare by code points, numbers by their text.
func sameData(_ a: JSON, _ b: JSON) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)), (.number(let x), .number(let y)):
        return x.utf8.elementsEqual(y.utf8)
    case (.array(let xs), .array(let ys)):
        return xs.count == ys.count && zip(xs, ys).allSatisfy { sameData($0, $1) }
    case (.object(let xs), .object(let ys)):
        let byKey = { (members: [(String, JSON)]) in members.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) } }
        return xs.count == ys.count
            && zip(byKey(xs), byKey(ys)).allSatisfy { $0.0.utf8.elementsEqual($1.0.utf8) && sameData($0.1, $1.1) }
    default:
        return false
    }
}

/// The stack, in KiB, for reading and comparing a suite file's JSON: the
/// suite's JSON reader and ``sameData(_:_:)`` recurse once per JSON level,
/// and `valid/depth-limit.jsonl` has more than 500 (a test thread has 512 KiB).
let suiteStack = 64 << 10

/// A value of the suite's JSON encoding (test-suite/README.md, "Expected output encoding").
func fromSuiteJSON(_ j: JSON) throws -> HausValue {
    switch j {
    case .string(let s): return .string(s)
    case .number: break
    case .array(let items): return .array(try items.map(fromSuiteJSON))
    case .object:
        if case .object(let fields)? = j["_rec"] {
            return .record(try HausRecord(fields.map { (key: $0, value: try fromSuiteJSON($1)) }))
        }
        if let n = j["_num"]?.string { return .number(try HausNumber(n)) }
        if let hex = j["_bytes"]?.string {
            let digits = Array(hex.utf8)
            return .bytes(
                stride(from: 0, to: digits.count, by: 2).map {
                    UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
                })
        }
        if let name = j["_tag"]?.string {
            let tag = try HausTag(name)
            guard case .array(let args)? = j["_args"] else { return .variant(tag, []) }
            return .variant(tag, try args.map(fromSuiteJSON))
        }
    }
    fatalError("not suite JSON")
}

/// Runs `body` on a thread with a stack of the size given.
func onStack<T: Sendable>(kibibytes: Int, _ body: @escaping @Sendable () throws -> T) throws -> T {
    nonisolated(unsafe) var result: Result<T, any Error>?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result = Result(catching: body)
        done.signal()
    }
    thread.stackSize = kibibytes << 10
    thread.start()
    done.wait()
    return try result!.get()
}
