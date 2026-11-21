<!-- Generated from errors.haus by scripts/errors.ts. Don't edit: edit errors.haus and run `node spec/scripts/errors.ts`. -->

# Error codes

The catalogue of the error codes of [§17](README.md#17-error-codes). Every implementation reports these codes, the same in
every binding; a code is never renamed, removed or reused after 1.0, only added. Each code has a page section at
`https://haus-fmt.org/docs/errors#<code>`. The machine-readable source is [`errors.haus`](errors.haus).

115 codes in 8 categories:

- [Syntax](#syntax): 33
- [Limits](#limits): 8
- [Streams](#streams): 2
- [Schema files](#schema-files): 22
- [Imports](#imports): 21
- [Decoding and encoding](#decoding): 14
- [JSON](#json): 11
- [Hints and warnings](#hints): 4

## Syntax

<a id="syntax"></a>Reading haus text (§1–§5, [grammar.ebnf](grammar.ebnf)).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `invalid-utf8` | The input is not valid UTF-8 (§4): a byte sequence that encodes no character, an overlong form or a surrogate. Also an unpaired surrogate in a string of the language (UTF-16) given to a parser instead of bytes. | the bytes 22 FF 22: a quote, a byte that never starts a character, a quote | Save the file as UTF-8. |
| `version-directive` | The file starts with a `#haus` version directive (§10): it was written for a later, incompatible version of haus. | `#haus 2 ⏎ { a: 1 }` | Read the file with a version of haus that supports it. |
| `expected-value` | A value is missing: after a key's colon, between commas, or at the start of a file, something else comes where a value must be. | `{ a: }` | Write a value here, or remove the extra comma or bracket. |
| `missing-comma` | Two values, fields or top-level values follow each other without a comma between them. | `[1 2]` | Add a comma between the two values. |
| `payload-newline` | A tag is followed by `(` or `{` on a later line, or after a comment. A payload must start on the tag's line (§5), so the two are read as separate values, and a comma is missing between them. | `Heartbeat ⏎ { at: 1 }` | Put the payload on the tag's line, or add a comma if they are two values. |
| `unexpected-closer` | A closing bracket that doesn't match the open one, or that has no open one. | `[1}` | Close each bracket with its own kind (`{` `}`, `[` `]`, `(` `)`) and remove extra closing brackets. |
| `unclosed-bracket` | A `{`, `[` or `(` is never closed: the input ends first. | `[1, 2` | Add the closing bracket. |
| `null-literal` | `null` is not a value: haus has no null (§1). | `{ x: null }` | Write `None` (with a `Maybe` type), or leave the field out. |
| `boolean-literal` | `true` and `false` are not values: booleans are the tags `True` and `False` (§1). | `{ ok: true }` | Write `True` or `False`. |
| `bare-identifier` | A lowercase word where a value should be. Lowercase identifiers are only record keys. | `[foo]` | Quote it as a string, or start it with a capital letter to make it a tag. |
| `expected-key` | Something that can't be a record key where a key should be, such as a number or a comma. | `{ 1: 1 }` | Write a key: a lowercase identifier or a string. |
| `uppercase-key` | A record key starts with a capital letter. Bare keys start with a lowercase letter or `_`; capitalized words are tags. | `{ Name: 1 }` | Quote the key, or start it with a lowercase letter. |
| `block-string-key` | A block string (`"""`) is used as a record key. | `{ """ ⏎   k ⏎   """: 1 }` | Write the key as a basic string, `"…"`. |
| `missing-colon` | A record key is not followed by `:`. | `{ a 1 }` | Add `:` between the key and its value. |
| `duplicate-key` | A record has the same key twice, after escapes are read (`a` and `"a"` are the same key). Also a JSON object with the same member name twice (§16), and a record built in code that a writer, the canonical form or the hash is given (§11, §12). | `{ a: 1, a: 2 }` | Remove or rename one of the two. |
| `empty-payload` | A tag with empty parentheses, `Tag()`. A tag without arguments is written without them. | `Some()` | Remove the empty parentheses after the tag. |
| `invalid-number` | A number literal that doesn't follow the grammar (§3): a leading zero, a `+`, a `.` without digits on both sides, a misplaced `_`, an uppercase `0X`, digits followed by letters. Also a string that should hold a number literal and doesn't (a `Decimal` in schema-based JSON, §16.3), and a number built in code whose text isn't a literal (`01`, `NaN`) that a writer, the canonical form or the hash is given (§11, §12). | `007` | Write a decimal number (optional `-`, fraction and exponent) or a hex or binary integer, with `_` only between digits. |
| `unterminated-string` | A string has no closing `"` (in haus or JSON). | `"abc` | Add the closing quote. A quote inside the string is written `\"`. |
| `string-line-break` | A raw line break inside a `"…"` string. | `"a ⏎ b"` | Write the line break as `\n`, or use a `"""` block string. |
| `control-character` | A raw control character (C0, DEL, C1) in a string, block string or comment, where it could change what a terminal shows. A raw tab is allowed in block strings and comments, not in `"…"` strings. Also a raw control character in a JSON string: C0 in any JSON, DEL and C1 in self-describing JSON (§16). | "a⟨U+0007⟩b": a string with a raw BEL character | Write the character as an escape, `\u{…}`. |
| `bidi-control` | A raw bidirectional control character (U+202A–U+202E, U+2066–U+2069) in a string or comment, or in a self-describing JSON string (§16), where it could reorder how the text is displayed ("Trojan Source", §9). | // access⟨U+202E⟩ denied: a comment with a raw right-to-left override | Write it as an escape (`\u{…}`) inside a string, or remove it. |
| `invalid-escape` | A backslash followed by a character that doesn't start an escape. haus has `\"`, `\\`, `\n`, `\r`, `\t` and `\u{…}`; JSON has its own set. | `"\x41"` | Use one of the escapes of §4, or write `\\` for a backslash. |
| `invalid-unicode-escape` | A `\u` escape that isn't `\u{` 1 to 6 hex digits `}`, or names no Unicode scalar value (a surrogate, or above 10FFFF). In JSON: `\u` not followed by four hex digits. | `"\u0041"` | Write the escape with braces, `\u{…}`, for a character from U+0000 to U+10FFFF other than a surrogate. |
| `block-string-opening` | Text after the opening `"""` of a block string. The content starts on the next line. | `"""text ⏎ """` | Start the content on the line after `"""`. |
| `block-string-closing` | The closing `"""` of a block string has text before it on its line. | `""" ⏎   text"""` | Put the closing `"""` on its own line; its indentation is removed from every line. |
| `block-string-indent` | A line of a block string is indented less than the closing `"""`, whose indentation every line must start with. | `""" ⏎   a ⏎  b ⏎   """` | Indent every line at least as far as the closing `"""`. |
| `unterminated-block-string` | A block string has no closing `"""`. | `""" ⏎   abc` | Add the closing `"""` on its own line. |
| `unterminated-bytes` | A byte string `x"…` has no closing `"`. | `x"00` | Add the closing quote. |
| `bytes-not-hex` | A byte string holds something other than hex digits, spaces and tabs, such as a letter after `f`, an escape or a line break. | `x"zz"` | Write two hex digits per byte, on one line. |
| `bytes-odd-digits` | A byte in a byte string has only one hex digit: an odd number of digits, or a space inside a byte. | `x"abc"` | Write each byte as two hex digits. |
| `lone-carriage-return` | A carriage return (CR) not followed by a line feed. Line breaks are LF or CRLF. | 1,⟨CR⟩2: a carriage return on its own | Save the file with LF or CRLF line endings. |
| `unterminated-comment` | A `/*` comment is never closed. Block comments nest, so each `/*` needs its own `*/`. | `/* never closed` | Add `*/`, one for each `/*`. |
| `stray-slash` | A `/` that doesn't start a comment. Comments are `//` and `/* */`; haus has no operators. | `{ a: 1 / 2 }` | Write `//` or `/*` for a comment, or remove the `/`. |

## Limits

<a id="limits"></a>The resource limits of §7. Each can be configured; the defaults are in §7.

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `nesting-too-deep` | Records, arrays and payloads are nested deeper than the depth limit (default 256). In JSON, deeper than its JSON limit (§16). | [[[[ … ]]]]: 257 levels | Flatten the data, or raise the depth limit if you trust the input. |
| `number-too-long` | A number literal has more characters than the limit (default 1000), or a hex literal more hex digits than the number limit allows (default 829), so that every integer fits the limit in decimal (§7). | a number with 1001 digits | Write a shorter number (a `String` or `Bytes` for very long data), or raise the number length limit. |
| `exponent-too-large` | A number's exponent is larger than the limit (default 6144), in either direction. | `1e6145` | Write a number with a smaller exponent, or raise the exponent limit. |
| `string-too-long` | A string or byte string has more characters than the limit (default 16 Mi). | a string of 16,777,217 characters | Split the string, or raise the string length limit. |
| `key-too-long` | A record key has more characters than the string limit (default 16 Mi). | a bare key of 16,777,217 characters | Use a shorter key, or raise the string length limit. |
| `tag-too-long` | A tag has more characters than the string limit (default 16 Mi). | a tag of 16,777,217 characters | Use a shorter tag, or raise the string length limit. |
| `value-too-long` | One top-level value of a haus stream has more characters than the limit (default 64 Mi). A line of JSON Lines has no such limit (§16). | a stream whose second value is 64 Mi characters long | Send smaller values, or raise the value length limit. |
| `unsupported-depth` | The configured depth limit is above the deepest nesting the binding supports, or isn't a whole number (§7). Raised when the limits are set, not by any input. | maxDepth: 100000 | Configure a depth limit within the binding's documented maximum. |

## Streams

<a id="streams"></a>Sequences of values (§6).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `not-one-value` | One value was expected (a single document, a type that isn't a `Stream`), and the input holds none or several. | parse("1, 2"): two values where one is expected | Give exactly one value, or read the input as a stream. |
| `stream-truncated` | In strict mode, a stream ended without a comma (or, in JSON Lines, a line feed) after its last value, so the last value may be cut off (§6). | 1, 2, 3 (strict mode: the last value has no comma) | End every value with a comma, or check that the stream wasn't cut off. |

## Schema files

<a id="schema-files"></a>Schema files that implementations must reject (§14).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `schema-syntax` | A schema file doesn't follow the grammar: an unexpected token, a character that has no place there. Mistakes in the comments, whitespace and strings a schema file shares with data files (§14) have the codes they have there: `unterminated-string`, `unterminated-comment`, `lone-carriage-return`, `control-character`, `bidi-control`, `invalid-utf8`, `invalid-escape`. | `type A = { x Int }` | Write it as the grammar says (grammar.ebnf); the message names what was expected. |
| `unknown-type` | A type name that is neither defined in the file, imported, nor a prelude type. A type a standard module or official extension has needs its import. | `type A = { at: Date }` | Define the type, fix its spelling, or import it from the module that defines it. |
| `wrong-arity` | A type is used with the wrong number of arguments: `Array` without its element type, `Int` with one, a generic type of your own with too few or too many. | `type A = { key: Secret }` | Give the type exactly as many arguments as it has parameters. |
| `duplicate-type` | Two definitions of the same type name, or a definition with the name of an imported type. | `type A = Int ⏎ type A = String` | Rename one of them. |
| `redefine-prelude` | A definition with the name of a prelude type (`Int`, `Any`, `Secret`, `Maybe`, …), which schemas can't redefine. | `type Any = String` | Give your type another name. |
| `unknown-parameter` | A lowercase name in a type that is not a parameter of the definition. | `type Box = { item: a }` | Declare the parameter after the type's name, or use a type name. |
| `invalid-parameter` | A type parameter starting with `_`, or the same parameter twice in one definition. | `type Pair _ = { a: Int }` | Give each parameter its own lowercase name. |
| `underscore-type` | `_` used as a type. Types are open by default, so there is no wildcard. | `type A = { x: _ }` | Write `< >` for a variant with any tags, `Any` for any value, or use a type parameter. |
| `duplicate-field` | A record type lists the same field twice, also one copied in by a spread. | `type A = { x: Int, x: String }` | Remove or rename one of them. |
| `duplicate-tag` | A variant type lists the same tag twice, also one copied in by a spread. | `type A = < B \| B >` | Remove or rename one of them. |
| `closed-empty-variant` | `closed < >`: a closed variant without tags accepts nothing. | `type A = closed < >` | List its tags, or write `< >` for a variant with any tags. |
| `invalid-spread` | A spread of something that can't be spread: not a named type, a type with parameters, a `Stream`, or a record spread into a variant (or a variant into a record). | `type R = { x: Int } ⏎ type V = < ...R >` | Spread a named variant into a variant, or a named record into a record, without parameters. |
| `spread-cycle` | A type spreads itself, directly or through other types. | `type A = < ...B > ⏎ type B = < ...A >` | Break the cycle: let one of the types list its tags or fields itself. |
| `row-parameter` | A spread of a parameter, `...r`. Row parameters are not part of the language. | `type A r = { ...r, x: Int }` | Spread a named type instead, or nest the open part as a field with a type parameter. |
| `misplaced-stream` | `Stream` used anywhere but as the whole type of a definition, or a reference to such a definition. A stream is a whole file. | `type A = { events: Stream Int }` | Use `Array` inside types, and `Stream` only as the whole of a definition. |
| `unguarded-recursion` | A type refers to itself without a record field, array element or variant payload in between (§9.9), so decoding it would consume no input. `Secret` and names don't count as a step. | `type A = B ⏎ type B = A` | Put the recursion inside a record field, array element or variant payload. |
| `growing-recursion` | Generic types whose instances could grow without bound: a type parameter passes, wrapped in a bigger type, along a cycle of references back to itself (`type T a = < X (T (Pair a a)) >`, §9.10). | `type Nest a = < Leaf a \| Deeper (Nest (Array a)) >` | Refer to the type inside itself with exactly its own parameters. |
| `type-too-deep` | Type expressions are nested deeper than the schema parser's limit. | Array (Array (Array … )) nested 300 levels | Name the inner types with definitions of their own. |
| `attribute-arguments` | An attribute this version defines, given arguments it doesn't take: `@deprecated` takes nothing or one string. Also empty parentheses after an attribute. | `@deprecated(1) ⏎ type A = Int` | Give the attribute only the arguments it takes: `@deprecated` takes none, or one string. |
| `attribute-twice` | The same attribute twice on one type, field or tag. | `@deprecated @deprecated ⏎ type A = Int` | Keep one of them. |
| `attribute-space` | A space between an attribute's name and its `(`. | `type A = { @deprecated ("x") x: Int }` | Write the parenthesis right after the attribute's name, without a space. |
| `attribute-on-spread` | An attribute on a spread. The fields and tags a spread copies keep their own attributes. | `type B = { x: Int } ⏎ type A = { @deprecated ...B }` | Put the attribute on the fields or tags in the spread type. |

## Imports

<a id="imports"></a>Standard modules, schema packages and files (§13.3).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `unknown-module` | An import of a module that doesn't exist: an unknown standard module, a former standard module, or a name that is neither `std/…`, a package `@org/name` nor a file `./name`. | `import std/money (Money) ⏎ type A = Money` | Fix the module's name; a former standard module is now a package, which the message names. |
| `unknown-import` | An import names a type the module doesn't have, or no type at all. | `import std/time (Data) ⏎ type A = Int` | Import a type the module defines; the message lists them. |
| `duplicate-import` | The same type name is imported twice. | `import std/time (Date, Date) ⏎ type A = Date` | Import each name once. |
| `import-unavailable` | The schema imports a package or file, and the tool reading it has no way to find one (no module resolver): only standard modules can be imported there. | `import ./common (Address) ⏎ type A = Address` | Read the schema with a resolver that loads imports (from files or packages), or inline the types. |
| `import-not-found` | An imported package or file can't be found: it is not installed, the path is wrong, or the package found names another package in its manifest. | import @acme/geo (LatLng), with @acme/geo not installed | Install the package, or fix the path. |
| `import-version` | An import asks for a major version (`@org/name@2`) and another one is installed, or names something other than a major version: `@1.1`, `@1.1.0`, `@01`, `@x`. | `import @haus-fmt/money@1.1 (Money) ⏎ type A = Money` | Install the major version the schema asks for, or update the import. An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range. |
| `import-cycle` | Schema files import each other in a cycle. | a.schema.haus imports ./b, and b.schema.haus imports ./a | Move the shared types to a file both import. |
| `duplicate-package` | One schema reaches two different packages with the same name: two versions of one package (also two major versions), two copies of one version whose files differ, or two packages that call themselves the same. Byte-identical copies are one package. | @haus-fmt/money 1.4.0 in node_modules/@haus-fmt/money and 1.2.0 in node_modules/@acme/orders/node_modules/@haus-fmt/money | Install one copy of the package: align the version ranges and deduplicate (`npm dedupe`). On npm, declare schema packages a package imports as `peerDependencies`. |
| `undeclared-package` | A file imports a package that its package or project doesn't declare as a dependency (with npm: in the package's own `package.json`, or the nearest one above an application file), or a file with no `package.json` above it imports a package that wasn't given explicitly. A package found only because the package manager placed it nearby, such as a hoisted dependency of a dependency, could be replaced by another one placed there. Checked before the package is looked for. | @acme/orders imports @acme/common@1, and the package.json of @acme/orders doesn't list @acme/common | Add the package to the dependencies of the importing package or project (on npm, `peerDependencies` for a package). Outside an npm project, such as in a Cargo or Python project, give the package explicitly (`--package`, `--packages`, the editor's `haus.packages`, Python's `packages=`). |
| `package-manifest` | A package's `package.haus` is not a valid manifest: not one record, a `name` that isn't a lowercase `@org/name` (or has the part `node_modules`), a `version` that isn't a semantic version, or more than 64 KiB. | a package.haus with { name: "@Acme/Orders", version: "1" } | Write `{ name: "@org/name", version: "1.2.0" }`, in lowercase, with a full version. |
| `package-version` | A package's `package.haus` has another version than the package manager gives the package (the `version` of its `package.json`, its Cargo version). A check implementations SHOULD make (§13.3). | package.haus says 1.2.0, the package.json next to it 1.3.0 | Release both with the same version: change them together. |
| `package-path` | A schema package refers to a file it may not: its `schema.haus` imports a file (`import ./x`) instead of a package; its `package.haus`, `schema.haus` or `package.json` is a symbolic link or not a regular file; or a file outside any package imports a file in a package's directory (`import ./node_modules/x/y`). The file is not read. | a package whose schema.haus has import ../../.env (T) | A package is its `package.haus` and one `schema.haus`, and imports other packages by name (`import @org/name`); import a package by name from your own files too. |
| `package-name` | A package manager's name for a schema package differs from its manifest's: the `name` of its `package.json` isn't the `name` of its `package.haus`. On npm, imports find a package by that name, so it must be the manifest's (§13.3). Reported by package checks such as `haus package check`. | package.haus names @acme/orders, the package.json next to it @acme/order | Publish the package under its manifest's name: make the `name` of `package.json` the same. |
| `package-crate` | A schema package's crate can't be named by the code generated for crates that use its types: its `links` is missing or isn't its library's name (`[lib] name`), or a crate depends on a schema package's crate under another name (`package = …`). Generated code names a schema package's crate by its `links`, which is its library's name. Reported by package checks such as `haus package check`. | a Cargo.toml with links = "money" and [lib] name = "haus_money" | Set `links` to the library's name in `[package]`, and depend on schema package crates under their own names. |
| `package-install-script` | A schema package runs code when it is installed: an npm `preinstall`, `install` or `postinstall` script, or a `binding.gyp`, for which npm runs node-gyp. A schema package is data and MUST NOT need code to install (§13.3). | a package.json with "scripts": { "postinstall": "node setup.js" } | Remove the script: a schema package is its manifest, its schema and its profiles, and needs nothing run. |
| `package-files` | A package manager's configuration doesn't ship a file of the schema package: `package.haus`, `schema.haus`, or a profile's vectors or rule. Read from the configuration (`files` of `package.json`, `include` of `Cargo.toml`, a wheel's build configuration), without packing anything. | a package.json with "files": ["schema.haus"], without package.haus | List `package.haus`, `schema.haus` and `profiles` in what the package manager ships. |
| `profile-vectors` | A profile of a schema package is malformed (§13.3): it has no rule (`profiles/<name>.md`) next to its vectors; a vector isn't `Accept { type, value, output?, note? }` or `Reject { type, value, note? }` with string fields and no others (only an `Accept` has an `output`); its `type` isn't a type of the package without parameters; its `value` or `output` isn't one haus value; or an accepted value or its output isn't valid for its type, which a codec running after the schema can't accept. Also a profile name that isn't lowercase, and a vectors file with no vectors. | Reject { type: "Money", value: "Money(1, US)", output: "Money(1, US)" } | Write the rule in `profiles/<name>.md`, and each vector as `Accept { type: "T", value: "…" }` or `Reject { type: "T", value: "…" }`, with values valid for `T`. |
| `package-wrapper` | A package manager's file of a schema package can't be read as one: a `package.json` that isn't a JSON object or has no `name`, a `Cargo.toml` or `pyproject.toml` that isn't valid TOML, a `Cargo.toml` without `[package]`. Reported by package checks such as `haus package check`. | a Cargo.toml with [package without its closing bracket | Fix the file so that its package manager can read it. |
| `codec-unreachable` | A codec's type occurs where this binding can't apply the codec, such as the payload of a record case whose fields sit beside its tag in the host value. Decoding there with the default host type would silently differ from the other bindings (§13.4). | a codec for app#Rec, the payload of the record case Box (TypeScript Effect) | Give the codec's type a place of its own (a field), or decode the outer type yourself; the message names where the type occurs. |
| `file-too-large` | A schema file or a package's `package.json` is larger than the tool allows (1 MiB by default). It is not read. | an imported common.schema.haus of 3 MiB | Split the schema into several files, or raise the limit if you trust the file. |
| `too-many-files` | A schema imports more schema files, directly or not, than the tool allows (256 by default, the root included), or a folder of packages has more entries than allowed (4096). | a schema whose imports reach 300 files | Import fewer files. |

## Decoding and encoding

<a id="decoding"></a>Values that don't fit a schema type (§15), and values a program can't encode.

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `type-mismatch` | A value of another kind than the type accepts: a string for an `Int`, an array for a record, a tag that isn't `True` or `False` for a `Bool`. Decoders never convert between kinds (§15). | `{ qty: "2" }` with `type Root = { qty: Int }` | Write a value of the expected type; the message says which. |
| `not-an-integer` | A number with a fraction or an exponent where an integer type is expected. `1.0` and `1e3` are not whole numbers by spelling (§15). | `{ qty: 1.0 }` with `type Root = { qty: Int }` | Write the integer without a fraction or exponent. |
| `out-of-range` | A number outside the type's range: an `Int8` above 127, a negative `UInt32`, a float too large for `Float32`. Never wrapped or clamped. | `{ age: 300 }` with `type Root = { age: UInt8 }` | Write a value within the range, or use a larger type (`Int`, `Float64`, `Decimal`). |
| `missing-field` | A record lacks a field the type requires. Only fields with `?` may be missing; `None` is not missing. | `{ id: 1 }` with `type Root = { id: Int, name: String }` | Add the field, or mark it optional in the schema with `?` after its name. |
| `unknown-field` | A field a closed record doesn't list. Open records ignore such fields (see `unlisted-field`). | `{ id: 1, extra: 2 }` with `type Root = closed { id: Int }` | Remove the field, fix its spelling, or add it to the schema. |
| `unknown-tag` | A tag a closed variant doesn't list. Open variants read it as an unknown value (see `unlisted-tag`). | `Blue` with `type Root = closed < Red \| Green >` | Use one of the variant's tags, fix the spelling, or add the tag to the schema. |
| `wrong-payload` | A listed tag with another payload than its case says: arguments for a tag without payload, the wrong number of arguments, a positional payload where a record is expected, such as `Circle(1.5)` for the case `Circle { r: Float64 }` (§15). | `Some(1, 2)` with `type Root = closed < None \| Some Int >` | Write the payload the schema gives the tag: none, one record, or its positional arguments; the message says which. |
| `invalid-time` | A std/time value whose text the std/time profile rejects: a day that doesn't exist, a missing offset, a lowercase `t` (spec/std/time.md). | `{ on: Date("2026-02-30") }` with `import std/time (Date) ⏎ type Root = { on: Date }` | Write the date or time as the std/time profile says (spec/std/time.md); the message names the type. |
| `invalid-secret` | A value of a `Secret` type that its type doesn't accept, when decoding, or that can't be written, when encoding. The error names the place and the type only, never the value or why it failed (§15). | `{ key: 42 }` with `type Root = { key: Secret String }` | Write a value of the secret's type; the value isn't shown, so check it where it comes from. |
| `codec-rejected` | A value its type's schema accepts and a codec rejects (§13.4), such as an amount whose currency isn't in ISO 4217 for the `@haus-fmt/money/iso` profile. At the place of the codec's type. | Money(1, US) decoded with the codec of the profile @haus-fmt/money/iso: US is no ISO 4217 currency | Write a value the codec accepts; the profile's rule (profiles/<name>.md) or the codec's documentation says which. |
| `cannot-encode` | Encoding: a value of the program's language that the type can't write, such as a JavaScript number for an `Int` that expects a bigint, or a string that is no valid `Date`. Writing a value built in code (§11, §12): a string, key or tag with an unpaired surrogate, which has no UTF-8 form, or something that is no haus value. | encode(h.Int, 5): Int is a bigint, 5 is a number | Pass a value of the host type the binding documents for the type. |
| `cyclic-value` | Encoding: a value contains itself, so it has no finite text. | const a = { children: [] }; a.children.push(a); encode(Tree, a) | Break the cycle before encoding. |
| `step-budget` | Decoding or encoding took more steps than the input justifies, a sign of a schema doing unbounded work. Bindings MUST bound the work of one decode (§9.8). | a hand-written schema that decodes each value many times | Simplify the schema, or raise the step limit if the work is expected. |
| `too-many-nodes` | A value built in code (not parsed) has more nodes than the call allows, or shares nodes so much that it would expand beyond the limits. | a value built in code whose arrays share one another a million times | Build a smaller value, or raise the limit. |

## JSON

<a id="json"></a>The JSON mappings (§16).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `json-syntax` | Text that isn't JSON (RFC 8259): a missing comma or colon, an unquoted name, a trailing comma, a comment, text after the value. Also an empty line in JSON Lines, or a byte order mark at the start of a line after the first. | `{"_haus": 1,}` | Write valid JSON; the message says what was expected. |
| `unpaired-surrogate` | A JSON string with half of a UTF-16 surrogate pair, raw or as `\uD800`. I-JSON forbids them, and they are no Unicode characters (§16). | `{"_haus": 1, "_value": "\uD800"}` | Write both halves of the surrogate pair, or the character itself. |
| `haus-json-form` | JSON that isn't self-describing JSON (§16.2): a text without the envelope `{"_haus": 1, "_value": …}`, an envelope with other members, a bare number, `true`, `null`, an object with other members, a `_rec` that isn't an object, an `_args` that isn't a non-empty array. | `{"_haus": 1, "_value": 1}` | Write the envelope with one of the forms of §16.2 in `_value`: a string, an array, or an object with `_num`, `_bytes`, `_rec`, or `_tag` (and `_args`). For ordinary JSON, read it with a schema or import it instead. |
| `haus-json-version` | A self-describing JSON envelope whose `_haus` isn't 1, the only version of the form (§16.2): it was written for a later version of haus, or isn't haus. | `{"_haus": 2, "_value": "a"}` | Read it with a newer version of haus, or write `"_haus": 1`. |
| `haus-json-number` | A self-describing `_num` that isn't a normalized number literal (§2): `"1E5"`, `"01"`, `"0xff"`, or not a string. | `{"_haus": 1, "_value": {"_num": "1E5"}}` | Write the number's normalized literal (§2) as a string. |
| `haus-json-bytes` | A self-describing `_bytes` that isn't two lowercase hex digits per byte. | `{"_haus": 1, "_value": {"_bytes": "FF"}}` | Write the bytes as lowercase hex, two digits per byte. |
| `invalid-tag` | A tag name that isn't `[A-Z][A-Za-z0-9_]*`, or a `"_tag"` that isn't a string: in a `_tag` of either JSON form, in the string of a closed variant whose tags have no payload in schema-based JSON (`"debug"`, §16.3), or in a value built in code. | `{"_haus": 1, "_value": {"_tag": "lower"}}` | Start the tag with a capital letter and use only letters, digits and `_`. |
| `invalid-base64` | Schema-based JSON `Bytes` that aren't canonical base64 with padding (RFC 4648 §4): whitespace, the URL alphabet, missing padding, non-zero pad bits. | `"CzQ"` with `type Root = Bytes` | Write standard base64, with padding. |
| `missing-member` | Schema-based JSON: an object lacks a member its form needs, such as `"_tag"` for a variant or `"value"` for a tag with one argument. | `{"_tag": "Ok"}` with `type Root = < Ok Int \| Err String >` | Add the member the message names. |
| `unexpected-member` | Schema-based JSON: an object has a member its form doesn't have, such as `"value"` next to a tag without payload (§16.3). | `{"_tag": "Empty", "value": 1}` with `type Root = < Ok Int \| Empty >` | Remove the member. |
| `no-json-form` | A value or type that has no JSON form: a string with an unpaired surrogate, a record payload with a field named `_tag` or `_args` in schema-based JSON (§16.3), a type with no schema-based form. | toJson of Odd { _tag: 1 }, for the case `Odd { _tag: Int32 }` | Rename the field, or use self-describing JSON. |

## Hints and warnings

<a id="hints"></a>Reported by checkers and editors without failing (§14).

| Code | Meaning | Example | Fix |
|---|---|---|---|
| `unknown-attribute` | A warning: an attribute this version of haus doesn't define. It is accepted and has no meaning (§14). | `@since("1.2") ⏎ type A = Int` | Check the spelling; attributes of a later version are fine. |
| `deprecated` | A hint: the schema or the data uses a type, field or tag marked `@deprecated` (§14). | `{ mail: "a@b.c" }` with `type Root = { @deprecated("use email") mail?: String, email?: String }` | Use what the deprecation note says instead. |
| `unlisted-field` | A hint: a field an open record doesn't list. A reader ignores it, but it may be a typo. | `{ name: "a", nmae: "b" }` with `type Root = { name: String }` | Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers. |
| `unlisted-tag` | A hint: a tag an open variant doesn't list. A reader keeps it as an unknown value, but it may be a typo. | `Gren` with `type Root = < Red \| Green >` | Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers. |
