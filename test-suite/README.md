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
`valid/limits-separators.haus` has literals of exactly 1000 characters
counting the sign, the `0x` prefix, digit separators and the exponent, which
all count toward the number limit (spec §7); `valid/depth-limit.haus` has
values of exactly 256 levels counted as §7 does (`Tag { … }` is one level,
`Tag({ … })` two), `invalid/too-deep-by-one.haus` has 257 levels, and
`invalid/too-deep-paren-record.haus` 257 counted as §7 does. The `.jsonl` of a
value 256 levels deep has more than 256 JSON levels (up to four per level), so
a runner compares it without the JSON depth limit of §16.

## Stream suite

`stream/limits.cases.haus` checks stream readers (spec §6) against the value
limit (§7) and strict mode. Each case is a record: `text`, `maxValueLength`,
`strict` (optional, default `False`), and `result`: `Ok([values])`, compared
as values (§2), or `Err("code")`. A reader must give the same result for every
way of splitting `text` into chunks: run each case at least whole, one
character at a time, and split at every position. The value limit applies to
stream readers only; parsing the whole text doesn't apply it: a case with
`whole: Ok([values])` must also parse whole (as `parseAll`, default limits)
to these values. An `Err` case may also give `line` and `column` (both or
neither, 1-based, counted as in the positions suite below): the reader's error
must be there for every split. `value-too-long` is at the first character the
value limit counts, the one after the previous top-level comma (`1,⏎ 1234567`:
line 1, column 3, the line break), or the start of the stream after a byte
order mark (column 2). Runners that ignored unknown fields must now read these
two, or say they skip the places.

`stream/document.cases.haus` checks readers of a single document (spec §6,
as `parse`): `text`, and `result`: `Ok(value)` or `Err("code")`. One value,
with or without a comma after it, is a document; no value, or two or more,
is `not-one-value`.

`stream/typed.schema.haus` and `stream/typed.cases.haus` decode a text with
a type (spec §15, "Streams"). `Ok { type, text, output }`: a `Stream a` type
decodes each top-level value of `text` as an `a`, and encoding the results
gives the array `output`; a type that isn't a stream decodes the one value
of `text`, and encoding it gives `output`. For such a type, a `text` with no
value or with several is `not-one-value`, at `$`. Values are compared as values
(§2). `Err { type, text, code, path }`: decoding fails with the code `code`
at the place `path` (§15), which starts with the item's index in a stream
(`$[1].level`). Runners use their binding's stream decoding (not a loop of
their own), so that the index comes from the binding.

## Error positions

`positions/cases.haus` checks the line and column of errors (spec §8). Each
case: `text`, with one mistake at one character, and the `code`, `line` and
`column` it must be rejected with when the whole text is parsed (as
`parseAll`), or, when the case says `document: True`, when it is read as a
single document (as `parse`; `not-one-value` is at the end of the input).
The cases of the file's last section have two mistakes each, where the spec
fixes which is reported: a duplicate key at its name, before its colon and
value (§8), and a block string's closing quotes, then its lines in order,
each line's indent before its characters (§4). Lines and columns are 1-based; columns count code points (an
emoji is one column, and so is each combining mark), a byte order mark at the
start is column 1, and only a line feed (or CR LF) ends a line: U+2028 and
U+2029 don't. An error inside a block string is at the offending character,
not at the opening `"""` (spec §8).

## Equality and order

`equality/cases.haus` checks `equals` and `compare` (spec §2, §12): `a` and
`b`, two values written in the file itself, `equal` (`True` or `False`), and
`order`, the sign of `compare(a, b)`: `-1`, `0` or `1`. Runners check both
directions: `equals(b, a)` is `equal`, and `compare(b, a)` has the opposite
sign.

## Checker suite

`check/cases.haus` checks what tools that check schema files and data report
without failing (spec §14, §15, §16). Schemas are given as text in each
case, one file without imports.

- `Schema { schema, warnings }`: the schema loads, and its warnings are
  exactly `warnings`: `Warning(code, line, column)`, at what the warning is
  about (an unknown attribute's `@`, the use of a deprecated type, a case
  without a schema-based JSON form).
- `Data { schema, type, data, issues, first? }`: checking the text `data`
  against `type` (every value for a `Stream` type, item by item, else
  exactly one) gives exactly `issues`: `Hint(code, path)` for what is
  allowed but pointed out (`unlisted-field`, `unlisted-tag`, `deprecated`),
  `Error(code, path)` for what the type forbids, and `Syntax(code, line,
  column)` for a syntax or limit error of the text, at its line and column
  (spec §8). `path` is the place of spec §15. Without `first`, the check
  reports every error (spec §14, "Every error"); with `first: True`, it stops
  at the first (`haus check --first`). Runners check the text as a whole,
  through the binding's checker of text, not a parse of their own, so that
  a stream is read as the checker reads it.

