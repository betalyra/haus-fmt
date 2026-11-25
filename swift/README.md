# haus for Swift

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** This package has the parser, the formatter, the stream reader, the canonical form and hashing, the three JSON forms, schemas with their packages, and typed decoding into Swift types with Codable.

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

Values are a `HausValue`, an enum of the six kinds of spec §1: `.number(HausNumber)`, `.string(String)`, `.bytes([UInt8])`, `.array([HausValue])`, `.record(HausRecord)` and `.variant(HausTag, [HausValue])`. A `HausNumber` keeps its normalized literal (`0xFF` is `255`, `1E+05` is `1e5`, `19.90` stays `19.90`); `integer(as:)` gives an integer that fits a Swift integer type, and converting to a float is up to you. A `HausRecord` keeps its fields in source order, and is a collection of `(key, value)` pairs with a `subscript(key:)`. `Tag { … }` is a variant whose one argument is a record, the same value as `Tag({ … })`; `value["key"]` reads a field of a record or of such a payload. String, integer, array and dictionary literals make values: `["id": 7, "tags": ["a"], "status": .tag("Shipped")]`.

Values are checked when they are built (spec §11), so every `HausValue` is a haus value: `try HausTag(name)` fails with `invalid-tag` unless `name` is `[A-Z][A-Za-z0-9_]*`, `try HausNumber("01")` with `invalid-number`, and `try HausRecord(fields)` with `duplicate-key`. A string literal is a tag too (`.tag("Shipped")`, `case .variant("Shipped", _)`), checked when it is made: a literal that isn't a tag stops the program, as a mistake in the code; use `HausTag(_:)` for tags from data. Constructors apply no limits: `HausNumber("1e99999")` is a number, and the writers reject what is over their limits.

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

`maxDepth` can be at most `Limits.maxSupportedDepth`, 256, the spec's minimum and the default; a larger limit is rejected with the code `unsupported-depth`. The parser, the JSON reader, the one-line writers (compact, minimised, canonical form, self-describing JSON), the value checker and equality don't recurse. The pretty writer, decoding with a schema, the Codable coders and releasing a value recurse once per level, and each handles the deepest value within 512 KiB of stack, the size of the threads of Swift's concurrency pool, in a debug build too (self-describing JSON takes up to 4·d + 2 JSON levels for d levels, spec §16). Swift releases nested arrays recursively, so a value built in code much deeper than that (about 100,000 levels on an 8 MiB stack, in a debug build) would overflow the stack when it is released: `value.release()` releases a value of any depth a level at a time, without recursion (its parts shared with other values are left to them).

The writers of values (`stringify` and `stringifyAll` in every layout, `toHausJSON`, `toHausJSONLines`, schema-based JSON) check every limit a value built in code can break (spec §11): the depth (a record payload `Tag { … }` is one level, an empty container a level), the length of each string, key, tag and byte string (two characters a byte), the number and exponent limits, and `maxNodes`, the values written for one top-level value (default 64 Mi). Swift's arrays share their storage, so a value small in memory can hold one array many times, and be very large written out: above the limit a writer fails with `too-many-nodes`. `checkValue(value, limits:)` checks a value as the writers do. `canonical`, `hash` and `hashAll` take `limits:` too, and apply only `maxNodes`: every other value has a canonical form, however deep or long.

Duplicate keys are found in linear time whatever the keys: the keys of a small record are compared only when a cheap sketch of them (length, first and last byte) matches, those of a larger one are chained by a cheap hash of their length and first and last eight bytes, and a chain that grows long, as only keys made to collide do, switches the record to Swift's `Hasher`, which is seeded at random per process (unless `SWIFT_DETERMINISTIC_HASHING` is set).

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

## JSON

The three JSON forms of spec §16, with numbers kept exact:

```swift
let v = try importJSON(#"{"total": 19.90, "paid": true}"#)  // { total: 19.90, paid: True }: any JSON (§16.1)
let text = try toHausJSON(v)                                 // {"_haus":1,"_value":{"_rec":{…}}}: every haus value (§16.2)
let back = try fromHausJSON(text)                            // the same value
```

Readers take I-JSON: duplicate member names are `duplicate-key`, unpaired surrogates `unpaired-surrogate`, and errors in the text have their position, errors in the form their place (`$._value._rec.price._num`). `toHausJSONLines`, `fromHausJSONLines` and `importJSONLines` do JSON Lines, and a `JSONLinesReader(.selfDescribing)` reads it from chunks, one line at a time. Schema-based JSON, the JSON a JSON consumer expects, goes with a type: `type.toJSON(value)` and `type.fromJSON(text)` (below).

## Schemas

`HausSchema` reads a schema file (spec §14) with its imports: `std/time`, files next to it, and schema packages (§13.3), given explicitly with a `PackageLocator`: `.explicit(packages:folders:)` takes directories on disk, `.explicit(in:packages:folders:)` a read-only file tree, such as a SwiftPM resource bundle (`Bundle.module`, so a Swift package can publish schema packages as resources) or a directory URL, and `a.or(b)` puts two together. A tree follows no links. Like every implementation outside the npm ecosystem, this one never looks in `node_modules`. Every rule of §13.3 and §14 is checked when it loads, so a type decodes in time linear in the input.

