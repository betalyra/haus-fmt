# haus specification — draft 0.1

The syntax is defined in [`grammar.ebnf`](grammar.ebnf). This document defines
what the syntax means and the rules every implementation must follow. The
standard types are in [`prelude.schema.haus`](prelude.schema.haus) and [`std/`](std) (§13), and
[`../test-suite`](../test-suite) holds the conformance tests.

"MUST", "SHOULD" and "MAY" are used as in RFC 2119.

## 1. Data model

A **value** is one of:

| Kind | Example | Notes |
|---|---|---|
| number | `19.90`, `-1e10`, `0xFF` | exact decimal, see §3 |
| string | `"text"`, `"""…"""` | a sequence of Unicode code points, see §4 |
| bytes | `x"0b34ff"`, `x"9f86d081 884c7d65"` | a sequence of bytes: two hex digits per byte, spaces and tabs between bytes, on one line |
| array | `[1, 2]` | ordered |
| record | `{ id: 1, "x-y": 2 }` | string keys, no duplicates |
| variant | `None`, `Some(1)`, `Circle { r: 1 }` | a tag plus zero or more argument values |

There is no `null` and there are no booleans in the syntax. `True`, `False` and
`None` are ordinary tags whose meaning is fixed by the prelude.

A **file** is a sequence of zero or more values separated by commas (§6). A
single document is a sequence of one.

**Absence is not a value.** A record either contains a field or it doesn't.
`{ }` and `{ x: None }` are different values, and nothing converts one into
the other. Two separate things exist, each with exactly one spelling:

| Schema | Field present | Field missing |
|---|---|---|
| `x: T` | `x: <T value>` | error |
| `x?: T` (optional field) | `x: <T value>` | allowed: "not given" |
| `x: Maybe T` | `x: None` or `x: Some(<T value>)`, always written | error |
| `x?: Maybe T` | `x: None` or `x: Some(…)` | allowed: "not given" |

- An **optional field** (`?`) is a property of the record: the key may be missing. It is never `None`, and decoders MUST keep "missing" and `None` apart (a missing key, not a `None` value, in the decoded result).
- **`Maybe a`** is an ordinary variant, `< None | Some a >`. Its values are always written; a bare `32` is not `Some(32)`.
- `x?: Maybe T` has three states: not given, `None`, `Some(…)`. That is how a partial update says "leave it", "clear it" and "set it" (§1.1).
- The parser never invents values for missing fields, and neither does any decoder: what "not given" means (a default, "unchanged", "unknown") is up to the application.

Bindings MUST represent a missing optional field and `None` differently in their language (in TypeScript: a missing key and `{ _tag: "None" }`), so the two can't be confused when encoding.

### 1.1 Partial updates

A large document is updated by sending only what changes: a record of the same shape whose fields are optional.

```haus
// type UserUpdate = { name?: String, nickname?: Maybe String, address?: AddressUpdate }
{ nickname: None, address: { city: "Paris" } }
```

`nickname` is cleared, `address.city` is set, everything else is not given and stays as it is. Updates that a sparse record can't express (adding one element to an array, renaming) are written as a list of change variants, e.g. `changes: [AddRole(Admin), Rename { from: "a", to: "b" }]`.

## 2. Equality

Two values are equal when they have the same kind and:

- **numbers:** the normalized literals are equal. Normalizing removes digit separators, writes the exponent as `e` followed by its value (no `+`, no leading zeros, no `-` on zero), and converts hex and binary literals to decimal integers, keeping the sign (`-0x0` is `-0`, as `-0` is). So `1_000` = `1000`, `0xFF` = `255` and `1E+05` = `1e5`, but `1.0` ≠ `1` and `1e2` ≠ `100`: scale and notation are part of the value. Numeric equality ("is 1.0 the same amount as 1?") belongs to the schema or the application.
- **strings:** the code point sequences are identical. There is no Unicode normalization (§4).
- **bytes:** the byte sequences are identical. Case and spacing in the literal don't matter (`x"0B 34"` = `x"0b34"`).
- **bytes vs. other kinds:** a byte string is never equal to a string or an array of numbers.
- **arrays:** the same length, and the elements are pairwise equal.
- **records:** the same set of keys, and the values for each key are equal. Field order doesn't matter.
- **variants:** the same tag, and the arguments are pairwise equal. `Tag { … }` and `Tag({ … })` are the same value.

## 3. Numbers

