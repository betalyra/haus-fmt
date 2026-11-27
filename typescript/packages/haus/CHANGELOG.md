# @haus-fmt/haus

## 0.2.0

### Minor Changes

- 816f39f: The stream option (spec §11): `format(values, { stream: true })` and `h.formatAll(schema, values, { stream: true })` write a comma after every top-level value, a single one too, in every layout, so that a log holding one value so far can be appended to. Without it nothing changes; `stringify` writes one value and ignores it.
  Comments are read left to right: a control or bidi character or a lone carriage return in a block comment that is never closed is reported at its place, before the missing `*/` (it was `unterminated-comment`), in data and schema files.
- 1034c68: Checking data with a schema: `checkText` checks a data file's text and gives each issue a `code` and a `path`. A `Stream` is checked item by item, so a syntax error comes after the errors of the items before it; each missing field is an error of its own; the check stops after 200 errors (hints don't count) and says so (`stopped`).
  A tag that breaks the tag rule is `invalid-tag`, also when it holds a lone surrogate (it was `cannot-encode`).
  Codecs apply to every named type: the prelude's and std/time's too (`prelude#Decimal`, `std/time#Instant`), wherever the type occurs, in packages' types too. A codec whose id no type has never runs: `compiled.warnings` lists `unused-codec` for it.
