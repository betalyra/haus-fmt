# Format suite

Expected output of the standard formatter (spec §11), in both layouts. Every
binding with a formatter must produce these files byte for byte.

| Inputs | Expected output |
|---|---|
| `cases/NAME.haus`: written for this suite (comments, blank lines, block strings, spellings, streams, width, BOM, CRLF, …) | `cases/NAME.pretty`, `cases/NAME.compact` |
| `examples/NAME.haus`: copies of the data files in [`examples`](../../examples) | `examples/NAME.pretty`, `examples/NAME.compact` |
| `../valid/NAME.haus`: every file of the conformance suite | `valid/NAME.pretty`, `valid/NAME.compact` |

For each input:

- Format it in the pretty layout, keeping comments: the result must equal
  `NAME.pretty`. Format it in the compact layout: the result must equal
  `NAME.compact`.
- Format each result again in the same layout: it must not change
  (idempotence), and it must parse to the same values as the input.
- `NAME.options`, where present, is a haus record of options for both
  layouts, `{ indent: 4, width: 40 }`. Without it, the defaults apply: indent
  2, width 80.

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