- **Precision:** a number literal denotes an exact decimal. Parsers MUST keep it without loss, e.g. as the normalized literal text. Converting it to a binary float is a decoding decision made by the schema (`Float64`), never by the parser.
- **Scale:** encoders MUST keep the scale of a decimal: a `Decimal` decoded from `19.90` is written back as `19.90`. Library formatters often drop trailing zeros (Effect's `BigDecimal.format` writes `19.9`), so implementations write the literal themselves.
- **Native equality:** a language's decimal type may ignore scale when comparing (Effect `BigDecimal`, Java `BigDecimal.compareTo`, Python `Decimal` all treat `19.90` and `19.9` as equal), while haus doesn't (§2). Use haus equality, not the native one, for hashing and deduplication.
- **Without a schema:** a decoder that turns values into native types without a schema MUST NOT lose precision, and MUST NOT reject a number for its size within the limits (§7). Every integer becomes an arbitrary-size integer type (`bigint` in JavaScript), and every other number an exact decimal or its literal text, never a rounded binary float. A decoder MUST NOT choose the type by looking at the data, such as a JavaScript `number` for a field whose integers all fit one: types must not depend on the document, and a stream reader can't look ahead at later values.
- **`Int`:** decodes to an arbitrary-size integer in every binding. For a native fixed-size integer, the schema says `Int32`, `Int64` and so on, and a value out of range is an error.
- **NaN and infinities:** there are no `NaN` or infinity literals. The prelude tags `NaN`, `Infinity` and `NegInfinity` are accepted where the schema says `Float32` or `Float64`. A finite literal too large for the float type is an error, not an infinity (§15).
- **Limits:** a number literal is at most 1000 characters, a hex literal at most 829 hex digits, and an exponent at most ±6144 (§7). So every integer has a decimal form of at most 1000 characters.

## 4. Strings and Unicode

- **Encoding:** input is UTF-8. Invalid UTF-8 MUST be rejected. A leading byte order mark is ignored.
- **Escapes:** `\"`, `\\`, `\n`, `\r`, `\t` and `\u{1–6 hex digits}`. A `\u{…}` escape MUST denote a Unicode scalar value, so surrogates are rejected.
- **Block strings** hold text over several lines. The opening `"""` ends its line (only spaces and tabs may follow it), and the closing `"""` stands on a line of its own, after only spaces and tabs: they are the *indent*. Every line in between is a content line:
  - a line that starts with the indent loses it, and keeps everything after it, spaces and tabs included;
  - a line of only spaces and tabs that doesn't start with the indent (it is shorter, or uses other blanks) is an empty line;
  - any other line is an error.

  The content lines are joined with line feeds (a CR LF ends a line like a LF); the line break before the closing `"""` is not part of the value. Escapes are processed after the indent is removed, so `\n` in a block string is a line feed, and a quote followed by two more quotes must be escaped (`\"""`). Spaces and tabs at the end of a content line are part of the value; editors that trim them change it, which is why the formatter never ends a line with one (§11).

  ```haus
  note: """
    Dear Ada,
      thank you.
    """,
  ```
  is the string `"Dear Ada,\n  thank you."`.
- **Raw control characters:** the raw control characters U+0000–U+001F, U+007F (DEL) and U+0080–U+009F (C1) MUST NOT appear anywhere in the input, except tab and line breaks (LF, CR LF) where whitespace, block strings and comments allow them. A carriage return is only allowed directly before a line feed. Control characters can rewrite what a terminal displays (ESC and CSI sequences) or truncate text (NUL), so a file could show different content from what it contains. Inside strings, write them as escapes, e.g. `\u{1B}`.
- **Which error.** A raw control character in a string, block string or comment is `control-character`, and so is a carriage return in a `"…"` string, also one directly before a line feed; a raw line feed in a `"…"` string is `string-line-break`. A carriage return not followed by a line feed in whitespace or a comment is `lone-carriage-return`. Outside strings and comments a control or bidi character is not a token, so the error is the one for that place: `expected-value` where a value is expected, `expected-key` where a key is, `missing-comma` after a value.
- **Bidirectional controls:** the raw characters U+202A–U+202E and U+2066–U+2069 MUST NOT appear anywhere in the input, including strings, block strings and comments. They can make source text display differently from what is parsed ("Trojan Source"). Inside strings, write them as escapes, e.g. `\u{202E}`.
- **Key comparison:** keys are compared by code point, with **no normalization**. `"café"` (NFC) and `"café"` (NFD) are different keys. Producers that need normalized keys must normalize before writing.
- **NUL characters:** `\u{0}` is allowed. Consumers that pass strings to C APIs must handle embedded NUL characters.
- **Identifiers:** bare keys and tags are ASCII (`[a-z_][A-Za-z0-9_]*` for keys, `[A-Z][A-Za-z0-9_]*` for tags). Any other key must be quoted.

## 5. Variants

- **Payload placement:** a variant's payload MUST start on the same line as its tag; only spaces and tabs may come between them. `Circle { r: 1 }` and `Point (1, 2)` are valid. A line break or comment between the tag and its payload is an error, because a forgotten comma could otherwise silently change the meaning.
- **Positional arguments:** `Point(1, 2)` has two positional arguments. A decoder that maps them to named fields MUST do so only where the schema declares the payload positional (for example `< Point Float64 Float64 >`, `h.Tuple`, or `Haus.Positional` in the Effect adapter). Otherwise reordering schema fields would silently swap values.

## 6. Streams

- **Separators:** top-level values are separated by commas, and a trailing comma is allowed. Writers of streams SHOULD put a comma after every value, including the last. Then appending to a file, `tail -f` and concatenating files all produce valid streams, and a reader knows a value is complete when it sees the comma.
- **Truncation:** a cut-off last value can look valid, e.g. `100` instead of `1000`. Readers of network streams SHOULD offer a strict mode that requires the comma after the last value and reports a truncated stream otherwise.
- **One value too many:** a reader expecting a single document MUST reject a sequence of two or more values.

## 7. Limits

Implementations MUST enforce limits while parsing and MUST let users configure them. With the default limits, they MUST accept every input that stays within them:

| Limit | Default |
|---|---|
| nesting depth (records, arrays, payloads) | 256 |
| characters in one number literal | 1000 |
| hex digits in one hex literal (`_` not counted) | 829: derived from the number limit *n* as the largest *h* with 16<sup>*h*</sup> ≤ 10<sup>*n*−1</sup>, so that every integer's decimal form, sign included, fits in *n* characters |
| absolute exponent | 6144 |
| characters in one string (its value, after escapes and a block string's indent are processed), record key or tag, or between the quotes of a byte string | 16 Mi (16,777,216) |
| characters in one top-level value of a stream | 64 Mi (67,108,864) |

A stream reader counts a value's characters from the previous top-level comma (or the start of the stream, after a byte order mark) up to the next one: whitespace and comments before the value count, the commas don't. A value of exactly the limit is accepted. This limit applies to stream readers only, which hold one value at a time while they read: it bounds their memory. A parser given the whole text already holds it, and doesn't apply this limit (all the others apply). So a file with one value larger than the limit parses as a whole and fails in a stream reader with `value-too-long`; a stream reader that must read such files needs a larger limit.

Nesting depth is counted on the text as written, since it is checked while parsing: each record, array and parenthesized payload `Tag( … )` is one level, and so is a record payload written without parentheses, `Tag { … }`. A value outside any of them, like `1`, is at depth 0. So `Some(1)`, `[1]` and `Some { a: 1 }` need depth 1, while `Some({ a: 1 })`, `Some([])` and `A(B(1))` need 2, although `Some({ a: 1 })` and `Some { a: 1 }` are the same value. Writers and checks of values built in code count a record payload as one level, the shorter spelling, which is also the one the canonical form uses (§12), and count an empty record, array or payload as a level as parsing does, so a value built in code and the same value parsed have the same depth.

A binding whose parser, decoder or encoder uses the call stack MAY support only a bounded nesting depth, of at least the default (256). It MUST document that maximum, and MUST reject a larger configured depth when the limits are set, with an error that names the maximum, rather than overflow its stack on deep input.

Parsing time MUST be linear in the input size for any input within the limits, also for input crafted against the implementation, with one allowance: duplicate keys (§3) MAY be found with a sorted structure in O(n log n). Otherwise they are found with a hash table whose hash an attacker can't predict (seeded at random per process, as SipHash in Rust, Python and JavaScript engines are); never with a list scan or a hash with a fixed seed, which crafted keys turn quadratic.

## 8. Error positions

Errors report a 1-based line and column. Columns count **Unicode code points**, so a character outside the Basic Multilingual Plane, such as an emoji, is one column. A byte order mark at the start is a character too: the first character after it is in column 2. A line ends at a line feed; a carriage return before it belongs to that line break, and no other character (not U+2028 or U+2029) starts a new line. Every error also has a code that names the mistake, the same in every implementation (§17).

## 9. Security considerations

1. **Tags are data.** Implementations MUST NOT map tag names to classes, constructors or functions dynamically. Decode only into the types a schema lists explicitly. That kind of dynamic mapping is the root of the "gadget" attacks against Java and .NET deserializers.
2. **No references, includes or remote schemas.** The format has no anchors, references, includes or imports, and parsing never touches the network or the file system. Schemas belong to the reader. Schema imports (§13.3) are resolved when a schema is built, from packages the application's package manager installed and pinned, never while parsing. A package is data: implementations read only its `package.haus`, `schema.haus` and `package.json`, which are never symbolic links, and its schema imports packages, never files (§13.3). So a package can't make a build read other files, and errors never show the content of a file they refused to read. Text that errors quote from files (a token, a name, a version) is escaped (control and bidirectional characters) and at most 40 characters long; a version from a `package.json` is quoted only if it is a valid version. Packages are looked for only among those given explicitly and the build's own dependencies, never in global locations or over the network, so a package planted in a shared folder is never used.
3. **Enforce limits while parsing** (§7), not afterwards.
4. **Record keys are data.** A key such as `__proto__`, `constructor` or `$type` MUST NOT reach an object's prototype or any internal field. JavaScript bindings use own properties, a null prototype or a `Map`.
5. **Unknown variants carry raw data.** The raw value kept for an unknown tag in an open variant is untrusted and subject to the same limits when stored or forwarded.
6. **Fail on the first error.** Parsers MUST NOT guess or repair invalid input. Two parsers that "repair" differently disagree about what a document says.
7. **Signatures.** Either sign the exact bytes and transport them unchanged, as JWS and COSE do, or sign the canonical form (§12), so that equal values verify whatever their layout.
8. **Decoding with a schema is linear in the input,** whatever the schema. Implementations MUST:
   - choose a variant's case by looking up its tag, never by trying cases in turn and backtracking. A union of members that the value's tag or kind can't tell apart MUST NOT be allowed in a recursive schema;
   - limit the nesting depth while decoding and encoding (default 256, as in §7), including for values built in code rather than parsed;
   - limit the total work of one decode to a constant times the number of values in the input (a *work budget*; TypeScript uses 16 steps per value). The budget ends any schema mistake, such as a combinator that decodes a value twice, before it can grow with the input;
   - when encoding, detect values that contain themselves, and limit the total work, since objects shared many times (a DAG) expand when written out;
   - check a raw value kept for an unknown variant (item 5) with the same limits before writing it again;
   - build error messages in constant time: no printing of whole schemas or values.
9. **Recursive types** (a type that contains itself, like a tree) are allowed but MUST be explicit (e.g. `h.Recursive`). Every cycle MUST pass through a record field, array element or variant payload, so that each level of recursion consumes a level of input. A schema that applies itself to the same value again MUST fail. By default, recursive values are limited only by the nesting depth of §7 (256), so every binding accepts the same values; bindings MAY let applications set a smaller limit for a recursive type.
10. **Schemas are declarative.** The schema language describes structure only: records, arrays, variants, prelude types and recursion. Generic types MUST NOT grow without bound through their references (the *expansive-cycle* rule of .NET generics): draw a graph with one node per type parameter of every definition, and for each reference `B t₁ … tₙ` in the body of a definition `A`, an edge from each parameter `a` of `A` that occurs in `tᵢ` to the i-th parameter of `B`, marked *expanding* when `tᵢ` isn't `a` itself (`a` sits inside `Pair a a`, `Array a`, `{ x: a }`, …). A schema in which an expanding edge lies on a cycle of this graph is invalid (`growing-recursion`), and every other schema has finitely many instances. So `type List a = < Nil | Cons a (List a) >`, `Tree a` with `type Forest a = Array (Tree a)`, `type Swap a b = < S (Swap b a) | E >` and `type Node a = { value: a, meta: Meta }` with `type Meta = { history: Node String }` are fine, while `type T a = < X (T (Pair a a)) >` and `type A a = < X (B (P a a)) >` with `type B a = < Y (A (P a a)) >` are not: their instances double in size at every step. There are no type-level functions, conditions on values, references between values, or user code in schemas, and no syntax for rules about values: the only such rules are those of built-in types (§13.1), which run in linear time. Checking a value against a schema then always terminates in linear time; anything more belongs in application code, where the work budget (item 8) still applies.
11. **A hash hides nothing.** `hash` and `hashAll` (§12) are unkeyed: anyone who can guess a document's content can compute its hash and confirm the guess. A value with little entropy (a short password, a PIN, an email address, an amount) inside an otherwise predictable document is exposed by publishing the document's hash, whether or not a schema marks it `Secret` (§15), since the hash doesn't depend on a schema. Don't publish hashes or signatures of documents with private content on their own; use a keyed hash (HMAC) or keep the hash as private as the data.

## 10. Evolution and versions

This specification is versioned. Versions 0.x are drafts, in which anything may still change. From 1.0 on, haus only grows:

- A **minor version** (1.1, 1.2, …) may add: syntax, schema-language constructs (never prelude types, see below), standard modules and types in them, attributes (§14), and new canonical forms or hashes under new names (§12).
- A **patch version** (1.0.1, …) only clarifies wording. Nothing it changes changes behaviour.
- There is **no breaking version**. A later version may make invalid text valid, through new syntax or new schema constructs. It never makes valid text invalid, never changes what valid text means, never changes what an existing schema accepts or what it decodes to, and never changes the canonical form or the hash of a value. Default limits (§7) may only grow. The rules of built-in types (§13.1) never change once published. The compact and minimised layouts (§11) never change; the pretty layout may change in a minor version, as only people read it.
- **New syntax MUST be a syntax error in every earlier version,** so an old parser fails loudly instead of misreading newer data.
- **The prelude is fixed at 1.0.** A schema may not redefine a prelude type (§14), so adding one would break schemas that define a type of that name. Built-in types added later go into standard modules, which a schema imports (§13.2).

**No version header.** A file doesn't say which version it is written in: every version reads every earlier version's text the same way. Files whose first character (after a byte order mark) is `#` are reserved for a version directive, such as `#haus 2`, should a version that breaks compatibility ever become unavoidable. Such a version would require the directive in every file, and a file without one would always be read by the rules of 1.x. Parsers SHOULD report a file starting with `#haus` (whatever follows it: `#haus 2`, `#haus2`, `#hausfoo`) as needing a newer version of haus (`version-directive`), rather than as an ordinary syntax error; a file starting with any other `#` is an ordinary syntax error (`expected-value`).

**Conformance.** An implementation states the version it implements ("haus 1.1"). The conformance suite (`../test-suite`) is tagged for each version. Media types MAY carry the version as a parameter: `application/vnd.haus; version=1.1`.

Schema packages are versioned separately, with the rules of §13.3.

## 11. Standard format

There are three official layouts, and like `gofmt` they have no other style
options (indent width defaults to 2 spaces; line width, default 80, only
affects positional payloads in pretty). Formatters MUST produce them exactly.

| | Comments | Key order, number spellings | Whitespace | For |
|---|---|---|---|---|
| **Pretty** | kept | as written | one entry per line | people who edit |
| **Compact** | dropped | as written | spaces, one item per line | logs and streams people look at |
| **Minimised** | dropped | as written | none between tokens, one item per line | the wire and storage |

The canonical form (§12) is the fourth way to write values; it sorts keys and normalizes spellings, for hashing. All four forms of the same values have the same hash (§12), as they parse to the same values.

Strings are escaped alike in every layout: `\"`, `\\`, and `\u{…}` for raw control characters, bidi controls and the line and paragraph separators U+2028 and U+2029 (which some software splits lines at); a string is never written with any of them raw.

### Pretty (default)

For people.

- **One entry per line in every non-empty record and array,** each followed by a comma, indented one level, with the closing bracket on its own line:
  ```haus
  Person {
    name: "John Doe",
    tags: [
      "a",
      "b",
    ],
    price: Money(7.90, EUR),
  }
  ```
- **Positional payloads stay inline when they fit** the line width (`Money(7.90, EUR)`, `Point(1, 2)`). Otherwise they get one argument per line. The width is counted in code points, as columns are (§8), over the whole line including the comma after the entry, so a pretty line is never wider than the width when it can fit. A payload holding a non-empty record or array never fits, as those are always one entry per line: `Some([1])` is written over five lines.
- **Spacing:** one space after `:` and `,`; one space between a tag and its `{`; none between a tag and its `(`. Empty containers are written `{}` and `[]`.
- **Keys** are bare when they can be, otherwise quoted, written from the key itself with the minimal escapes below, in every layout: a key never keeps its spelling (`"caf\u{E9}"` is written `"café"`, `"a"` is written `a`).
- **Byte strings** keep their source spelling when a document is reformatted. When serializing values, they are written as lowercase hex without spaces, `x"0b34ff"`.
- **Strings** containing a line feed are written as `"""` block strings (§4), the indent one level deeper than the entry. All other strings use `"…"` with the minimal escapes: `\"`, `\\`, `\n`, `\r`, `\t`, and `\u{…}` for control and bidi characters and U+2028, U+2029. In a block string, a quote followed by two more quotes is escaped, a carriage return is `\r`, and **no line ends in a space or tab**: the last space or tab of a content line that ends in one is written as an escape (`\u{20}`, `\t`), so an editor that trims trailing whitespace can't change the value:
  ```haus
  note: """
    Delivery to the back door \u{20}
    Ring twice
    """,
  ```
- **Numbers keep their source spelling** when a document is reformatted (`0xFF` stays `0xFF`). **Strings** keep theirs only where the layout writes them in the same form: a `"…"` string stays as written (`"\u{41}"` stays `"\u{41}"`) unless pretty turns it into a block string because it holds a line feed. A string that changes form is written from its value: in pretty, a `"…"` string with a line feed becomes a block string and a block string without one becomes `"…"`; compact and minimised write every block string as `"…"`. When serializing values with no source text, numbers are written in normalized form, always in decimal; an integer whose decimal form is longer than the number limit (§7) of the reader written for can't be written (`number-too-long`).
- **Streams:** a file with more than one top-level item puts a comma after every item, with a blank line after each multi-line item that another item follows. A single item is written without a comma. Comments after the last item follow it directly, unless the source has a blank line there.
- **Comments** are kept (they are part of the layout, not of the data model):
  - A comment on its own line stays above the entry that follows it.
  - A comment after an entry on the same line stays after that entry's comma.
  - Comments before a closing bracket stay at the end of the container.
  - A comment after an opening bracket, on the same line, moves above the container's first entry.
  - A comment between a key and its colon, or between the colon and the value, moves above the entry, after the entry's own comments above it.
  - `Tag({ … })` is written `Tag { … }`: comments inside its parentheses but outside the braces move inside the braces. A comment after the closing `)` on the same line stays after the last entry when the `}` was on that entry's line, and otherwise goes at the end of the container.
  - A comment after an entry's comma doesn't count toward the line width (above).
  - A positional payload that holds a comment or a multi-line string never fits on one line.
- **Blank lines** between entries (and between comments and entries) are kept, at most one. Blank lines right after an opening bracket or right before a closing one are dropped.
- **Line endings:** LF everywhere, inside comments too (a CR LF in a comment is written as LF; block strings already join their lines with LF), and the file ends with a line break.

### Compact

One item per line, still readable:

```haus
Person { name: "John Doe", age: 30, type: Engineer },
Person { name: "Jane Smith", age: 28, type: Designer },
```

- **Each top-level item is written on a single line,** with the same spacing as pretty (`{ a: 1 }`, `[1, 2]`, `Tag(a, b)`).
- **Strings never span lines:** multi-line text uses `\n` escapes, and U+2028 and U+2029 are escaped too, so a compact stream can be split by lines (like NDJSON) and is still valid haus.
- **Streams:** every item is followed by `,`.
- **Comments are dropped,** also those between top-level items.
- Byte strings, numbers and strings keep their spelling, as in pretty.
- Encoders that write a stream item by item use compact by default.

### Minimised

The compact layout without the whitespace between tokens, and nothing else different:

```haus
Person{name:"John Doe",age:30,type:Engineer},
Person{name:"Jane Smith",age:28,type:Designer},
```

- **Each top-level item on a single line,** with no space or tab anywhere outside strings and byte strings. Streams as in compact: every item is followed by `,`.
- **Literals stay as written:** digit separators (`1_000`), the case of hex digits, and the blanks inside a byte string (`x"9f86 d081"`) are spelling, not whitespace between tokens. When serializing values with no source text, they are written as in pretty.
- **Comments are dropped,** as in compact. Key order and number spellings are kept, so formatting a minimised file as pretty gives back the pretty file without its comments and blank lines.
- Encoders MAY offer minimised for the wire and storage; compact stays their default.

**Comments and layouts.** Tools that cannot keep comments MUST refuse to format in the pretty layout rather than drop them. A tool that rewrites a file in place in the compact or minimised layout MUST refuse when the file has comments, unless the user asked to drop them; writing to standard output or another file needs no such check.

## 12. Canonical form, equality and hashing

The canonical form writes a value as one exact sequence of bytes, so that
two values are equal (§2) exactly when their canonical forms are identical.
It is for hashing, signing, deduplication, content addressing and comparing
values in tests; for people there are the layouts of §11.

Bindings SHOULD provide `canonical(value)`, `equals(a, b)`,
`hash(value)` and `hashAll(values)`, and MAY provide `compare(a, b)`. A binding that provides any of them MUST follow this section
exactly, so that every binding gives the same bytes and the same hash.

The canonical form of a value is UTF-8 without a byte order mark, with no
comments, no whitespace outside strings, and no trailing comma or line break:

| Value | Canonical form |
|---|---|
| number | its normalized literal (§2), always in decimal: `255`, `19.90`, `-0`, `1e5`. Every value has a canonical form: an integer of any size is written with all its digits. |
| string | `"…"`, never a block string. These are escaped: `\"`, `\\`, line feed as `\n`, carriage return as `\r`, tab as `\t`, and every other raw control character (U+0000–U+001F, U+007F–U+009F) bidi control (U+202A–U+202E, U+2066–U+2069) and line or paragraph separator (U+2028, U+2029) as `\u{…}` with uppercase hex digits and no leading zeros (`\u{1B}`). Every other character is written as itself, in UTF-8. |
| bytes | `x"…"`: two lowercase hex digits per byte, nothing between them. |
| array | `[` the elements, separated by `,` `]`. |
| record | `{` the fields, separated by `,` `}`. Each field is `key:value`. Fields are sorted by their keys' code points, which is the order of their UTF-8 bytes (not of UTF-16 units, JavaScript's default). A key is bare if it is an identifier (`[a-z_][A-Za-z0-9_]*`), and otherwise written as a string. |
| variant | the tag alone without arguments (`None`); `Tag{…}` when the only argument is a record; otherwise `Tag(` the arguments, separated by `,` `)`. |

```haus
Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }
```

is, in canonical form:

```
Order{id:255,p:Point(1,2),total:19.90,"x-y":1e5}
```

The canonical form parses back to the same value.

- **Equality:** `equals(a, b)` is equality as in §2. Comparing canonical forms is one correct way to compute it.
- **Order:** `compare(a, b)` orders values by the bytes of their canonical forms (UTF-8), shorter first when one is a prefix of the other. It is a total order consistent with equality, for sorting and for values as keys of ordered maps; it is not numeric order (`10` sorts before `9`).
- **Hashing:** `hash(value)` is the SHA-256 digest of the canonical form, written as 64 lowercase hex digits.
- **Files:** `hashAll(values)` hashes a list of values, such as a whole file (§1): the SHA-256 digest of their canonical forms joined by `,`, with nothing else between them and no trailing comma, as 64 lowercase hex digits. `1, "a", Order { id: 0xFF },` is hashed as `1,"a",Order{id:255}`.
  - A file with one value hashes like the value: `hashAll([v])` is `hash(v)`. `v` and `v,` are the same file, so they have the same hash.
  - The empty file hashes to the digest of the empty text.
  - The joined text is a valid file and parses back to the same list, so two lists have the same text exactly when they have the same length and equal values in the same order. Order matters.

  Bindings that provide `hash` SHOULD provide `hashAll`. The items of a stream (§6) are hashed one by one with `hash`; the format defines no hash of a whole stream as it is read.
- **What is hashed:** values, not their text. Layout, comments, key order and the different spellings of the same value (`0xFF` and `255`, `"\u{41}"` and `"A"`, `Tag({ … })` and `Tag { … }`) don't change the hash. What §2 tells apart does: `1.0` and `1`, a missing field and `None`, NFC and NFD strings. Hash the values a parser or encoder gives, not native values after decoding, which may have lost such differences (a JavaScript `number` can't tell `1.0` from `1`).
- **Stability:** this is version 1 of the canonical form and of `hash`. It will not change: a change would change every stored hash. Another hash algorithm or form, if one is ever added, gets its own name.

