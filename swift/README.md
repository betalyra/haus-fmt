# haus for Swift

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** This package has the parser, the formatter, the stream reader, and the canonical form and hashing. Schemas, JSON and codecs are not there yet.

It follows the [specification](../spec/README.md): exact numbers, limits enforced while parsing, error positions in code points, and an error code from the catalogue on every error. It needs Swift 6.0 or later, runs on macOS 13, iOS 16 and Linux, and has no dependencies.

```swift
import Haus

let order = try parse(#"{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }"#)
if case .variant("Shipped", _)? = order["status"], case .string(let tracking)? = order["status"]?["tracking"] {
    print("shipped:", tracking) // DE-4711
}

if case .number(let n) = try parse("19.90") {
    print(n) // 19.90: exact, never a float
}

let values = try parseAll("Log { a: 1 },\nHeartbeat,\n") // a stream: every top-level value
```

Values are a `HausValue`, an enum of the six kinds of spec §1: `.number(HausNumber)`, `.string(String)`, `.bytes([UInt8])`, `.array([HausValue])`, `.record(HausRecord)` and `.variant(String, [HausValue])`. A `HausNumber` keeps its normalized literal (`0xFF` is `255`, `1E+05` is `1e5`, `19.90` stays `19.90`); `integer(as:)` gives an integer that fits a Swift integer type, and converting to a float is up to you. A `HausRecord` keeps its fields in source order, and is a collection of `(key, value)` pairs with a `subscript(key:)`. `Tag { … }` is a variant whose one argument is a record, the same value as `Tag({ … })`; `value["key"]` reads a field of a record or of such a payload. String, integer, array and dictionary literals make values: `["id": 7, "tags": ["a"], "status": .tag("Shipped")]`.

## Equality: code points, not canonical equivalence

`HausValue` is `Equatable` and `Hashable` by haus equality (spec §2): field order doesn't matter, `1.0` and `1` differ, and strings and record keys compare by their **code points**. Swift's own `String ==` compares by canonical equivalence, so `"café"` written with a precomposed `é` (NFC) and with `e` and a combining accent (NFD) are equal Swift strings, but different haus values and different record keys, with different canonical forms and hashes (spec §4):

```swift
let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
nfc == nfd                                   // true: Swift strings
HausValue.string(nfc) == .string(nfd)        // false: haus values
try parse(#"{ "\#(nfc)": 1, "\#(nfd)": 2 }"#) // two keys, not a duplicate
```

Compare the canonical forms of values by their bytes (`canonical(a).utf8.elementsEqual(canonical(b).utf8)`), or compare the values themselves.

## Errors

Every error is a `HausError` with a `code` (spec §17), a `message`, and for an error in text a `position`: a 1-based line and column, counted in code points. The functions throw it as a typed error:

```swift
do {
    _ = try parse("{ ok: true }")
} catch {
    print(error.code, error.position!) // booleanLiteral 1:7
}
```

`HausError.Code` is generated from the catalogue, [`spec/errors.haus`](../spec/errors.haus); its raw value is the code's name (`boolean-literal`), `hint` the usual fix and `error.docs` its documentation. `error.json` is the JSON form of spec §17:

```json
{"code":"payload-newline","message":"the payload of Heartbeat must start on its line: expected ',', found '{'",
 "line":2,"column":1,"expected":"','","found":"'{'",
 "hint":"Put the payload on the tag's line, or add a comma if they are two values.",
 "docs":"https://haus-fmt.org/docs/errors#payload-newline"}
```

## Limits

`parseAll(text, limits: Limits(maxDepth: 64))` sets limits (spec §7); the defaults are the spec's: depth 256, 1000 characters per number literal (and so 829 hex digits), exponents up to ±6144, 16 Mi characters per string, key, tag or byte string (counted on the value, after escapes; for a byte string, between the quotes), and 64 Mi characters per top-level value of a stream (`maxValueLength`, which only the stream reader applies: it bounds the reader's memory, while `parseAll` already holds the whole text).

`maxDepth` can be at most `Limits.maxSupportedDepth`, 1024; a larger limit is rejected with the code `unsupported-depth`. The parser doesn't recurse, but the writers, the canonical form, equality and releasing a value recurse once per level of nesting: in an optimized build each of them handles 1024 levels within 512 KiB of stack, the size of the threads of Swift's concurrency pool. A debug build needs several times more per level, and handles the default depth in 512 KiB.

Duplicate keys are found in linear time whatever the keys: small records are scanned, larger ones indexed with Swift's `Hasher`, which is seeded at random per process (unless `SWIFT_DETERMINISTIC_HASHING` is set).

## Streams

A `StreamReader` reads the values of a file or stream from chunks of UTF-8 (spec §6), holding one value at a time:

```swift
var reader = StreamReader(strict: true)
for try await chunk in socket {
    reader.push(chunk)
    while let value = try reader.next() { handle(value) }
}
reader.finish()
while let value = try reader.next() { handle(value) } // stream-truncated if the last value has no comma
```

`HausValues(chunks, strict: true)` is the same as an `AsyncSequence` over an `AsyncSequence` of byte chunks. Whatever the chunks, the reader gives what parsing the whole input gives, with the same error codes and positions. `strict` requires a comma after the last value, so that a stream cut off after a complete-looking value is an error.

## Formatting

`format(text, FormatOptions(layout: .pretty))` rewrites text in one of the three layouts of spec §11: `.pretty` keeps comments and blank lines, `.compact` writes one item per line, and `.minimised` drops the whitespace between tokens. Numbers, byte strings and `"…"` strings keep their spelling. `indent` (default 2) and `width` (default 80) are the only options. `hasComments(text)` tells a tool that rewrites files in place in the compact or minimised layout whether it would drop comments.

`stringify(value, options)` and `stringifyAll(values, options)` write values built in code: numbers normalized, byte strings in lowercase hex, strings with the fewest escapes, and a stream with a comma after every value. A value's `description` is its compact layout.

## Canonical form and hashing

```swift
let v = try parse(#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#)
let text = try canonical(v) // Order{id:255,total:19.90,"x-y":1e5}
let digest = try hash(v)    // SHA-256 of the canonical form, 64 hex digits
```

`hashAll(values)` hashes a whole file; the items of a stream are hashed one by one with `hash`. The hash is unkeyed: don't publish the hash of a document with private content (spec §9).

`hash` and `hashAll` use CryptoKit, so they exist where CryptoKit does (Apple platforms). On Linux, `canonical` gives the bytes to hash with a SHA-256 of your choice.

## Development

```sh
swift test                                                   # the conformance suite (../test-suite) and the package's tests
HAUS_WRITE_ERROR_CODES=1 swift test --filter ErrorCodeTests  # Sources/Haus/ErrorCodes.swift from spec/errors.haus
swift format -i --configuration .swift-format -r Sources Tests ../fuzz/swift-runner
```

The differential fuzzers (`../fuzz`) run the Swift parser, stream reader, canonical form and formatters against the other bindings and the Lean reference parser, through [`../fuzz/swift-runner`](../fuzz/swift-runner).

Byte scanning lives in [`Sources/Haus/Scan.swift`](Sources/Haus/Scan.swift), shared by the parser and the writers: the classes of bytes, the characters a string can't hold raw (named code-point ranges and the UTF-8 lead bytes they start with), and plain ASCII skipped eight bytes at a time.
