; haus schema files. Capture names of nvim-treesitter, which Zed and
; `tree-sitter highlight` share. In Neovim a later pattern wins over an
; earlier one for the same node, so general patterns come first.

[
  (line_comment)
  (block_comment)
] @comment @spell

"type" @keyword.type

"import" @keyword.import

"closed" @keyword.modifier

(module) @module

; Values (attribute arguments) and quoted keys
(number) @number

[
  (string)
  (block_string)
] @string

(escape_sequence) @string.escape

(bytes) @string.special

; Types
(type_name) @type

((type_name) @type.builtin
  (#any-of? @type.builtin
    "Bool" "Maybe" "Result" "String" "Bytes" "Array" "Map" "Int" "Int8" "Int16" "Int32" "Int64"
    "UInt8" "UInt16" "UInt32" "UInt64" "Float32" "Float64" "Decimal" "Any" "Secret" "Stream"))

(type_definition
  name: (type_name) @type.definition)

(type_parameter) @variable.parameter

; Tags: the cases of variant types, and variants in attribute arguments
(case
  tag: (tag) @constructor)

(variant
  tag: (tag) @constructor)

((tag) @boolean
  (#any-of? @boolean "True" "False"))

((tag) @constant.builtin
  (#eq? @constant.builtin "None"))

; ...Name is one token (spec §14).
(spread) @type

; Fields: key: T, or key?: T for a field that may be missing
(field_declaration
  key: (_) @property)

(field_declaration
  "?" @operator)

(field
  key: (_) @property)

; Attributes: @deprecated("use email")
(attribute
  "@" @attribute
  name: (identifier) @attribute)

[
  "="
  "|"
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