## 13. Prelude, standard modules and schema packages

Types come from four places:

| Tier | Contents | Rules about values | Bindings |
|---|---|---|---|
| **Prelude** ([`prelude.schema.haus`](prelude.schema.haus)) | the data model: `Bool`, `Maybe`, `Result`, `String`, `Bytes`, `Array a`, `Map v`, records, `Int`, `Int8`…`UInt64`, `Float32`, `Float64`, `Decimal`, `Any`, `Secret a` | built in (ranges of `Int8`…) | MUST support |
| **Standard modules** ([`std/`](std)) | [`std/time`](std/time.schema.haus) only | built in: the [std/time profile](std/time.md) | MUST support |
| **Official extensions** ([`../extensions`](../extensions)) | schema packages `@haus-fmt/…`, e.g. `@haus-fmt/money`, `@haus-fmt/geo` | none; profiles for codecs | MAY offer codecs |
| **Community packages** | schema packages of any other organisation | none | MAY offer codecs |

The prelude is always in scope. Everything else is imported:

```
import std/time (Date, Instant)     // a standard module
import @haus-fmt/money (Money)      // a schema package
import @haus-fmt/money@1 (Money)    // the same, asserting major version 1
import ./common (Address)           // a schema file next to this one (./common.schema.haus)
```

