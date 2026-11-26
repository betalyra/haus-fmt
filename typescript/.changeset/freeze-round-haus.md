---
"@haus-fmt/haus": minor
---

The stream option (spec §11): `format(values, { stream: true })` and `h.formatAll(schema, values, { stream: true })` write a comma after every top-level value, a single one too, in every layout, so that a log holding one value so far can be appended to. Without it nothing changes; `stringify` writes one value and ignores it.
Comments are read left to right: a control or bidi character or a lone carriage return in a block comment that is never closed is reported at its place, before the missing `*/` (it was `unterminated-comment`), in data and schema files.
