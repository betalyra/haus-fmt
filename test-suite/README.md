# haus conformance suite

Language-independent tests that every haus parser must pass.

- `valid/NAME.haus` must parse. `valid/NAME.jsonl` is the expected result.
- `valid/NAME.canonical` is the canonical form (spec §12) of each of its
  top-level values, one per line. Bindings that provide `canonical` must
  produce it byte for byte.
- `valid/NAME.hash` is `hashAll` (spec §12) of the file's values: the SHA-256
  of their canonical forms joined by `,`, as 64 lowercase hex digits and a
  line break. A file with one value has the same hash as the value.
- `invalid/NAME.haus` must be rejected: a syntax error, or invalid UTF-8.
  `invalid/NAME.error` is the error code (spec §17) it must be rejected with:
  one line, such as `payload-newline`. Positions and messages are not compared.

Files are raw bytes. Some use CRLF line endings, a BOM or literal tab
characters, so keep them byte-exact. Don't let editors or git rewrite them.

## Schema suite

`schema/NAME.schema.haus` is a schema file, and `schema/NAME.cases.haus` holds
cases for it (spec §15), written in haus:

```haus
Ok { type: "F64", input: 0.10, output: 0.1 },   // decodes; encoding gives output
Ok { type: "I", input: 42 },                     // no output: encoding gives input back
Err { type: "I", input: 1.0, code: "not-an-integer" },  // decoding fails, with this code
```

`type` names a definition without parameters. For `Ok`, decode `input` with
the type, encode the result with the same type, and compare its canonical form
(§12) with that of `output`, or of `input` when there is no `output`. For
`Err`, decoding must fail with the error code `code` (spec §17). Error
messages and places are not compared.

`schema/invalid/NAME.schema.haus` must be rejected by schema checkers (spec §14),
with the error code in `schema/invalid/NAME.error`.
Bindings also check that attributes don't matter: each schema file, with every
attribute removed, must give the same result for every case.

## Expected output encoding

`NAME.jsonl` is self-describing JSON (spec §16.2) as JSON Lines: one line per
top-level value of the file, in order (an empty file gives an empty file), each
an envelope `{"_haus": 1, "_value": …}`. Each value in `_value` is encoded as:

| haus value             | JSON                                   |
|------------------------|----------------------------------------|
| string                 | JSON string                            |
| array                  | JSON array                             |
| record                 | `{"_rec": { "key": value, ... }}`      |
| number                 | `{"_num": "literal"}`                  |
| bytes                  | `{"_bytes": "hex"}`, lowercase, no spaces |
| variant without payload| `{"_tag": "Name"}`                     |
| variant with payload   | `{"_tag": "Name", "_args": [value, ...]}`|

Number literals are written as exact text, normalised (spec §2): digit
separators removed, the exponent written `e` and its value (`1E+05` → `1e5`),
hex/binary converted to decimal integers (`0xFF` → `255`). Otherwise kept as written (`19.90`
stays `19.90`, `-0` stays `-0`).

`Tag { ... }` and `Tag({ ... })` both encode as a variant with one record arg.

## Limits

Conformance is tested with the default limits from the spec:

| Limit | Default |
|---|---|
| nesting depth | 256 |
| characters in a number literal | 1000 |
| absolute exponent | 6144 |
| characters in a string | 16 Mi |

`valid/limits-boundary.haus` sits exactly at the number limits, and
`invalid/*-too-*.haus` goes one past them.

## JSON suite

`json/` tests the three JSON forms (spec §16). Each file holds cases written in
haus, with JSON text in strings:

- `schema-based.schema.haus` and `schema-based.cases.haus`: schema-based JSON, with a type.
  `Ok { type, input, json }`: writing the decoded `input` gives `json`, and
  reading `json` gives a value that encodes to `input` (or `output`).
  `Read { type, json, output }`: reading `json` gives `output`.
  `Err { type, json, code }`: reading fails, with the error code `code`.
- `self-describing.cases.haus`: self-describing JSON, without a type (`Ok { input, json }`, `Err { json, code }`).
  Every `valid/NAME.jsonl` is a case too, one envelope per value of the file.
- `import.cases.haus`: the JSON import, without a schema (`Read { json, output }`, `Err { json, code }`).

JSON is compared as data: member order and whitespace don't matter, and
numbers compare by their text.

## Error codes

Every error has a code from the catalogue (spec §17, [`../spec/errors.md`](../spec/errors.md)).
Where a case is rejected, the suite gives the code it must be rejected with:
`invalid/NAME.error`, `schema/invalid/NAME.error`, and `code` in each `Err`
case. A file or case has one mistake, so the code doesn't depend on which
error a binding finds first. A binding that doesn't report codes yet can
ignore them; one that does must report exactly these.
