// Generated from spec/errors.haus by tests/error_codes.rs. Don't edit: edit spec/errors.haus and run
// `HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes`.

/// An error code (spec §17): which mistake an error is. Stable, and the same in every binding.
/// [`ErrorCode::as_str`] is its name, `payload-newline`; [`ErrorCode::hint`] the usual fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[non_exhaustive]
pub enum ErrorCode {
    /// `invalid-utf8`: The input is not valid UTF-8 (§4): a byte sequence that encodes no character, an overlong form or a surrogate. Also an unpaired surrogate in a string of the language (UTF-16) given to a parser instead of bytes. Reported at: Where the decoder says, at the first byte that isn't UTF-8; nowhere when it doesn't say. Text is checked before it is parsed (§4), a stream's chunk by chunk as it arrives. An unpaired surrogate in a string of the language: at it, one column.
    InvalidUtf8,
    /// `version-directive`: The file starts with a `#haus` version directive (§10): it was written for a later, incompatible version of haus. Reported at: The `#` (line 1, column 2 after a byte order mark).
    VersionDirective,
    /// `expected-value`: A value is missing: after a key's colon, between commas, or at the start of a file, something else comes where a value must be, also a closing bracket (`\[}`, `\]`, `1,\]`). After a key's colon the end of the input is this error too; anywhere else inside a bracket it is `unclosed-bracket`. Reported at: What stands where the value should be: the token, or the end of the input.
    ExpectedValue,
    /// `missing-comma`: Two values, fields or top-level values follow each other without a comma between them. Reported at: The token found where the comma should be.
    MissingComma,
    /// `payload-newline`: A tag is followed by `(` or `{` on a later line, or after a comment. A payload must start on the tag's line (§5), so the two are read as separate values, and a comma is missing between them. Reported at: The payload's `(` or `{`.
    PayloadNewline,
    /// `unexpected-closer`: A closing bracket after a value that doesn't match the open one (`\[1}`), or that has no open one (`{ a: 1 }}`). Where a value or key is expected, a closing bracket is `expected-value` or `expected-key`. Reported at: The closing bracket.
    UnexpectedCloser,
    /// `unclosed-bracket`: A `{`, `\[` or `(` is never closed: the input ends first (`\[1,`, `Some(`), except right after a key's colon, where it is `expected-value`. Reported at: The opening bracket.
    UnclosedBracket,
    /// `null-literal`: `null` is not a value: haus has no null (§1). Reported at: The word.
    NullLiteral,
    /// `boolean-literal`: `true` and `false` are not values: booleans are the tags `True` and `False` (§1). Reported at: The word.
    BooleanLiteral,
    /// `bare-identifier`: A lowercase word where a value should be. Lowercase identifiers are only record keys. Reported at: The word.
    BareIdentifier,
    /// `expected-key`: Something that can't be a record key where a key should be, such as a number or a comma. Reported at: What stands where the key should be: the token, or the end of the input.
    ExpectedKey,
    /// `uppercase-key`: A record key starts with a capital letter. Bare keys start with a lowercase letter or `_`; capitalized words are tags. Reported at: The key.
    UppercaseKey,
    /// `block-string-key`: A block string (`"""`) is used as a record key. Reported at: The opening `"""`.
    BlockStringKey,
    /// `missing-colon`: A record key is not followed by `:`. Reported at: The token found where the colon should be, or the end of the input.
    MissingColon,
    /// `duplicate-key`: A record has the same key twice, after escapes are read (`a` and `"a"` are the same key). Also a JSON object with the same member name twice (§16), and a record built in code with a key twice, rejected when it is built or, at the latest, when it is written, canonicalised or hashed (§11). Reported at: The second key, as soon as it is read, before its colon and value: an error in the value is never reached. In JSON, the second name, the same way (§16). Built in code: informative (§11).
    DuplicateKey,
    /// `empty-payload`: A tag with empty parentheses, `Tag()`. A tag without arguments is written without them. Reported at: The `(`.
    EmptyPayload,
    /// `invalid-number`: A number literal that doesn't follow the grammar (§3): a leading zero, a `+`, a `.` without digits on both sides, a misplaced `_`, an uppercase `0X`, digits followed by letters. Also a string that should hold a number literal and doesn't (a `Decimal` in schema-based JSON, §16.3), and a number built in code whose text isn't a literal (`01`, `NaN`), rejected when it is built or, at the latest, when it is written, canonicalised or hashed (§11). Reported at: The literal's first character, a sign or a leading `.` included. Built in code: informative (§11).
    InvalidNumber,
    /// `unterminated-string`: A string has no closing `"` (in haus or JSON). Reported at: The opening quote.
    UnterminatedString,
    /// `string-line-break`: A raw line break inside a `"…"` string. Reported at: The line break.
    StringLineBreak,
    /// `control-character`: A raw control character (C0, DEL, C1) in a string, block string or comment, where it could change what a terminal shows. A raw tab is allowed in block strings and comments, not in `"…"` strings. Also a raw control character in a JSON string: C0 in any JSON, DEL and C1 in self-describing JSON (§16). Reported at: The character.
    ControlCharacter,
    /// `bidi-control`: A raw bidirectional control character (U+202A–U+202E, U+2066–U+2069) in a string or comment, or in a self-describing JSON string (§16), where it could reorder how the text is displayed ("Trojan Source", §9). Reported at: The character.
    BidiControl,
    /// `invalid-escape`: A backslash followed by a character that doesn't start an escape, or by the end of the input. haus has `\"`, `\\`, `\n`, `\r`, `\t` and `\u{…}`; JSON has its own set. Reported at: The backslash.
    InvalidEscape,
    /// `invalid-unicode-escape`: A `\u` escape that isn't `\u{` 1 to 6 hex digits `}`, or names no Unicode scalar value (a surrogate, or above 10FFFF). In JSON: `\u` not followed by four hex digits. Reported at: The backslash.
    InvalidUnicodeEscape,
    /// `block-string-opening`: Text after the opening `"""` of a block string, or the end of the input right after it. The content starts on the next line. Reported at: The first character after the opening `"""` and its spaces and tabs, or the end of the input.
    BlockStringOpening,
    /// `block-string-closing`: The closing `"""` of a block string has text before it on its line. Reported at: The first quote of the closing `"""`. Found before any error in the lines (§4).
    BlockStringClosing,
    /// `block-string-indent`: A line of a block string is indented less than the closing `"""`, whose indentation every line must start with. Reported at: Column 1 of the line. Checked before the line's characters (§4).
    BlockStringIndent,
    /// `unterminated-block-string`: A block string has no closing `"""`. Reported at: The opening `"""`. Found before any error in the lines (§4).
    UnterminatedBlockString,
    /// `unterminated-bytes`: A byte string `x"…` has no closing `"`. Reported at: The `x` of `x"`.
    UnterminatedBytes,
    /// `bytes-not-hex`: A byte string holds something other than hex digits, spaces and tabs, such as a letter after `f`, an escape or a line break, where a byte starts. After a byte's first digit, anything but a second one is `bytes-odd-digits`. Reported at: The character.
    BytesNotHex,
    /// `bytes-odd-digits`: A byte in a byte string has only one hex digit: an odd number of digits, or anything but a second hex digit after the first (a space, a letter after `f`, a line break: `x"az"`). Reported at: The lone hex digit.
    BytesOddDigits,
    /// `lone-carriage-return`: A carriage return (CR) not followed by a line feed. Line breaks are LF or CRLF. Reported at: The carriage return.
    LoneCarriageReturn,
    /// `unterminated-comment`: A `/*` comment is never closed. Block comments nest, so each `/*` needs its own `*/`. Reported at: The outermost `/*`.
    UnterminatedComment,
    /// `stray-slash`: A `/` that doesn't start a comment. Comments are `//` and `/* */`; haus has no operators. Reported at: The `/`.
    StraySlash,
    /// `nesting-too-deep`: Records, arrays and payloads are nested deeper than the depth limit (default 256). In JSON, deeper than its JSON limit (§16). Reported at: The opening bracket of the first level too deep: the `(` of `Tag(`, the `{` of `Tag {`. Writing a value: its place, or no place; in the i-th value of a stream written, a place that starts with `$\[i\]` (§11).
    NestingTooDeep,
    /// `number-too-long`: A number literal has more characters than the limit (default 1000), or a hex literal more hex digits than the number limit allows (default 829), so that every integer fits the limit in decimal (§7). A writer measures a number built in code on its normalized literal (§11); one over both the number and the exponent limit may fail with either code. Reported at: The literal's first character. In JSON, the number token's first character, or the string's place for a string read as a number (§16).
    NumberTooLong,
    /// `exponent-too-large`: A number's exponent is larger than the limit (default 6144), in either direction. A writer measures a number built in code on its normalized literal (§11), as for `number-too-long`. Reported at: The literal's first character. In JSON, as `number-too-long`.
    ExponentTooLarge,
    /// `string-too-long`: A string or byte string has more characters than the limit (default 16 Mi). Reported at: The opening quote.
    StringTooLong,
    /// `key-too-long`: A record key has more characters than the string limit (default 16 Mi). Reported at: The key's first character.
    KeyTooLong,
    /// `tag-too-long`: A tag has more characters than the string limit (default 16 Mi). Reported at: The tag's first character.
    TagTooLong,
    /// `value-too-long`: One top-level value of a haus stream has more characters than the limit (default 64 Mi). A line of JSON Lines has no such limit (§16). Reported at: The start of the value's text: the character after the previous top-level comma, whatever it is (`1,⏎ 1234567`: line 1, column 3, the line break), or the start of the stream, after a byte order mark (column 2).
    ValueTooLong,
    /// `unsupported-depth`: The configured depth limit is above the deepest nesting the binding supports, or isn't a whole number (§7). Raised when the limits are set, not by any input. Reported at: No place: an error of the API that sets the limits.
    UnsupportedDepth,
    /// `not-one-value`: One value was expected (a single document, a type that isn't a `Stream`), and the input holds none or several. Reported at: The end of the input; `$` when decoding with a type.
    NotOneValue,
    /// `stream-truncated`: In strict mode, a stream ended without a comma (or, in JSON Lines, a line feed) after its last value, so the last value may be cut off (§6). Reported at: The end of the stream.
    StreamTruncated,
    /// `schema-syntax`: A schema file doesn't follow the grammar: an unexpected token, a character that has no place there. Mistakes in the comments, whitespace and strings a schema file shares with data files (§14) have the codes they have there: `unterminated-string`, `unterminated-comment`, `lone-carriage-return`, `control-character`, `bidi-control`, `invalid-utf8`, `invalid-escape`. Reported at (informative): The token found, or the end of the file.
    SchemaSyntax,
    /// `unknown-type`: A type name that is neither defined in the file, imported, nor a prelude type. A type a standard module or official extension has needs its import. Reported at (informative): The type's name where it is used.
    UnknownType,
    /// `wrong-arity`: A type is used with the wrong number of arguments: `Array` without its element type, `Int` with one, a generic type of your own with too few or too many. Reported at (informative): The type's name where it is used.
    WrongArity,
    /// `duplicate-type`: Two definitions of the same type name, or a definition with the name of an imported type. Reported at (informative): The second definition, at its `type`.
    DuplicateType,
    /// `redefine-prelude`: A definition with the name of a prelude type (`Int`, `Any`, `Secret`, `Maybe`, …), which schemas can't redefine. Reported at (informative): The definition, at its `type`.
    RedefinePrelude,
    /// `unknown-parameter`: A lowercase name in a type that is not a parameter of the definition. Reported at (informative): The name where it is used.
    UnknownParameter,
    /// `invalid-parameter`: A type parameter starting with `_`, or the same parameter twice in one definition. Reported at (informative): The parameter: the second one, for a parameter given twice.
    InvalidParameter,
    /// `underscore-type`: `_` used as a type. Types are open by default, so there is no wildcard. Reported at (informative): The `_`.
    UnderscoreType,
    /// `duplicate-field`: A record type lists the same field twice, also one copied in by a spread. Reported at (informative): The second field's key.
    DuplicateField,
    /// `duplicate-tag`: A variant type lists the same tag twice, also one copied in by a spread. Reported at (informative): The second tag.
    DuplicateTag,
    /// `closed-empty-variant`: `closed < >`: a closed variant without tags accepts nothing. Checked as written: `closed < ...E >` is accepted even when `E` has no tags. Reported at (informative): The `<`.
    ClosedEmptyVariant,
    /// `invalid-spread`: A spread of something that can't be spread: not a named type, a type with parameters, a `Stream`, a type of the prelude (`...Bool`), or a record spread into a variant (or a variant into a record). An alias or a generic instance is spread as what it stands for. Reported at (informative): The name after `...`.
    InvalidSpread,
    /// `spread-cycle`: A type spreads itself, directly or through other types. Reported at (informative): A definition in the cycle, at its `type`.
    SpreadCycle,
    /// `row-parameter`: A spread of a parameter, `...r`. Row parameters are not part of the language. Reported at (informative): The name after `...`.
    RowParameter,
    /// `misplaced-stream`: `Stream` used anywhere but as the whole type of a definition, or a reference to such a definition. A stream is a whole file. Reported at (informative): The name `Stream`, or the reference to the stream's definition.
    MisplacedStream,
    /// `unguarded-recursion`: A type refers to itself without a record field, array element or variant payload in between (§9.9), so decoding it would consume no input. `Secret` and names don't count as a step. Reported at (informative): A definition in the cycle, at its `type`.
    UnguardedRecursion,
    /// `growing-recursion`: Generic types whose instances could grow without bound: a type parameter passes, wrapped in a bigger type, along a cycle of references back to itself (`type T a = < X (T (Pair a a)) >`, §9.10). Reported at (informative): The reference on the cycle that passes the parameter in a bigger type.
    GrowingRecursion,
    /// `type-too-deep`: Type expressions are nested deeper than the schema parser's limit. Reported at (informative): The bracket that opens the first level too deep.
    TypeTooDeep,
    /// `attribute-arguments`: An attribute this version defines, given arguments it doesn't take: `@deprecated` takes nothing or one string. Also empty parentheses after an attribute. Reported at (informative): The attribute's `@`.
    AttributeArguments,
    /// `attribute-twice`: The same attribute twice on one type, field or tag, for an attribute this version defines. One it doesn't define may appear twice, with a warning each (`unknown-attribute`). Reported at (informative): The second attribute's `@`.
    AttributeTwice,
    /// `attribute-space`: A space between an attribute's name and its `(`. Reported at (informative): The space after the attribute's name.
    AttributeSpace,
    /// `attribute-on-spread`: An attribute on a spread. The fields and tags a spread copies keep their own attributes. Reported at (informative): The attribute's `@`.
    AttributeOnSpread,
    /// `unknown-module`: An import of a module that doesn't exist: an unknown standard module, a former standard module, a package name that breaks npm's rules (`@Haus/money`), or a module that starts with `.` but not with `./` or `../` (`.../a`). Any other word where a module belongs (`foo/bar`) is `schema-syntax` (grammar.ebnf). Reported at (informative): The import, at its `import`.
    UnknownModule,
    /// `unknown-import`: An import names a type the module doesn't have, or no type at all. Reported at (informative): The type's name in the import.
    UnknownImport,
    /// `duplicate-import`: The same type name is imported twice. Reported at (informative): The second name in the imports.
    DuplicateImport,
    /// `import-unavailable`: The schema imports a package or file, and the tool reading it has no way to find one (no module resolver): only standard modules can be imported there. Reported at (informative): The import, at its `import`.
    ImportUnavailable,
    /// `import-not-found`: An imported package or file can't be found: it is not installed, the path is wrong, the file is not a regular file (a directory, a FIFO, a device) or is spelled otherwise than its directory lists it, a directory on its way can't be listed, a name on a relative import's path is a symbolic link (which a relative import never follows), whether the file is in a package's directory can't be checked (a directory between it and the build's root can't be listed), or the package found names another package in its manifest. With npm, also a `node_modules/@org/name` that is there but can't be used (a dangling link, a cycle of links, a directory that can't be entered): the search stops there (§13.3). Reported at (informative): The import, at its `import`.
    ImportNotFound,
    /// `import-outside-root`: A relative import reaches a file outside the build's root directory (§13.3): by default the directory of the schema file the build starts from, or the directory given as the build's `root` option. Its `..` names go above the root: it is rejected before anything is looked at (a relative import follows no symbolic link, so it can't leave the root otherwise). Also a `root` option that doesn't contain the schema file the build starts from. Reported at (informative): The import, at its `import`. A `root` option that doesn't contain the entry file: no place.
    ImportOutsideRoot,
    /// `import-version`: An import asks for a major version (`@org/name@2`) and another one is installed, or names something other than a major version: `@1.1`, `@1.1.0`, `@01`, `@x`, `@1~x`, `@1@2` (a package module is one token up to a blank or `(`, grammar.ebnf). Reported at (informative): The import, at its `import`.
    ImportVersion,
    /// `import-cycle`: Schema files import each other in a cycle. Reported at (informative): The import that closes the cycle, at its `import`.
    ImportCycle,
    /// `duplicate-package`: One schema reaches two different packages with the same name: two versions of one package (also two major versions), two copies of one version whose files differ, or two packages that call themselves the same. Byte-identical copies are one package. Reported at (informative): The import that reaches the second package, at its `import`.
    DuplicatePackage,
    /// `undeclared-package`: A file imports a package that its package or project doesn't declare as a dependency (with npm: in the package's own `package.json`, or the nearest one above an application file), or a file with no `package.json` above it imports a package that wasn't given explicitly. A package found only because the package manager placed it nearby, such as a hoisted dependency of a dependency, could be replaced by another one placed there. Checked before the package is looked for. Reported at (informative): The import, at its `import`.
    UndeclaredPackage,
    /// `package-manifest`: A package's `package.haus` is not a valid manifest: not one record, a `name` that isn't a lowercase `@org/name` (or has the part `node_modules`), a `version` that isn't a semantic version, or more than 64 KiB. Reported at (informative): The import that reaches the package; the message names the manifest. A package given by its directory: no place.
    PackageManifest,
    /// `package-version`: A package's `package.haus` has another version than the package manager gives the package (the `version` of its `package.json`, its Cargo version). A check implementations SHOULD make (§13.3), also for a package given explicitly by its directory that has a `package.json` next to its manifest. A subdirectory of a folder of packages with such a version is skipped instead, like one with a broken manifest, and named when an import isn't found; a `package.json` beside a package given by its directory that can't be read is ignored, by every implementation. Reported at (informative): The import that reaches the package; the message names both versions.
    PackageVersion,
    /// `package-path`: A schema package refers to a file it may not: its `schema.haus` imports a file (`import ./x`) instead of a package; its `package.haus`, `schema.haus` or `package.json` is a symbolic link or not a regular file; or a file outside any package imports a file in a package's directory (`import ./node_modules/x/y`). The file is not read. Reported at (informative): The import that reaches the file; the message names the file.
    PackagePath,
    /// `package-name`: A package manager's name for a schema package differs from its manifest's: the `name` of its `package.json` isn't the `name` of its `package.haus`. On npm, imports find a package by that name, so it must be the manifest's (§13.3). Reported by package checks such as `haus package check`. Reported at (informative): No place in text: the message names the package and its files.
    PackageName,
    /// `package-crate`: A schema package's crate can't be named by the code generated for crates that use its types: its `links` is missing or isn't its library's name (`\[lib\] name`), or a crate depends on a schema package's crate under another name (`package = …`). Generated code names a schema package's crate by its `links`, which is its library's name. Reported by package checks such as `haus package check`. Reported at (informative): No place in text: the message names the crate.
    PackageCrate,
    /// `package-install-script`: A schema package runs code when it is installed: an npm `preinstall`, `install` or `postinstall` script, or a `binding.gyp`, for which npm runs node-gyp. A schema package is data and MUST NOT need code to install (§13.3). Reported at (informative): No place in text: the message names the package and the script.
    PackageInstallScript,
    /// `package-files`: A package manager's configuration doesn't ship a file of the schema package: `package.haus`, `schema.haus`, or a profile's vectors or rule. Read from the configuration (`files` of `package.json`, `include` of `Cargo.toml`, a wheel's build configuration), without packing anything. Reported at (informative): No place in text: the message names the package and the file.
    PackageFiles,
    /// `profile-vectors`: A profile of a schema package is malformed (§13.3): it has no rule (`profiles/<name>.md`) next to its vectors; a vector isn't `Accept { type, value, output?, note? }` or `Reject { type, value, note? }` with string fields and no others (only an `Accept` has an `output`); its `type` isn't a type of the package without parameters; its `value` or `output` isn't one haus value; or an accepted value or its output isn't valid for its type, which a codec running after the schema can't accept. Also a profile name that isn't lowercase, and a vectors file with no vectors. Reported at (informative): The vector's place in its file, or the profile when its rule is missing.
    ProfileVectors,
    /// `package-wrapper`: A package manager's file of a schema package can't be read as one: a `package.json` that isn't a JSON object or has no `name`, a `Cargo.toml` or `pyproject.toml` that isn't valid TOML, a `Cargo.toml` without `\[package\]`. Reported by package checks such as `haus package check`. Reported at (informative): No place in text: the message names the file.
    PackageWrapper,
    /// `codec-unreachable`: A codec's type occurs where this binding can't apply the codec, such as the payload of a record case whose fields sit beside its tag in the host value. Decoding there with the default host type would silently differ from the other bindings (§13.4). Reported at (informative): The place of the codec's type in the schema, or in the value (§15).
    CodecUnreachable,
    /// `file-too-large`: A schema file or a package's `package.json` is larger than the tool allows (1 MiB by default). It is not read. Reported at (informative): The import that reaches the file.
    FileTooLarge,
    /// `too-many-files`: A schema imports more schema files, directly or not, than the tool allows (256 by default, the root included), or a folder of packages has more entries than allowed (4096). Reported at (informative): The import that reaches one file too many, or the folder.
    TooManyFiles,
    /// `type-mismatch`: A value of another kind than the type accepts: a string for an `Int`, an array for a record, a tag that isn't `True` or `False` for a `Bool`. Decoders never convert between kinds (§15). Reported at: The value (§15): `$.items\[2\]`. For a std/time type, any value that isn't its tag around one string, at the value (`Date(1)` at `$`).
    TypeMismatch,
    /// `not-an-integer`: A number with a fraction or an exponent where an integer type is expected. `1.0` and `1e3` are not whole numbers by spelling (§15). Reported at: The number.
    NotAnInteger,
    /// `out-of-range`: A number outside the type's range: an `Int8` above 127, a negative `UInt32`, a float too large for `Float32`. Never wrapped or clamped. Reported at: The number.
    OutOfRange,
    /// `missing-field`: A record lacks a field the type requires. Only fields with `?` may be missing; `None` is not missing. Reported at: The record, not the field.
    MissingField,
    /// `unknown-field`: A field a closed record doesn't list. Open records ignore such fields (see `unlisted-field`). Reported at: The field: `$.extra`.
    UnknownField,
    /// `unknown-tag`: A tag a closed variant doesn't list. Open variants read it as an unknown value (see `unlisted-tag`). Reported at: The variant.
    UnknownTag,
    /// `wrong-payload`: A listed tag with another payload than its case says: arguments for a tag without payload, the wrong number of arguments, a positional payload where a record is expected, such as `Circle(1.5)` for the case `Circle { r: Float64 }` (§15). Reported at: The variant.
    WrongPayload,
    /// `invalid-time`: A std/time value whose text the std/time profile rejects: a day that doesn't exist, a missing offset, a lowercase `t` (spec/std/time.md). Reported at: The string: `$\[0\]` for `Date("2026-02-30")`.
    InvalidTime,
    /// `invalid-secret`: A value of a `Secret` type that its type doesn't accept, when decoding, or that can't be written, when encoding. The error names the place and the type only, never the value or why it failed (§15). Reported at: The secret itself, never a place inside it.
    InvalidSecret,
    /// `codec-rejected`: A value its type's schema accepts and a codec rejects (§13.4), such as an amount whose currency isn't in ISO 4217 for the `@haus-fmt/money/iso` profile. At the place of the codec's type. Reported at: The place of the codec's type: of the innermost codec that rejects (§13.4).
    CodecRejected,
    /// `cannot-encode`: Encoding: a value of the program's language that the type can't write, such as a JavaScript number for an `Int` that expects a bigint, or a string that is no valid `Date`. Building a value in code (§11): a string, key or tag with an unpaired surrogate, which has no UTF-8 form, or, in a binding whose strings are bytes, one that isn't valid UTF-8; or something that is no haus value (an object of another type where a value or a number is expected). Rejected when the value is built or, at the latest, when it is written, canonicalised or hashed. Reported at: The place of the value in the type being encoded. Building a value in code: informative (§11).
    CannotEncode,
    /// `cyclic-value`: Encoding: a value contains itself, so it has no finite text. Reported at: The place of the value that contains itself, or `$`.
    CyclicValue,
    /// `step-budget`: Decoding or encoding took more steps than the input justifies, a sign of a schema doing unbounded work. Bindings MUST bound the work of one decode (§9.8). Reported at: `$`: the whole decode or encode.
    StepBudget,
    /// `too-many-nodes`: A value built in code (not parsed) would write more values than the node limit allows (default 64 Mi, §7): its parts share each other so much that it expands when written, counted as writers, the canonical form and hashing write it. Reported at: `$`: the value given to the writer, the canonical form or the hash, or to an encoder or decoder with a schema (§15); `$\[i\]` for the i-th value of a stream written, or of `hashAll`, also when the stream has one value (`$\[0\]`). From `equals` or `compare`: `$`, and the message says which operand.
    TooManyNodes,
    /// `json-syntax`: Text that isn't JSON (RFC 8259): a missing comma or colon, an unquoted name, a trailing comma, a comment, text after the value. Also an empty line in JSON Lines, or a byte order mark at the start of a line after the first. A string that isn't closed, and a bad escape, have the codes of haus text: `unterminated-string`, `invalid-escape`, `invalid-unicode-escape`. Reported at: `$`, with the line and column of the token found or of the end of the text. In JSON Lines, the line: `$\[3\]`.
    JsonSyntax,
    /// `unpaired-surrogate`: A JSON string with half of a UTF-16 surrogate pair, raw or as `\uD800`. I-JSON forbids them, and they are no Unicode characters (§16). Reported at: `$`, with the line and column of the escape's backslash, or of the raw character.
    UnpairedSurrogate,
    /// `haus-json-form`: JSON that isn't self-describing JSON (§16.2): a text without the envelope `{"_haus": 1, "_value": …}`, an envelope with other members, a bare number, `true`, `null`, an object with other members, a `_rec` that isn't an object, an `_args` that isn't a non-empty array. Reported at: The object that isn't a form (§16.3, "Places"): `$` for a text without the envelope.
    HausJsonForm,
    /// `haus-json-version`: A self-describing JSON envelope whose `_haus` isn't 1, the only version of the form (§16.2): it was written for a later version of haus, or isn't haus. Reported at: The member: `$._haus`.
    HausJsonVersion,
    /// `haus-json-number`: A self-describing `_num` that isn't a normalized number literal (§2): `"1E5"`, `"01"`, `"0xff"`, or not a string. Reported at: The member: `$._value._num`.
    HausJsonNumber,
    /// `haus-json-bytes`: A self-describing `_bytes` that isn't two lowercase hex digits per byte. Reported at: The member: `$._value._bytes`.
    HausJsonBytes,
    /// `invalid-tag`: A tag name that isn't `\[A-Z\]\[A-Za-z0-9_\]*`, or a `"_tag"` that isn't a string: in a `_tag` of either JSON form, in the string of a closed variant whose tags have no payload in schema-based JSON (`"debug"`, §16.3), or in a value built in code (rejected when it is built or, at the latest, when it is written, canonicalised or hashed, §11). Reported at: The object that holds the `"_tag"`, or the string of a closed enum (§16.3, "Places"). Built in code: informative (§11).
    InvalidTag,
    /// `invalid-base64`: Schema-based JSON `Bytes` that aren't canonical base64 with padding (RFC 4648 §4): whitespace, the URL alphabet, missing padding, non-zero pad bits. Reported at: The string.
    InvalidBase64,
    /// `missing-member`: Schema-based JSON: an object lacks a member its form needs, such as `"_tag"` for a variant or `"value"` for a tag with one argument. Reported at: The object.
    MissingMember,
    /// `unexpected-member`: Schema-based JSON: an object has a member its form doesn't have, such as `"value"` next to a tag without payload (§16.3). Reported at: The member: `$.x`.
    UnexpectedMember,
    /// `no-json-form`: A value or type that has no JSON form: a string with an unpaired surrogate, a record payload with a field named `_tag` or `_args` in schema-based JSON (§16.3), a type with no schema-based form. Reported at: The value's place when writing or reading; in a schema file, a warning at the case's tag (§14).
    NoJsonForm,
    /// `unknown-attribute`: A warning: an attribute this version of haus doesn't define. It is accepted and has no meaning (§14). Reported at: The attribute's `@`.
    UnknownAttribute,
    /// `deprecated`: A hint: the schema or the data uses a type, field or tag marked `@deprecated` (§14). Reported at: In a schema, the type's name where it is used (after `...` for a spread); in data, the field's value or the tagged value: `$.lines\[0\].count`.
    Deprecated,
    /// `unlisted-field`: A hint: a field an open record doesn't list. A reader ignores it, but it may be a typo. Reported at: The field: `$.nmae`. Never inside a `Secret` (§14).
    UnlistedField,
    /// `unlisted-tag`: A hint: a tag an open variant doesn't list. A reader keeps it as an unknown value, but it may be a typo. Reported at: The variant. Never inside a `Secret` (§14).
    UnlistedTag,
    /// `missing-codec`: A warning: the schema reaches a type that an official profile has a rule for (`@haus-fmt/money@1#Currency`, `@haus-fmt/geo@1#LatLng`, `@haus-fmt/geo@1#BBox`), and no codec is set for it, so the rule is not checked: its values are checked for their shape only (§13.4). Decoding is unchanged. Tools without codecs (`haus check`, editors) report it as a note, once per import of such a package. Reported at: Nowhere: it is about the codecs the application set, reported once per type id. From a tool without codecs: the import of the package.
    MissingCodec,
}

