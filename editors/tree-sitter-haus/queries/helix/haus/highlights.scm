; haus data files, with Helix's capture names. In Helix the first pattern
; that matches a node wins, so specific patterns come first.

[
  (line_comment)
  (block_comment)
] @comment

((tag) @constant.builtin.boolean
  (#any-of? @constant.builtin.boolean "True" "False"))

((tag) @constant.builtin
  (#eq? @constant.builtin "None"))

(variant
  tag: (tag) @constructor)

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
  "{"
  "}"
  "["
  "]"
  "("
  ")"
] @punctuation.bracket

[
  ","
  ":"
] @punctuation.delimiter