A domain goes in a module even when it is built in: the prelude reserves its names (§14), and `Time` or `Duration` are names schemas want for their own types.

### 13.1 Rules about values

**The schema language has no syntax for rules about values.** A schema describes structure (§9.10). The only rules about values are those of built-in types: the range of `UInt8`, the digits of a `Decimal`, the std/time profile. They are fixed by this specification, run in linear time, and mean the same in every implementation.

There are two conformance classes:

- A **parser** reads the syntax (§1–§8). It knows no types: `Date("2026-02-30")` and `Int8`-sized numbers are just a tag with a string and a number. A parser MUST NOT apply rules about values.
- A **schema binding** decodes values with a schema. It MUST support the prelude and every standard module completely, and MUST check their rules: `Int8(300)` and `Date("2026-02-30")` are errors. Applications MAY choose other host types for standard types (§13.4), but never change what is valid.

Rules about values never change haus equality (§2), the canonical form or the hash (§12): those compare values as written. Two strings a standard type considers the same time (`.250` and `.25`) are different haus values, as `19.90` and `19.9` are different numbers that a `Float64` decodes alike.

### 13.2 Standard modules

Standard modules ship with this specification and are versioned with it. A module only gains types; its rules never change (§10), so imports of standard modules carry no version.

- [`std/time`](std/time.schema.haus): `Date`, `Time`, `DateTime`, `Instant`, `ZonedDateTime`, `Duration`, `YearMonth`, `TimeZone`, the model of JavaScript's Temporal and java.time. Values are a tag around a string; the strings a schema binding accepts are defined by the [std/time profile](std/time.md), a strict subset of RFC 3339, RFC 9557 and ISO 8601. Nothing in it depends on a registry: zone names are checked for their syntax, never looked up.

A type belongs in a standard module only if it passes all three tests: the prelude can't express it (a plain string or number loses or blurs its meaning), nearly every domain needs it, and a fixed, published grammar defines it. Today only time passes. Money passes the second test only partly, and `Decimal` already prevents the loss of precision: it is the package `@haus-fmt/money`. Identifiers (UUIDs, ULIDs, …) lose nothing as strings. Units, currencies, countries and languages are registries that change.

Implementations SHOULD tell users of the former module `std/money` to import `@haus-fmt/money` instead.

### 13.3 Schema packages

A **schema package** is a directory with two files: a manifest, `package.haus`, and the package's one schema file, `schema.haus`, next to it:

```
{ name: "@haus-fmt/money", version: "1.2.0" }
```

- `name` is `@organisation/name`, with npm's rules for scoped names in lowercase: each part starts with a letter or digit and has only `a`–`z`, `0`–`9`, `-`, `.` and `_`, is not `node_modules`, and the whole name has at most 214 characters. `@haus-fmt/` is reserved for the official extensions maintained with haus.
- `version` is a semantic version (below).
- Other fields of the manifest are ignored, so later versions can add some. A manifest is at most 64 KiB.
- `schema.haus` is an ordinary schema file: shape only, like every schema. It imports standard modules and other packages, never files. Packages change no syntax: `Money(19.99, EUR)` is valid haus with or without `@haus-fmt/money`.
- The directory may hold other files, such as profiles (below) and the wrappers of package managers (`package.json`, `Cargo.toml`). No import reads them.

**Resolution.** Relative imports read the file next to the importing file: `import ./common` is `common.schema.haus` (the extension is always added). Each name in the path MUST be spelled as its directory lists it, also on file systems that ignore case or Unicode normalization, and the real path of the file MUST end in `.schema.haus`. Packages are found when a schema is built, never while data is parsed. The exact version and content hash are pinned by the application's package manager (its lock file), not by the schema.

Resolution follows five principles, and the rules below apply them; an implementation for another ecosystem derives its rules from them the same way:

1. A build reads only a package's own files, and those are plain files, never links.
2. Packages are found only where the build declared them, never because something happens to be nearby or in a shared place.
3. Two different packages never share a name silently.
4. The work is bounded: sizes, the number of files, each file read once.
5. Text from files is never repeated unescaped.

Where an implementation looks for packages is part of the security model (§9.2). It MUST look only in:

- packages given to it explicitly: a package's directory, or a folder whose subdirectories with a `package.haus` are packages. Tools and runtime loaders MUST accept these; a code generator whose output uses the packages' own generated code takes them from the package manager instead. A package given by its directory is used instead of any other one with the same name. A package found in a folder is not: if the importer's dependencies hold another package with its name and other files, the schema has two packages with one name;
- the dependencies of the build, as its package manager installed them: `node_modules` (below), the crate's dependencies (Cargo);

and never in global or environment-wide locations (npm's global folder, `NODE_PATH`, a shared cache), and never over the network.

**npm.** An implementation that looks in `node_modules` MUST follow these rules, so that every binding finds the same package and a dependency can't place one where another is looked for:

- A file imports only packages it declares, and the implementation checks this before it looks. For a package's `schema.haus`, the declarations are in the package's own `package.json`. For other files, they are in the nearest `package.json` above the file's real path, skipping one that has neither a `name` nor a dependency field (such as `{ "type": "module" }`). The declared packages are those in `dependencies`, `peerDependencies` and `optionalDependencies`, and for every file other than a package's `schema.haus` also `devDependencies`. Without such a `package.json`, a file declares nothing. Explicit packages count as declared. Otherwise: `undeclared-package`.
- It starts from the real path of the importing file and tries `D/node_modules/@org/name` for each directory `D` from the file's directory up, nearest first, as Node does. It skips a `D` that is itself named `node_modules`, a scope directory directly inside one (`node_modules/@acme`), or the root of a Windows drive (`C:\`), where any user can create `node_modules`. It SHOULD skip a `D` that everyone may write to, such as `/tmp`, so that a `node_modules` planted there is never used.
- The first `node_modules/@org/name` that exists is the package. If it has no `package.haus`, the import is not found; the search doesn't go on.
- A package found this way MUST have the imported name in its manifest, and npm's name for it (its directory) is that name too.

**Package versions** (`package-version`): implementations SHOULD check that a package's manifest `version` equals the version the package manager gives it, where it gives one (the `version` of npm's `package.json`, Cargo's package version). The check catches publishing mistakes and doesn't change what a schema means.

**Files and limits.** A package's `package.haus`, `schema.haus` and `package.json` MUST be regular files, not symbolic links (the package's directory may be one). Implementations open them without following links, check the type and the size on the opened file, and read from it, so that the file checked is the file read. Each file is read at most once for a schema, by its real path, also when one file is needed in two roles (a `package.json` that is a link to a schema file): every use sees the same bytes. These limits MUST be enforced by default and MAY be raised by the user:

