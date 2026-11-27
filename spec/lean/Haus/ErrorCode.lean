/-!
# Error codes

The codes of the catalogue (spec §17, `spec/errors.haus`) that the reference
reports: the parser's (syntax and limits), the schema decoder's, the JSON
readers' and writers' (§16), package resolution's (§13.3) and the
schema-file checker's (§14). A code
names the mistake, the same in every binding; `Code.name` is its text. The
TypeScript tests check that every name here is in the catalogue.

Codes only label errors: the proofs are about which inputs are accepted and
what they mean, and say nothing about which error a rejected input gets.
-/

namespace Haus

inductive Code
  -- syntax (§1–§5)
  | invalidUtf8 | versionDirective | expectedValue | missingComma | payloadNewline
  | unexpectedCloser | unclosedBracket | nullLiteral | booleanLiteral | bareIdentifier
  | expectedKey | uppercaseKey | blockStringKey | missingColon | duplicateKey | emptyPayload
  | invalidNumber | unterminatedString | stringLineBreak | controlCharacter | bidiControl
  | invalidEscape | invalidUnicodeEscape | blockStringOpening | blockStringClosing
  | blockStringIndent | unterminatedBlockString | unterminatedBytes | bytesNotHex
  | bytesOddDigits | loneCarriageReturn | unterminatedComment | straySlash
  -- limits (§7)
  | nestingTooDeep | numberTooLong | exponentTooLarge | stringTooLong | keyTooLong | tagTooLong
  | valueTooLong
  -- streams (§6)
  | streamTruncated | notOneValue
  -- decoding with a schema (§15)
  | typeMismatch | notAnInteger | outOfRange | missingField | unknownField | unknownTag
  | wrongPayload | invalidTime | invalidSecret | codecRejected | unguardedRecursion | unknownType
  -- building values (§7, §11, §15): a value built in code over the node limit; a secret
  -- encoded without `revealSecrets`
  | tooManyNodes | cannotEncode
  -- JSON (§16)
  | jsonSyntax | unpairedSurrogate | hausJsonForm | hausJsonVersion | hausJsonNumber | hausJsonBytes | invalidTag
  | invalidBase64 | missingMember | unexpectedMember | noJsonForm
  -- schema files and imports (§13.3, §14), as package resolution reports them
  | schemaSyntax | unknownModule | unknownImport | duplicateImport | duplicateType
  | importNotFound | importVersion | importCycle | duplicatePackage | undeclaredPackage
  | packageManifest | packageVersion | packagePath | fileTooLarge | tooManyFiles
  | importOutsideRoot
  -- the package layer's rules (packages.md §7): a package's rule the program doesn't implement
  | missingCodec
  -- the static rules of schema files (§14), as the schema-file checker reports them
  | wrongArity | redefinePrelude | unknownParameter | invalidParameter | underscoreType
  | duplicateField | duplicateTag | closedEmptyVariant | invalidSpread | spreadCycle
  | rowParameter | misplacedStream | growingRecursion | typeTooDeep | attributeArguments
  | attributeTwice | attributeSpace | attributeOnSpread | importUnavailable
  /-- A recursive function ran out of fuel. Never reported: the completeness
  proof shows the fuel always suffices. Not a code of the catalogue. -/
  | outOfFuel
  deriving Repr, DecidableEq, Inhabited

