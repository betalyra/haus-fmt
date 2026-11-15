# Generated from spec/errors.haus by python/tests/test_error_codes.py. Don't edit:
# edit spec/errors.haus and run `uv run python tests/test_error_codes.py` in python/.
"""Every error code of spec §17, with its category and the fix reported as the hint."""

from __future__ import annotations

from collections.abc import Mapping
from types import MappingProxyType
from typing import Final, Literal, NamedTuple, TypeAlias

ErrorCategory: TypeAlias = Literal[
    "syntax", "limits", "streams", "schema-files", "imports", "decoding", "json", "hints"
]
"""The category of an error code."""

ErrorCode: TypeAlias = Literal[
    "invalid-utf8",
    "version-directive",
    "expected-value",
    "missing-comma",
    "payload-newline",
    "unexpected-closer",
    "unclosed-bracket",
    "null-literal",
    "boolean-literal",
    "bare-identifier",
    "expected-key",
    "uppercase-key",
    "block-string-key",
    "missing-colon",
    "duplicate-key",
    "empty-payload",
    "invalid-number",
    "unterminated-string",
    "string-line-break",
    "control-character",
    "bidi-control",
    "invalid-escape",
    "invalid-unicode-escape",
    "block-string-opening",
    "block-string-closing",
    "block-string-indent",
    "unterminated-block-string",
    "unterminated-bytes",
    "bytes-not-hex",
    "bytes-odd-digits",
    "lone-carriage-return",
    "unterminated-comment",
    "stray-slash",
    "nesting-too-deep",
    "number-too-long",
    "exponent-too-large",
    "string-too-long",
    "key-too-long",
    "tag-too-long",
    "value-too-long",
    "unsupported-depth",
    "not-one-value",
    "stream-truncated",
    "schema-syntax",
    "unknown-type",
    "wrong-arity",
    "duplicate-type",
    "redefine-prelude",
    "unknown-parameter",
    "invalid-parameter",
    "underscore-type",
    "duplicate-field",
    "duplicate-tag",
    "closed-empty-variant",
    "invalid-spread",
    "spread-cycle",
    "row-parameter",
    "misplaced-stream",
    "unguarded-recursion",
    "growing-recursion",
    "type-too-deep",
    "attribute-arguments",
    "attribute-twice",
    "attribute-space",
    "attribute-on-spread",
    "unknown-module",
    "unknown-import",
    "duplicate-import",
    "import-unavailable",
    "import-not-found",
    "import-version",
    "import-cycle",
    "duplicate-package",
    "too-many-files",
    "type-mismatch",
    "not-an-integer",
    "out-of-range",
    "missing-field",
    "unknown-field",
    "unknown-tag",
    "wrong-payload",
    "invalid-time",
    "invalid-secret",
    "cannot-encode",
    "cyclic-value",
    "step-budget",
    "too-many-nodes",
    "json-syntax",
    "unpaired-surrogate",
    "lossless-form",
    "lossless-number",
    "lossless-bytes",
    "invalid-tag",
    "invalid-base64",
    "missing-member",
    "unexpected-member",
    "no-json-form",
    "unknown-attribute",
    "deprecated",
    "unlisted-field",
    "unlisted-tag",
]
"""An error code (spec §17): stable, the same in every binding."""


class ErrorInfo(NamedTuple):
    """What the catalogue says about a code."""

    category: ErrorCategory
    hint: str
    """The usual fix, reported as the hint of an error that knows no better one."""