/// The category of an error code (spec §17).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[non_exhaustive]
pub enum ErrorCategory {
    Syntax,
    Limits,
    Streams,
    SchemaFiles,
    Imports,
    Decoding,
    Json,
    Hints,
}

impl ErrorCategory {
    /// Its id: `schema-files`.
    pub const fn as_str(self) -> &'static str {
        match self {
            ErrorCategory::Syntax => "syntax",
            ErrorCategory::Limits => "limits",
            ErrorCategory::Streams => "streams",
            ErrorCategory::SchemaFiles => "schema-files",
            ErrorCategory::Imports => "imports",
            ErrorCategory::Decoding => "decoding",
            ErrorCategory::Json => "json",
            ErrorCategory::Hints => "hints",
        }
    }
}

impl ErrorCode {
    /// Every code, in the catalogue's order.
    pub const ALL: [ErrorCode; 117] = [
        ErrorCode::InvalidUtf8,
        ErrorCode::VersionDirective,
        ErrorCode::ExpectedValue,
        ErrorCode::MissingComma,
        ErrorCode::PayloadNewline,
        ErrorCode::UnexpectedCloser,
        ErrorCode::UnclosedBracket,
        ErrorCode::NullLiteral,
        ErrorCode::BooleanLiteral,
        ErrorCode::BareIdentifier,
        ErrorCode::ExpectedKey,
        ErrorCode::UppercaseKey,
        ErrorCode::BlockStringKey,
        ErrorCode::MissingColon,
        ErrorCode::DuplicateKey,
        ErrorCode::EmptyPayload,
        ErrorCode::InvalidNumber,
        ErrorCode::UnterminatedString,
        ErrorCode::StringLineBreak,
        ErrorCode::ControlCharacter,
        ErrorCode::BidiControl,
        ErrorCode::InvalidEscape,
        ErrorCode::InvalidUnicodeEscape,
        ErrorCode::BlockStringOpening,
        ErrorCode::BlockStringClosing,
        ErrorCode::BlockStringIndent,
        ErrorCode::UnterminatedBlockString,
        ErrorCode::UnterminatedBytes,
        ErrorCode::BytesNotHex,
        ErrorCode::BytesOddDigits,
        ErrorCode::LoneCarriageReturn,
        ErrorCode::UnterminatedComment,
        ErrorCode::StraySlash,
        ErrorCode::NestingTooDeep,
        ErrorCode::NumberTooLong,
        ErrorCode::ExponentTooLarge,
        ErrorCode::StringTooLong,
        ErrorCode::KeyTooLong,
        ErrorCode::TagTooLong,
        ErrorCode::ValueTooLong,
        ErrorCode::UnsupportedDepth,
        ErrorCode::NotOneValue,
        ErrorCode::StreamTruncated,
        ErrorCode::SchemaSyntax,
        ErrorCode::UnknownType,
        ErrorCode::WrongArity,
        ErrorCode::DuplicateType,
        ErrorCode::RedefinePrelude,
        ErrorCode::UnknownParameter,
        ErrorCode::InvalidParameter,
        ErrorCode::UnderscoreType,
        ErrorCode::DuplicateField,
        ErrorCode::DuplicateTag,
        ErrorCode::ClosedEmptyVariant,
        ErrorCode::InvalidSpread,
        ErrorCode::SpreadCycle,
        ErrorCode::RowParameter,
        ErrorCode::MisplacedStream,
        ErrorCode::UnguardedRecursion,
        ErrorCode::GrowingRecursion,
        ErrorCode::TypeTooDeep,
        ErrorCode::AttributeArguments,
        ErrorCode::AttributeTwice,
        ErrorCode::AttributeSpace,
        ErrorCode::AttributeOnSpread,
        ErrorCode::UnknownModule,
        ErrorCode::UnknownImport,
        ErrorCode::DuplicateImport,
        ErrorCode::ImportUnavailable,
        ErrorCode::ImportNotFound,
        ErrorCode::ImportOutsideRoot,
        ErrorCode::ImportVersion,
        ErrorCode::ImportCycle,
        ErrorCode::DuplicatePackage,
        ErrorCode::UndeclaredPackage,
        ErrorCode::PackageManifest,
        ErrorCode::PackageVersion,
        ErrorCode::PackagePath,
        ErrorCode::PackageName,
        ErrorCode::PackageCrate,
        ErrorCode::PackageInstallScript,
        ErrorCode::PackageFiles,
        ErrorCode::ProfileVectors,
        ErrorCode::PackageWrapper,
        ErrorCode::CodecUnreachable,
        ErrorCode::FileTooLarge,
        ErrorCode::TooManyFiles,
        ErrorCode::TypeMismatch,
        ErrorCode::NotAnInteger,
        ErrorCode::OutOfRange,
        ErrorCode::MissingField,
        ErrorCode::UnknownField,
        ErrorCode::UnknownTag,
        ErrorCode::WrongPayload,
        ErrorCode::InvalidTime,
        ErrorCode::InvalidSecret,
        ErrorCode::CodecRejected,
        ErrorCode::CannotEncode,
        ErrorCode::CyclicValue,
        ErrorCode::StepBudget,
        ErrorCode::TooManyNodes,
        ErrorCode::JsonSyntax,
        ErrorCode::UnpairedSurrogate,
        ErrorCode::HausJsonForm,
        ErrorCode::HausJsonVersion,
        ErrorCode::HausJsonNumber,
        ErrorCode::HausJsonBytes,
        ErrorCode::InvalidTag,
        ErrorCode::InvalidBase64,
        ErrorCode::MissingMember,
        ErrorCode::UnexpectedMember,
        ErrorCode::NoJsonForm,
        ErrorCode::UnknownAttribute,
        ErrorCode::Deprecated,
        ErrorCode::UnlistedField,
        ErrorCode::UnlistedTag,
        ErrorCode::MissingCodec,
    ];