| Limit | Default | Error |
|---|---|---|
| manifest | 64 KiB | `package-manifest` |
| schema file, `package.json` | 1 MiB | `file-too-large` |
| entries in a folder of packages | 4096 | `too-many-files` |
| schema files in one schema, the root included (manifests and `package.json` don't count) | 256 | `too-many-files` |

A `package.json` that isn't valid JSON declares nothing and gives no version to check.

**Distribution.** There is no haus registry. Authors publish schema packages however their users install dependencies: language registries (npm, crates.io, PyPI, …), private registries, git dependencies, workspaces, or copies in the project (vendored, still imported by name). Codec libraries for registries that reject git dependencies (crates.io, PyPI) can carry the schema text they target.

The reasons:

- Package managers already provide hosting, mirrors, lock files, hashes, authentication and private registries.
- A haus registry would be one more service to run and one more point of failure for every build.
- Types are identified by manifest names (`@haus-fmt/money@1#Money`), not by a registry, so a registry or a catalog can be added later without breaking anything; removing one could not be done the same way.

What this means for users:

- **Names are claims.** A manifest name doesn't prove who wrote a package: trust comes from the dependency the application chose to add. Scopes make names reliable on npm, and less so on registries with unscoped names. `@haus-fmt/` is reserved by convention; on npm the `@haus-fmt` scope enforces it. Organisations SHOULD use a name they own: their domain or their code hosting organisation.
- **No install scripts.** A schema package is data and MUST NOT need code to install, such as npm `postinstall`. Codecs are code, and are trusted like any other library.
- **Copies in several languages.** A package published to several registries SHOULD be published from one source, so that equal versions have equal files.
- **One copy per build.** On npm, a schema package SHOULD declare the schema packages it imports as `peerDependencies`, so that npm installs one copy for the whole application or reports a conflict when installing, as Cargo does.
- **Discovery.** There is no index. The official extensions are listed in [`../extensions`](../extensions).

**Identity.** Every named type has an id, the same in every language: `@haus-fmt/money@1#Money` is the type `Money` of the package `@haus-fmt/money`, major version 1. Types of the prelude and the standard modules have the ids `prelude#Decimal` and `std/time#Instant`. Files outside a package get an id from the binding (the JavaScript binding uses the nearest `package.json` name and the file's path); two imports reach the same such file when its real path is the same, whatever its id. Major versions are compared as text (`@18446744073709551616` is a valid major that no package has). Codecs (§13.4) and tools refer to types by their id.

**Imports.** `import M (A, B)` makes the types `A` and `B` defined in `M` available under their names; a file can't re-export types it imports. Implementations MUST reject:

- a module that can't be found, or a type it doesn't define;
- a name imported twice, or imported and also defined;
- two different packages with the same name in one schema, such as `@acme/ids` 3.1.0 and 3.2.0 found in different places, two major versions of it (`@acme/ids@2` and `@acme/ids@3`), or two packages that both call themselves `@acme/ids`. Copies whose `package.haus` and `schema.haus` are byte for byte the same, and whose imports reach the same packages, are one package;
- `@org/name@N` when the package found has another major version, and a version that isn't a major version: `@1.1`, `@01`;
- a manifest that breaks the rules above (its `name`, its `version`, its size);
- a relative import in a package's `schema.haus` (a package imports other packages by name);
- a relative import from a file outside a package to a file in a package's directory (import the package by name);
- a package's `package.haus`, `schema.haus` or `package.json` that is a symbolic link or not a regular file. Such a file is not read;
- a relative import whose file isn't a schema file (its real path doesn't end in `.schema.haus`) or that spells a name differently from its directory. Such a file is not read. A real path inside a package's directory is checked first: it is the error above, whatever the file's name;
- import cycles: a file that imports itself, directly or not.

Errors inside an imported file are reported at the import, with their place in that file.

**Versions.** A package's version says what a change does to data:

| Version | Allowed changes | Guarantee |
|---|---|---|
| major | everything not listed below, for example: removing or renaming types, fields or tags; changing a field's type or a tag's payload; adding a required field (a `Maybe` field is required); making an optional field required or a required one optional; adding a field or tag to a closed type; making a type `closed` or open | none |
| minor | new types; new optional fields (`x?: T`) in open records; new tags in open variants | see below |
| patch | comments, documentation and attributes (§14) | nothing changes |

A minor version guarantees, between any two versions of the same major:

- **Older data, newer reader.** Data valid under the older version that uses only the fields and tags it lists stays valid under the newer one and decodes to the same value.
- **Newer data, older reader.** Data valid under the newer version stays valid under the older one, which ignores the new fields and decodes the new tags to unknown values (§15).

A field or tag that an open type doesn't list is reserved for later versions of its schema: writers SHOULD NOT use one, as a later minor version may give it a meaning or a type the data doesn't match. `{ id: 1, note: 5 }` is valid under an open `{ id: Int }`, and invalid once 1.1 adds `note?: String`.

An import names at most a major version, `@N` without leading zeros. A minimum minor version (a package relying on a type, field or tag added in 1.2) goes in the package manager's dependency range: `^1.2` (npm), `1.2` (Cargo), `>=1.2,<2` (Python).

**Profiles.** A package MAY define profiles: rules beyond its shape that codecs can implement, named like `@haus-fmt/money/iso`. A profile is defined by its **rule**, written in prose in `profiles/<name>.md`: which values a codec implementing it accepts, stated on the value the type's schema decoded (§13.4), never on how it was written. Its **test vectors** (`profiles/<name>.vectors.haus`) are examples of the rule that every implementation must pass: values it accepts, with the text they encode back to where that differs from the input, and values it rejects. Vectors can't define a rule (two codecs can pass all of them and still disagree), so where a rule and its vectors disagree, the vectors are wrong. The official profiles also have a reference checker in Lean, which the bindings' codecs are fuzzed against. Profiles are how the official extensions say what "valid money" means without putting rules into the schema language.

### 13.4 Codecs

A schema binding MAY let applications choose the host type of a named type without arguments: a **codec**, selected by the type's id. A codec:

- runs after the type's schema: it can reject more values, never fewer;
- encodes back to the type's values, so that decoding what it encoded gives the same result: decode, encode, decode is the same as decode;
- never changes what a value means: the same text means the same thing with and without it, the same instant or the same amount.

Host types differ in what they can hold, as `Decimal` does: Python's `datetime` and .NET's `DateTime` can't hold the year `0000` of std/time, while JavaScript's Temporal, Go's `time.Time` and `java.time` can. A binding whose language lacks a type for the whole range keeps the value another way (the checked text, or a type of its own) by default, and offers the native type as a codec that rejects what it can't hold. A host type may keep less than the haus value: `Temporal.Instant` or a JavaScript `Date` keeps the instant but not the offset it was written with, and a decimal type may forget `-0` or exponent notation. Encoding through it then writes a value that means the same but is not equal (§2), with another canonical form and hash. A binding's default host types MUST keep the value, so that encoding what the defaults decoded always gives back an equal value, with the exceptions of §15 only. A host type that keeps less is offered only as a choice the application makes explicitly (a codec, or a schema variant such as `InstantAsDate`), and its documentation MUST say what it drops. Hash and sign parsed values, not re-encoded ones (§12).

A codec applies wherever its type occurs, inside the types of imported packages too. Where a package's types are generated once, in its own library (a crate, a Roc package), the application's generated code generates again those of the package's types that contain the codec's type, directly or not, and uses the package's own types for the rest; it needs the schema files of the packages its packages import, transitively. A binding that can't apply a codec somewhere, such as a host value that has no place of its own for a record case's payload, MUST report an error (`codec-unreachable`) instead of decoding there with the default host type.

When codecs apply at several places in one value (a codec for `Currency` inside one for `Money`), decoding runs them from the inside out: a part's codec runs before the codec of the value that holds it, and the first that rejects gives the error, at its own place (`$[1]` for the currency).

Codecs are part of the application, not of the schema. Two applications reading the same file with different codecs agree on what the file says, and may disagree only on what they accept. A codec for a standard type changes the host type only (§13.1).

## 14. Schema files

A schema file (`.schema.haus`, grammar in [`grammar.ebnf`](grammar.ebnf)) is a list of imports (§13) and type definitions. It has the same comments, whitespace and quoted strings as data files (§4, §5), with the same rules and error codes: a lone carriage return, a raw control or bidi character in a comment, invalid UTF-8, an unterminated string or comment, and a bad escape in a quoted field key are reported as in data (`lone-carriage-return`, `control-character`, `bidi-control`, `invalid-utf8`, `unterminated-string`, `unterminated-comment`, `invalid-escape`), and a quoted field key takes every escape a data string does.

**Open by default.** Records and variants are open: a reader ignores fields the schema doesn't list (they are not part of the decoded value) and decodes tags it doesn't list as an *unknown* value that keeps the raw data. Writers can add fields and tags without breaking older readers. `closed { … }` and `closed < … >` forbid anything not listed. `< >` is a variant with any tags.

Tools that check a file against its schema (editors, `haus check`) MUST report what a closed type forbids as an error, and SHOULD mark fields and tags an open type doesn't list as a hint ("not in the schema"), without failing the check.

**Spreads.** `...Name` copies the tags of the named variant into a variant, or the fields of the named record into a record, at the place where it is written. Whether the result is open or closed is decided by its own `closed` alone, never by the type it copies from:

```
type UserEvent = < UserCreated { id: Int } | UserRenamed { id: Int, to: String } >
type AppEvent = closed < ...UserEvent | Heartbeat >   // exactly these three tags
type ServerEvent = < ...UserEvent >                   // the user events; other tags become Unknown

type Base = { id: Int, createdAt: Instant }
type Person = closed { ...Base, name: String }
```

Only a named type without parameters can be spread; to reuse a structure with a part left open, use a type parameter (`type Envelope e = { id: String, event: e }`). There are no row parameters: `...r` is reserved and MUST be rejected.

**Attributes.** An attribute gives tools information about a type, field or tag. It is written before it:

```
@deprecated("use Customer")
type Client = { id: Int, @deprecated("use email") mail?: String, email?: String }
type Shape = < Circle { r: Float64 } | @deprecated Square { side: Float64 } >
```

Attributes are metadata: they never change which data a type accepts or what it decodes to (§15). There is one:

- `@deprecated` or `@deprecated("why, and what to use instead")`: the type, field or tag will be removed in a later major version of its package (§13.3). Tools that check data against a schema SHOULD mark a deprecated field or tag the data uses with a hint (not an error), at the field's value or the tagged value (`$.lines[0].count`), as `unlisted-field` is; tools SHOULD mark a schema's use of a deprecated type, a spread of it (`...OldEvent`) included, once where it is written; code generators SHOULD emit the language's own marker, such as `#[deprecated]` in Rust or `@deprecated` in JSDoc. A field or tag copied by a spread keeps its attributes.

An attribute is added to this list only if it passes three tests: it doesn't change which data is valid or what it decodes to; tools act on it the same way in every language (text for people belongs in comments); and most target languages have a counterpart for it. Rules about values (`@min`, `@pattern`, `@default`) never pass the first test (§9.10).

Tools MUST accept an attribute this version doesn't define, MUST NOT give it a meaning, and SHOULD warn about it, so that a schema using an attribute of a later version still works with older tools. Implementations MUST NOT define attributes of their own.

Implementations MUST reject:

- unknown types, types used with the wrong number of arguments, types defined twice, and redefinitions of prelude types;
- duplicate fields in a record and duplicate tags in a variant, also those copied in by a spread;
- `closed < >`;
- a spread of something other than a named variant (in a variant) or a named record (in a record), of a type with parameters, or of a `Stream`;
- a type that spreads itself, directly or through other types, however deep the spreads are written (`type A = < ...B >`, `type B = < ...A >`; `type P = { x: { ...R } }`, `type R = { y: { ...P } }`);
- `...r`: row parameters are not part of the language;
- an attribute this version defines with arguments it doesn't take (`@deprecated(1)`), or twice on one type, field or tag (attributes it doesn't define are accepted as they are, §14 above);
- recursion that doesn't pass through a record field, array element or variant payload (`type A = B`, `type B = A`), §9.9, in every type defined, used or not (`type Q a = Q a`). `Secret a` is not a step of its own: `type A = Secret A` is unguarded;
- generic types whose instances could grow without bound: an expanding edge on a cycle of the parameter graph, §9.10 (`growing-recursion`);
- `Stream a` anywhere but as the whole type of a definition, and references to such a definition. Its number of arguments is checked first: `type Q = Stream` and `{ e: Stream }` are the wrong number of arguments (`wrong-arity`), not a misplaced stream;
- the import errors of §13.3.

