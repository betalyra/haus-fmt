---
title: Error codes
description: Every error haus reports, with its stable code, an example and the fix.
---

<!-- Generated from spec/errors.haus by spec/scripts/errors.ts. Don't edit: edit spec/errors.haus and run `node spec/scripts/errors.ts`. -->

Every error haus reports has a **code**: a short name such as `payload-newline` that is the same in every binding and never changes. Look it up here, or match on it in code. The specification defines them in [§17](/docs/spec#17-error-codes).

Bindings also give each error as JSON, so tools and agents can act on it:

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

`hint` is the fix below, unless a binding knows a better one for the case at hand. `path` (`$.items[2].price`) says where in the value a schema error is.

**Syntax:** [invalid-utf8](#invalid-utf8), [version-directive](#version-directive), [expected-value](#expected-value), [missing-comma](#missing-comma), [payload-newline](#payload-newline), [unexpected-closer](#unexpected-closer), [unclosed-bracket](#unclosed-bracket), [null-literal](#null-literal), [boolean-literal](#boolean-literal), [bare-identifier](#bare-identifier), [expected-key](#expected-key), [uppercase-key](#uppercase-key), [block-string-key](#block-string-key), [missing-colon](#missing-colon), [duplicate-key](#duplicate-key), [empty-payload](#empty-payload), [invalid-number](#invalid-number), [unterminated-string](#unterminated-string), [string-line-break](#string-line-break), [control-character](#control-character), [bidi-control](#bidi-control), [invalid-escape](#invalid-escape), [invalid-unicode-escape](#invalid-unicode-escape), [block-string-opening](#block-string-opening), [block-string-closing](#block-string-closing), [block-string-indent](#block-string-indent), [unterminated-block-string](#unterminated-block-string), [unterminated-bytes](#unterminated-bytes), [bytes-not-hex](#bytes-not-hex), [bytes-odd-digits](#bytes-odd-digits), [lone-carriage-return](#lone-carriage-return), [unterminated-comment](#unterminated-comment), [stray-slash](#stray-slash)

**Limits:** [nesting-too-deep](#nesting-too-deep), [number-too-long](#number-too-long), [exponent-too-large](#exponent-too-large), [string-too-long](#string-too-long), [key-too-long](#key-too-long), [tag-too-long](#tag-too-long), [value-too-long](#value-too-long), [unsupported-depth](#unsupported-depth)

**Streams:** [not-one-value](#not-one-value), [stream-truncated](#stream-truncated)

**Schema files:** [schema-syntax](#schema-syntax), [unknown-type](#unknown-type), [wrong-arity](#wrong-arity), [duplicate-type](#duplicate-type), [redefine-prelude](#redefine-prelude), [unknown-parameter](#unknown-parameter), [invalid-parameter](#invalid-parameter), [underscore-type](#underscore-type), [duplicate-field](#duplicate-field), [duplicate-tag](#duplicate-tag), [closed-empty-variant](#closed-empty-variant), [invalid-spread](#invalid-spread), [spread-cycle](#spread-cycle), [row-parameter](#row-parameter), [misplaced-stream](#misplaced-stream), [unguarded-recursion](#unguarded-recursion), [growing-recursion](#growing-recursion), [type-too-deep](#type-too-deep), [attribute-arguments](#attribute-arguments), [attribute-twice](#attribute-twice), [attribute-space](#attribute-space), [attribute-on-spread](#attribute-on-spread)

**Imports:** [unknown-module](#unknown-module), [unknown-import](#unknown-import), [duplicate-import](#duplicate-import), [import-unavailable](#import-unavailable), [import-not-found](#import-not-found), [import-version](#import-version), [import-cycle](#import-cycle), [duplicate-package](#duplicate-package), [undeclared-package](#undeclared-package), [package-manifest](#package-manifest), [package-version](#package-version), [package-path](#package-path), [package-name](#package-name), [package-crate](#package-crate), [package-install-script](#package-install-script), [package-files](#package-files), [profile-vectors](#profile-vectors), [package-wrapper](#package-wrapper), [codec-unreachable](#codec-unreachable), [file-too-large](#file-too-large), [too-many-files](#too-many-files)

**Decoding and encoding:** [type-mismatch](#type-mismatch), [not-an-integer](#not-an-integer), [out-of-range](#out-of-range), [missing-field](#missing-field), [unknown-field](#unknown-field), [unknown-tag](#unknown-tag), [wrong-payload](#wrong-payload), [invalid-time](#invalid-time), [invalid-secret](#invalid-secret), [cannot-encode](#cannot-encode), [cyclic-value](#cyclic-value), [step-budget](#step-budget), [too-many-nodes](#too-many-nodes)

**JSON:** [json-syntax](#json-syntax), [unpaired-surrogate](#unpaired-surrogate), [haus-json-form](#haus-json-form), [haus-json-version](#haus-json-version), [haus-json-number](#haus-json-number), [haus-json-bytes](#haus-json-bytes), [invalid-tag](#invalid-tag), [invalid-base64](#invalid-base64), [missing-member](#missing-member), [unexpected-member](#unexpected-member), [no-json-form](#no-json-form)

**Hints and warnings:** [unknown-attribute](#unknown-attribute), [deprecated](#deprecated), [unlisted-field](#unlisted-field), [unlisted-tag](#unlisted-tag)

## invalid-utf8

*Syntax.* The input is not valid UTF-8 (§4): a byte sequence that encodes no character, an overlong form or a surrogate.

For example: the bytes 22 FF 22: a quote, a byte that never starts a character, a quote.

**Fix:** Save the file as UTF-8.

## version-directive

*Syntax.* The file starts with a `#haus` version directive (§10): it was written for a later, incompatible version of haus.

```haus
#haus 2
{ a: 1 }
```

**Fix:** Read the file with a version of haus that supports it.

## expected-value

*Syntax.* A value is missing: after a key's colon, between commas, or at the start of a file, something else comes where a value must be.

```haus
{ a: }
```

**Fix:** Write a value here, or remove the extra comma or bracket.

## missing-comma

*Syntax.* Two values, fields or top-level values follow each other without a comma between them.

```haus
[1 2]
```

**Fix:** Add a comma between the two values.

## payload-newline

*Syntax.* A tag is followed by `(` or `{` on a later line, or after a comment. A payload must start on the tag's line (§5), so the two are read as separate values, and a comma is missing between them.

```haus
Heartbeat
{ at: 1 }
```

**Fix:** Put the payload on the tag's line, or add a comma if they are two values.

## unexpected-closer

*Syntax.* A closing bracket that doesn't match the open one, or that has no open one.

```haus
[1}
```

**Fix:** Close each bracket with its own kind (`{` `}`, `[` `]`, `(` `)`) and remove extra closing brackets.

## unclosed-bracket

*Syntax.* A `{`, `[` or `(` is never closed: the input ends first.

```haus
[1, 2
```

**Fix:** Add the closing bracket.

## null-literal

*Syntax.* `null` is not a value: haus has no null (§1).

```haus
{ x: null }
```

**Fix:** Write `None` (with a `Maybe` type), or leave the field out.

## boolean-literal

*Syntax.* `true` and `false` are not values: booleans are the tags `True` and `False` (§1).

```haus
{ ok: true }
```

**Fix:** Write `True` or `False`.

## bare-identifier

*Syntax.* A lowercase word where a value should be. Lowercase identifiers are only record keys.

```haus
[foo]
```

**Fix:** Quote it as a string, or start it with a capital letter to make it a tag.

## expected-key

*Syntax.* Something that can't be a record key where a key should be, such as a number or a comma.

```haus
{ 1: 1 }
```

**Fix:** Write a key: a lowercase identifier or a string.

## uppercase-key

*Syntax.* A record key starts with a capital letter. Bare keys start with a lowercase letter or `_`; capitalized words are tags.

```haus
{ Name: 1 }
```

**Fix:** Quote the key, or start it with a lowercase letter.

## block-string-key

*Syntax.* A block string (`"""`) is used as a record key.

```haus
{ """
  k
  """: 1 }
```

**Fix:** Write the key as a basic string, `"…"`.

## missing-colon

*Syntax.* A record key is not followed by `:`.

```haus
{ a 1 }
```

**Fix:** Add `:` between the key and its value.

## duplicate-key

*Syntax.* A record has the same key twice, after escapes are read (`a` and `"a"` are the same key). Also a JSON object with the same member name twice (§16).

```haus
{ a: 1, a: 2 }
```

**Fix:** Remove or rename one of the two.

## empty-payload

*Syntax.* A tag with empty parentheses, `Tag()`. A tag without arguments is written without them.

```haus
Some()
```

**Fix:** Remove the empty parentheses after the tag.

## invalid-number

*Syntax.* A number literal that doesn't follow the grammar (§3): a leading zero, a `+`, a `.` without digits on both sides, a misplaced `_`, an uppercase `0X`, digits followed by letters. Also a string that should hold a number literal and doesn't (a `Decimal` in schema-based JSON, §16.3).

```haus
007
```

**Fix:** Write a decimal number (optional `-`, fraction and exponent) or a hex or binary integer, with `_` only between digits.

## unterminated-string

*Syntax.* A string has no closing `"` (in haus or JSON).

```haus
"abc
```

**Fix:** Add the closing quote. A quote inside the string is written `\"`.

## string-line-break

*Syntax.* A raw line break inside a `"…"` string.

```haus
"a
b"
```

**Fix:** Write the line break as `\n`, or use a `"""` block string.

## control-character

*Syntax.* A raw control character (C0, DEL, C1) in a string, block string or comment, where it could change what a terminal shows. A raw tab is allowed in block strings and comments, not in `"…"` strings. Also a raw control character in a JSON string: C0 in any JSON, DEL and C1 in self-describing JSON (§16).

For example: "a⟨U+0007⟩b": a string with a raw BEL character.

**Fix:** Write the character as an escape, `\u{…}`.

## bidi-control

*Syntax.* A raw bidirectional control character (U+202A–U+202E, U+2066–U+2069) in a string or comment, or in a self-describing JSON string (§16), where it could reorder how the text is displayed ("Trojan Source", §9).

For example: // access⟨U+202E⟩ denied: a comment with a raw right-to-left override.

**Fix:** Write it as an escape (`\u{…}`) inside a string, or remove it.

## invalid-escape

*Syntax.* A backslash followed by a character that doesn't start an escape. haus has `\"`, `\\`, `\n`, `\r`, `\t` and `\u{…}`; JSON has its own set.

```haus
"\x41"
```

**Fix:** Use one of the escapes of §4, or write `\\` for a backslash.

## invalid-unicode-escape

*Syntax.* A `\u` escape that isn't `\u{` 1 to 6 hex digits `}`, or names no Unicode scalar value (a surrogate, or above 10FFFF). In JSON: `\u` not followed by four hex digits.

```haus
"\u0041"
```

**Fix:** Write the escape with braces, `\u{…}`, for a character from U+0000 to U+10FFFF other than a surrogate.

## block-string-opening

*Syntax.* Text after the opening `"""` of a block string. The content starts on the next line.

```haus
"""text
"""
```

**Fix:** Start the content on the line after `"""`.

## block-string-closing

*Syntax.* The closing `"""` of a block string has text before it on its line.

```haus
"""
  text"""
```

**Fix:** Put the closing `"""` on its own line; its indentation is removed from every line.

## block-string-indent

*Syntax.* A line of a block string is indented less than the closing `"""`, whose indentation every line must start with.

```haus
"""
  a
 b
  """
```

**Fix:** Indent every line at least as far as the closing `"""`.

## unterminated-block-string

*Syntax.* A block string has no closing `"""`.

```haus
"""
  abc
```

**Fix:** Add the closing `"""` on its own line.

## unterminated-bytes

*Syntax.* A byte string `x"…` has no closing `"`.

```haus
x"00
```

**Fix:** Add the closing quote.

## bytes-not-hex

*Syntax.* A byte string holds something other than hex digits, spaces and tabs, such as a letter after `f`, an escape or a line break.

```haus
x"zz"
```

**Fix:** Write two hex digits per byte, on one line.

## bytes-odd-digits

*Syntax.* A byte in a byte string has only one hex digit: an odd number of digits, or a space inside a byte.

```haus
x"abc"
```

**Fix:** Write each byte as two hex digits.

## lone-carriage-return

*Syntax.* A carriage return (CR) not followed by a line feed. Line breaks are LF or CRLF.

For example: 1,⟨CR⟩2: a carriage return on its own.

**Fix:** Save the file with LF or CRLF line endings.

## unterminated-comment

*Syntax.* A `/*` comment is never closed. Block comments nest, so each `/*` needs its own `*/`.

```haus
/* never closed
```

**Fix:** Add `*/`, one for each `/*`.

## stray-slash

*Syntax.* A `/` that doesn't start a comment. Comments are `//` and `/* */`; haus has no operators.

```haus
{ a: 1 / 2 }
```

**Fix:** Write `//` or `/*` for a comment, or remove the `/`.

## nesting-too-deep

*Limits.* Records, arrays and payloads are nested deeper than the depth limit (default 256). In JSON, deeper than its JSON limit (§16).

For example: [[[[ … ]]]]: 257 levels.

**Fix:** Flatten the data, or raise the depth limit if you trust the input.

## number-too-long

*Limits.* A number literal has more characters than the limit (default 1000), or a hex literal more hex digits than the number limit allows (default 829), so that every integer fits the limit in decimal (§7).

For example: a number with 1001 digits.

**Fix:** Write a shorter number (a `String` or `Bytes` for very long data), or raise the number length limit.

## exponent-too-large

*Limits.* A number's exponent is larger than the limit (default 6144), in either direction.

```haus
1e6145
```

**Fix:** Write a number with a smaller exponent, or raise the exponent limit.

## string-too-long

*Limits.* A string or byte string has more characters than the limit (default 16 Mi).

For example: a string of 16,777,217 characters.

**Fix:** Split the string, or raise the string length limit.

## key-too-long

*Limits.* A record key has more characters than the string limit (default 16 Mi).

For example: a bare key of 16,777,217 characters.

**Fix:** Use a shorter key, or raise the string length limit.

## tag-too-long

*Limits.* A tag has more characters than the string limit (default 16 Mi).

For example: a tag of 16,777,217 characters.

**Fix:** Use a shorter tag, or raise the string length limit.

## value-too-long

*Limits.* One top-level value of a stream (or one line of JSON Lines) has more characters than the limit (default 64 Mi).

For example: a stream whose second value is 64 Mi characters long.

**Fix:** Send smaller values, or raise the value length limit.

## unsupported-depth

*Limits.* The configured depth limit is above the deepest nesting the binding supports, or isn't a whole number (§7). Raised when the limits are set, not by any input.

For example: maxDepth: 100000.

**Fix:** Configure a depth limit within the binding's documented maximum.

## not-one-value

*Streams.* One value was expected (a single document, a type that isn't a `Stream`), and the input holds none or several.

For example: parse("1, 2"): two values where one is expected.

**Fix:** Give exactly one value, or read the input as a stream.

## stream-truncated

*Streams.* In strict mode, a stream ended without a comma (or, in JSON Lines, a line feed) after its last value, so the last value may be cut off (§6).

For example: 1, 2, 3 (strict mode: the last value has no comma).

**Fix:** End every value with a comma, or check that the stream wasn't cut off.

## schema-syntax

*Schema files.* A schema file doesn't follow the grammar: an unexpected token, a character that has no place there. Mistakes in the comments, whitespace and strings a schema file shares with data files (§14) have the codes they have there: `unterminated-string`, `unterminated-comment`, `lone-carriage-return`, `control-character`, `bidi-control`, `invalid-utf8`, `invalid-escape`.

```haus-schema
type A = { x Int }
```

**Fix:** Write it as the grammar says (grammar.ebnf); the message names what was expected.

## unknown-type

*Schema files.* A type name that is neither defined in the file, imported, nor a prelude type. A type a standard module or official extension has needs its import.

```haus-schema
type A = { at: Date }
```

**Fix:** Define the type, fix its spelling, or import it from the module that defines it.

## wrong-arity

*Schema files.* A type is used with the wrong number of arguments: `Array` without its element type, `Int` with one, a generic type of your own with too few or too many.

```haus-schema
type A = { key: Secret }
```

**Fix:** Give the type exactly as many arguments as it has parameters.

## duplicate-type

*Schema files.* Two definitions of the same type name, or a definition with the name of an imported type.

```haus-schema
type A = Int
type A = String
```

**Fix:** Rename one of them.

## redefine-prelude

*Schema files.* A definition with the name of a prelude type (`Int`, `Any`, `Secret`, `Maybe`, …), which schemas can't redefine.

```haus-schema
type Any = String
```

**Fix:** Give your type another name.

## unknown-parameter

*Schema files.* A lowercase name in a type that is not a parameter of the definition.

```haus-schema
type Box = { item: a }
```

**Fix:** Declare the parameter after the type's name, or use a type name.

## invalid-parameter

*Schema files.* A type parameter named `_`, or the same parameter twice.

```haus-schema
type Pair _ = { a: Int }
```

**Fix:** Give each parameter its own lowercase name.

## underscore-type

*Schema files.* `_` used as a type. Types are open by default, so there is no wildcard.

```haus-schema
type A = { x: _ }
```

**Fix:** Write `< >` for a variant with any tags, `Any` for any value, or use a type parameter.

## duplicate-field

*Schema files.* A record type lists the same field twice, also one copied in by a spread.

```haus-schema
type A = { x: Int, x: String }
```

**Fix:** Remove or rename one of them.

## duplicate-tag

*Schema files.* A variant type lists the same tag twice, also one copied in by a spread.

```haus-schema
type A = < B | B >
```

**Fix:** Remove or rename one of them.

## closed-empty-variant

*Schema files.* `closed < >`: a closed variant without tags accepts nothing.

```haus-schema
type A = closed < >
```

**Fix:** List its tags, or write `< >` for a variant with any tags.

## invalid-spread

*Schema files.* A spread of something that can't be spread: not a named type, a type with parameters, a `Stream`, or a record spread into a variant (or a variant into a record).

```haus-schema
type R = { x: Int }
type V = < ...R >
```

**Fix:** Spread a named variant into a variant, or a named record into a record, without parameters.

## spread-cycle

*Schema files.* A type spreads itself, directly or through other types.

```haus-schema
type A = < ...B >
type B = < ...A >
```

**Fix:** Break the cycle: let one of the types list its tags or fields itself.

## row-parameter

*Schema files.* A spread of a parameter, `...r`. Row parameters are not part of the language.

```haus-schema
type A r = { ...r, x: Int }
```

**Fix:** Spread a named type instead, or nest the open part as a field with a type parameter.

## misplaced-stream

*Schema files.* `Stream` used anywhere but as the whole type of a definition, or a reference to such a definition. A stream is a whole file.

```haus-schema
type A = { events: Stream Int }
```

**Fix:** Use `Array` inside types, and `Stream` only as the whole of a definition.

## unguarded-recursion

*Schema files.* A type refers to itself without a record field, array element or variant payload in between (§9.9), so decoding it would consume no input. `Secret` and names don't count as a step.

```haus-schema
type A = B
type B = A
```

**Fix:** Put the recursion inside a record field, array element or variant payload.

## growing-recursion

*Schema files.* A generic type refers to itself, directly or through definitions that refer back to it, with arguments other than its own parameters (§9.10), so its instances could grow without bound.

```haus-schema
type Nest a = < Leaf a | Deeper (Nest (Array a)) >
```

**Fix:** Refer to the type inside itself with exactly its own parameters.

## type-too-deep

*Schema files.* Type expressions are nested deeper than the schema parser's limit.

For example: Array (Array (Array … )) nested 300 levels.

**Fix:** Name the inner types with definitions of their own.

## attribute-arguments

*Schema files.* An attribute this version defines, given arguments it doesn't take: `@deprecated` takes nothing or one string. Also empty parentheses after an attribute.

```haus-schema
@deprecated(1)
type A = Int
```

**Fix:** Give the attribute only the arguments it takes: `@deprecated` takes none, or one string.

## attribute-twice

*Schema files.* The same attribute twice on one type, field or tag.

```haus-schema
@deprecated @deprecated
type A = Int
```

**Fix:** Keep one of them.

## attribute-space

*Schema files.* A space between an attribute's name and its `(`.

```haus-schema
type A = { @deprecated ("x") x: Int }
```

**Fix:** Write the parenthesis right after the attribute's name, without a space.

## attribute-on-spread

*Schema files.* An attribute on a spread. The fields and tags a spread copies keep their own attributes.

```haus-schema
type B = { x: Int }
type A = { @deprecated ...B }
```

**Fix:** Put the attribute on the fields or tags in the spread type.

## unknown-module

*Imports.* An import of a module that doesn't exist: an unknown standard module, a former standard module, or a name that is neither `std/…`, a package `@org/name` nor a file `./name`.

```haus-schema
import std/money (Money)
type A = Money
```

**Fix:** Fix the module's name; a former standard module is now a package, which the message names.

## unknown-import

*Imports.* An import names a type the module doesn't have, or no type at all.

```haus-schema
import std/time (Data)
type A = Int
```

**Fix:** Import a type the module defines; the message lists them.

## duplicate-import

*Imports.* The same type name is imported twice.

```haus-schema
import std/time (Date, Date)
type A = Date
```

**Fix:** Import each name once.

## import-unavailable

*Imports.* The schema imports a package or file, and the tool reading it has no way to find one (no module resolver): only standard modules can be imported there.

```haus-schema
import ./common (Address)
type A = Address
```

**Fix:** Read the schema with a resolver that loads imports (from files or packages), or inline the types.

## import-not-found

*Imports.* An imported package or file can't be found: it is not installed, the path is wrong, or the package found names another package in its manifest.

For example: import @acme/geo (LatLng), with @acme/geo not installed.

**Fix:** Install the package, or fix the path.

## import-version

*Imports.* An import asks for a major version (`@org/name@2`) and another one is installed, or names something other than a major version: `@1.1`, `@1.1.0`, `@01`, `@x`.

```haus-schema
import @haus-fmt/money@1.1 (Money)
type A = Money
```

**Fix:** Install the major version the schema asks for, or update the import. An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range.

## import-cycle

*Imports.* Schema files import each other in a cycle.

For example: a.schema.haus imports ./b, and b.schema.haus imports ./a.

**Fix:** Move the shared types to a file both import.

## duplicate-package

*Imports.* One schema reaches two different packages with the same name: two versions of one package (also two major versions), two copies of one version whose files differ, or two packages that call themselves the same. Byte-identical copies are one package.

For example: @haus-fmt/money 1.4.0 in node_modules/@haus-fmt/money and 1.2.0 in node_modules/@acme/orders/node_modules/@haus-fmt/money.

**Fix:** Install one copy of the package: align the version ranges and deduplicate (`npm dedupe`). On npm, declare schema packages a package imports as `peerDependencies`.

## undeclared-package

*Imports.* A file imports a package that its package or project doesn't declare as a dependency (with npm: in the package's own `package.json`, or the nearest one above an application file), or a file with no `package.json` above it imports a package that wasn't given explicitly. A package found only because the package manager placed it nearby, such as a hoisted dependency of a dependency, could be replaced by another one placed there. Checked before the package is looked for.

For example: @acme/orders imports @acme/common@1, and the package.json of @acme/orders doesn't list @acme/common.

**Fix:** Add the package to the dependencies of the importing package or project (on npm, `peerDependencies` for a package). Outside an npm project, such as in a Cargo or Python project, give the package explicitly (`--package`, `--packages`, the editor's `haus.packages`, Python's `packages=`).

## package-manifest

*Imports.* A package's `package.haus` is not a valid manifest: not one record, a `name` that isn't a lowercase `@org/name` (or has the part `node_modules`), a `version` that isn't a semantic version, or more than 64 KiB.

For example: a package.haus with { name: "@Acme/Orders", version: "1" }.

**Fix:** Write `{ name: "@org/name", version: "1.2.0" }`, in lowercase, with a full version.

## package-version

*Imports.* A package's `package.haus` has another version than the package manager gives the package (the `version` of its `package.json`, its Cargo version). A check implementations SHOULD make (§13.3).

For example: package.haus says 1.2.0, the package.json next to it 1.3.0.

**Fix:** Release both with the same version: change them together.

## package-path

*Imports.* A schema package refers to a file it may not: its `schema.haus` imports a file (`import ./x`) instead of a package; its `package.haus`, `schema.haus` or `package.json` is a symbolic link or not a regular file; or a file outside any package imports a file in a package's directory (`import ./node_modules/x/y`). The file is not read.

For example: a package whose schema.haus has import ../../.env (T).

**Fix:** A package is its `package.haus` and one `schema.haus`, and imports other packages by name (`import @org/name`); import a package by name from your own files too.

## package-name

*Imports.* A package manager's name for a schema package differs from its manifest's: the `name` of its `package.json` isn't the `name` of its `package.haus`. On npm, imports find a package by that name, so it must be the manifest's (§13.3). Reported by package checks such as `haus package check`.

For example: package.haus names @acme/orders, the package.json next to it @acme/order.

**Fix:** Publish the package under its manifest's name: make the `name` of `package.json` the same.

## package-crate

*Imports.* A schema package's crate can't be named by the code generated for crates that use its types: its `links` is missing or isn't its library's name (`[lib] name`), or a crate depends on a schema package's crate under another name (`package = …`). Generated code names a schema package's crate by its `links`, which is its library's name. Reported by package checks such as `haus package check`.

For example: a Cargo.toml with links = "money" and [lib] name = "haus_money".

**Fix:** Set `links` to the library's name in `[package]`, and depend on schema package crates under their own names.

## package-install-script

*Imports.* A schema package runs code when it is installed: an npm `preinstall`, `install` or `postinstall` script, or a `binding.gyp`, for which npm runs node-gyp. A schema package is data and MUST NOT need code to install (§13.3).

For example: a package.json with "scripts": { "postinstall": "node setup.js" }.

**Fix:** Remove the script: a schema package is its manifest, its schema and its profiles, and needs nothing run.

## package-files

*Imports.* A package manager's configuration doesn't ship a file of the schema package: `package.haus`, `schema.haus`, or a profile's vectors or rule. Read from the configuration (`files` of `package.json`, `include` of `Cargo.toml`, a wheel's build configuration), without packing anything.

For example: a package.json with "files": ["schema.haus"], without package.haus.

**Fix:** List `package.haus`, `schema.haus` and `profiles` in what the package manager ships.

## profile-vectors

*Imports.* A profile of a schema package is malformed (§13.3): it has no rule (`profiles/<name>.md`) next to its vectors; a vector isn't `Accept { type, value, output?, note? }` or `Reject { type, value, note? }` with string fields and no others (only an `Accept` has an `output`); its `type` isn't a type of the package without parameters; its `value` or `output` isn't one haus value; or an accepted value or its output isn't valid for its type, which a codec running after the schema can't accept. Also a profile name that isn't lowercase, and a vectors file with no vectors.

For example: Reject { type: "Money", value: "Money(1, US)", output: "Money(1, US)" }.

**Fix:** Write the rule in `profiles/<name>.md`, and each vector as `Accept { type: "T", value: "…" }` or `Reject { type: "T", value: "…" }`, with values valid for `T`.

## package-wrapper

*Imports.* A package manager's file of a schema package can't be read as one: a `package.json` that isn't a JSON object or has no `name`, a `Cargo.toml` or `pyproject.toml` that isn't valid TOML, a `Cargo.toml` without `[package]`. Reported by package checks such as `haus package check`.

For example: a Cargo.toml with [package without its closing bracket.

**Fix:** Fix the file so that its package manager can read it.

## codec-unreachable

*Imports.* A codec's type occurs where this binding can't apply the codec, such as the payload of a record case whose fields sit beside its tag in the host value. Decoding there with the default host type would silently differ from the other bindings (§13.4).

For example: a codec for app#Rec, the payload of the record case Box (TypeScript Effect).

**Fix:** Give the codec's type a place of its own (a field), or decode the outer type yourself; the message names where the type occurs.

## file-too-large

*Imports.* A schema file or a package's `package.json` is larger than the tool allows (1 MiB by default). It is not read.

For example: an imported common.schema.haus of 3 MiB.

**Fix:** Split the schema into several files, or raise the limit if you trust the file.

## too-many-files

*Imports.* A schema imports more schema files, directly or not, than the tool allows (256 by default, the root included), or a folder of packages has more entries than allowed (4096).

For example: a schema whose imports reach 300 files.

**Fix:** Import fewer files.

## type-mismatch

*Decoding and encoding.* A value of another kind than the type accepts: a string for an `Int`, an array for a record, a tag that isn't `True` or `False` for a `Bool`. Decoders never convert between kinds (§15).

```haus-schema
type Root = { qty: Int }
```

```haus
{ qty: "2" }
```

**Fix:** Write a value of the expected type; the message says which.

## not-an-integer

*Decoding and encoding.* A number with a fraction or an exponent where an integer type is expected. `1.0` and `1e3` are not whole numbers by spelling (§15).

```haus-schema
type Root = { qty: Int }
```

```haus
{ qty: 1.0 }
```

**Fix:** Write the integer without a fraction or exponent.

## out-of-range

*Decoding and encoding.* A number outside the type's range: an `Int8` above 127, a negative `UInt32`, a float too large for `Float32`. Never wrapped or clamped.

```haus-schema
type Root = { age: UInt8 }
```

```haus
{ age: 300 }
```

**Fix:** Write a value within the range, or use a larger type (`Int`, `Float64`, `Decimal`).

## missing-field

*Decoding and encoding.* A record lacks a field the type requires. Only fields with `?` may be missing; `None` is not missing.

```haus-schema
type Root = { id: Int, name: String }
```

```haus
{ id: 1 }
```

**Fix:** Add the field, or mark it optional in the schema with `?` after its name.

## unknown-field

*Decoding and encoding.* A field a closed record doesn't list. Open records ignore such fields (see `unlisted-field`).

```haus-schema
type Root = closed { id: Int }
```

```haus
{ id: 1, extra: 2 }
```

**Fix:** Remove the field, fix its spelling, or add it to the schema.

## unknown-tag

*Decoding and encoding.* A tag a closed variant doesn't list. Open variants read it as an unknown value (see `unlisted-tag`).

```haus-schema
type Root = closed < Red | Green >
```

```haus
Blue
```

**Fix:** Use one of the variant's tags, fix the spelling, or add the tag to the schema.

## wrong-payload

*Decoding and encoding.* A listed tag with another payload than its case says: arguments for a tag without payload, the wrong number of arguments, a positional payload where a record is expected, such as `Circle(1.5)` for the case `Circle { r: Float64 }` (§15).

```haus-schema
type Root = closed < None | Some Int >
```

```haus
Some(1, 2)
```

**Fix:** Write the payload the schema gives the tag: none, one record, or its positional arguments; the message says which.

## invalid-time

*Decoding and encoding.* A std/time value whose text the std/time profile rejects: a day that doesn't exist, a missing offset, a lowercase `t` (spec/std/time.md).

```haus-schema
import std/time (Date)
type Root = { on: Date }
```

```haus
{ on: Date("2026-02-30") }
```

**Fix:** Write the date or time as the std/time profile says (spec/std/time.md); the message names the type.

## invalid-secret

*Decoding and encoding.* A value of a `Secret` type that its type doesn't accept, when decoding, or that can't be written, when encoding. The error names the place and the type only, never the value or why it failed (§15).

```haus-schema
type Root = { key: Secret String }
```

```haus
{ key: 42 }
```

**Fix:** Write a value of the secret's type; the value isn't shown, so check it where it comes from.

## cannot-encode

*Decoding and encoding.* Encoding: a value of the program's language that the type can't write, such as a JavaScript number for an `Int` that expects a bigint, or a string that is no valid `Date`.

For example: encode(h.Int, 5): Int is a bigint, 5 is a number.

**Fix:** Pass a value of the host type the binding documents for the type.

## cyclic-value

*Decoding and encoding.* Encoding: a value contains itself, so it has no finite text.

For example: const a = { children: [] }; a.children.push(a); encode(Tree, a).

**Fix:** Break the cycle before encoding.

## step-budget

*Decoding and encoding.* Decoding or encoding took more steps than the input justifies, a sign of a schema doing unbounded work. Bindings MAY bound the work per call (§9.8).

For example: a hand-written schema that decodes each value many times.

**Fix:** Simplify the schema, or raise the step limit if the work is expected.

## too-many-nodes

*Decoding and encoding.* A value built in code (not parsed) has more nodes than the call allows, or shares nodes so much that it would expand beyond the limits.

For example: a value built in code whose arrays share one another a million times.

**Fix:** Build a smaller value, or raise the limit.

## json-syntax

*JSON.* Text that isn't JSON (RFC 8259): a missing comma or colon, an unquoted name, a trailing comma, a comment, text after the value. Also an empty line in JSON Lines, or a byte order mark at the start of a line after the first.

Read as self-describing JSON:

```json
{"_haus": 1,}
```

**Fix:** Write valid JSON; the message says what was expected.

## unpaired-surrogate

*JSON.* A JSON string with half of a UTF-16 surrogate pair, raw or as `\uD800`. I-JSON forbids them, and they are no Unicode characters (§16).

Read as self-describing JSON:

```json
{"_haus": 1, "_value": "\uD800"}
```

**Fix:** Write both halves of the surrogate pair, or the character itself.

## haus-json-form

*JSON.* JSON that isn't self-describing JSON (§16.2): a text without the envelope `{"_haus": 1, "_value": …}`, an envelope with other members, a bare number, `true`, `null`, an object with other members, a `_rec` that isn't an object, an `_args` that isn't a non-empty array.

Read as self-describing JSON:

```json
{"_haus": 1, "_value": 1}
```

**Fix:** Write the envelope with one of the forms of §16.2 in `_value`: a string, an array, or an object with `_num`, `_bytes`, `_rec`, or `_tag` (and `_args`). For ordinary JSON, read it with a schema or import it instead.

## haus-json-version

*JSON.* A self-describing JSON envelope whose `_haus` isn't 1, the only version of the form (§16.2): it was written for a later version of haus, or isn't haus.

Read as self-describing JSON:

```json
{"_haus": 2, "_value": "a"}
```

**Fix:** Read it with a newer version of haus, or write `"_haus": 1`.

## haus-json-number

*JSON.* A self-describing `_num` that isn't a normalized number literal (§2): `"1E5"`, `"01"`, `"0xff"`, or not a string.

Read as self-describing JSON:

```json
{"_haus": 1, "_value": {"_num": "1E5"}}
```

**Fix:** Write the number's normalized literal (§2) as a string.

## haus-json-bytes

*JSON.* A self-describing `_bytes` that isn't two lowercase hex digits per byte.

Read as self-describing JSON:

```json
{"_haus": 1, "_value": {"_bytes": "FF"}}
```

**Fix:** Write the bytes as lowercase hex, two digits per byte.

## invalid-tag

*JSON.* A tag name that isn't `[A-Z][A-Za-z0-9_]*`, or a `"_tag"` that isn't a string: in a `_tag` of either JSON form, or in a value built in code.

Read as self-describing JSON:

```json
{"_haus": 1, "_value": {"_tag": "lower"}}
```

**Fix:** Start the tag with a capital letter and use only letters, digits and `_`.

## invalid-base64

*JSON.* Schema-based JSON `Bytes` that aren't canonical base64 with padding (RFC 4648 §4): whitespace, the URL alphabet, missing padding, non-zero pad bits.

```haus-schema
type Root = Bytes
```

```json
"CzQ"
```

**Fix:** Write standard base64, with padding.

## missing-member

*JSON.* Schema-based JSON: an object lacks a member its form needs, such as `"_tag"` for a variant or `"value"` for a tag with one argument.

```haus-schema
type Root = < Ok Int | Err String >
```

```json
{"_tag": "Ok"}
```

**Fix:** Add the member the message names.

## unexpected-member

*JSON.* Schema-based JSON: an object has a member its form doesn't have, such as `"value"` next to a tag without payload (§16.3).

```haus-schema
type Root = < Ok Int | Empty >
```

```json
{"_tag": "Empty", "value": 1}
```

**Fix:** Remove the member.

## no-json-form

*JSON.* A value or type that has no JSON form: a string with an unpaired surrogate, a record payload with a field named `_tag` or `_args` in schema-based JSON (§16.3), a type with no schema-based form.

For example: toJson of Odd { _tag: 1 }, for the case `Odd { _tag: Int32 }`.

**Fix:** Rename the field, or use self-describing JSON.

## unknown-attribute

*Hints and warnings.* A warning: an attribute this version of haus doesn't define. It is accepted and has no meaning (§14).

```haus-schema
@since("1.2")
type A = Int
```

**Fix:** Check the spelling; attributes of a later version are fine.

## deprecated

*Hints and warnings.* A hint: the schema or the data uses a type, field or tag marked `@deprecated` (§14).

```haus-schema
type Root = { @deprecated("use email") mail?: String, email?: String }
```

```haus
{ mail: "a@b.c" }
```

**Fix:** Use what the deprecation note says instead.

## unlisted-field

*Hints and warnings.* A hint: a field an open record doesn't list. A reader ignores it, but it may be a typo.

```haus-schema
type Root = { name: String }
```

```haus
{ name: "a", nmae: "b" }
```

**Fix:** Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers.

## unlisted-tag

*Hints and warnings.* A hint: a tag an open variant doesn't list. A reader keeps it as an unknown value, but it may be a typo.

```haus-schema
type Root = < Red | Green >
```

```haus
Gren
```

**Fix:** Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers.
