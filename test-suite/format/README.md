# Format suite

Expected output of the standard formatter (spec §11), in its three layouts:
pretty, compact and minimised. Every binding with a formatter must produce
these files byte for byte.

| Inputs | Expected output |
|---|---|
| `cases/NAME.haus`: written for this suite (comments, blank lines, block strings, spellings, streams, width, BOM, CRLF, …) | `cases/NAME.pretty`, `cases/NAME.compact`, `cases/NAME.minimised` |
| `examples/NAME.haus`: copies of the data files in [`examples`](../../examples) | `examples/NAME.pretty`, `examples/NAME.compact`, `examples/NAME.minimised` |
| `../valid/NAME.haus`: every file of the conformance suite | `valid/NAME.pretty`, `valid/NAME.compact`, `valid/NAME.minimised` |

For each input:

- Format it in the pretty layout, keeping comments: the result must equal
  `NAME.pretty`. Format it in the compact layout: the result must equal
  `NAME.compact`. Format it in the minimised layout: the result must equal
  `NAME.minimised`.
- Format each result again in the same layout: it must not change
  (idempotence), and it must parse to the same values as the input.
- Format the minimised result in the pretty layout: it must equal the pretty
  file without its comments and blank lines (spec §11).
- Remove the spaces and tabs at the end of every line of the pretty result,
  as an editor that trims trailing whitespace does: it must still parse to
  the same values. No line of the pretty result ends in a space or tab,
  except inside a comment.
- `NAME.options`, where present, is a haus record of options for every
  layout, `{ indent: 4, width: 40 }`. Without it, the defaults apply: indent
  2, width 80.

`options.cases.haus` checks the two options of the pretty layout themselves:
each case is `input`, `indent` and `width` where given (unset otherwise, so
the default applies), and `result`: `Ok(text)`, the pretty result, or
`Rejected` for options a formatter must refuse (a negative number, spec §11).
Rejecting is an API error, with no code of §17; a binding whose option types
can't hold a negative number rejects it by its types and passes the case.

Inputs are raw bytes (some have a BOM or CRLF line endings): read them as
UTF-8 without removing a byte order mark (the parser skips it). The expected
files are UTF-8 too.

The TypeScript formatter is the reference: its test
(`typescript/packages/haus/test/format-suite.test.ts`) writes the expected
files when run with `HAUS_UPDATE_FORMAT=1`. Review the diff against spec §11
before committing it. A new file in `valid/` needs its expected output written
this way.

## What the cases pin down

Besides the rules of spec §11, some cases test points that are easy to get
wrong:

- The width counts code points (`😀` is 1) and includes the comma after the
  entry; a single top-level item has no comma (`cases/width*`).
- A CR LF in a comment is written as LF (`cases/crlf*`, `valid/comments-tabs-crlf`).
- Comments inside the parentheses of `Tag({ … })` but outside the braces move
  inside the braces of `Tag { … }` (`cases/comments-payload-parens`).
- In a block string, the last space or tab of a line that ends in one is
  written as an escape (`\u{20}`, `\t`), also on a line of only blanks; earlier
  blanks stay raw (`cases/block-strings-trailing-blanks`, `valid/strings`).
- Raw U+2028 and U+2029 in strings, keys and block strings are written as
  `\u{2028}` and `\u{2029}` in every layout, also when a string keeps its
  source spelling; in a comment, pretty keeps them raw
  (`cases/line-separators`, `valid/line-separators`).
- Minimised keeps every literal as written: digit separators, hex case, a
  negative hex zero, and the blanks inside a byte string. It drops every
  comment, also those between top-level items (`cases/minimised-spellings`).
- Compact and minimised write a single top-level item without a comma, and
  every item of a stream with one (`cases/single-with-comma`,
  `cases/stream-no-trailing-comma`).
- A comment after an entry's comma doesn't count toward the width: an entry
  of exactly 80 columns with its comma stays inline (`cases/width-comment-excluded`).
- An item is multi-line by its value: a multi-line comment after a one-line
  item adds no blank line (`cases/stream-multiline-comment`); the comments
  after such a comment lead the next entry (`cases/comments-after-multiline`).
- Comments moved above an entry go after the blank line it had above it
  (`cases/comments-moved-blank-line`).
- An indent or width of 0 is taken literally, not as the default: indent 0
  indents nothing, and with width 0 every positional payload is written one
  argument per line (`cases/indent-zero`, `cases/width-zero`). Their options
  files name one option each; the other keeps its default.
