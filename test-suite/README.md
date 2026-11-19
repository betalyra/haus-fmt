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
Err { type: "I", input: 1.0, code: "not-an-integer", path: "$" },  // fails with this code, at this place
```

`type` names a definition without parameters. For `Ok`, decode `input` with
the type, encode the result with the same type, and compare its canonical form
(§12) with that of `output`, or of `input` when there is no `output`. For
`Err`, decoding must fail with the error code `code` (spec §17), at the place
`path` (spec §15, "General rules": `$.items[2].price`, `$.m["pt-BR"]`,
`$[1].of[0]`), compared as text. Error messages are not compared.

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
| hex digits in a hex literal (`_` not counted) | 829 |
| absolute exponent | 6144 |
| characters in a string | 16 Mi |

`valid/limits-boundary.haus` sits exactly at the number limits (its hex
literals have 829 hex digits, and canonical form and JSON write them in
decimal), and `invalid/*-too-*.haus` goes one past them.

## Stream suite

`stream/limits.cases.haus` checks stream readers (spec §6) against the value
limit (§7) and strict mode. Each case is a record: `text`, `maxValueLength`,
`strict` (optional, default `False`), and `result`: `Ok([values])`, compared
as values (§2), or `Err("code")`. A reader must give the same result for every
way of splitting `text` into chunks: run each case at least whole, one
character at a time, and split at every position. The value limit applies to
stream readers only; parsing the whole text doesn't apply it.

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

## Package suite

`packages/cases.haus` tests how schema imports find packages and files (spec
§13.3). Each `Case` is a file tree, the schema file to load, how packages are
found, and the result:

```haus
Case {
  name: "undeclared-in-package",
  files: [
    Npm("app", { dependencies: ["@acme/orders"] }),               // app/package.json
    File("app/app.schema.haus", "import @acme/orders@1 (Order)\ntype Root = { order: Order }"),
    Package("app/node_modules/@acme/orders", "@acme/orders", "1.0.0", "type Order = { id: Int }"),
    Link("app/node_modules/@acme/x", "../../../vendor/x"),       // a symbolic link
  ],
  root: "app/app.schema.haus",
  mode: Npm,
  expect: Err { code: "undeclared-package", mentions: ["@acme/orders"] },
},
```

An adapter writes the tree into an empty temporary directory, then loads
`root` as a schema with its binding's resolver:

- `File(path, text)` writes `text` to `path`.
- `Package(dir, name, version, schema)` writes `dir/package.haus` as
  `{ name: "NAME", version: "VERSION" }` and `dir/schema.haus` as `schema`.
- `Npm(dir, { name?, version?, dependencies?, peerDependencies?, devDependencies?, optionalDependencies? })`
  writes `dir/package.json`, each dependency list as an object from the names
  to `"*"`. Fields that are missing are left out.
- `Link(path, target)` makes `path` a symbolic link to `target`, relative to
  the link's directory (as `ln -s target path`).

Paths use `/` and are relative to the temporary directory. Parent directories
are created as needed.

`mode` says how packages are found:

- `Explicit { packages?, folders? }`: the packages are given explicitly, and
  nothing else is looked at (no `node_modules`). Each of `packages` is a
  package's directory; each of `folders` is a directory whose subdirectories
  with a `package.haus` are packages. Their manifests name them. Every
  binding runs these cases.
- `Npm` or `Npm { packages?, folders? }`: from `node_modules` by the npm
  rules of spec §13.3, together with the packages given explicitly, if any.
  Only bindings that read `node_modules` run these cases.

`expect` is the result:

- `Ok { packages }`: the schema loads, and `packages` lists every package it
  reaches, as `name@version` (the version of its `package.haus`), sorted.
- `Err { code, mentions?, hides? }`: loading fails with the error code `code`.
  The message must contain each string of `mentions` and none of `hides`.
  Paths in `mentions` use `/`; adapters compare them with every `\` in the
  message read as `/`.
  Places are not compared.

`should: True` marks a case for the version check, which implementations
SHOULD make (spec §13.3, "Package versions"). An implementation that doesn't
make it skips these cases and says so; one that makes it must pass them.

## Error codes

Every error has a code from the catalogue (spec §17, [`../spec/errors.md`](../spec/errors.md)).
Where a case is rejected, the suite gives the code it must be rejected with:
`invalid/NAME.error`, `schema/invalid/NAME.error`, and `code` in each `Err`
case. A file or case has one mistake, so the code doesn't depend on which
error a binding finds first. A binding that doesn't report codes yet can
ignore them; one that does must report exactly these.