Relative imports stay inside the build's root (`import-outside-root`): by default the directory of the schema file, or `Options.root`, a directory that contains it, such as a repository's schema folder (a relative one is from the schema file's directory). The schema file and the root are resolved to real paths once, and may be reached through links; a relative import follows none: each name on its path is listed by its directory with that spelling, also on file systems that ignore case, and a link anywhere on it is `import-not-found`. Every file read is a regular file, opened without following a link at its last name and without blocking, and checked on the opened file. Messages show paths relative to the root (`../vendor/money` for a package outside it).

```swift
let packages = try PackageLocator.explicit(in: Bundle.module, folders: ["schemas"])
let schema = try HausSchema(contentsOf: "order.schema.haus", options: .init(packages: packages, root: "."))
let order = try schema.type("Order")
let decoded = try order.decode(try parse(text))  // the value an encoder writes back (§15)
let json = try order.toJSON(decoded)             // schema-based JSON (§16.3)
```

Errors have a code and the place of the failing value, `$.items[2].price`. `checkTime("Date", "2026-02-30")` checks a std/time text by its profile, and `Secret<T>` holds a value that is never printed. Decoding into a `HausValue` gives a `Secret` type's value as `.secret(Secret<HausValue>)`, hidden: `stringify`, `canonical` and hashing refuse it (`cannot-encode`), and `SchemaType.encode` writes it in full. A `Secret` is written only by the schema's encoder: Foundation's `JSONEncoder` fails on it.

### Swift types

Types that are `Codable` decode with a schema type and encode back; the schema checks the value first, so its errors keep their codes and places:

```swift
struct UserId: Codable { let id: String }                  // UserId("usr_ada"): one argument, one field
enum Status: Codable { case pending, shipped(tracking: String), cancelled }
struct Order: Codable { let id: Int; let customer: UserId; let status: Status }

let order = try schema.type("Order").decode(Order.self, fromText: text)
let value = try schema.type("Order").encode(order)       // a HausValue the type accepts
```

Records are structs (or `[String: V]` for a `Map`), variants enums whose cases are the tags with a lowercase first letter (`Shipped` is `shipped`, `HTTPError` `httpError`), with the fields of a record case as labelled values and positional arguments as `_0`, `_1`. A payload-less closed variant can also be a `String` raw-value enum. `Maybe` is an `Optional`, integers any fixed-width integer (range checked, `out-of-range`), `Float64` a `Double`, `Decimal` a `HausNumber` (exact), `Bytes` `[UInt8]`, a std/time value its text, `Any` a `HausValue`. An enum with a case `unknown(HausValue)` keeps the tags an open variant doesn't list; without it, they are `unknown-tag`. A `HausCodec` chooses another host type for a named type by its id (§13.4), such as Foundation's `Date` for `std/time#Date`; an error of its `hausBase` when encoding is `cannot-encode`. Its `HausBase` decides what it gets for a part with a codec of its own: that codec's Swift value, or, with the part's base type, the value the schema decoded, which a codec that checks a profile's rule should use.

[`Examples/quickstart`](Examples/quickstart/main.swift) and [`Examples/order`](Examples/order/main.swift) do the same as the other bindings' examples, on the same files: `swift run quickstart`, `swift run order`.

## Canonical form and hashing

```swift
let v = try parse(#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#)
let text = try canonical(v) // Order{id:255,total:19.90,"x-y":1e5}
let digest = try hash(v)    // SHA-256 of the canonical form, 64 hex digits
```

`hashAll(values)` hashes a whole file; the items of a stream are hashed one by one with `hash`. The hash is unkeyed: don't publish the hash of a document with private content (spec §9). Every value has a canonical form: the three fail only for a value whose arrays share each other so much that it would write more than `limits.maxNodes` values (`too-many-nodes`, spec §12), and take no other limit.

`hash` and `hashAll` use CryptoKit, so they exist where CryptoKit does (Apple platforms). On Linux, `canonical` gives the bytes to hash with a SHA-256 of your choice.

## Concurrency

The package builds in the Swift 6 language mode, and the types you share are `Sendable`: values, `Limits`, `FormatOptions`, `HausError`, `HausSchema` and `SchemaType`. A schema doesn't change once built, so tasks can share one; a `StreamReader` is a value, one per stream.

## Development

```sh
swift test                                                   # the conformance suite (../test-suite) and the package's tests
HAUS_WRITE_ERROR_CODES=1 swift test --filter ErrorCodeTests  # Sources/Haus/ErrorCodes.swift from spec/errors.haus
swift format -i --configuration .swift-format -r Sources Tests ../fuzz/swift-runner
```

The differential fuzzers (`../fuzz`) run the Swift parser, stream reader, canonical form and formatters against the other bindings and the Lean reference parser, through [`../fuzz/swift-runner`](../fuzz/swift-runner).

Byte scanning lives in [`Sources/Haus/Scan.swift`](Sources/Haus/Scan.swift), shared by the parser and the writers: the classes of bytes, the characters a string can't hold raw (named code-point ranges and the UTF-8 lead bytes they start with), plain ASCII skipped eight bytes at a time, and the sketch, cheap hash and comparison of record keys. The writers of one-line text (compact, minimised, canonical form, self-describing JSON) and the value checker share one walk without recursion, [`Sources/Haus/Walk.swift`](Sources/Haus/Walk.swift), each with its own spelling.