**Which schema describes a file.** The reader decides (§9.2): an application passes its schema to the decoder, and tools take one when given (`--schema`). Without one, tools MAY use the type `Root` of the schema file `x.schema.haus` next to a data file `x.haus`. A data file never names its schema.

## 15. Decoding with a schema

A schema binding (§13.1) decodes a value with a type. The result is a value of the binding's language, or an error. This section says which values each type accepts, what of them a binding must keep, and what an encoder writes. What a decoded value looks like in a language (an object, a struct, a `bigint`) is up to the binding, as long as these rules hold.

**General rules.**

- Decoding depends only on the type and the value: never on other values in the file, on layout or comments, or on spellings that §2 treats as the same value. `0xFF` and `255` decode alike, and so do `Tag({ … })` and `Tag { … }`.
- A value the type doesn't accept is an error. Decoders MUST NOT convert between kinds of values: the string `"42"` is not an `Int`, a bare `32` is not `Some(32)`, and a missing field is not `None` (§1).
- An error names the place of the failing value, for example `$.items[2].price`. Reporting the first error is enough (§9.6). The place is a path from `$`, the decoded value, with one step per level:
  - a field of a record, or an entry of a `Map`: `.key` when the key is an identifier (`ident` in the grammar: `[a-z_][A-Za-z0-9_]*`), otherwise `[` the key as a string in canonical form (§12) `]`: `$.m["pt-BR"]`, `$.m["A"]`, `$.m[""]`;
  - an item of an array: `[i]`, counted from 0;
  - an argument of a variant case: `[i]`, counted from 0, also for `Some(x)` and the tags of `std/time` (`$[0]` for `Date("2026-02-30")`). The fields of a record case are steps from the case itself, without a step for the payload: `$.shape.r` for `{ shape: Circle { r: "x" } }`, however the record case is written (§15 "Variants").

  An error about a value as a whole is at that value: a wrong kind of value, a missing field (at the record), a wrong payload or an unknown tag (at the variant). An unknown field of a closed record is at the field. An error inside a `Secret` is at the secret, with no step into it (`Secret` below). In a stream (§6), the path of an error in an item starts with the item's index, `$[3].price`.
- Decoding is linear in the input whatever the schema, within the limits of §9.8 and §9.9.

**Numbers.** Decoding works on the exact decimal a literal denotes (§3).

| Type | Accepts |
|---|---|
| `Int` | a number whose normalized literal (§2) is a whole number: digits with an optional `-`, no fraction and no exponent. `0xFF`, `1_000` and `-0` are whole numbers (`-0` is 0). `1.0` and `1e3` are not, as `1.0` is not the same value as `1` (§2). Any size (§3). |
| `Int8`, `Int16`, `Int32`, `Int64` | as `Int`, from −2<sup>n−1</sup> to 2<sup>n−1</sup>−1 |
| `UInt8`, `UInt16`, `UInt32`, `UInt64` | as `Int`, from 0 to 2<sup>n</sup>−1 |
| `Float64`, `Float32` | any number, rounded to the nearest IEEE 754 binary64 or binary32 value (ties to even), directly from its exact decimal value: rounding to binary64 first and then to binary32 can be off by one unit. A number too large for the type (one that would round to an infinity) is an error. A number too small rounds to zero, keeping its sign; `-0` is negative zero. Also the tags `NaN`, `Infinity` and `NegInfinity` without a payload. |
| `Decimal` | any number, kept exactly as its normalized literal, scale and exponent included: `19.90` stays `19.90`, `1.5e3` stays `1.5e3`. |

A value outside an integer type's range is an error, never wrapped or clamped. For values a `Float32` can't hold exactly, use `Float64`, or `Decimal` for exact values.

**Other built-in types.**

| Type | Accepts |
|---|---|
| `String` | a string, kept exactly (§4: no normalization) |
| `Bytes` | a byte string |
| `Bool` | `True` or `False` |
| `Maybe a` | `None`, or `Some(x)` with exactly one argument `x` that `a` accepts |
| `Result e a` | `Err(x)` with `x` an `e`, or `Ok(x)` with `x` an `a` |
| `Array a` | an array whose elements `a` all accept |
| `Map v` | a record with any keys, whose values `v` all accept. As for records (§2), the order of its entries carries no meaning. |
| `Any` | any value, kept exactly as parsed: the binding's value tree (§9.5 applies, as for unknown values). Encoding writes it back unchanged, after checking it is a value within the limits (§9.8). |
| `Secret a` | exactly what `a` accepts, decoded as `a` decodes it, in a host type that hides it (below) |
| `Date`, `Time`, … (std/time) | the type's own tag with exactly one string argument that the [std/time profile](std/time.md) accepts: `Date("2026-11-13")`. `Instant("2026-11-13T10:00:00Z")` is not a `Date`. |

**Records.** `{ … }` accepts a record in which:

- every field without `?` is present, and each field the type lists that is present is accepted by its type;
- a field with `?` may be missing. It then stays missing in the result: never `None`, never a default (§1);
- a field the type doesn't list is ignored by an open record (it is not part of the result) and an error in a closed one.

**Variants.** `< … >` accepts a variant. Its tag selects the case, by lookup (§9.8), and the case says what payload the tag takes:

| Case in the schema | Payload in the data |
|---|---|
| `Tag` | none |
| `Tag { … }` | one argument, a record, which the record type `{ … }` accepts (open or closed by its own `closed`). `Tag { … }` and `Tag({ … })` are the same value (§2). |
| `Tag T1 … Tn` | exactly n arguments, the i-th accepted by `Ti`. With `type Order = { … }`, the case `Ok Order` accepts `Ok { … }`. |