ERROR_CODES: Final[Mapping[ErrorCode, ErrorInfo]] = MappingProxyType(
    {
        "invalid-utf8": ErrorInfo("syntax", "Save the file as UTF-8."),
        "version-directive": ErrorInfo("syntax", "Read the file with a version of haus that supports it."),
        "expected-value": ErrorInfo("syntax", "Write a value here, or remove the extra comma or bracket."),
        "missing-comma": ErrorInfo("syntax", "Add a comma between the two values."),
        "payload-newline": ErrorInfo(
            "syntax", "Put the payload on the tag's line, or add a comma if they are two values."
        ),
        "unexpected-closer": ErrorInfo(
            "syntax",
            "Close each bracket with its own kind (`{` `}`, `[` `]`, `(` `)`) and remove extra closing brackets.",
        ),
        "unclosed-bracket": ErrorInfo("syntax", "Add the closing bracket."),
        "null-literal": ErrorInfo("syntax", "Write `None` (with a `Maybe` type), or leave the field out."),
        "boolean-literal": ErrorInfo("syntax", "Write `True` or `False`."),
        "bare-identifier": ErrorInfo(
            "syntax", 'Quote it as a string (`"foo"`), or start it with a capital letter to make it a tag (`Foo`).'
        ),
        "expected-key": ErrorInfo("syntax", 'Write a key: a lowercase identifier (`name`) or a string (`"1"`).'),
        "uppercase-key": ErrorInfo("syntax", 'Quote the key (`"Name"`) or start it with a lowercase letter.'),
        "block-string-key": ErrorInfo("syntax", 'Write the key as a basic string: `"k"`.'),
        "missing-colon": ErrorInfo("syntax", "Add `:` between the key and its value."),
        "duplicate-key": ErrorInfo("syntax", "Remove or rename one of the two."),
        "empty-payload": ErrorInfo("syntax", "Remove the parentheses: `Tag`."),
        "invalid-number": ErrorInfo("syntax", "Write a number like `7`, `-1.5`, `1e10`, `0xff` or `1_000`."),
        "unterminated-string": ErrorInfo(
            "syntax", 'Add the closing quote. A quote inside the string is written `\\"`.'
        ),
        "string-line-break": ErrorInfo("syntax", 'Write the line break as `\\n`, or use a `"""` block string.'),
        "control-character": ErrorInfo("syntax", "Write the character as an escape: `\\t`, `\\u{7}`."),
        "bidi-control": ErrorInfo("syntax", "Write it as an escape (`\\u{202E}`) inside a string, or remove it."),
        "invalid-escape": ErrorInfo(
            "syntax", "Use one of the escapes, e.g. `\\u{41}`, or write `\\\\` for a backslash."
        ),
        "invalid-unicode-escape": ErrorInfo(
            "syntax", "Write `\\u{41}`, with braces, for a character from U+0000 to U+10FFFF other than a surrogate."
        ),
        "block-string-opening": ErrorInfo("syntax", 'Start the content on the line after `"""`.'),
        "block-string-closing": ErrorInfo(
            "syntax", 'Put the closing `"""` on its own line; its indentation is removed from every line.'
        ),
        "block-string-indent": ErrorInfo("syntax", 'Indent every line at least as far as the closing `"""`.'),
        "unterminated-block-string": ErrorInfo("syntax", 'Add the closing `"""` on its own line.'),
        "unterminated-bytes": ErrorInfo("syntax", "Add the closing quote."),
        "bytes-not-hex": ErrorInfo("syntax", 'Write two hex digits per byte (`x"0b34ff"`), on one line.'),
        "bytes-odd-digits": ErrorInfo("syntax", 'Write each byte as two hex digits: `x"0abc"`.'),
        "lone-carriage-return": ErrorInfo("syntax", "Save the file with LF or CRLF line endings."),
        "unterminated-comment": ErrorInfo("syntax", "Add `*/`, one for each `/*`."),
        "stray-slash": ErrorInfo("syntax", "Write `//` or `/*` for a comment, or remove the `/`."),
        "nesting-too-deep": ErrorInfo("limits", "Flatten the data, or raise `maxDepth` if you trust the input."),
        "number-too-long": ErrorInfo(
            "limits", "Write a shorter number (a `String` or `Bytes` for very long data), or raise `maxNumberLength`."
        ),
        "exponent-too-large": ErrorInfo("limits", "Write a number with a smaller exponent, or raise `maxExponent`."),
        "string-too-long": ErrorInfo("limits", "Split the string, or raise `maxStringLength`."),
        "key-too-long": ErrorInfo("limits", "Use a shorter key, or raise `maxStringLength`."),
        "tag-too-long": ErrorInfo("limits", "Use a shorter tag, or raise `maxStringLength`."),
        "value-too-long": ErrorInfo("limits", "Send smaller values, or raise `maxValueLength`."),
        "unsupported-depth": ErrorInfo("limits", "Configure a depth limit within the binding's documented maximum."),
        "not-one-value": ErrorInfo("streams", "Give exactly one value, or read the input as a stream."),
        "stream-truncated": ErrorInfo(
            "streams", "End every value with a comma, or check that the stream wasn't cut off."
        ),
        "schema-syntax": ErrorInfo(
            "schema-files", "Write it as the grammar says (grammar.ebnf); the message names what was expected."
        ),
        "unknown-type": ErrorInfo(
            "schema-files", "Define the type, fix its spelling, or import it (`import std/time (Date)`)."
        ),
        "wrong-arity": ErrorInfo(
            "schema-files",
            "Give the type exactly the arguments it takes, e.g. `Secret String`, `Map Int`, `Result String Int`.",
        ),
        "duplicate-type": ErrorInfo("schema-files", "Rename one of them."),
        "redefine-prelude": ErrorInfo("schema-files", "Give your type another name."),
        "unknown-parameter": ErrorInfo(
            "schema-files", "Declare the parameter (`type Box a = { item: a }`) or use a type name."
        ),
        "invalid-parameter": ErrorInfo("schema-files", "Give each parameter its own lowercase name."),
        "underscore-type": ErrorInfo(
            "schema-files", "Write `< >` for a variant with any tags, `Any` for any value, or use a type parameter."
        ),
        "duplicate-field": ErrorInfo("schema-files", "Remove or rename one of them."),
        "duplicate-tag": ErrorInfo("schema-files", "Remove or rename one of them."),
        "closed-empty-variant": ErrorInfo("schema-files", "List its tags, or write `< >` for a variant with any tags."),
        "invalid-spread": ErrorInfo(
            "schema-files",
            "Spread a named variant into a variant, or a named record into a record, without parameters.",
        ),
        "spread-cycle": ErrorInfo(
            "schema-files", "Break the cycle: let one of the types list its tags or fields itself."
        ),
        "row-parameter": ErrorInfo(
            "schema-files", "Spread a named type instead, or nest the open part as a field with a type parameter."
        ),
        "misplaced-stream": ErrorInfo(
            "schema-files", "Use `Array` inside types; `Stream` only as `type Events = Stream Event`."
        ),
        "unguarded-recursion": ErrorInfo(
            "schema-files",
            "Put the recursion inside a record, array or variant: `type Tree = { children: Array Tree }`.",
        ),
        "growing-recursion": ErrorInfo("schema-files", "Refer to the type with its own parameters (`Nest a`)."),
        "type-too-deep": ErrorInfo("schema-files", "Name the inner types with definitions of their own."),
        "attribute-arguments": ErrorInfo(
            "schema-files", 'Write `@deprecated` or `@deprecated("why, and what to use instead")`.'
        ),
        "attribute-twice": ErrorInfo("schema-files", "Keep one of them."),
        "attribute-space": ErrorInfo("schema-files", 'Write the parenthesis right after the name: `@deprecated("x")`.'),
        "attribute-on-spread": ErrorInfo("schema-files", "Put the attribute on the fields or tags in the spread type."),
        "unknown-module": ErrorInfo(
            "imports", "Import an existing module; `std/money` is now the package `@haus-fmt/money`."
        ),
        "unknown-import": ErrorInfo("imports", "Import a type the module defines; the message lists them."),
        "duplicate-import": ErrorInfo("imports", "Import each name once."),
        "import-unavailable": ErrorInfo(
            "imports",
            "Read the schema with a resolver (e.g. from a file, with `@haus-fmt/haus/node`), or inline the types.",
        ),
        "import-not-found": ErrorInfo("imports", "Install the package (as a direct dependency), or fix the path."),
        "import-version": ErrorInfo("imports", "Install the major version the schema asks for, or update the import."),
        "import-cycle": ErrorInfo("imports", "Move the shared types to a file both import."),
        "duplicate-package": ErrorInfo("imports", "Install one copy of the package (deduplicate your dependencies)."),
        "too-many-files": ErrorInfo("imports", "Import fewer files."),
        "type-mismatch": ErrorInfo("decoding", "Write a value of the expected type; the message says which."),
        "not-an-integer": ErrorInfo("decoding", "Write the integer without a fraction or exponent: `1`, `1000`."),
        "out-of-range": ErrorInfo(
            "decoding", "Write a value within the range, or use a larger type (`Int`, `Float64`, `Decimal`)."
        ),
        "missing-field": ErrorInfo("decoding", "Add the field, or mark it optional in the schema (`name?: String`)."),
        "unknown-field": ErrorInfo("decoding", "Remove the field, fix its spelling, or add it to the schema."),
        "unknown-tag": ErrorInfo(
            "decoding", "Use one of the variant's tags, fix the spelling, or add the tag to the schema."
        ),
        "wrong-payload": ErrorInfo("decoding", "Write the payload the schema gives the tag: `Some(1)`."),
        "invalid-time": ErrorInfo(
            "decoding",
            'Write the date or time as the profile says: `Date("2026-02-28")`, `Instant("2026-11-08T09:12:00Z")`.',
        ),
        "invalid-secret": ErrorInfo(
            "decoding", "Write a value of the secret's type; the value isn't shown, so check it where it comes from."
        ),
        "cannot-encode": ErrorInfo("decoding", "Pass a value of the host type the binding documents for the type."),
        "cyclic-value": ErrorInfo("decoding", "Break the cycle before encoding."),
        "step-budget": ErrorInfo("decoding", "Simplify the schema, or raise the step limit if the work is expected."),
        "too-many-nodes": ErrorInfo("decoding", "Build a smaller value, or raise the limit."),
        "json-syntax": ErrorInfo("json", "Write valid JSON; the message says what was expected."),
        "unpaired-surrogate": ErrorInfo("json", "Write the whole pair (`\\uD83D\\uDE00`), or the character itself."),
        "lossless-form": ErrorInfo(
            "json", 'Write the lossless form: `{"num": "1"}`, `{"tag": "True"}`, `{"rec": {…}}`.'
        ),
        "lossless-number": ErrorInfo("json", 'Write the normalized literal: `{"num": "1e5"}`.'),
        "lossless-bytes": ErrorInfo("json", 'Write lowercase hex, two digits per byte: `{"bytes": "ff"}`.'),
        "invalid-tag": ErrorInfo("json", "Start the tag with a capital letter and use only letters, digits and `_`."),
        "invalid-base64": ErrorInfo("json", 'Write standard base64 with padding: `"CzQ="`.'),
        "missing-member": ErrorInfo("json", 'Add the member: `{"_tag": "Ok", "value": 1}`.'),
        "unexpected-member": ErrorInfo("json", "Remove the member."),
        "no-json-form": ErrorInfo("json", "Rename the field, or use the lossless mapping."),
        "unknown-attribute": ErrorInfo("hints", "Check the spelling; attributes of a later version are fine."),
        "deprecated": ErrorInfo("hints", "Use what the deprecation note says instead."),
        "unlisted-field": ErrorInfo(
            "hints", "Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers."
        ),
        "unlisted-tag": ErrorInfo(
            "hints", "Fix the spelling, add the tag to the schema, or leave it if it is meant for newer readers."
        ),
    }
)
"""Every error code (spec §17), in the order of the catalogue."""
