; haus schema files, with Helix's capture names. In Helix the first pattern
; that matches a node wins, so specific patterns come first.

[
  (line_comment)
  (block_comment)
] @comment

"type" @keyword.storage.type

"import" @keyword.control.import

"closed" @keyword.storage.modifier

(module) @namespace

(attribute
  "@" @attribute
  name: (identifier) @attribute)

((type_name) @type.builtin
  (#any-of? @type.builtin
    "Bool" "Maybe" "Result" "String" "Bytes" "Array" "Map" "Int" "Int8" "Int16" "Int32" "Int64"
    "UInt8" "UInt16" "UInt32" "UInt64" "Float32" "Float64" "Decimal" "Any" "Secret" "Stream"))

(type_name) @type

(type_parameter) @type.parameter

((tag) @constant.builtin.boolean
  (#any-of? @constant.builtin.boolean "True" "False"))

((tag) @constant.builtin
  (#eq? @constant.builtin "None"))

(case
  tag: (tag) @constructor)

(variant
  tag: (tag) @constructor)

(field_declaration
  key: (_) @variable.other.member)

(field
  key: (_) @variable.other.member)

(escape_sequence) @constant.character.escape

[
  (string)
  (block_string)
] @string

(bytes) @string.special

(number) @constant.numeric

[
  "="
  "|"
  "?"
  "..."
] @operator

[
  "{"
  "}"
  "["
  "]"
  "("
  ")"
  "<"
  ">"
] @punctuation.bracket

[
  ","
  ":"
] @punctuation.delimiter