A case with one argument whose type is a record is a **record case**, however the record is written: `Circle { r: Float64 }`, `Circle ({ r: Float64 })`, and `Circle Disc` with `type Disc = { r: Float64 }` (or a name applied to arguments that gives a record, `Found (Page Int)`) are the same case, so naming a record type changes nothing. A type parameter is not a record, even where the argument given for it is one: in `type Result e a = < Err e | Ok a >`, `Ok a` is never a record case. Nor is `Secret R`, `Maybe R` or any other type around a record: `Box S` with `type S = Secret { … }` has one positional argument.

A listed tag with any other payload is an error, in open variants too: an unknown value is for tags the reader doesn't know, and changing a tag's payload is a major change (§13.3). A tag that isn't listed is an error in a closed variant and decodes to an *unknown value* in an open one. `< >` lists no tags, so it decodes every variant to an unknown value.

**Unknown values.** An unknown value keeps the tag and its arguments as parsed values. Bindings MUST:

- keep both unchanged, so that encoding an unknown value writes a value equal (§2) to the one decoded;
- represent it so that it can't be confused with a listed case;
- treat its content as untrusted data, subject to the limits (§9.5, §9.8).

How it is represented is up to the binding. For example, a binding MAY represent an unknown value without a payload by its tag name, so that `< >` decodes `EUR` to the string `"EUR"`.

**Secrets.** `Secret a` marks a value that must not end up in logs, such as an API key or a password. The data is the same as for `a`: it is written in full, since the receiver needs it, and its canonical form and hash (§12) don't change. What changes is the host side. Bindings MUST:

- decode it to a type that hides the value when printed, logged, inspected or converted to JSON (showing something like `<redacted>`), and gives it out only through an explicit call;
- leave the value out of error messages, when decoding and when encoding: an error inside a `Secret` is reported at the secret itself (`$.apiKey`), with its type, never with the value found or any part of it. A path into the secret could itself reveal it, through the keys of a `Map` or an `Any`.

Tools that show data, such as editors and `haus check`, SHOULD mask values of a `Secret` type.

`Secret` protects against accidental exposure in a program, not against anyone who sees the data: it is not encryption, the text holds the value in full, and a hash of the document can confirm a guess of it (§9.11).

**Attributes don't matter.** Decoding and encoding are the same with and without the attributes of a schema (§14).

**Named, generic and recursive types.** A named type decodes as its definition. A generic type decodes as its definition with the parameters replaced by the arguments: `Maybe Int`, `Envelope Event`. A recursive type decodes one level of the input at a time (§9.9).

**Streams.** `Stream a` describes a file: each top-level value decodes as an `a`, on its own, as it is read. An error names the value's index in the stream.

**Encoding.** A binding that encodes writes values that the type accepts, and encoding fits decoding: for every value `v` that a type accepts, decoding `encode(decode(v))` gives the same result as decoding `v`. `encode(decode(v))` is equal to `v` (§2), except where decoding drops information by design:

- fields an open record ignores;
- the spelling of a float: `0.10` decodes as `Float64` to the float 0.1, which is written `0.1`;
- `-0` decoded as an integer, which is written `0`.

Integers are written as decimal integers, and decimals as their literal, scale included (§3).

**Floats** are written as `NaN`, `Infinity` and `NegInfinity`, and otherwise in one exact spelling, so that every binding writes the same float as the same text and gives it the same canonical form and hash (§12):

- The digits are the fewest decimal digits that decode back to the same float of the type (binary64 for `Float64`, binary32 for `Float32`). If several digit strings of that length do, the one closest to the float is written, and of two equally close ones, the one whose last digit is even: the Float32 value 2097152.25 is written `2097152.2`, not `2097152.3`.
- With digits d₁…d<sub>k</sub> and the value 0.d₁…d<sub>k</sub> × 10<sup>n</sup>, the layout is that of JavaScript's `Number.prototype.toString`, except that the exponent has no `+`. The first row that applies is used:

  | When | Written as | Examples |
  |---|---|---|
  | k ≤ n ≤ 21 | the digits, then n − k zeros | `1`, `100`, `123000` |
  | 0 < n ≤ 21 | the digits, with a `.` after the first n | `1.5`, `12.25` |
  | −6 < n ≤ 0 | `0.`, then −n zeros, then the digits | `0.1`, `0.000001` |
  | otherwise | d₁, then `.` and d₂…d<sub>k</sub> if k > 1, then `e` and n − 1 | `1e21`, `1.5e-7` |

- A negative float starts with `-`. Negative zero is `-0`.

## 16. JSON

Three forms connect haus and JSON:

- **Schema-based JSON** (16.3) writes the values of a schema type as the JSON a JSON consumer expects, for APIs and export. The schema carries what JSON can't say (that a string is a date or a decimal), so reading it needs the schema.
- **Self-describing JSON** (16.2) writes every haus value exactly, without a schema, for carrying haus through systems that only store JSON.
- **JSON import** (16.1) reads any JSON as a haus value, without a schema. It only reads.

All three are version 1 and never change; a different mapping would get a new name (§10). A key that starts with `_` is always haus's, never data: `_tag` in schema-based JSON, `_haus`, `_value`, `_tag`, `_args`, `_rec`, `_num` and `_bytes` in self-describing JSON.

**Which form.** The party that knows least decides. When every reader has the schema, use schema-based JSON. When a reader lacks the schema but uses haus and needs the exact values, use self-describing JSON. When a reader lacks the schema and wants ordinary JSON, use schema-based JSON, which any JSON library reads.

Schema-based JSON is not a pass-through format. Read without its schema (by the import, or as an unknown value, 16.3), `Int`, `Int64` and `UInt64` values, decimals, std/time values and bytes are strings, a `Maybe` that uses `null` is the bare value or `None`, positional arguments are fields named `value` and `values`, and a variant is a record with a key `_tag`. Written back, that is not the writer's value. To pass data through a party that lacks the schema, use self-describing JSON or haus text.

**A reader checks the form; it never chooses it.** The caller says which form it reads: the data never decides how it is read. The self-describing reader requires the envelope (16.2); the schema-based reader and the import don't look for one, so to them an envelope is an object like any other. A tool MAY detect the form as a convenience, with an option that overrides it; the command line does.

**JSON that is read.** Readers read JSON (RFC 8259) restricted to I-JSON (RFC 7493): UTF-8, no duplicate member names, no unpaired surrogates in `\u` escapes. A leading byte order mark is ignored, as in haus. Numbers keep their exact text: a reader MUST NOT round them through a binary float, except where schema-based JSON says a float. JSON is compared as data: member order and whitespace don't matter. The self-describing reader also rejects raw DEL, C1 and bidi controls (§4) in strings and member names (`control-character`, `bidi-control`), as only haus tools write that form and they escape them. The schema-based reader and the import accept them raw, as other software writes them so (`JSON.stringify` does).

**JSON that is written.** Writers escape, in strings and member names, every character below U+0020, DEL, U+0080–U+009F, the bidi controls U+202A–U+202E and U+2066–U+2069, and U+2028 and U+2029, so that written JSON can't display differently from what it holds, as haus text can't (§4), and JSON Lines can be split at any line break software knows. Readers accept U+2028 and U+2029 raw. Which escape (`\n` or `\u000A`) is up to the writer.

**Limits.** The limits of §7 apply to the haus value that results (with a type: the value the decoded result encodes to), and the number limits (characters in a number literal, and the absolute exponent) also to JSON number tokens as written, as to haus number literals: `1e-7000` is `exponent-too-large` whatever the type, as it is in haus text. Lengths are counted on that value, not on the JSON text: a string's characters after its escapes are read (`"\u00e9"` is one character), a key or tag as a haus key or tag, and bytes as two characters per byte, as in the hex of a haus byte string, whether the JSON spells them in hex (`_bytes`) or base64. A form can need several JSON levels for one haus level (`Tag { … }` is `{"_tag": …, "_args": [{"_rec": {…}}]}`), so the JSON nesting is limited to 4·d + 1, where d is the depth limit of §7, plus 1 for the envelope of self-describing JSON, and the depth of the resulting haus value is then checked against d. The import's JSON nesting is limited to d.

**Streams.** A stream maps to JSON Lines: one JSON text per value, each followed by a line feed. In self-describing JSON each line is an envelope of its own, so lines stay independent for appending and tailing (§6). Readers accept a missing line feed after the last value and CR LF line ends; an empty line is an error (`json-syntax`: it is no JSON text). A byte order mark is ignored only at the start of the stream, as in haus (§4), not at the start of each line, where it is `json-syntax` too. These errors name the line.

### 16.1 JSON import

Any JSON text reads as a haus value: an object as a record, an array as an array, a string as a string, a number as a number with its literal normalized (§2), `true` and `false` as `True` and `False`, and `null` as `None`. Nothing in the data is special: `{"_tag": "Circle"}` and `{"_haus": 1, "_value": 2}` are records.

### 16.2 Self-describing JSON

A JSON text in this form is an envelope, an object with exactly two members: `{"_haus": 1, "_value": <value>}`. `_haus` is the version of the form, `_value` the haus value as:

| haus | JSON |
|---|---|
| string | a string |
| array | an array |
| number | `{"_num": "<normalized literal>"}`: `{"_num": "19.90"}` |
| bytes | `{"_bytes": "<two lowercase hex digits per byte>"}` |
| record | `{"_rec": {<key>: <value>, …}}` |
| variant | `{"_tag": "<Tag>"}` without arguments, `{"_tag": "<Tag>", "_args": [<value>, …]}` with them; `Tag { … }` is `Tag({ … })` (§2) |

