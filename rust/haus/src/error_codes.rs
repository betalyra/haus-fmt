// Generated from spec/errors.haus by tests/error_codes.rs. Don't edit: edit spec/errors.haus and run
// `HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes`.

/// An error code (spec §17): which mistake an error is. Stable, and the same in every binding.
/// [`ErrorCode::as_str`] is its name, `payload-newline`; [`ErrorCode::hint`] the usual fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[non_exhaustive]
pub enum ErrorCode {
    /// `invalid-utf8`: The input is not valid UTF-8 (§4): a byte sequence that encodes no character, an overlong form or a surrogate.
    InvalidUtf8,
    /// `version-directive`: The file starts with a `#haus` version directive (§10): it was written for a later, incompatible version of haus.
    VersionDirective,
    /// `expected-value`: A value is missing: after a key's colon, between commas, or at the start of a file, something else comes where a value must be.
    ExpectedValue,
    /// `missing-comma`: Two values, fields or top-level values follow each other without a comma between them.
    MissingComma,
    /// `payload-newline`: A tag is followed by `(` or `{` on a later line, or after a comment. A payload must start on the tag's line (§5), so the two are read as separate values, and a comma is missing between them.
    PayloadNewline,
    /// `unexpected-closer`: A closing bracket that doesn't match the open one, or that has no open one.
    UnexpectedCloser,
    /// `unclosed-bracket`: A `{`, `\[` or `(` is never closed: the input ends first.
    UnclosedBracket,
    /// `null-literal`: `null` is not a value: haus has no null (§1).
    NullLiteral,
    /// `boolean-literal`: `true` and `false` are not values: booleans are the tags `True` and `False` (§1).
    BooleanLiteral,
    /// `bare-identifier`: A lowercase word where a value should be. Lowercase identifiers are only record keys.
    BareIdentifier,
    /// `expected-key`: Something that can't be a record key where a key should be, such as a number or a comma.
    ExpectedKey,
    /// `uppercase-key`: A record key starts with a capital letter. Bare keys start with a lowercase letter or `_`; capitalized words are tags.
    UppercaseKey,
    /// `block-string-key`: A block string (`"""`) is used as a record key.
    BlockStringKey,
    /// `missing-colon`: A record key is not followed by `:`.
    MissingColon,
    /// `duplicate-key`: A record has the same key twice, after escapes are read (`a` and `"a"` are the same key). Also a JSON object with the same member name twice (§16).
    DuplicateKey,
    /// `empty-payload`: A tag with empty parentheses, `Tag()`. A tag without arguments is written without them.
    EmptyPayload,
    /// `invalid-number`: A number literal that doesn't follow the grammar (§3): a leading zero, a `+`, a `.` without digits on both sides, a misplaced `_`, an uppercase `0X`, digits followed by letters. Also a string that should hold a number literal and doesn't (a `Decimal` in plain JSON, §16.3).
    InvalidNumber,
    /// `unterminated-string`: A string has no closing `"` (in haus or JSON).
    UnterminatedString,
    /// `string-line-break`: A raw line break inside a `"…"` string.
    StringLineBreak,
    /// `control-character`: A raw control character (C0, DEL, C1) in a string, block string or comment, where it could change what a terminal shows. A raw tab is allowed in block strings and comments, not in `"…"` strings. Also a raw control character in a JSON string.
    ControlCharacter,
    /// `bidi-control`: A raw bidirectional control character (U+202A–U+202E, U+2066–U+2069) in a string or comment, where it could reorder how the text is displayed ("Trojan Source", §9).
    BidiControl,
    /// `invalid-escape`: A backslash followed by a character that doesn't start an escape. haus has `\"`, `\\`, `\n`, `\r`, `\t` and `\u{…}`; JSON has its own set.
    InvalidEscape,
    /// `invalid-unicode-escape`: A `\u` escape that isn't `\u{` 1 to 6 hex digits `}`, or names no Unicode scalar value (a surrogate, or above 10FFFF). In JSON: `\u` not followed by four hex digits.
    InvalidUnicodeEscape,
    /// `block-string-opening`: Text after the opening `"""` of a block string. The content starts on the next line.
    BlockStringOpening,
    /// `block-string-closing`: The closing `"""` of a block string has text before it on its line.
    BlockStringClosing,
    /// `block-string-indent`: A line of a block string is indented less than the closing `"""`, whose indentation every line must start with.
    BlockStringIndent,
    /// `unterminated-block-string`: A block string has no closing `"""`.
    UnterminatedBlockString,
    /// `unterminated-bytes`: A byte string `x"…` has no closing `"`.
    UnterminatedBytes,
    /// `bytes-not-hex`: A byte string holds something other than hex digits, spaces and tabs, such as a letter after `f`, an escape or a line break.
    BytesNotHex,
    /// `bytes-odd-digits`: A byte in a byte string has only one hex digit: an odd number of digits, or a space inside a byte.
    BytesOddDigits,
    /// `lone-carriage-return`: A carriage return (CR) not followed by a line feed. Line breaks are LF or CRLF.
    LoneCarriageReturn,
    /// `unterminated-comment`: A `/*` comment is never closed. Block comments nest, so each `/*` needs its own `*/`.
    UnterminatedComment,
    /// `stray-slash`: A `/` that doesn't start a comment. Comments are `//` and `/* */`; haus has no operators.
    StraySlash,
    /// `nesting-too-deep`: Records, arrays and payloads are nested deeper than the depth limit (default 256). In JSON, deeper than its JSON limit (§16).
    NestingTooDeep,
    /// `number-too-long`: A number literal has more characters than the limit (default 1000).
    NumberTooLong,
    /// `exponent-too-large`: A number's exponent is larger than the limit (default 6144), in either direction.
    ExponentTooLarge,
    /// `string-too-long`: A string or byte string has more characters than the limit (default 16 Mi).
    StringTooLong,
    /// `key-too-long`: A record key has more characters than the string limit (default 16 Mi).
    KeyTooLong,
    /// `tag-too-long`: A tag has more characters than the string limit (default 16 Mi).
    TagTooLong,
    /// `value-too-long`: One top-level value of a stream (or one line of JSON Lines) has more characters than the limit (default 64 Mi).
    ValueTooLong,
    /// `unsupported-depth`: The configured depth limit is above the deepest nesting the binding supports, or isn't a whole number (§7). Raised when the limits are set, not by any input.
    UnsupportedDepth,
    /// `not-one-value`: One value was expected (a single document, a type that isn't a `Stream`), and the input holds none or several.
    NotOneValue,
    /// `stream-truncated`: In strict mode, a stream ended without a comma (or, in JSON Lines, a line feed) after its last value, so the last value may be cut off (§6).
    StreamTruncated,
    /// `schema-syntax`: A schema file doesn't follow the grammar: an unexpected token, an unterminated string or comment, a character that has no place there.
    SchemaSyntax,
    /// `unknown-type`: A type name that is neither defined in the file, imported, nor a prelude type. A type a standard module or official extension has needs its import.
    UnknownType,
    /// `wrong-arity`: A type is used with the wrong number of arguments: `Array` without its element type, `Int` with one, a generic type of your own with too few or too many.
    WrongArity,
    /// `duplicate-type`: Two definitions of the same type name, or a definition with the name of an imported type.
    DuplicateType,
    /// `redefine-prelude`: A definition with the name of a prelude type (`Int`, `Any`, `Secret`, `Maybe`, …), which schemas can't redefine.
    RedefinePrelude,
    /// `unknown-parameter`: A lowercase name in a type that is not a parameter of the definition.
    UnknownParameter,
    /// `invalid-parameter`: A type parameter named `_`, or the same parameter twice.
    InvalidParameter,
    /// `underscore-type`: `_` used as a type. Types are open by default, so there is no wildcard.
    UnderscoreType,
    /// `duplicate-field`: A record type lists the same field twice, also one copied in by a spread.
    DuplicateField,
    /// `duplicate-tag`: A variant type lists the same tag twice, also one copied in by a spread.
    DuplicateTag,
    /// `closed-empty-variant`: `closed < >`: a closed variant without tags accepts nothing.
    ClosedEmptyVariant,
    /// `invalid-spread`: A spread of something that can't be spread: not a named type, a type with parameters, a `Stream`, or a record spread into a variant (or a variant into a record).
    InvalidSpread,
    /// `spread-cycle`: A type spreads itself, directly or through other types.
    SpreadCycle,
    /// `row-parameter`: A spread of a parameter, `...r`. Row parameters are not part of the language.
    RowParameter,
    /// `misplaced-stream`: `Stream` used anywhere but as the whole type of a definition, or a reference to such a definition. A stream is a whole file.
    MisplacedStream,
    /// `unguarded-recursion`: A type refers to itself without a record field, array element or variant payload in between (§9.9), so decoding it would consume no input. `Secret` and names don't count as a step.
    UnguardedRecursion,
    /// `growing-recursion`: A generic type refers to itself with arguments other than its own parameters (§9.10), so its instances could grow without bound.
    GrowingRecursion,
    /// `type-too-deep`: Type expressions are nested deeper than the schema parser's limit.
    TypeTooDeep,
    /// `attribute-arguments`: An attribute this version defines, given arguments it doesn't take: `@deprecated` takes nothing or one string. Also empty parentheses after an attribute.
    AttributeArguments,
    /// `attribute-twice`: The same attribute twice on one type, field or tag.
    AttributeTwice,
    /// `attribute-space`: A space between an attribute's name and its `(`.
    AttributeSpace,
    /// `attribute-on-spread`: An attribute on a spread. The fields and tags a spread copies keep their own attributes.
    AttributeOnSpread,
    /// `unknown-module`: An import of a module that doesn't exist: an unknown standard module, a former standard module, or a name that is neither `std/…`, a package `@org/name` nor a file `./name`.
    UnknownModule,
    /// `unknown-import`: An import names a type the module doesn't have, or no type at all.
    UnknownImport,
    /// `duplicate-import`: The same type name is imported twice.
    DuplicateImport,
    /// `import-unavailable`: The schema imports a package or file, and the tool reading it has no way to find one (no module resolver): only standard modules can be imported there.
    ImportUnavailable,
    /// `import-not-found`: An imported package or file can't be found: it is not installed, not a direct dependency, or the path is wrong. Also a package whose manifest is broken or names another package.
    ImportNotFound,
    /// `import-version`: An import asks for a major version (`@org/name@2`) and another one is installed, or names something other than a major version: `@1.1`, `@1.1.0`, `@01`, `@x`.
    ImportVersion,
    /// `import-cycle`: Schema files import each other in a cycle.
    ImportCycle,
    /// `duplicate-package`: Two different files claim to be the same package: two copies of one package, or two packages with the same name.
    DuplicatePackage,
    /// `package-path`: A schema package refers to a file it may not: its `schema.haus` imports a file (`import ./x`) instead of a package, or its `package.haus` or `schema.haus` is a symbolic link to a file outside the package's directory; or a file outside any package imports a file in a package's directory (`import ./node_modules/x/y`). The file is not read.
    PackagePath,
    /// `too-many-files`: A schema imports more files, directly or not, than the tool allows.
    TooManyFiles,
    /// `type-mismatch`: A value of another kind than the type accepts: a string for an `Int`, an array for a record, a tag that isn't `True` or `False` for a `Bool`. Decoders never convert between kinds (§15).
    TypeMismatch,
    /// `not-an-integer`: A number with a fraction or an exponent where an integer type is expected. `1.0` and `1e3` are not whole numbers by spelling (§15).
    NotAnInteger,
    /// `out-of-range`: A number outside the type's range: an `Int8` above 127, a negative `UInt32`, a float too large for `Float32`. Never wrapped or clamped.
    OutOfRange,
    /// `missing-field`: A record lacks a field the type requires. Only fields with `?` may be missing; `None` is not missing.
    MissingField,
    /// `unknown-field`: A field a closed record doesn't list. Open records ignore such fields (see `unlisted-field`).
    UnknownField,
    /// `unknown-tag`: A tag a closed variant doesn't list. Open variants read it as an unknown value (see `unlisted-tag`).
    UnknownTag,
    /// `wrong-payload`: A listed tag with another payload than its case says: arguments for a tag without payload, the wrong number of arguments, a positional payload where a record is expected, such as `Circle(1.5)` for the case `Circle { r: Float64 }` (§15).
    WrongPayload,
    /// `invalid-time`: A std/time value whose text the std/time profile rejects: a day that doesn't exist, a missing offset, a lowercase `t` (spec/std/time.md).
    InvalidTime,
    /// `invalid-secret`: A value of a `Secret` type that its type doesn't accept. The error names the place and the type only, never the value or why it failed (§15).
    InvalidSecret,
    /// `cannot-encode`: Encoding: a value of the program's language that the type can't write, such as a JavaScript number for an `Int` that expects a bigint, or a string that is no valid `Date`.
    CannotEncode,
    /// `cyclic-value`: Encoding: a value contains itself, so it has no finite text.
    CyclicValue,
    /// `step-budget`: Decoding or encoding took more steps than the input justifies, a sign of a schema doing unbounded work. Bindings MAY bound the work per call (§9.8).
    StepBudget,
    /// `too-many-nodes`: A value built in code (not parsed) has more nodes than the call allows, or shares nodes so much that it would expand beyond the limits.
    TooManyNodes,
    /// `json-syntax`: Text that isn't JSON (RFC 8259): a missing comma or colon, an unquoted name, a trailing comma, a comment, text after the value. Also an empty line in JSON Lines.
    JsonSyntax,
    /// `unpaired-surrogate`: A JSON string with half of a UTF-16 surrogate pair, raw or as `\uD800`. I-JSON forbids them, and they are no Unicode characters (§16).
    UnpairedSurrogate,
    /// `lossless-form`: JSON that isn't one of the lossless forms (§16.2): a bare number, `true`, `null`, an object with other members, a `rec` that isn't an object, an `args` that isn't a non-empty array.
    LosslessForm,
    /// `lossless-number`: A lossless `num` that isn't a normalized number literal (§2): `"1E5"`, `"01"`, `"0xff"`, or not a string.
    LosslessNumber,
    /// `lossless-bytes`: A lossless `bytes` that isn't two lowercase hex digits per byte.
    LosslessBytes,
    /// `invalid-tag`: A tag name that isn't `\[A-Z\]\[A-Za-z0-9_\]*`: in a lossless `tag`, in a plain `_tag`, or in a value built in code.
    InvalidTag,
    /// `invalid-base64`: Plain JSON `Bytes` that aren't canonical base64 with padding (RFC 4648 §4): whitespace, the URL alphabet, missing padding, non-zero pad bits.
    InvalidBase64,
    /// `missing-member`: Plain JSON: an object lacks a member its form needs, such as `"_tag"` for a variant or `"value"` for a tag with one argument.
    MissingMember,
    /// `unexpected-member`: Plain JSON: an object has a member its form doesn't have, such as `"value"` next to a tag without payload (§16.3).
    UnexpectedMember,
    /// `no-json-form`: A value or type that has no JSON form: a string with an unpaired surrogate, a record payload with a field named `_tag` in plain JSON (§16.3), a type with no plain mapping.
    NoJsonForm,
    /// `unknown-attribute`: A warning: an attribute this version of haus doesn't define. It is accepted and has no meaning (§14).
    UnknownAttribute,
    /// `deprecated`: A hint: the schema or the data uses a type, field or tag marked `@deprecated` (§14).
    Deprecated,
    /// `unlisted-field`: A hint: a field an open record doesn't list. A reader ignores it, but it may be a typo.
    UnlistedField,
    /// `unlisted-tag`: A hint: a tag an open variant doesn't list. A reader keeps it as an unknown value, but it may be a typo.
    UnlistedTag,
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
    pub const ALL: [ErrorCode; 102] = [
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
        ErrorCode::ImportVersion,
        ErrorCode::ImportCycle,
        ErrorCode::DuplicatePackage,
        ErrorCode::PackagePath,
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
        ErrorCode::CannotEncode,
        ErrorCode::CyclicValue,
        ErrorCode::StepBudget,
        ErrorCode::TooManyNodes,
        ErrorCode::JsonSyntax,
        ErrorCode::UnpairedSurrogate,
        ErrorCode::LosslessForm,
        ErrorCode::LosslessNumber,
        ErrorCode::LosslessBytes,
        ErrorCode::InvalidTag,
        ErrorCode::InvalidBase64,
        ErrorCode::MissingMember,
        ErrorCode::UnexpectedMember,
        ErrorCode::NoJsonForm,
        ErrorCode::UnknownAttribute,
        ErrorCode::Deprecated,
        ErrorCode::UnlistedField,
        ErrorCode::UnlistedTag,
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
            ErrorCode::ImportVersion => "import-version",
            ErrorCode::ImportCycle => "import-cycle",
            ErrorCode::DuplicatePackage => "duplicate-package",
            ErrorCode::PackagePath => "package-path",
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
            ErrorCode::CannotEncode => "cannot-encode",
            ErrorCode::CyclicValue => "cyclic-value",
            ErrorCode::StepBudget => "step-budget",
            ErrorCode::TooManyNodes => "too-many-nodes",
            ErrorCode::JsonSyntax => "json-syntax",
            ErrorCode::UnpairedSurrogate => "unpaired-surrogate",
            ErrorCode::LosslessForm => "lossless-form",
            ErrorCode::LosslessNumber => "lossless-number",
            ErrorCode::LosslessBytes => "lossless-bytes",
            ErrorCode::InvalidTag => "invalid-tag",
            ErrorCode::InvalidBase64 => "invalid-base64",
            ErrorCode::MissingMember => "missing-member",
            ErrorCode::UnexpectedMember => "unexpected-member",
            ErrorCode::NoJsonForm => "no-json-form",
            ErrorCode::UnknownAttribute => "unknown-attribute",
            ErrorCode::Deprecated => "deprecated",
            ErrorCode::UnlistedField => "unlisted-field",
            ErrorCode::UnlistedTag => "unlisted-tag",
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
            ErrorCode::ImportVersion => ErrorCategory::Imports,
            ErrorCode::ImportCycle => ErrorCategory::Imports,
            ErrorCode::DuplicatePackage => ErrorCategory::Imports,
            ErrorCode::PackagePath => ErrorCategory::Imports,
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
            ErrorCode::CannotEncode => ErrorCategory::Decoding,
            ErrorCode::CyclicValue => ErrorCategory::Decoding,
            ErrorCode::StepBudget => ErrorCategory::Decoding,
            ErrorCode::TooManyNodes => ErrorCategory::Decoding,
            ErrorCode::JsonSyntax => ErrorCategory::Json,
            ErrorCode::UnpairedSurrogate => ErrorCategory::Json,
            ErrorCode::LosslessForm => ErrorCategory::Json,
            ErrorCode::LosslessNumber => ErrorCategory::Json,
            ErrorCode::LosslessBytes => ErrorCategory::Json,
            ErrorCode::InvalidTag => ErrorCategory::Json,
            ErrorCode::InvalidBase64 => ErrorCategory::Json,
            ErrorCode::MissingMember => ErrorCategory::Json,
            ErrorCode::UnexpectedMember => ErrorCategory::Json,
            ErrorCode::NoJsonForm => ErrorCategory::Json,
            ErrorCode::UnknownAttribute => ErrorCategory::Hints,
            ErrorCode::Deprecated => ErrorCategory::Hints,
            ErrorCode::UnlistedField => ErrorCategory::Hints,
            ErrorCode::UnlistedTag => ErrorCategory::Hints,
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
            ErrorCode::ImportNotFound => "Install the package (as a direct dependency), or fix the path.",
            ErrorCode::ImportVersion => "Install the major version the schema asks for, or update the import. An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range.",
            ErrorCode::ImportCycle => "Move the shared types to a file both import.",
            ErrorCode::DuplicatePackage => "Install one copy of the package (deduplicate your dependencies).",
            ErrorCode::PackagePath => "A package is its `package.haus` and one `schema.haus`, and imports other packages by name (`import @org/name`); import a package by name from your own files too.",
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
            ErrorCode::CannotEncode => "Pass a value of the host type the binding documents for the type.",
            ErrorCode::CyclicValue => "Break the cycle before encoding.",
            ErrorCode::StepBudget => "Simplify the schema, or raise the step limit if the work is expected.",
            ErrorCode::TooManyNodes => "Build a smaller value, or raise the limit.",
            ErrorCode::JsonSyntax => "Write valid JSON; the message says what was expected.",
            ErrorCode::UnpairedSurrogate => "Write both halves of the surrogate pair, or the character itself.",
            ErrorCode::LosslessForm => "Write one of the lossless forms of §16.2: a string, an array, or an object with `num`, `bytes`, `rec`, or `tag` (and `args`).",
            ErrorCode::LosslessNumber => "Write the number's normalized literal (§2) as a string.",
            ErrorCode::LosslessBytes => "Write the bytes as lowercase hex, two digits per byte.",
            ErrorCode::InvalidTag => "Start the tag with a capital letter and use only letters, digits and `_`.",
            ErrorCode::InvalidBase64 => "Write standard base64, with padding.",
            ErrorCode::MissingMember => "Add the member the message names.",
            ErrorCode::UnexpectedMember => "Remove the member.",
            ErrorCode::NoJsonForm => "Rename the field, or use the lossless mapping.",
            ErrorCode::UnknownAttribute => "Check the spelling; attributes of a later version are fine.",
            ErrorCode::Deprecated => "Use what the deprecation note says instead.",
            ErrorCode::UnlistedField => "Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers.",
            ErrorCode::UnlistedTag => "Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers.",
        }
    }
}
