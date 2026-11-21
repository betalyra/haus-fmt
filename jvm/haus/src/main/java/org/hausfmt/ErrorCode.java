// Generated from spec/errors.haus by spec/scripts/errors.ts. Don't edit: edit spec/errors.haus and run `node spec/scripts/errors.ts`.
package org.hausfmt;

/** The error codes of the catalogue (spec §17): stable, the same in every binding. */
public enum ErrorCode {
  /** {@code invalid-utf8}: The input is not valid UTF-8 (§4): a byte sequence that encodes no character, an overlong form or a surrogate. */
  INVALID_UTF8("invalid-utf8", ErrorCategory.SYNTAX, "Save the file as UTF-8."),
  /** {@code version-directive}: The file starts with a `#haus` version directive (§10): it was written for a later, incompatible version of haus. */
  VERSION_DIRECTIVE("version-directive", ErrorCategory.SYNTAX, "Read the file with a version of haus that supports it."),
  /** {@code expected-value}: A value is missing: after a key's colon, between commas, or at the start of a file, something else comes where a value must be. */
  EXPECTED_VALUE("expected-value", ErrorCategory.SYNTAX, "Write a value here, or remove the extra comma or bracket."),
  /** {@code missing-comma}: Two values, fields or top-level values follow each other without a comma between them. */
  MISSING_COMMA("missing-comma", ErrorCategory.SYNTAX, "Add a comma between the two values."),
  /** {@code payload-newline}: A tag is followed by `(` or `{` on a later line, or after a comment. A payload must start on the tag's line (§5), so the two are read as separate values, and a comma is missing between them. */
  PAYLOAD_NEWLINE("payload-newline", ErrorCategory.SYNTAX, "Put the payload on the tag's line, or add a comma if they are two values."),
  /** {@code unexpected-closer}: A closing bracket that doesn't match the open one, or that has no open one. */
  UNEXPECTED_CLOSER("unexpected-closer", ErrorCategory.SYNTAX, "Close each bracket with its own kind (`{` `}`, `[` `]`, `(` `)`) and remove extra closing brackets."),
  /** {@code unclosed-bracket}: A `{`, `[` or `(` is never closed: the input ends first. */
  UNCLOSED_BRACKET("unclosed-bracket", ErrorCategory.SYNTAX, "Add the closing bracket."),
  /** {@code null-literal}: `null` is not a value: haus has no null (§1). */
  NULL_LITERAL("null-literal", ErrorCategory.SYNTAX, "Write `None` (with a `Maybe` type), or leave the field out."),
  /** {@code boolean-literal}: `true` and `false` are not values: booleans are the tags `True` and `False` (§1). */
  BOOLEAN_LITERAL("boolean-literal", ErrorCategory.SYNTAX, "Write `True` or `False`."),
  /** {@code bare-identifier}: A lowercase word where a value should be. Lowercase identifiers are only record keys. */
  BARE_IDENTIFIER("bare-identifier", ErrorCategory.SYNTAX, "Quote it as a string, or start it with a capital letter to make it a tag."),
  /** {@code expected-key}: Something that can't be a record key where a key should be, such as a number or a comma. */
  EXPECTED_KEY("expected-key", ErrorCategory.SYNTAX, "Write a key: a lowercase identifier or a string."),
  /** {@code uppercase-key}: A record key starts with a capital letter. Bare keys start with a lowercase letter or `_`; capitalized words are tags. */
  UPPERCASE_KEY("uppercase-key", ErrorCategory.SYNTAX, "Quote the key, or start it with a lowercase letter."),
  /** {@code block-string-key}: A block string (`"""`) is used as a record key. */
  BLOCK_STRING_KEY("block-string-key", ErrorCategory.SYNTAX, "Write the key as a basic string, `\"…\"`."),
  /** {@code missing-colon}: A record key is not followed by `:`. */
  MISSING_COLON("missing-colon", ErrorCategory.SYNTAX, "Add `:` between the key and its value."),
  /** {@code duplicate-key}: A record has the same key twice, after escapes are read (`a` and `"a"` are the same key). Also a JSON object with the same member name twice (§16). */
  DUPLICATE_KEY("duplicate-key", ErrorCategory.SYNTAX, "Remove or rename one of the two."),
  /** {@code empty-payload}: A tag with empty parentheses, `Tag()`. A tag without arguments is written without them. */
  EMPTY_PAYLOAD("empty-payload", ErrorCategory.SYNTAX, "Remove the empty parentheses after the tag."),
  /** {@code invalid-number}: A number literal that doesn't follow the grammar (§3): a leading zero, a `+`, a `.` without digits on both sides, a misplaced `_`, an uppercase `0X`, digits followed by letters. Also a string that should hold a number literal and doesn't (a `Decimal` in schema-based JSON, §16.3). */
  INVALID_NUMBER("invalid-number", ErrorCategory.SYNTAX, "Write a decimal number (optional `-`, fraction and exponent) or a hex or binary integer, with `_` only between digits."),
  /** {@code unterminated-string}: A string has no closing `"` (in haus or JSON). */
  UNTERMINATED_STRING("unterminated-string", ErrorCategory.SYNTAX, "Add the closing quote. A quote inside the string is written `\\\"`."),
  /** {@code string-line-break}: A raw line break inside a `"…"` string. */
  STRING_LINE_BREAK("string-line-break", ErrorCategory.SYNTAX, "Write the line break as `\\n`, or use a `\"\"\"` block string."),
  /** {@code control-character}: A raw control character (C0, DEL, C1) in a string, block string or comment, where it could change what a terminal shows. A raw tab is allowed in block strings and comments, not in `"…"` strings. Also a raw control character in a JSON string: C0 in any JSON, DEL and C1 in self-describing JSON (§16). */
  CONTROL_CHARACTER("control-character", ErrorCategory.SYNTAX, "Write the character as an escape, `\\u{…}`."),
  /** {@code bidi-control}: A raw bidirectional control character (U+202A–U+202E, U+2066–U+2069) in a string or comment, or in a self-describing JSON string (§16), where it could reorder how the text is displayed ("Trojan Source", §9). */
  BIDI_CONTROL("bidi-control", ErrorCategory.SYNTAX, "Write it as an escape (`\\u{…}`) inside a string, or remove it."),
  /** {@code invalid-escape}: A backslash followed by a character that doesn't start an escape. haus has `&#92;"`, `&#92;&#92;`, `&#92;n`, `&#92;r`, `&#92;t` and `&#92;u{…}`; JSON has its own set. */
  INVALID_ESCAPE("invalid-escape", ErrorCategory.SYNTAX, "Use one of the escapes of §4, or write `\\\\` for a backslash."),
  /** {@code invalid-unicode-escape}: A `&#92;u` escape that isn't `&#92;u{` 1 to 6 hex digits `}`, or names no Unicode scalar value (a surrogate, or above 10FFFF). In JSON: `&#92;u` not followed by four hex digits. */
  INVALID_UNICODE_ESCAPE("invalid-unicode-escape", ErrorCategory.SYNTAX, "Write the escape with braces, `\\u{…}`, for a character from U+0000 to U+10FFFF other than a surrogate."),
  /** {@code block-string-opening}: Text after the opening `"""` of a block string. The content starts on the next line. */
  BLOCK_STRING_OPENING("block-string-opening", ErrorCategory.SYNTAX, "Start the content on the line after `\"\"\"`."),
  /** {@code block-string-closing}: The closing `"""` of a block string has text before it on its line. */
  BLOCK_STRING_CLOSING("block-string-closing", ErrorCategory.SYNTAX, "Put the closing `\"\"\"` on its own line; its indentation is removed from every line."),
  /** {@code block-string-indent}: A line of a block string is indented less than the closing `"""`, whose indentation every line must start with. */
  BLOCK_STRING_INDENT("block-string-indent", ErrorCategory.SYNTAX, "Indent every line at least as far as the closing `\"\"\"`."),
  /** {@code unterminated-block-string}: A block string has no closing `"""`. */
  UNTERMINATED_BLOCK_STRING("unterminated-block-string", ErrorCategory.SYNTAX, "Add the closing `\"\"\"` on its own line."),
  /** {@code unterminated-bytes}: A byte string `x"…` has no closing `"`. */
  UNTERMINATED_BYTES("unterminated-bytes", ErrorCategory.SYNTAX, "Add the closing quote."),
  /** {@code bytes-not-hex}: A byte string holds something other than hex digits, spaces and tabs, such as a letter after `f`, an escape or a line break. */
  BYTES_NOT_HEX("bytes-not-hex", ErrorCategory.SYNTAX, "Write two hex digits per byte, on one line."),
  /** {@code bytes-odd-digits}: A byte in a byte string has only one hex digit: an odd number of digits, or a space inside a byte. */
  BYTES_ODD_DIGITS("bytes-odd-digits", ErrorCategory.SYNTAX, "Write each byte as two hex digits."),
  /** {@code lone-carriage-return}: A carriage return (CR) not followed by a line feed. Line breaks are LF or CRLF. */
  LONE_CARRIAGE_RETURN("lone-carriage-return", ErrorCategory.SYNTAX, "Save the file with LF or CRLF line endings."),
  /** {@code unterminated-comment}: A `/*` comment is never closed. Block comments nest, so each `/*` needs its own `*&#47;`. */
  UNTERMINATED_COMMENT("unterminated-comment", ErrorCategory.SYNTAX, "Add `*/`, one for each `/*`."),
  /** {@code stray-slash}: A `/` that doesn't start a comment. Comments are `//` and `/* *&#47;`; haus has no operators. */
  STRAY_SLASH("stray-slash", ErrorCategory.SYNTAX, "Write `//` or `/*` for a comment, or remove the `/`."),
  /** {@code nesting-too-deep}: Records, arrays and payloads are nested deeper than the depth limit (default 256). In JSON, deeper than its JSON limit (§16). */
  NESTING_TOO_DEEP("nesting-too-deep", ErrorCategory.LIMITS, "Flatten the data, or raise the depth limit if you trust the input."),
  /** {@code number-too-long}: A number literal has more characters than the limit (default 1000), or a hex literal more hex digits than the number limit allows (default 829), so that every integer fits the limit in decimal (§7). */
  NUMBER_TOO_LONG("number-too-long", ErrorCategory.LIMITS, "Write a shorter number (a `String` or `Bytes` for very long data), or raise the number length limit."),
  /** {@code exponent-too-large}: A number's exponent is larger than the limit (default 6144), in either direction. */
  EXPONENT_TOO_LARGE("exponent-too-large", ErrorCategory.LIMITS, "Write a number with a smaller exponent, or raise the exponent limit."),
  /** {@code string-too-long}: A string or byte string has more characters than the limit (default 16 Mi). */
  STRING_TOO_LONG("string-too-long", ErrorCategory.LIMITS, "Split the string, or raise the string length limit."),
  /** {@code key-too-long}: A record key has more characters than the string limit (default 16 Mi). */
  KEY_TOO_LONG("key-too-long", ErrorCategory.LIMITS, "Use a shorter key, or raise the string length limit."),
  /** {@code tag-too-long}: A tag has more characters than the string limit (default 16 Mi). */
  TAG_TOO_LONG("tag-too-long", ErrorCategory.LIMITS, "Use a shorter tag, or raise the string length limit."),
  /** {@code value-too-long}: One top-level value of a stream (or one line of JSON Lines) has more characters than the limit (default 64 Mi). */
  VALUE_TOO_LONG("value-too-long", ErrorCategory.LIMITS, "Send smaller values, or raise the value length limit."),
  /** {@code unsupported-depth}: The configured depth limit is above the deepest nesting the binding supports, or isn't a whole number (§7). Raised when the limits are set, not by any input. */
  UNSUPPORTED_DEPTH("unsupported-depth", ErrorCategory.LIMITS, "Configure a depth limit within the binding's documented maximum."),
  /** {@code not-one-value}: One value was expected (a single document, a type that isn't a `Stream`), and the input holds none or several. */
  NOT_ONE_VALUE("not-one-value", ErrorCategory.STREAMS, "Give exactly one value, or read the input as a stream."),
  /** {@code stream-truncated}: In strict mode, a stream ended without a comma (or, in JSON Lines, a line feed) after its last value, so the last value may be cut off (§6). */
  STREAM_TRUNCATED("stream-truncated", ErrorCategory.STREAMS, "End every value with a comma, or check that the stream wasn't cut off."),
  /** {@code schema-syntax}: A schema file doesn't follow the grammar: an unexpected token, a character that has no place there. Mistakes in the comments, whitespace and strings a schema file shares with data files (§14) have the codes they have there: `unterminated-string`, `unterminated-comment`, `lone-carriage-return`, `control-character`, `bidi-control`, `invalid-utf8`, `invalid-escape`. */
  SCHEMA_SYNTAX("schema-syntax", ErrorCategory.SCHEMA_FILES, "Write it as the grammar says (grammar.ebnf); the message names what was expected."),
  /** {@code unknown-type}: A type name that is neither defined in the file, imported, nor a prelude type. A type a standard module or official extension has needs its import. */
  UNKNOWN_TYPE("unknown-type", ErrorCategory.SCHEMA_FILES, "Define the type, fix its spelling, or import it from the module that defines it."),
  /** {@code wrong-arity}: A type is used with the wrong number of arguments: `Array` without its element type, `Int` with one, a generic type of your own with too few or too many. */
  WRONG_ARITY("wrong-arity", ErrorCategory.SCHEMA_FILES, "Give the type exactly as many arguments as it has parameters."),
  /** {@code duplicate-type}: Two definitions of the same type name, or a definition with the name of an imported type. */
  DUPLICATE_TYPE("duplicate-type", ErrorCategory.SCHEMA_FILES, "Rename one of them."),
  /** {@code redefine-prelude}: A definition with the name of a prelude type (`Int`, `Any`, `Secret`, `Maybe`, …), which schemas can't redefine. */
  REDEFINE_PRELUDE("redefine-prelude", ErrorCategory.SCHEMA_FILES, "Give your type another name."),
  /** {@code unknown-parameter}: A lowercase name in a type that is not a parameter of the definition. */
  UNKNOWN_PARAMETER("unknown-parameter", ErrorCategory.SCHEMA_FILES, "Declare the parameter after the type's name, or use a type name."),
  /** {@code invalid-parameter}: A type parameter starting with `_`, or the same parameter twice in one definition. */
  INVALID_PARAMETER("invalid-parameter", ErrorCategory.SCHEMA_FILES, "Give each parameter its own lowercase name."),
  /** {@code underscore-type}: `_` used as a type. Types are open by default, so there is no wildcard. */
  UNDERSCORE_TYPE("underscore-type", ErrorCategory.SCHEMA_FILES, "Write `< >` for a variant with any tags, `Any` for any value, or use a type parameter."),
  /** {@code duplicate-field}: A record type lists the same field twice, also one copied in by a spread. */
  DUPLICATE_FIELD("duplicate-field", ErrorCategory.SCHEMA_FILES, "Remove or rename one of them."),
  /** {@code duplicate-tag}: A variant type lists the same tag twice, also one copied in by a spread. */
  DUPLICATE_TAG("duplicate-tag", ErrorCategory.SCHEMA_FILES, "Remove or rename one of them."),
  /** {@code closed-empty-variant}: `closed &lt; &gt;`: a closed variant without tags accepts nothing. */
  CLOSED_EMPTY_VARIANT("closed-empty-variant", ErrorCategory.SCHEMA_FILES, "List its tags, or write `< >` for a variant with any tags."),
  /** {@code invalid-spread}: A spread of something that can't be spread: not a named type, a type with parameters, a `Stream`, or a record spread into a variant (or a variant into a record). */
  INVALID_SPREAD("invalid-spread", ErrorCategory.SCHEMA_FILES, "Spread a named variant into a variant, or a named record into a record, without parameters."),
  /** {@code spread-cycle}: A type spreads itself, directly or through other types. */
  SPREAD_CYCLE("spread-cycle", ErrorCategory.SCHEMA_FILES, "Break the cycle: let one of the types list its tags or fields itself."),
  /** {@code row-parameter}: A spread of a parameter, `...r`. Row parameters are not part of the language. */
  ROW_PARAMETER("row-parameter", ErrorCategory.SCHEMA_FILES, "Spread a named type instead, or nest the open part as a field with a type parameter."),
  /** {@code misplaced-stream}: `Stream` used anywhere but as the whole type of a definition, or a reference to such a definition. A stream is a whole file. */
  MISPLACED_STREAM("misplaced-stream", ErrorCategory.SCHEMA_FILES, "Use `Array` inside types, and `Stream` only as the whole of a definition."),
  /** {@code unguarded-recursion}: A type refers to itself without a record field, array element or variant payload in between (§9.9), so decoding it would consume no input. `Secret` and names don't count as a step. */
  UNGUARDED_RECURSION("unguarded-recursion", ErrorCategory.SCHEMA_FILES, "Put the recursion inside a record field, array element or variant payload."),
  /** {@code growing-recursion}: Generic types whose instances could grow without bound: a type parameter passes, wrapped in a bigger type, along a cycle of references back to itself (`type T a = &lt; X (T (Pair a a)) &gt;`, §9.10). */
  GROWING_RECURSION("growing-recursion", ErrorCategory.SCHEMA_FILES, "Refer to the type inside itself with exactly its own parameters."),
  /** {@code type-too-deep}: Type expressions are nested deeper than the schema parser's limit. */
  TYPE_TOO_DEEP("type-too-deep", ErrorCategory.SCHEMA_FILES, "Name the inner types with definitions of their own."),
  /** {@code attribute-arguments}: An attribute this version defines, given arguments it doesn't take: `&#64;deprecated` takes nothing or one string. Also empty parentheses after an attribute. */
  ATTRIBUTE_ARGUMENTS("attribute-arguments", ErrorCategory.SCHEMA_FILES, "Give the attribute only the arguments it takes: `@deprecated` takes none, or one string."),
  /** {@code attribute-twice}: The same attribute twice on one type, field or tag. */
  ATTRIBUTE_TWICE("attribute-twice", ErrorCategory.SCHEMA_FILES, "Keep one of them."),
  /** {@code attribute-space}: A space between an attribute's name and its `(`. */
  ATTRIBUTE_SPACE("attribute-space", ErrorCategory.SCHEMA_FILES, "Write the parenthesis right after the attribute's name, without a space."),
  /** {@code attribute-on-spread}: An attribute on a spread. The fields and tags a spread copies keep their own attributes. */
  ATTRIBUTE_ON_SPREAD("attribute-on-spread", ErrorCategory.SCHEMA_FILES, "Put the attribute on the fields or tags in the spread type."),
  /** {@code unknown-module}: An import of a module that doesn't exist: an unknown standard module, a former standard module, or a name that is neither `std/…`, a package `&#64;org/name` nor a file `./name`. */
  UNKNOWN_MODULE("unknown-module", ErrorCategory.IMPORTS, "Fix the module's name; a former standard module is now a package, which the message names."),
  /** {@code unknown-import}: An import names a type the module doesn't have, or no type at all. */
  UNKNOWN_IMPORT("unknown-import", ErrorCategory.IMPORTS, "Import a type the module defines; the message lists them."),
  /** {@code duplicate-import}: The same type name is imported twice. */
  DUPLICATE_IMPORT("duplicate-import", ErrorCategory.IMPORTS, "Import each name once."),
  /** {@code import-unavailable}: The schema imports a package or file, and the tool reading it has no way to find one (no module resolver): only standard modules can be imported there. */
  IMPORT_UNAVAILABLE("import-unavailable", ErrorCategory.IMPORTS, "Read the schema with a resolver that loads imports (from files or packages), or inline the types."),
  /** {@code import-not-found}: An imported package or file can't be found: it is not installed, the path is wrong, or the package found names another package in its manifest. */
  IMPORT_NOT_FOUND("import-not-found", ErrorCategory.IMPORTS, "Install the package, or fix the path."),
  /** {@code import-version}: An import asks for a major version (`&#64;org/name&#64;2`) and another one is installed, or names something other than a major version: `&#64;1.1`, `&#64;1.1.0`, `&#64;01`, `&#64;x`. */
  IMPORT_VERSION("import-version", ErrorCategory.IMPORTS, "Install the major version the schema asks for, or update the import. An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range."),
  /** {@code import-cycle}: Schema files import each other in a cycle. */
  IMPORT_CYCLE("import-cycle", ErrorCategory.IMPORTS, "Move the shared types to a file both import."),
  /** {@code duplicate-package}: One schema reaches two different packages with the same name: two versions of one package (also two major versions), two copies of one version whose files differ, or two packages that call themselves the same. Byte-identical copies are one package. */
  DUPLICATE_PACKAGE("duplicate-package", ErrorCategory.IMPORTS, "Install one copy of the package: align the version ranges and deduplicate (`npm dedupe`). On npm, declare schema packages a package imports as `peerDependencies`."),
  /** {@code undeclared-package}: A file imports a package that its package or project doesn't declare as a dependency (with npm: in the package's own `package.json`, or the nearest one above an application file), or a file with no `package.json` above it imports a package that wasn't given explicitly. A package found only because the package manager placed it nearby, such as a hoisted dependency of a dependency, could be replaced by another one placed there. Checked before the package is looked for. */
  UNDECLARED_PACKAGE("undeclared-package", ErrorCategory.IMPORTS, "Add the package to the dependencies of the importing package or project (on npm, `peerDependencies` for a package). Outside an npm project, such as in a Cargo or Python project, give the package explicitly (`--package`, `--packages`, the editor's `haus.packages`, Python's `packages=`)."),
  /** {@code package-manifest}: A package's `package.haus` is not a valid manifest: not one record, a `name` that isn't a lowercase `&#64;org/name` (or has the part `node_modules`), a `version` that isn't a semantic version, or more than 64 KiB. */
  PACKAGE_MANIFEST("package-manifest", ErrorCategory.IMPORTS, "Write `{ name: \"@org/name\", version: \"1.2.0\" }`, in lowercase, with a full version."),
  /** {@code package-version}: A package's `package.haus` has another version than the package manager gives the package (the `version` of its `package.json`, its Cargo version). A check implementations SHOULD make (§13.3). */
  PACKAGE_VERSION("package-version", ErrorCategory.IMPORTS, "Release both with the same version: change them together."),
  /** {@code package-path}: A schema package refers to a file it may not: its `schema.haus` imports a file (`import ./x`) instead of a package; its `package.haus`, `schema.haus` or `package.json` is a symbolic link or not a regular file; or a file outside any package imports a file in a package's directory (`import ./node_modules/x/y`). The file is not read. */
  PACKAGE_PATH("package-path", ErrorCategory.IMPORTS, "A package is its `package.haus` and one `schema.haus`, and imports other packages by name (`import @org/name`); import a package by name from your own files too."),
  /** {@code package-name}: A package manager's name for a schema package differs from its manifest's: the `name` of its `package.json` isn't the `name` of its `package.haus`. On npm, imports find a package by that name, so it must be the manifest's (§13.3). Reported by package checks such as `haus package check`. */
  PACKAGE_NAME("package-name", ErrorCategory.IMPORTS, "Publish the package under its manifest's name: make the `name` of `package.json` the same."),
  /** {@code package-crate}: A schema package's crate can't be named by the code generated for crates that use its types: its `links` is missing or isn't its library's name (`[lib] name`), or a crate depends on a schema package's crate under another name (`package = …`). Generated code names a schema package's crate by its `links`, which is its library's name. Reported by package checks such as `haus package check`. */
  PACKAGE_CRATE("package-crate", ErrorCategory.IMPORTS, "Set `links` to the library's name in `[package]`, and depend on schema package crates under their own names."),
  /** {@code package-install-script}: A schema package runs code when it is installed: an npm `preinstall`, `install` or `postinstall` script, or a `binding.gyp`, for which npm runs node-gyp. A schema package is data and MUST NOT need code to install (§13.3). */
  PACKAGE_INSTALL_SCRIPT("package-install-script", ErrorCategory.IMPORTS, "Remove the script: a schema package is its manifest, its schema and its profiles, and needs nothing run."),
  /** {@code package-files}: A package manager's configuration doesn't ship a file of the schema package: `package.haus`, `schema.haus`, or a profile's vectors or rule. Read from the configuration (`files` of `package.json`, `include` of `Cargo.toml`, a wheel's build configuration), without packing anything. */
  PACKAGE_FILES("package-files", ErrorCategory.IMPORTS, "List `package.haus`, `schema.haus` and `profiles` in what the package manager ships."),
  /** {@code profile-vectors}: A profile of a schema package is malformed (§13.3): it has no rule (`profiles/&lt;name&gt;.md`) next to its vectors; a vector isn't `Accept { type, value, output?, note? }` or `Reject { type, value, note? }` with string fields and no others (only an `Accept` has an `output`); its `type` isn't a type of the package without parameters; its `value` or `output` isn't one haus value; or an accepted value or its output isn't valid for its type, which a codec running after the schema can't accept. Also a profile name that isn't lowercase, and a vectors file with no vectors. */
  PROFILE_VECTORS("profile-vectors", ErrorCategory.IMPORTS, "Write the rule in `profiles/<name>.md`, and each vector as `Accept { type: \"T\", value: \"…\" }` or `Reject { type: \"T\", value: \"…\" }`, with values valid for `T`."),
  /** {@code package-wrapper}: A package manager's file of a schema package can't be read as one: a `package.json` that isn't a JSON object or has no `name`, a `Cargo.toml` or `pyproject.toml` that isn't valid TOML, a `Cargo.toml` without `[package]`. Reported by package checks such as `haus package check`. */
  PACKAGE_WRAPPER("package-wrapper", ErrorCategory.IMPORTS, "Fix the file so that its package manager can read it."),
  /** {@code codec-unreachable}: A codec's type occurs where this binding can't apply the codec, such as the payload of a record case whose fields sit beside its tag in the host value. Decoding there with the default host type would silently differ from the other bindings (§13.4). */
  CODEC_UNREACHABLE("codec-unreachable", ErrorCategory.IMPORTS, "Give the codec's type a place of its own (a field), or decode the outer type yourself; the message names where the type occurs."),
  /** {@code file-too-large}: A schema file or a package's `package.json` is larger than the tool allows (1 MiB by default). It is not read. */
  FILE_TOO_LARGE("file-too-large", ErrorCategory.IMPORTS, "Split the schema into several files, or raise the limit if you trust the file."),
  /** {@code too-many-files}: A schema imports more schema files, directly or not, than the tool allows (256 by default, the root included), or a folder of packages has more entries than allowed (4096). */
  TOO_MANY_FILES("too-many-files", ErrorCategory.IMPORTS, "Import fewer files."),
  /** {@code type-mismatch}: A value of another kind than the type accepts: a string for an `Int`, an array for a record, a tag that isn't `True` or `False` for a `Bool`. Decoders never convert between kinds (§15). */
  TYPE_MISMATCH("type-mismatch", ErrorCategory.DECODING, "Write a value of the expected type; the message says which."),
  /** {@code not-an-integer}: A number with a fraction or an exponent where an integer type is expected. `1.0` and `1e3` are not whole numbers by spelling (§15). */
  NOT_AN_INTEGER("not-an-integer", ErrorCategory.DECODING, "Write the integer without a fraction or exponent."),
  /** {@code out-of-range}: A number outside the type's range: an `Int8` above 127, a negative `UInt32`, a float too large for `Float32`. Never wrapped or clamped. */
  OUT_OF_RANGE("out-of-range", ErrorCategory.DECODING, "Write a value within the range, or use a larger type (`Int`, `Float64`, `Decimal`)."),
  /** {@code missing-field}: A record lacks a field the type requires. Only fields with `?` may be missing; `None` is not missing. */
  MISSING_FIELD("missing-field", ErrorCategory.DECODING, "Add the field, or mark it optional in the schema with `?` after its name."),
  /** {@code unknown-field}: A field a closed record doesn't list. Open records ignore such fields (see `unlisted-field`). */
  UNKNOWN_FIELD("unknown-field", ErrorCategory.DECODING, "Remove the field, fix its spelling, or add it to the schema."),
  /** {@code unknown-tag}: A tag a closed variant doesn't list. Open variants read it as an unknown value (see `unlisted-tag`). */
  UNKNOWN_TAG("unknown-tag", ErrorCategory.DECODING, "Use one of the variant's tags, fix the spelling, or add the tag to the schema."),
  /** {@code wrong-payload}: A listed tag with another payload than its case says: arguments for a tag without payload, the wrong number of arguments, a positional payload where a record is expected, such as `Circle(1.5)` for the case `Circle { r: Float64 }` (§15). */
  WRONG_PAYLOAD("wrong-payload", ErrorCategory.DECODING, "Write the payload the schema gives the tag: none, one record, or its positional arguments; the message says which."),
  /** {@code invalid-time}: A std/time value whose text the std/time profile rejects: a day that doesn't exist, a missing offset, a lowercase `t` (spec/std/time.md). */
  INVALID_TIME("invalid-time", ErrorCategory.DECODING, "Write the date or time as the std/time profile says (spec/std/time.md); the message names the type."),
  /** {@code invalid-secret}: A value of a `Secret` type that its type doesn't accept, when decoding, or that can't be written, when encoding. The error names the place and the type only, never the value or why it failed (§15). */
  INVALID_SECRET("invalid-secret", ErrorCategory.DECODING, "Write a value of the secret's type; the value isn't shown, so check it where it comes from."),
  /** {@code cannot-encode}: Encoding: a value of the program's language that the type can't write, such as a JavaScript number for an `Int` that expects a bigint, or a string that is no valid `Date`. */
  CANNOT_ENCODE("cannot-encode", ErrorCategory.DECODING, "Pass a value of the host type the binding documents for the type."),
  /** {@code cyclic-value}: Encoding: a value contains itself, so it has no finite text. */
  CYCLIC_VALUE("cyclic-value", ErrorCategory.DECODING, "Break the cycle before encoding."),
  /** {@code step-budget}: Decoding or encoding took more steps than the input justifies, a sign of a schema doing unbounded work. Bindings MUST bound the work of one decode (§9.8). */
  STEP_BUDGET("step-budget", ErrorCategory.DECODING, "Simplify the schema, or raise the step limit if the work is expected."),
  /** {@code too-many-nodes}: A value built in code (not parsed) has more nodes than the call allows, or shares nodes so much that it would expand beyond the limits. */
  TOO_MANY_NODES("too-many-nodes", ErrorCategory.DECODING, "Build a smaller value, or raise the limit."),
  /** {@code json-syntax}: Text that isn't JSON (RFC 8259): a missing comma or colon, an unquoted name, a trailing comma, a comment, text after the value. Also an empty line in JSON Lines, or a byte order mark at the start of a line after the first. */
  JSON_SYNTAX("json-syntax", ErrorCategory.JSON, "Write valid JSON; the message says what was expected."),
  /** {@code unpaired-surrogate}: A JSON string with half of a UTF-16 surrogate pair, raw or as `&#92;uD800`. I-JSON forbids them, and they are no Unicode characters (§16). */
  UNPAIRED_SURROGATE("unpaired-surrogate", ErrorCategory.JSON, "Write both halves of the surrogate pair, or the character itself."),
  /** {@code haus-json-form}: JSON that isn't self-describing JSON (§16.2): a text without the envelope `{"_haus": 1, "_value": …}`, an envelope with other members, a bare number, `true`, `null`, an object with other members, a `_rec` that isn't an object, an `_args` that isn't a non-empty array. */
  HAUS_JSON_FORM("haus-json-form", ErrorCategory.JSON, "Write the envelope with one of the forms of §16.2 in `_value`: a string, an array, or an object with `_num`, `_bytes`, `_rec`, or `_tag` (and `_args`). For ordinary JSON, read it with a schema or import it instead."),
  /** {@code haus-json-version}: A self-describing JSON envelope whose `_haus` isn't 1, the only version of the form (§16.2): it was written for a later version of haus, or isn't haus. */
  HAUS_JSON_VERSION("haus-json-version", ErrorCategory.JSON, "Read it with a newer version of haus, or write `\"_haus\": 1`."),
  /** {@code haus-json-number}: A self-describing `_num` that isn't a normalized number literal (§2): `"1E5"`, `"01"`, `"0xff"`, or not a string. */
  HAUS_JSON_NUMBER("haus-json-number", ErrorCategory.JSON, "Write the number's normalized literal (§2) as a string."),
  /** {@code haus-json-bytes}: A self-describing `_bytes` that isn't two lowercase hex digits per byte. */
  HAUS_JSON_BYTES("haus-json-bytes", ErrorCategory.JSON, "Write the bytes as lowercase hex, two digits per byte."),
  /** {@code invalid-tag}: A tag name that isn't `[A-Z][A-Za-z0-9_]*`, or a `"_tag"` that isn't a string: in a `_tag` of either JSON form, in the string of a closed variant whose tags have no payload in schema-based JSON (`"debug"`, §16.3), or in a value built in code. */
  INVALID_TAG("invalid-tag", ErrorCategory.JSON, "Start the tag with a capital letter and use only letters, digits and `_`."),
  /** {@code invalid-base64}: Schema-based JSON `Bytes` that aren't canonical base64 with padding (RFC 4648 §4): whitespace, the URL alphabet, missing padding, non-zero pad bits. */
  INVALID_BASE64("invalid-base64", ErrorCategory.JSON, "Write standard base64, with padding."),
  /** {@code missing-member}: Schema-based JSON: an object lacks a member its form needs, such as `"_tag"` for a variant or `"value"` for a tag with one argument. */
  MISSING_MEMBER("missing-member", ErrorCategory.JSON, "Add the member the message names."),
  /** {@code unexpected-member}: Schema-based JSON: an object has a member its form doesn't have, such as `"value"` next to a tag without payload (§16.3). */
  UNEXPECTED_MEMBER("unexpected-member", ErrorCategory.JSON, "Remove the member."),
  /** {@code no-json-form}: A value or type that has no JSON form: a string with an unpaired surrogate, a record payload with a field named `_tag` or `_args` in schema-based JSON (§16.3), a type with no schema-based form. */
  NO_JSON_FORM("no-json-form", ErrorCategory.JSON, "Rename the field, or use self-describing JSON."),
  /** {@code unknown-attribute}: A warning: an attribute this version of haus doesn't define. It is accepted and has no meaning (§14). */
  UNKNOWN_ATTRIBUTE("unknown-attribute", ErrorCategory.HINTS, "Check the spelling; attributes of a later version are fine."),
  /** {@code deprecated}: A hint: the schema or the data uses a type, field or tag marked `&#64;deprecated` (§14). */
  DEPRECATED("deprecated", ErrorCategory.HINTS, "Use what the deprecation note says instead."),
  /** {@code unlisted-field}: A hint: a field an open record doesn't list. A reader ignores it, but it may be a typo. */
  UNLISTED_FIELD("unlisted-field", ErrorCategory.HINTS, "Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers."),
  /** {@code unlisted-tag}: A hint: a tag an open variant doesn't list. A reader keeps it as an unknown value, but it may be a typo. */
  UNLISTED_TAG("unlisted-tag", ErrorCategory.HINTS, "Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers.");

  private final String code;
  private final ErrorCategory category;
  private final String hint;

  ErrorCode(String code, ErrorCategory category, String hint) {
    this.code = code;
    this.category = category;
    this.hint = hint;
  }

  /** The code as the catalogue writes it, such as {@code payload-newline}. */
  public String code() {
    return code;
  }

  /** The part of the catalogue the code belongs to. */
  public ErrorCategory category() {
    return category;
  }

  /** The catalogue's usual fix for the mistake. */
  public String hint() {
    return hint;
  }

  /** The URL that documents the code. */
  public String docs() {
    return "https://haus-fmt.org/docs/errors#" + code;
  }

  /** The code, such as {@code payload-newline}. */
  @Override
  public String toString() {
    return code;
  }

  /** The constant for a code such as {@code payload-newline}, or null if the catalogue has none. */
  public static ErrorCode fromCode(String code) {
    for (ErrorCode c : values()) {
      if (c.code.equals(code)) {
        return c;
      }
    }
    return null;
  }
}
