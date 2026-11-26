// The Swift runner of the differential fuzzers (fuzz/README.md): it reads
// DIR/00000.haus … DIR/{N-1}.haus and prints one line for each.
//
//   swift-runner DIR N                 `ok <values>` in the test suite's JSON encoding, or
//                                      `err <line> <column> <code> <reason>`
//   swift-runner --stream DIR N        the same through the stream reader, the input in chunks
//   swift-runner --canonical DIR N     `ok` and the canonical form of each value, a JSON array of strings
//   swift-runner --format STYLE [--indent N] [--width N] [--stream] DIR N
//                                      `ok` and `format`'s output as a JSON string
//   swift-runner --write STYLE [--indent N] [--width N] [--stream] DIR N
//                                      `ok {"values": [...], "file": ...}`: each value written
//                                      alone by `stringify` (without its line break), and all of
//                                      them by `stringifyAll`
//   (`--stream` after the style: the file is a stream, spec §11, so `format`
//   and `stringifyAll` put a comma after a single item too)
//
// and the modes that read a FILE of lines (Lines.swift): --time, --schema,
// --schema-check and --json MODE.
import Foundation
import Haus

let usage =
    "usage: swift-runner [--stream | --canonical | --format STYLE [--indent N] [--width N] [--stream]"
    + " | --write STYLE [--indent N] [--width N] [--stream]] DIR N"
    + " | --time FILE | --schema FILE | --schema-check FILE | --json MODE FILE"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// ── JSON ────────────────────────────────────────────────────────

/// A JSON string: quotes, backslashes and control characters escaped.
func json(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where c.value < 0x20 || (0x7F...0x9F).contains(c.value):
            let hex = String(c.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

func json(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }

/// A value in the test suite's JSON encoding (test-suite/README.md), as the runners write it.
func suiteJSON(_ v: HausValue) -> String {
    switch v {
    case .string(let s): json(s)
    case .number(let n): #"{"num":\#(json(n.literal))}"#
    case .bytes(let b): #"{"bytes":"\#(b.map { String(format: "%02x", $0) }.joined())"}"#
    case .array(let items): json(items.map(suiteJSON))
    case .record(let r): #"{"rec":{\#(r.map { json($0.key) + ":" + suiteJSON($0.value) }.joined(separator: ","))}}"#
    case .variant(let tag, let args) where args.isEmpty: #"{"tag":\#(json(tag.name))}"#
    case .variant(let tag, let args): #"{"tag":\#(json(tag.name)),"args":\#(json(args.map(suiteJSON)))}"#
    // The runners compare what was decoded, so a secret is compared by its value.
    case .secret(let s): suiteJSON(s.reveal())
    }
}

// ── modes ───────────────────────────────────────────────────────

/// One line: the result of `body`, or the error it threw.
func line(_ body: () throws(HausError) -> String) -> String {
    do {
        return try "ok " + body()
    } catch {
        let message = error.message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "err \(error.position?.line ?? 0) \(error.position?.column ?? 0) \(error.code.rawValue) \(message)"
    }
}

/// The pieces of case `i`, the same in every runner: piece k has size
/// sizes[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8 sequences.
func chunks(_ bytes: [UInt8], _ i: Int) -> [ArraySlice<UInt8>] {
    let sizes = [1, 2, 3, 5, 8, 13, 64]
    var out: [ArraySlice<UInt8>] = []
    var at = 0
    while at < bytes.count {
        let end = min(bytes.count, at + sizes[(i + out.count) % sizes.count])
        out.append(bytes[at..<end])
        at = end
    }
    return out
}

func streamed(_ bytes: [UInt8], _ i: Int) throws(HausError) -> [HausValue] {
    var reader = StreamReader()
    var values: [HausValue] = []
    for chunk in chunks(bytes, i) {
        reader.push(chunk)
        while let v = try reader.next() { values.append(v) }
    }
    reader.finish()
    while let v = try reader.next() { values.append(v) }
    return values
}

/// `STYLE [--indent N] [--width N] [--stream]`; `--stream`: the file is a
/// stream (spec §11), a comma after a single item too.
func formatOptions(_ flags: ArraySlice<String>) -> FormatOptions {
    guard let style = flags.first, let layout = Layout(rawValue: style) else { fail(usage) }
    var (indent, width, stream) = (2, 80, false)
    var rest = flags.dropFirst()
    while let flag = rest.first {
        if flag == "--stream" {
            stream = true
            rest = rest.dropFirst()
            continue
        }
        switch (flag, rest.dropFirst().first.flatMap { Int($0) }) {
        case ("--indent", let n?): indent = n
        case ("--width", let n?): width = n
        default: fail(usage)
        }
        rest = rest.dropFirst(2)
    }
    guard let options = try? FormatOptions(layout: layout, indent: indent, width: width, stream: stream) else {
        fail(usage)
    }
    return options
}

/// The result line of a case: its bytes and its number.
func mode(_ flags: ArraySlice<String>) -> ([UInt8], Int) -> String {
    switch flags.first {
    case nil:
        return { bytes, _ in line { () throws(HausError) in json(try parseAll(bytes: bytes).map(suiteJSON)) } }
    case "--stream" where flags.count == 1:
        return { bytes, i in line { () throws(HausError) in json(try streamed(bytes, i).map(suiteJSON)) } }
    case "--canonical" where flags.count == 1:
        return { bytes, _ in
            line { () throws(HausError) in
                var forms: [String] = []
                for v in try parseAll(bytes: bytes) { forms.append(json(try canonical(v))) }
                return json(forms)
            }
        }
    case "--format":
        let options = formatOptions(flags.dropFirst())
        return { bytes, _ in
            line { () throws(HausError) in
                // Text that isn't UTF-8 is rejected by the parser, as in the other runners.
                let text = String(decoding: bytes, as: UTF8.self)
                if !text.utf8.elementsEqual(bytes) { _ = try parseAll(bytes: bytes) }
                return json(try format(text, options))
            }
        }
    case "--write":
        let options = formatOptions(flags.dropFirst())
        return { bytes, _ in
            line { () throws(HausError) in
                let values = try parseAll(bytes: bytes)
                var written: [String] = []
                for v in values { written.append(json(String(try stringify(v, options).dropLast()))) }
                return #"{"values":\#(json(written)),"file":\#(json(try stringifyAll(values, options)))}"#
            }
        }
    default:
        fail(usage)
    }
}

let args = CommandLine.arguments.dropFirst()
if let (file, one) = lineMode(args) {
    runLines(file, one)
    exit(0)
}
guard args.count >= 2, let count = Int(args.last!) else { fail(usage) }
let dir = URL(fileURLWithPath: args[args.endIndex - 2])
let run = mode(args.dropLast(2))
var out = ""
for i in 0..<count {
    let file = dir.appendingPathComponent(String(format: "%05d.haus", i))
    guard let data = FileManager.default.contents(atPath: file.path) else { fail("can't read \(file.path)") }
    out += run([UInt8](data), i) + "\n"
    if out.utf8.count > 1 << 20 {
        FileHandle.standardOutput.write(Data(out.utf8))
        out = ""
    }
}
FileHandle.standardOutput.write(Data(out.utf8))