/-- The code as the catalogue writes it. -/
def Code.name : Code → String
  | .invalidUtf8 => "invalid-utf8"
  | .versionDirective => "version-directive"
  | .expectedValue => "expected-value"
  | .missingComma => "missing-comma"
  | .payloadNewline => "payload-newline"
  | .unexpectedCloser => "unexpected-closer"
  | .unclosedBracket => "unclosed-bracket"
  | .nullLiteral => "null-literal"
  | .booleanLiteral => "boolean-literal"
  | .bareIdentifier => "bare-identifier"
  | .expectedKey => "expected-key"
  | .uppercaseKey => "uppercase-key"
  | .blockStringKey => "block-string-key"
  | .missingColon => "missing-colon"
  | .duplicateKey => "duplicate-key"
  | .emptyPayload => "empty-payload"
  | .invalidNumber => "invalid-number"
  | .unterminatedString => "unterminated-string"
  | .stringLineBreak => "string-line-break"
  | .controlCharacter => "control-character"
  | .bidiControl => "bidi-control"
  | .invalidEscape => "invalid-escape"
  | .invalidUnicodeEscape => "invalid-unicode-escape"
  | .blockStringOpening => "block-string-opening"
  | .blockStringClosing => "block-string-closing"
  | .blockStringIndent => "block-string-indent"
  | .unterminatedBlockString => "unterminated-block-string"
  | .unterminatedBytes => "unterminated-bytes"
  | .bytesNotHex => "bytes-not-hex"
  | .bytesOddDigits => "bytes-odd-digits"
  | .loneCarriageReturn => "lone-carriage-return"
  | .unterminatedComment => "unterminated-comment"
  | .straySlash => "stray-slash"
  | .nestingTooDeep => "nesting-too-deep"
  | .numberTooLong => "number-too-long"
  | .exponentTooLarge => "exponent-too-large"
  | .stringTooLong => "string-too-long"
  | .keyTooLong => "key-too-long"
  | .tagTooLong => "tag-too-long"
  | .valueTooLong => "value-too-long"
  | .streamTruncated => "stream-truncated"
  | .notOneValue => "not-one-value"
  | .typeMismatch => "type-mismatch"
  | .notAnInteger => "not-an-integer"
  | .outOfRange => "out-of-range"
  | .missingField => "missing-field"
  | .unknownField => "unknown-field"
  | .unknownTag => "unknown-tag"
  | .wrongPayload => "wrong-payload"
  | .invalidTime => "invalid-time"
  | .invalidSecret => "invalid-secret"
  | .codecRejected => "codec-rejected"
  | .unguardedRecursion => "unguarded-recursion"
  | .unknownType => "unknown-type"
  | .tooManyNodes => "too-many-nodes"
  | .cannotEncode => "cannot-encode"
  | .jsonSyntax => "json-syntax"
  | .unpairedSurrogate => "unpaired-surrogate"
  | .hausJsonForm => "haus-json-form"
  | .hausJsonVersion => "haus-json-version"
  | .hausJsonNumber => "haus-json-number"
  | .hausJsonBytes => "haus-json-bytes"
  | .invalidTag => "invalid-tag"
  | .invalidBase64 => "invalid-base64"
  | .missingMember => "missing-member"
  | .unexpectedMember => "unexpected-member"
  | .noJsonForm => "no-json-form"
  | .schemaSyntax => "schema-syntax"
  | .unknownModule => "unknown-module"
  | .unknownImport => "unknown-import"
  | .duplicateImport => "duplicate-import"
  | .duplicateType => "duplicate-type"
  | .importNotFound => "import-not-found"
  | .importVersion => "import-version"
  | .importCycle => "import-cycle"
  | .duplicatePackage => "duplicate-package"
  | .undeclaredPackage => "undeclared-package"
  | .packageManifest => "package-manifest"
  | .packageVersion => "package-version"
  | .packagePath => "package-path"
  | .fileTooLarge => "file-too-large"
  | .tooManyFiles => "too-many-files"
  | .importOutsideRoot => "import-outside-root"
  | .missingCodec => "missing-codec"
  | .wrongArity => "wrong-arity"
  | .redefinePrelude => "redefine-prelude"
  | .unknownParameter => "unknown-parameter"
  | .invalidParameter => "invalid-parameter"
  | .underscoreType => "underscore-type"
  | .duplicateField => "duplicate-field"
  | .duplicateTag => "duplicate-tag"
  | .closedEmptyVariant => "closed-empty-variant"
  | .invalidSpread => "invalid-spread"
  | .spreadCycle => "spread-cycle"
  | .rowParameter => "row-parameter"
  | .misplacedStream => "misplaced-stream"
  | .growingRecursion => "growing-recursion"
  | .typeTooDeep => "type-too-deep"
  | .attributeArguments => "attribute-arguments"
  | .attributeTwice => "attribute-twice"
  | .attributeSpace => "attribute-space"
  | .attributeOnSpread => "attribute-on-spread"
  | .importUnavailable => "import-unavailable"
  | .outOfFuel => "(out of fuel)"

instance : ToString Code := ⟨Code.name⟩

/-- Every code of the catalogue the reference reports (`outOfFuel` is not one). -/
def Code.all : List Code := [
  .invalidUtf8, .versionDirective, .expectedValue, .missingComma, .payloadNewline,
  .unexpectedCloser, .unclosedBracket, .nullLiteral, .booleanLiteral, .bareIdentifier,
  .expectedKey, .uppercaseKey, .blockStringKey, .missingColon, .duplicateKey, .emptyPayload,
  .invalidNumber, .unterminatedString, .stringLineBreak, .controlCharacter, .bidiControl,
  .invalidEscape, .invalidUnicodeEscape, .blockStringOpening, .blockStringClosing,
  .blockStringIndent, .unterminatedBlockString, .unterminatedBytes, .bytesNotHex, .bytesOddDigits,
  .loneCarriageReturn, .unterminatedComment, .straySlash, .nestingTooDeep, .numberTooLong,
  .exponentTooLarge, .stringTooLong, .keyTooLong, .tagTooLong, .valueTooLong, .streamTruncated, .notOneValue,
  .typeMismatch, .notAnInteger, .outOfRange, .missingField, .unknownField, .unknownTag,
  .wrongPayload, .invalidTime, .invalidSecret, .codecRejected, .unguardedRecursion, .unknownType, .tooManyNodes, .cannotEncode, .jsonSyntax,
  .unpairedSurrogate, .hausJsonForm, .hausJsonVersion, .hausJsonNumber, .hausJsonBytes,
  .invalidTag, .invalidBase64, .missingMember, .unexpectedMember, .noJsonForm, .schemaSyntax,
  .unknownModule, .unknownImport, .duplicateImport, .duplicateType, .importNotFound,
  .importVersion, .importCycle, .duplicatePackage, .undeclaredPackage, .packageManifest,
  .packageVersion, .packagePath, .fileTooLarge, .tooManyFiles, .importOutsideRoot, .missingCodec, .wrongArity, .redefinePrelude,
  .unknownParameter, .invalidParameter, .underscoreType, .duplicateField, .duplicateTag,
  .closedEmptyVariant, .invalidSpread, .spreadCycle, .rowParameter, .misplacedStream,
  .growingRecursion, .typeTooDeep, .attributeArguments, .attributeTwice, .attributeSpace,
  .attributeOnSpread, .importUnavailable]

theorem Code.mem_all (c : Code) (h : c ≠ .outOfFuel) : c ∈ Code.all := by
  cases c <;> simp_all [Code.all]

end Haus
