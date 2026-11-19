[
  (record)
  (array)
  (arguments)
] @indent.begin

[
  "}"
  "]"
  ")"
] @indent.branch @indent.end

; Inside a block string the indentation is part of the text: keep the
; previous line's.
[
  (block_string)
  (block_comment)
] @indent.auto