    /// The code: `payload-newline`.
    pub const fn as_str(self) -> &'static str {
        match self {
            ErrorCode::InvalidUtf8 => "invalid-utf8",
            ErrorCode::VersionDirective => "version-directive",
            ErrorCode::ExpectedValue => "expected-value",
            ErrorCode::MissingComma => "missing-comma",
            ErrorCode::PayloadNewline => "payload-newline",
            ErrorCode::UnexpectedCloser => "unexpected-closer",
            ErrorCode::UnclosedBracket => "unclosed-bracket",
            ErrorCode::NullLiteral => "null-literal",
            ErrorCode::BooleanLiteral => "boolean-literal",
            ErrorCode::BareIdentifier => "bare-identifier",
            ErrorCode::ExpectedKey => "expected-key",
            ErrorCode::UppercaseKey => "uppercase-key",
            ErrorCode::BlockStringKey => "block-string-key",
            ErrorCode::MissingColon => "missing-colon",
            ErrorCode::DuplicateKey => "duplicate-key",
            ErrorCode::EmptyPayload => "empty-payload",
            ErrorCode::InvalidNumber => "invalid-number",
            ErrorCode::UnterminatedString => "unterminated-string",
            ErrorCode::StringLineBreak => "string-line-break",
            ErrorCode::ControlCharacter => "control-character",
            ErrorCode::BidiControl => "bidi-control",
            ErrorCode::InvalidEscape => "invalid-escape",
            ErrorCode::InvalidUnicodeEscape => "invalid-unicode-escape",
            ErrorCode::BlockStringOpening => "block-string-opening",
            ErrorCode::BlockStringClosing => "block-string-closing",
            ErrorCode::BlockStringIndent => "block-string-indent",
            ErrorCode::UnterminatedBlockString => "unterminated-block-string",
            ErrorCode::UnterminatedBytes => "unterminated-bytes",
            ErrorCode::BytesNotHex => "bytes-not-hex",
            ErrorCode::BytesOddDigits => "bytes-odd-digits",
            ErrorCode::LoneCarriageReturn => "lone-carriage-return",
            ErrorCode::UnterminatedComment => "unterminated-comment",
            ErrorCode::StraySlash => "stray-slash",
            ErrorCode::NestingTooDeep => "nesting-too-deep",
            ErrorCode::NumberTooLong => "number-too-long",
            ErrorCode::ExponentTooLarge => "exponent-too-large",
            ErrorCode::StringTooLong => "string-too-long",
            ErrorCode::KeyTooLong => "key-too-long",
            ErrorCode::TagTooLong => "tag-too-long",
            ErrorCode::ValueTooLong => "value-too-long",
            ErrorCode::UnsupportedDepth => "unsupported-depth",
            ErrorCode::NotOneValue => "not-one-value",
            ErrorCode::StreamTruncated => "stream-truncated",
            ErrorCode::SchemaSyntax => "schema-syntax",
            ErrorCode::UnknownType => "unknown-type",
            ErrorCode::WrongArity => "wrong-arity",
            ErrorCode::DuplicateType => "duplicate-type",
            ErrorCode::RedefinePrelude => "redefine-prelude",
            ErrorCode::UnknownParameter => "unknown-parameter",
            ErrorCode::InvalidParameter => "invalid-parameter",
            ErrorCode::UnderscoreType => "underscore-type",
            ErrorCode::DuplicateField => "duplicate-field",
            ErrorCode::DuplicateTag => "duplicate-tag",
            ErrorCode::ClosedEmptyVariant => "closed-empty-variant",
            ErrorCode::InvalidSpread => "invalid-spread",
            ErrorCode::SpreadCycle => "spread-cycle",
            ErrorCode::RowParameter => "row-parameter",
            ErrorCode::MisplacedStream => "misplaced-stream",
            ErrorCode::UnguardedRecursion => "unguarded-recursion",
            ErrorCode::GrowingRecursion => "growing-recursion",
            ErrorCode::TypeTooDeep => "type-too-deep",
            ErrorCode::AttributeArguments => "attribute-arguments",
            ErrorCode::AttributeTwice => "attribute-twice",
            ErrorCode::AttributeSpace => "attribute-space",
            ErrorCode::AttributeOnSpread => "attribute-on-spread",
            ErrorCode::UnknownModule => "unknown-module",
            ErrorCode::UnknownImport => "unknown-import",
            ErrorCode::DuplicateImport => "duplicate-import",
            ErrorCode::ImportUnavailable => "import-unavailable",
            ErrorCode::ImportNotFound => "import-not-found",
            ErrorCode::ImportOutsideRoot => "import-outside-root",
            ErrorCode::ImportVersion => "import-version",
            ErrorCode::ImportCycle => "import-cycle",
            ErrorCode::DuplicatePackage => "duplicate-package",
            ErrorCode::UndeclaredPackage => "undeclared-package",
            ErrorCode::PackageManifest => "package-manifest",
            ErrorCode::PackageVersion => "package-version",
            ErrorCode::PackagePath => "package-path",
            ErrorCode::PackageName => "package-name",
            ErrorCode::PackageCrate => "package-crate",
            ErrorCode::PackageInstallScript => "package-install-script",
            ErrorCode::PackageFiles => "package-files",
            ErrorCode::ProfileVectors => "profile-vectors",
            ErrorCode::PackageWrapper => "package-wrapper",
            ErrorCode::CodecUnreachable => "codec-unreachable",
            ErrorCode::FileTooLarge => "file-too-large",
            ErrorCode::TooManyFiles => "too-many-files",
            ErrorCode::TypeMismatch => "type-mismatch",
            ErrorCode::NotAnInteger => "not-an-integer",
            ErrorCode::OutOfRange => "out-of-range",
            ErrorCode::MissingField => "missing-field",
            ErrorCode::UnknownField => "unknown-field",
            ErrorCode::UnknownTag => "unknown-tag",
            ErrorCode::WrongPayload => "wrong-payload",
            ErrorCode::InvalidTime => "invalid-time",
            ErrorCode::InvalidSecret => "invalid-secret",
            ErrorCode::CodecRejected => "codec-rejected",
            ErrorCode::CannotEncode => "cannot-encode",
            ErrorCode::CyclicValue => "cyclic-value",
            ErrorCode::StepBudget => "step-budget",
            ErrorCode::TooManyNodes => "too-many-nodes",
            ErrorCode::JsonSyntax => "json-syntax",
            ErrorCode::UnpairedSurrogate => "unpaired-surrogate",
            ErrorCode::HausJsonForm => "haus-json-form",
            ErrorCode::HausJsonVersion => "haus-json-version",
            ErrorCode::HausJsonNumber => "haus-json-number",
            ErrorCode::HausJsonBytes => "haus-json-bytes",
            ErrorCode::InvalidTag => "invalid-tag",
            ErrorCode::InvalidBase64 => "invalid-base64",
            ErrorCode::MissingMember => "missing-member",
            ErrorCode::UnexpectedMember => "unexpected-member",
            ErrorCode::NoJsonForm => "no-json-form",
            ErrorCode::UnknownAttribute => "unknown-attribute",
            ErrorCode::Deprecated => "deprecated",
            ErrorCode::UnlistedField => "unlisted-field",
            ErrorCode::UnlistedTag => "unlisted-tag",
            ErrorCode::MissingCodec => "missing-codec",
        }
    }

    /// Its category.
    pub const fn category(self) -> ErrorCategory {
        match self {
            ErrorCode::InvalidUtf8 => ErrorCategory::Syntax,
            ErrorCode::VersionDirective => ErrorCategory::Syntax,
            ErrorCode::ExpectedValue => ErrorCategory::Syntax,
            ErrorCode::MissingComma => ErrorCategory::Syntax,
            ErrorCode::PayloadNewline => ErrorCategory::Syntax,
            ErrorCode::UnexpectedCloser => ErrorCategory::Syntax,
            ErrorCode::UnclosedBracket => ErrorCategory::Syntax,
            ErrorCode::NullLiteral => ErrorCategory::Syntax,
            ErrorCode::BooleanLiteral => ErrorCategory::Syntax,
            ErrorCode::BareIdentifier => ErrorCategory::Syntax,
            ErrorCode::ExpectedKey => ErrorCategory::Syntax,
            ErrorCode::UppercaseKey => ErrorCategory::Syntax,
            ErrorCode::BlockStringKey => ErrorCategory::Syntax,
            ErrorCode::MissingColon => ErrorCategory::Syntax,
            ErrorCode::DuplicateKey => ErrorCategory::Syntax,
            ErrorCode::EmptyPayload => ErrorCategory::Syntax,
            ErrorCode::InvalidNumber => ErrorCategory::Syntax,
            ErrorCode::UnterminatedString => ErrorCategory::Syntax,
            ErrorCode::StringLineBreak => ErrorCategory::Syntax,
            ErrorCode::ControlCharacter => ErrorCategory::Syntax,
            ErrorCode::BidiControl => ErrorCategory::Syntax,
            ErrorCode::InvalidEscape => ErrorCategory::Syntax,
            ErrorCode::InvalidUnicodeEscape => ErrorCategory::Syntax,
            ErrorCode::BlockStringOpening => ErrorCategory::Syntax,
            ErrorCode::BlockStringClosing => ErrorCategory::Syntax,
            ErrorCode::BlockStringIndent => ErrorCategory::Syntax,
            ErrorCode::UnterminatedBlockString => ErrorCategory::Syntax,
            ErrorCode::UnterminatedBytes => ErrorCategory::Syntax,
            ErrorCode::BytesNotHex => ErrorCategory::Syntax,
            ErrorCode::BytesOddDigits => ErrorCategory::Syntax,
            ErrorCode::LoneCarriageReturn => ErrorCategory::Syntax,
            ErrorCode::UnterminatedComment => ErrorCategory::Syntax,
            ErrorCode::StraySlash => ErrorCategory::Syntax,
            ErrorCode::NestingTooDeep => ErrorCategory::Limits,
            ErrorCode::NumberTooLong => ErrorCategory::Limits,
            ErrorCode::ExponentTooLarge => ErrorCategory::Limits,
            ErrorCode::StringTooLong => ErrorCategory::Limits,
            ErrorCode::KeyTooLong => ErrorCategory::Limits,
            ErrorCode::TagTooLong => ErrorCategory::Limits,
            ErrorCode::ValueTooLong => ErrorCategory::Limits,
            ErrorCode::UnsupportedDepth => ErrorCategory::Limits,
            ErrorCode::NotOneValue => ErrorCategory::Streams,
            ErrorCode::StreamTruncated => ErrorCategory::Streams,
            ErrorCode::SchemaSyntax => ErrorCategory::SchemaFiles,
            ErrorCode::UnknownType => ErrorCategory::SchemaFiles,
            ErrorCode::WrongArity => ErrorCategory::SchemaFiles,
            ErrorCode::DuplicateType => ErrorCategory::SchemaFiles,
            ErrorCode::RedefinePrelude => ErrorCategory::SchemaFiles,
            ErrorCode::UnknownParameter => ErrorCategory::SchemaFiles,
            ErrorCode::InvalidParameter => ErrorCategory::SchemaFiles,
            ErrorCode::UnderscoreType => ErrorCategory::SchemaFiles,
            ErrorCode::DuplicateField => ErrorCategory::SchemaFiles,
            ErrorCode::DuplicateTag => ErrorCategory::SchemaFiles,
            ErrorCode::ClosedEmptyVariant => ErrorCategory::SchemaFiles,
            ErrorCode::InvalidSpread => ErrorCategory::SchemaFiles,
            ErrorCode::SpreadCycle => ErrorCategory::SchemaFiles,
            ErrorCode::RowParameter => ErrorCategory::SchemaFiles,
            ErrorCode::MisplacedStream => ErrorCategory::SchemaFiles,
            ErrorCode::UnguardedRecursion => ErrorCategory::SchemaFiles,
            ErrorCode::GrowingRecursion => ErrorCategory::SchemaFiles,
            ErrorCode::TypeTooDeep => ErrorCategory::SchemaFiles,
            ErrorCode::AttributeArguments => ErrorCategory::SchemaFiles,
            ErrorCode::AttributeTwice => ErrorCategory::SchemaFiles,
            ErrorCode::AttributeSpace => ErrorCategory::SchemaFiles,
            ErrorCode::AttributeOnSpread => ErrorCategory::SchemaFiles,
            ErrorCode::UnknownModule => ErrorCategory::Imports,
            ErrorCode::UnknownImport => ErrorCategory::Imports,
            ErrorCode::DuplicateImport => ErrorCategory::Imports,
            ErrorCode::ImportUnavailable => ErrorCategory::Imports,
            ErrorCode::ImportNotFound => ErrorCategory::Imports,
            ErrorCode::ImportOutsideRoot => ErrorCategory::Imports,
            ErrorCode::ImportVersion => ErrorCategory::Imports,
            ErrorCode::ImportCycle => ErrorCategory::Imports,
            ErrorCode::DuplicatePackage => ErrorCategory::Imports,
            ErrorCode::UndeclaredPackage => ErrorCategory::Imports,
            ErrorCode::PackageManifest => ErrorCategory::Imports,
            ErrorCode::PackageVersion => ErrorCategory::Imports,
            ErrorCode::PackagePath => ErrorCategory::Imports,
            ErrorCode::PackageName => ErrorCategory::Imports,
            ErrorCode::PackageCrate => ErrorCategory::Imports,
            ErrorCode::PackageInstallScript => ErrorCategory::Imports,
            ErrorCode::PackageFiles => ErrorCategory::Imports,
            ErrorCode::ProfileVectors => ErrorCategory::Imports,
            ErrorCode::PackageWrapper => ErrorCategory::Imports,
            ErrorCode::CodecUnreachable => ErrorCategory::Imports,
            ErrorCode::FileTooLarge => ErrorCategory::Imports,
            ErrorCode::TooManyFiles => ErrorCategory::Imports,
            ErrorCode::TypeMismatch => ErrorCategory::Decoding,
            ErrorCode::NotAnInteger => ErrorCategory::Decoding,
            ErrorCode::OutOfRange => ErrorCategory::Decoding,
            ErrorCode::MissingField => ErrorCategory::Decoding,
            ErrorCode::UnknownField => ErrorCategory::Decoding,
            ErrorCode::UnknownTag => ErrorCategory::Decoding,
            ErrorCode::WrongPayload => ErrorCategory::Decoding,
            ErrorCode::InvalidTime => ErrorCategory::Decoding,
            ErrorCode::InvalidSecret => ErrorCategory::Decoding,
            ErrorCode::CodecRejected => ErrorCategory::Decoding,
            ErrorCode::CannotEncode => ErrorCategory::Decoding,
            ErrorCode::CyclicValue => ErrorCategory::Decoding,
            ErrorCode::StepBudget => ErrorCategory::Decoding,
            ErrorCode::TooManyNodes => ErrorCategory::Decoding,
            ErrorCode::JsonSyntax => ErrorCategory::Json,
            ErrorCode::UnpairedSurrogate => ErrorCategory::Json,
            ErrorCode::HausJsonForm => ErrorCategory::Json,
            ErrorCode::HausJsonVersion => ErrorCategory::Json,
            ErrorCode::HausJsonNumber => ErrorCategory::Json,
            ErrorCode::HausJsonBytes => ErrorCategory::Json,
            ErrorCode::InvalidTag => ErrorCategory::Json,
            ErrorCode::InvalidBase64 => ErrorCategory::Json,
            ErrorCode::MissingMember => ErrorCategory::Json,
            ErrorCode::UnexpectedMember => ErrorCategory::Json,
            ErrorCode::NoJsonForm => ErrorCategory::Json,
            ErrorCode::UnknownAttribute => ErrorCategory::Hints,
            ErrorCode::Deprecated => ErrorCategory::Hints,
            ErrorCode::UnlistedField => ErrorCategory::Hints,
            ErrorCode::UnlistedTag => ErrorCategory::Hints,
            ErrorCode::MissingCodec => ErrorCategory::Hints,
        }
    }

    /// The catalogue's fix: the hint of an error that knows no better one.
    pub const fn hint(self) -> &'static str {
        match self {
            ErrorCode::InvalidUtf8 => "Save the file as UTF-8.",
            ErrorCode::VersionDirective => "Read the file with a version of haus that supports it.",
            ErrorCode::ExpectedValue => "Write a value here, or remove the extra comma or bracket.",
            ErrorCode::MissingComma => "Add a comma between the two values.",
            ErrorCode::PayloadNewline => "Put the payload on the tag's line, or add a comma if they are two values.",
            ErrorCode::UnexpectedCloser => "Close each bracket with its own kind (`{` `}`, `[` `]`, `(` `)`) and remove extra closing brackets.",
            ErrorCode::UnclosedBracket => "Add the closing bracket.",
            ErrorCode::NullLiteral => "Write `None` (with a `Maybe` type), or leave the field out.",
            ErrorCode::BooleanLiteral => "Write `True` or `False`.",
            ErrorCode::BareIdentifier => "Quote it as a string, or start it with a capital letter to make it a tag.",
            ErrorCode::ExpectedKey => "Write a key: a lowercase identifier or a string.",
            ErrorCode::UppercaseKey => "Quote the key, or start it with a lowercase letter.",
            ErrorCode::BlockStringKey => "Write the key as a basic string, `\"…\"`.",
            ErrorCode::MissingColon => "Add `:` between the key and its value.",
            ErrorCode::DuplicateKey => "Remove or rename one of the two.",
            ErrorCode::EmptyPayload => "Remove the empty parentheses after the tag.",
            ErrorCode::InvalidNumber => "Write a decimal number (optional `-`, fraction and exponent) or a hex or binary integer, with `_` only between digits.",
            ErrorCode::UnterminatedString => "Add the closing quote. A quote inside the string is written `\\\"`.",
            ErrorCode::StringLineBreak => "Write the line break as `\\n`, or use a `\"\"\"` block string.",
            ErrorCode::ControlCharacter => "Write the character as an escape, `\\u{…}`.",
            ErrorCode::BidiControl => "Write it as an escape (`\\u{…}`) inside a string, or remove it.",
            ErrorCode::InvalidEscape => "Use one of the escapes of §4, or write `\\\\` for a backslash.",
            ErrorCode::InvalidUnicodeEscape => "Write the escape with braces, `\\u{…}`, for a character from U+0000 to U+10FFFF other than a surrogate.",
            ErrorCode::BlockStringOpening => "Start the content on the line after `\"\"\"`.",
            ErrorCode::BlockStringClosing => "Put the closing `\"\"\"` on its own line; its indentation is removed from every line.",
            ErrorCode::BlockStringIndent => "Indent every line at least as far as the closing `\"\"\"`.",
            ErrorCode::UnterminatedBlockString => "Add the closing `\"\"\"` on its own line.",
            ErrorCode::UnterminatedBytes => "Add the closing quote.",
            ErrorCode::BytesNotHex => "Write two hex digits per byte, on one line.",
            ErrorCode::BytesOddDigits => "Write each byte as two hex digits.",
            ErrorCode::LoneCarriageReturn => "Save the file with LF or CRLF line endings.",
            ErrorCode::UnterminatedComment => "Add `*/`, one for each `/*`.",
            ErrorCode::StraySlash => "Write `//` or `/*` for a comment, or remove the `/`.",
            ErrorCode::NestingTooDeep => "Flatten the data, or raise the depth limit if you trust the input.",
            ErrorCode::NumberTooLong => "Write a shorter number (a `String` or `Bytes` for very long data), or raise the number length limit.",
            ErrorCode::ExponentTooLarge => "Write a number with a smaller exponent, or raise the exponent limit.",
            ErrorCode::StringTooLong => "Split the string, or raise the string length limit.",
            ErrorCode::KeyTooLong => "Use a shorter key, or raise the string length limit.",
            ErrorCode::TagTooLong => "Use a shorter tag, or raise the string length limit.",
            ErrorCode::ValueTooLong => "Send smaller values, or raise the value length limit.",
            ErrorCode::UnsupportedDepth => "Configure a depth limit within the binding's documented maximum.",
            ErrorCode::NotOneValue => "Give exactly one value, or read the input as a stream.",
            ErrorCode::StreamTruncated => "End every value with a comma, or check that the stream wasn't cut off.",
            ErrorCode::SchemaSyntax => "Write it as the grammar says (grammar.ebnf); the message names what was expected.",
            ErrorCode::UnknownType => "Define the type, fix its spelling, or import it from the module that defines it.",
            ErrorCode::WrongArity => "Give the type exactly as many arguments as it has parameters.",
            ErrorCode::DuplicateType => "Rename one of them.",
            ErrorCode::RedefinePrelude => "Give your type another name.",
            ErrorCode::UnknownParameter => "Declare the parameter after the type's name, or use a type name.",
            ErrorCode::InvalidParameter => "Give each parameter its own lowercase name.",
            ErrorCode::UnderscoreType => "Write `< >` for a variant with any tags, `Any` for any value, or use a type parameter.",
            ErrorCode::DuplicateField => "Remove or rename one of them.",
            ErrorCode::DuplicateTag => "Remove or rename one of them.",
            ErrorCode::ClosedEmptyVariant => "List its tags, or write `< >` for a variant with any tags.",
            ErrorCode::InvalidSpread => "Spread a named variant into a variant, or a named record into a record, without parameters.",
            ErrorCode::SpreadCycle => "Break the cycle: let one of the types list its tags or fields itself.",
            ErrorCode::RowParameter => "Spread a named type instead, or nest the open part as a field with a type parameter.",
            ErrorCode::MisplacedStream => "Use `Array` inside types, and `Stream` only as the whole of a definition.",
            ErrorCode::UnguardedRecursion => "Put the recursion inside a record field, array element or variant payload.",
            ErrorCode::GrowingRecursion => "Refer to the type inside itself with exactly its own parameters.",
            ErrorCode::TypeTooDeep => "Name the inner types with definitions of their own.",
            ErrorCode::AttributeArguments => "Give the attribute only the arguments it takes: `@deprecated` takes none, or one string.",
            ErrorCode::AttributeTwice => "Keep one of them.",
            ErrorCode::AttributeSpace => "Write the parenthesis right after the attribute's name, without a space.",
            ErrorCode::AttributeOnSpread => "Put the attribute on the fields or tags in the spread type.",
            ErrorCode::UnknownModule => "Fix the module's name; a former standard module is now a package, which the message names.",
            ErrorCode::UnknownImport => "Import a type the module defines; the message lists them.",
            ErrorCode::DuplicateImport => "Import each name once.",
            ErrorCode::ImportUnavailable => "Read the schema with a resolver that loads imports (from files or packages), or inline the types.",
            ErrorCode::ImportNotFound => "Install the package, or fix the path.",
            ErrorCode::ImportOutsideRoot => "Give the build a `root` option that contains both files (such as the repository's schema directory), or move the shared file inside the root; publish types used across projects as a schema package.",
            ErrorCode::ImportVersion => "Install the major version the schema asks for, or update the import. An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range.",
            ErrorCode::ImportCycle => "Move the shared types to a file both import.",
            ErrorCode::DuplicatePackage => "Install one copy of the package: align the version ranges and deduplicate (`npm dedupe`). On npm, declare schema packages a package imports as `peerDependencies`.",
            ErrorCode::UndeclaredPackage => "Add the package to the dependencies of the importing package or project (on npm, `peerDependencies` for a package). Outside an npm project, such as in a Cargo or Python project, give the package explicitly (`--package`, `--packages`, the editor's `haus.packages`, Python's `packages=`).",
            ErrorCode::PackageManifest => "Write `{ name: \"@org/name\", version: \"1.2.0\" }`, in lowercase, with a full version.",
            ErrorCode::PackageVersion => "Release both with the same version: change them together.",
            ErrorCode::PackagePath => "A package is its `package.haus` and one `schema.haus`, and imports other packages by name (`import @org/name`); import a package by name from your own files too.",
            ErrorCode::PackageName => "Publish the package under its manifest's name: make the `name` of `package.json` the same.",
            ErrorCode::PackageCrate => "Set `links` to the library's name in `[package]`, and depend on schema package crates under their own names.",
            ErrorCode::PackageInstallScript => "Remove the script: a schema package is its manifest, its schema and its profiles, and needs nothing run.",
            ErrorCode::PackageFiles => "List `package.haus`, `schema.haus` and `profiles` in what the package manager ships.",
            ErrorCode::ProfileVectors => "Write the rule in `profiles/<name>.md`, and each vector as `Accept { type: \"T\", value: \"…\" }` or `Reject { type: \"T\", value: \"…\" }`, with values valid for `T`.",
            ErrorCode::PackageWrapper => "Fix the file so that its package manager can read it.",
            ErrorCode::CodecUnreachable => "Give the codec's type a place of its own (a field), or decode the outer type yourself; the message names where the type occurs.",
            ErrorCode::FileTooLarge => "Split the schema into several files, or raise the limit if you trust the file.",
            ErrorCode::TooManyFiles => "Import fewer files.",
            ErrorCode::TypeMismatch => "Write a value of the expected type; the message says which.",
            ErrorCode::NotAnInteger => "Write the integer without a fraction or exponent.",
            ErrorCode::OutOfRange => "Write a value within the range, or use a larger type (`Int`, `Float64`, `Decimal`).",
            ErrorCode::MissingField => "Add the field, or mark it optional in the schema with `?` after its name.",
            ErrorCode::UnknownField => "Remove the field, fix its spelling, or add it to the schema.",
            ErrorCode::UnknownTag => "Use one of the variant's tags, fix the spelling, or add the tag to the schema.",
            ErrorCode::WrongPayload => "Write the payload the schema gives the tag: none, one record, or its positional arguments; the message says which.",
            ErrorCode::InvalidTime => "Write the date or time as the std/time profile says (spec/std/time.md); the message names the type.",
            ErrorCode::InvalidSecret => "Write a value of the secret's type; the value isn't shown, so check it where it comes from.",
            ErrorCode::CodecRejected => "Write a value the codec accepts; the profile's rule (profiles/<name>.md) or the codec's documentation says which.",
            ErrorCode::CannotEncode => "Pass a value of the host type the binding documents for the type.",
            ErrorCode::CyclicValue => "Break the cycle before encoding.",
            ErrorCode::StepBudget => "Simplify the schema, or raise the step limit if the work is expected.",
            ErrorCode::TooManyNodes => "Build a smaller value, or raise the limit.",
            ErrorCode::JsonSyntax => "Write valid JSON; the message says what was expected.",
            ErrorCode::UnpairedSurrogate => "Write both halves of the surrogate pair, or the character itself.",
            ErrorCode::HausJsonForm => "Write the envelope with one of the forms of §16.2 in `_value`: a string, an array, or an object with `_num`, `_bytes`, `_rec`, or `_tag` (and `_args`). For ordinary JSON, read it with a schema or import it instead.",
            ErrorCode::HausJsonVersion => "Read it with a newer version of haus, or write `\"_haus\": 1`.",
            ErrorCode::HausJsonNumber => "Write the number's normalized literal (§2) as a string.",
            ErrorCode::HausJsonBytes => "Write the bytes as lowercase hex, two digits per byte.",
            ErrorCode::InvalidTag => "Start the tag with a capital letter and use only letters, digits and `_`.",
            ErrorCode::InvalidBase64 => "Write standard base64, with padding.",
            ErrorCode::MissingMember => "Add the member the message names.",
            ErrorCode::UnexpectedMember => "Remove the member.",
            ErrorCode::NoJsonForm => "Rename the field, or use self-describing JSON.",
            ErrorCode::UnknownAttribute => "Check the spelling; attributes of a later version are fine.",
            ErrorCode::Deprecated => "Use what the deprecation note says instead.",
            ErrorCode::UnlistedField => "Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers.",
            ErrorCode::UnlistedTag => "Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers.",
            ErrorCode::MissingCodec => "Add the codec of the profile your application uses (`iso` from `@haus-fmt/money`), or your own codec for the type.",
        }
    }
}
