; haus data files. Capture names of nvim-treesitter, which Zed and
; `tree-sitter highlight` share. In Neovim a later pattern wins over an
; earlier one for the same node.

[
  (line_comment)
  (block_comment)
] @comment @spell

(number) @number

[
  (string)
  (block_string)
] @string

(escape_sequence) @string.escape

(bytes) @string.special

; Tags. True, False and None are ordinary tags whose meaning the prelude fixes.
(variant
  tag: (tag) @constructor)

((tag) @boolean
  (#any-of? @boolean "True" "False"))

((tag) @constant.builtin
  (#eq? @constant.builtin "None"))

; Record keys, bare or quoted.
(field
  key: (_) @property)

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