Warnings and issues are compared as multisets of (code, place): the order
doesn't matter (spec §14 fixes none), and an entry listed twice must be
reported twice (two `missing-field` at one record). The place is the line and
column of a warning or a `Syntax` issue, and the path of the others; every
runner compares it.

A binding without a data checker runs the `Schema` cases only, and says so.

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
- `lines.cases.haus`: JSON Lines of self-describing JSON, read as a stream
  (`Ok { json, output }` with `output` an array of the values read,
  `Err { json, code, path? }`). The place of an error in a line starts with
  the line's index: `$[1]._value._num`.

JSON is compared as data: member order and whitespace don't matter, and
numbers compare by their text.

An `Err` case may also give `path`, the error's place in the JSON (spec §16.3
"Places"): member names and array indexes from the JSON text's root, written as
the paths of spec §15 (`$.shape.values[1]`, `$.counts["pt-BR"]`,
`$._value._args[1]._num`). Runners compare it, when it is there, with the
`path` of the error (spec §17). A case without `path` doesn't pin the place.

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
  ecosystem: "npm",
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
- `Fifo(path)` makes `path` a FIFO, a named pipe (`mkfifo path`). Nothing
  ever writes to it: a resolver that opens it blocking would hang, so
  adapters run these cases with a timeout (a few seconds) and fail on it.
  Only on Unix (the case has `os: "unix"`).
- `Large(path, bytes)` writes a file of `bytes` spaces (U+0020) to `path`.
- `Mode(path, mode)` sets the permissions of `path`, a directory written
  above, to `mode` in octal (`chmod 311 path`: the owner, who runs the
  tests, may enter and write it but not list it), after the whole tree is
  written. Adapters give back the owner's permissions (`chmod -R u+rwx`)
  before they remove the temporary directory. Only on Unix (`os: "unix"`),
  and not when the tests run as root (uid 0), which permissions don't stop:
  adapters skip these cases then, and say so.

Paths use `/` and are relative to the temporary directory. Parent directories
are created as needed.

`root` is the schema file the build starts from (the entry file). `rootDir`,
if there, is the build's `root` option (spec §13.3, "The root"), a directory
relative to the temporary directory; without it the build's root is the
directory of `root`'s real path, as by default. A binding without a `root`
option skips the cases with `rootDir` and says so.

`mode` says how packages are found:

- `Explicit { packages?, folders? }`: the packages are given explicitly, and
  nothing else is looked at (no `node_modules`). Each of `packages` is a
  package's directory; each of `folders` is a directory whose subdirectories
  with a `package.haus` are packages. Their manifests name them.
- `Npm` or `Npm { packages?, folders? }`: from `node_modules` by the npm
  rules of spec §13.3, together with the packages given explicitly, if any.

`ecosystem` says which implementations run a case (spec §13.3, "Installed
packages"):

- `"core"`: every implementation of every ecosystem, on every OS (`mode` is
  `Explicit`). A binding whose packages given explicitly can also be a file
  tree given in code (a Go `fs.FS`, a Swift `Bundle`, classpath resources, a
  Python `Traversable`) runs these cases that way too where it is cheap.
- `"npm"`: implementations of the npm ecosystem, which look in
  `node_modules` (`mode` is `Npm`): the TypeScript binding, under Node, Bun
  and Deno. Every other binding skips them, with a count; it MUST NOT read
  `node_modules`, which the core cases check.
- `"cargo"`: code generators that take packages from Cargo (`haus-build`).
  No case has it yet: Cargo passes packages through build-script metadata,
  which a file tree can't express, and `haus-build` runs the core cases.

There are 136 cases: 90 `"core"` and 46 `"npm"`; 6 of them have
`os: "unix"` (4 core, 2 npm), and 3 `unmodelled` (below).

The Lean reference (`haus-ref --packages`) runs every case of every
ecosystem: it has one resolver, with the npm lookup as an option.

`os: "unix"` marks a case that only Unix runs (a `Fifo` or `Mode` entry);
adapters on Windows skip it and say so. Cases that bite only on
case-insensitive file systems (macOS, Windows) or only on Windows (device
names such as `con`, a name ending in `.`) run, and must pass, everywhere.
`unmodelled: "why"` marks a case the Lean reference can't run (its file tree
has no permissions); it skips it and names it, and the bindings run it.

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