`"Shipped"` is the string `"Shipped"` here, and the tag `Shipped` in schema-based JSON with a closed enum: the envelope says which form a text is in.

Reading accepts exactly these forms and rejects every other JSON (`haus-json-form`): a text without the envelope, an envelope with other members or a `_haus` other than 1 (`haus-json-version`), a bare number, `true`, `false`, `null`, an object with other members, a `_num` that isn't a normalized literal (`"1E5"` and `"01"` are rejected, `haus-json-number`) or longer than the number limit (§7), uppercase hex in `_bytes` (`haus-json-bytes`), a `_tag` that isn't a tag, an empty `_args`. So every haus value has one self-describing form, reading it gives an equal value (§2), and each accepted JSON text is the form of exactly one value. Inside schema-based JSON (`Any`, unknown values, 16.3) the value appears without an envelope. The conformance suite's `.jsonl` files use this form, one envelope per value of the file.

### 16.3 Schema-based JSON

With a schema type, the decoded value (§15) is written as:

| Type | JSON |
|---|---|
| `String`, std/time types | a string; std/time values as written |
| `Bytes` | a string, base64 with padding (RFC 4648 §4); readers accept only this canonical form: no whitespace, no URL alphabet, zero pad bits |
| `Bool` | `true` or `false` (the prelude's `Bool` only; a schema's own `closed < False \| True >` is a closed enum like any other) |
| `Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32` | a number: the decimal integer |
| `Int`, `Int64`, `UInt64` | a string: the decimal integer (`"-12"`), since many JSON parsers round integers beyond 2⁵³. Readers accept `-?(0|[1-9][0-9]*)` (`"-0"` is 0). For `Int64` and `UInt64` a value outside the range is `out-of-range` whatever its length; for `Int`, which has no range, the number limit of §7 applies (`number-too-long`). |
| `Float32`, `Float64` | a number in the spelling of §15; `NaN`, `Infinity` and `NegInfinity` as the strings `"NaN"`, `"Infinity"` and `"-Infinity"` |
| `Decimal` | a string: the normalized literal (`"19.90"`), so that float parsers can't round it. Readers accept a JSON number literal in the string (`"1E+05"` is `1e5`), not hex or digit separators. |
| `Any` | its self-describing value (16.2), without the envelope |
| `Secret a` | as `a` |
| `Array a` | an array |
| `Map v`, records | an object; a missing optional field is a missing member |
| `Maybe a` (the prelude's; a schema's own `closed < None \| Some a >` is a variant like any other) | `null` for `None` and the value for `Some(x)`, when `a`'s JSON can't be `null`; otherwise `{"_tag": "None"}` and `{"_tag": "Some", "value": x}` |
| a closed variant whose tags have no payload (other than `Bool`) | a string: the tag (`"Debug"`) |
| other variants (`Result` too) | an object with the tag as `"_tag"`: `{"_tag": "Empty"}`; for a record case (§15: one argument whose type is a record, written inline or by name), the record's fields beside it (`{"_tag": "Circle", "r": 1.5}`, also for `Circle Disc` with `type Disc = { r: Float64 }`); one other argument as `"value"`, also where a type parameter stands for a record (`Ok a` of `Result`); several as `"values"`, an array. The schema's case decides, not the value. |
| an unknown value (§15) | `{"_tag": "<Tag>"}`, with `"_args"`, the arguments' self-describing values (16.2), if it has any |

A type's JSON can be `null` only if it is a `Maybe` that uses `null`, directly or through a named type or `Secret`. A `Maybe` that reaches itself only through `Maybe`, `Secret` and names (`type T = Maybe T`) always uses the tagged form, so the answer never depends on where one starts. A `Maybe` is identified by where it is written, not by its shape: with `type D = Maybe T`, `D` doesn't reach itself, `T`'s JSON can't be `null`, so `D` uses `null`. So `Maybe (Maybe Int32)` writes `None`, `Some(None)` and `Some(Some(5))` as `{"_tag": "None"}`, `{"_tag": "Some", "value": null}` and `{"_tag": "Some", "value": 5}`. The type decides the form, never the value. A record payload with a field named `_tag` or `_args` has no schema-based form. The schema is still valid, and so are its other cases: converters report the error only when writing or reading a value of that case. Tools that check schema files SHOULD warn about such a case already (`no-json-form`), without failing the check, so that it is found while the schema is written.

**Reading** with a type accepts the forms above and the rules of §15 apply: an open record or record payload ignores members it doesn't list, a closed one rejects them, and every other object (a tagged `Maybe`, a case without payload or with positional arguments) rejects members besides its own; an integer type accepts only a whole number by spelling (`1.0` is not one); a float type rounds as in §15, and a number too large for it is an error; a `"_tag"` an open variant doesn't list reads as an unknown value, and MUST be a tag (§4): with no other member, the bare tag; with `"_args"` and no other member, its arguments read as self-describing values, and an `"_args"` that isn't a non-empty array is an error; otherwise all its other members read as a record payload by the import (16.1): `{"_tag": "Hexagon", "sides": 6}` reads as `Hexagon { sides: 6 }`. Anything else is an error. A `"_tag"` that isn't a string, or isn't a tag (§4), is `invalid-tag`. The string of a closed variant whose tags have no payload reads as a `"_tag"` does: one that isn't a tag (`"debug"`, `""`, `"1A"`) is `invalid-tag`, a tag the variant doesn't list (`"Warn"`) is `unknown-tag`. A positional case whose `"values"` isn't an array, or has the wrong number of elements, is `wrong-payload`, as in haus text (§15).

**Places.** An error reading JSON names its place in the JSON: member names and array indexes from the JSON text's root (`$.shape.values[1]`, `$.maybe.value`), so it can be found in the document read. As in §15, an error about an object as a whole is at the object: a missing member (an envelope without `_haus` is at `$`), a `"_tag"` that isn't a tag or isn't listed. These are at the member: a `_haus` other than 1 (`$._haus`), an `"_args"` that isn't a non-empty array (`$.shape._args`, `$._value._args`), a `_num` or `_bytes` that isn't one. The string of a closed variant whose tags have no payload is the variant's value, so an error about it is at the string (`$.level`). In JSON Lines the place starts with the line's index, `$[3].price`.

So a reader accepts the schema-based JSON of a newer minor version of its schema (§13.3): it ignores the new fields and reads the new tags as unknown values. Such an unknown value is the import's reading of the newer case, not that case ("Which form", above).

**Round trip.** For every value `v` that a type accepts, reading the schema-based JSON of `decode(v)` gives `decode(v)` back, and two different decoded values never have the same schema-based JSON.

## 17. Error codes

Every error an implementation reports has a **code**: a short lowercase name such as `payload-newline`, `null-literal` or `missing-field` that says which mistake was made. Messages are for people and differ between implementations; codes are for programs, tools and agents, and are the same everywhere.

The catalogue is [`errors.md`](errors.md), generated from its machine-readable source [`errors.haus`](errors.haus). It lists each code with what it means, an example and the usual fix, in eight categories: syntax (§1–§5), limits (§7), streams (§6), schema files (§14), imports (§13.3), decoding and encoding (§15), JSON (§16), and hints and warnings, which checkers and editors report without failing (§14).

**Rules.**

- A code is lowercase kebab-case: `[a-z][a-z0-9]*(-[a-z0-9]+)*`.
- Codes are stable. From version 1.0 on, a code is never renamed, removed or reused for another mistake; new codes may be added, in a new version of the catalogue.
- An implementation MUST report, with every error it reports, the catalogue's code for that mistake, and MUST NOT report a code that isn't in the catalogue. It MAY add detail of its own (a message, a hint, the values involved), but no codes of its own.
- A code names one mistake that its user can fix, not one message: a missing comma between two values is `missing-comma`, and a payload on the line after its tag is `payload-newline`, although both are found as "no comma where one is needed".
- Which error is reported when an input has several is not fixed (§8, §15). For an input with one mistake, every implementation reports the same code; the conformance suite checks this (test-suite/README.md).

**JSON form.** An implementation that reports errors to programs, as a library or a command-line tool, SHOULD offer each error as a JSON object:

```json
{
  "code": "payload-newline",
  "message": "expected ',' between top-level values, found '{'",
  "line": 2,
  "column": 1,
  "expected": "','",
  "found": "'{'",
  "hint": "Put the payload on the tag's line, or add a comma if they are two values.",
  "docs": "https://haus-fmt.org/docs/errors#payload-newline"
}
```

| Member | |
|---|---|
| `code` | the code, always |
| `message` | what went wrong, for people, without the position, always |
| `line`, `column` | the position (§8), for an error in text: haus, a schema file, JSON text |
| `path` | the place in the value (§15), for an error in a value: `$.items[2].price` |
| `expected`, `found` | what should be there and what is, where that is natural |
| `hint` | a concrete fix: the catalogue's fix for the code, or a better one for the case at hand |
| `docs` | the documentation of the code: `https://haus-fmt.org/docs/errors#<code>` |

Members that don't apply are left out. An error of a decoder that has no place in text has `path` and no `line` or `column`; invalid UTF-8 has neither when the decoder doesn't say where it is. An error inside a `Secret` (§15) gives the code `invalid-secret` and nothing of the value, in any member.

**Documentation.** `https://haus-fmt.org/docs/errors#<code>` documents every code, with an example and the fix.
