# haus-fmt-cli

`haus`, the command line for the [haus](https://haus-fmt.org) data format: check
data files against their schemas, format them, and print canonical forms and
hashes. One static binary, no runtime, no network: files never leave the machine.

Built for people and for agents: no prompts, deterministic output, `-` reads
standard input, stable exit codes, `--json` for programs, and every error
comes with a stable code, a fix hint and a link to its documentation.

## Install

```sh
brew install betalyra/tap/haus     # macOS and Linux
cargo install haus-fmt-cli         # anywhere with Rust
```

Prebuilt binaries for macOS, Linux and Windows, with shell and PowerShell
installers, are on each [release](https://github.com/betalyra/haus-fmt/releases?q=haus-fmt-cli).
`haus --version` prints the version and the spec version it implements:
`haus 0.2.0 (spec draft 0.1)`.

## Commands

| Command | What it does |
|---|---|
| `haus check PATH…` | syntax errors; then the schema's errors and hints, for data files; errors and warnings, for schema files |
| `haus fmt PATH…` | rewrites data files in a standard layout (spec §11): pretty, compact or minimised; `--check` only lists them |
| `haus canonical [FILE]` | the canonical form (spec §12) of each value, one per line |
| `haus hash [FILE]` | `hashAll` of the file's values (spec §12); `--each` hashes each value |
| `haus completions SHELL` | a completion script for bash, zsh, fish, elvish or PowerShell |

A `PATH` is a file, a directory or `-` (standard input). `check` and `fmt`
need at least one: `haus check .` checks the current directory, `haus check`
alone is a usage error, so that a forgotten argument never checks or rewrites
more than meant. A directory is searched for `*.haus` files, in path order,
skipping what `.gitignore`, `.ignore` and hidden names exclude (in a Git
repository or not). A file named explicitly is always used, whatever its name.

### `haus check`

```sh
haus check order.haus              # one file
haus check .                       # every .haus file below the current directory
haus check --json data/ > report.json
cat order.haus | haus check -      # standard input, a data file
haus check --first order.haus      # stop at the first error
```

A **data file** is first parsed. If it is valid and has a schema, it is
checked against it: every error, and hints for fields and tags an open type
doesn't list and for deprecated ones the data uses. Hints never fail a check.
The errors are those of spec §14, "Every error": each failing place once,
nothing below a value that failed at its own level (a string where a record
is expected is one error, its contents aren't looked at), and an error inside
a `Secret` once, at the secret. A file with a syntax error has that one
error. The check stops after 200 problems per file (errors and hints) and
then says so (`note: order.haus: stopped after 200 problems; there may be
more`, and `"stopped": true` with `--json`). `--first` stops at the first
error of each file instead, keeping the hints found before it; on standard
input, at the first error of the stream. The schema is, in this order:

1. the one given with `--schema FILE[#Type]` (type default `Root`), for every data file checked;
2. `x.schema.haus` next to `x.haus`, type `Root`;
3. none: syntax only. `--no-schema` always checks syntax only.

A data file never names its own schema (spec §14): the reader decides, so a
file can't make `haus check` read another file. Comments in it mean nothing.

Imports in schemas resolve as in the other bindings (spec §13.3): `std/time`,
files next to the schema (`import ./common (Address)`), and schema packages.
A relative import stays inside the build's root, the real directory of the
schema file loaded: `..` names that go above it are `import-outside-root`,
before anything is looked at. A relative import follows no symbolic link: a
link anywhere on its path is `import-not-found` (the message doesn't say
where it points), and nothing behind it is read. Schema packages
are given explicitly; this tool never looks in `node_modules` (only
JavaScript runtimes, the npm ecosystem, do), nor anywhere else: not
`NODE_PATH`, not npm's global folder. Packages given count as declared:

```sh
haus check --package vendor/money order.haus             # a package's directory
haus check --package @acme/money=vendor/money order.haus # the same, its manifest must say @acme/money
haus check --packages schemas/ order.haus                # every subdirectory with a package.haus
```

Both options can be repeated. Their manifests name the packages, not the
directory names. A package given that can't be used (a directory without `package.haus`, an
invalid manifest, two packages with one name, a folder that doesn't exist or
has more than 4096 entries) stops the check before anything is checked, with
exit code 2. A subdirectory of a folder whose manifest is invalid is left
out; an import that isn't found names it.

The checks of §13.3 apply wherever a package is found: its manifest is valid
(`package-manifest`) and has the imported name (`import-not-found`) and
major version (`import-version`); the `version` of a `package.json` next to
it, if one can be read, is the manifest's (`package-version`); one schema
reaches one package of each name (`duplicate-package`, unless the copies are
byte for byte the same and their imports reach the same packages); a
package's `package.haus` and `schema.haus` are regular files, not links
(`package-path`), spelled exactly so; a relative import spells each name as
its directory lists it (a directory that can't be listed lists nothing) and
reaches a regular `.schema.haus` file (`import-not-found`), opened without
following a link and without blocking. A schema file and a `package.json`
are at most 1 MiB (`file-too-large`), and a schema reaches at most 256 schema
files (`too-many-files`).

A **schema file** (`*.schema.haus`) is loaded with its imports and checked
(spec §14): its errors, and its warnings (attributes this version doesn't
define, uses of deprecated types, record cases with a field named `_tag` or
`_args`, which have no schema-based JSON form), which don't fail the check.
An import of an official package with profiles (`@haus-fmt/money`,
`@haus-fmt/geo`, `@haus-fmt/uuid`) gets a hint (`missing-codec`): `haus check` has no codecs,
so it checks the package's types for their shape only, not its profiles'
rules (spec §13.4).

```text
error[type-mismatch]: expected Int, found the string "7"
 --> adjacent/order-bad.haus:3:7
  |
3 |   id: "7",
  |       ^^^
  |
  = at: $.id
  = hint: Write a value of the expected type; the message says which.
  = docs: https://haus-fmt.org/docs/errors#type-mismatch

hint[unlisted-field]: colour is not in the schema; a reader ignores it.
 --> adjacent/order-bad.haus:5:28
  |
5 |     { sku: "A-1", qty: -2, colour: "red" },
  |                            ^^^^^^
  |
  = at: $.items[0].colour
  = hint: Fix the spelling, add the field to the schema, or leave it if it is meant for newer readers.
  = docs: https://haus-fmt.org/docs/errors#unlisted-field

Checked 1 file: 1 error, 1 hint.
```

Lines and columns are 1-based, columns in Unicode code points (spec §8).
Everything goes to standard output, the summary line last.

Standard input (`-`) is checked as a stream, value by value: each
diagnostic is printed as soon as its value is complete, with its line and
column in the whole input, so `tail -f events.haus | haus check -` reports
each bad event as it arrives (see "Streams and `tail -f`" below). Its schema
is the one given with `--schema`, loaded once the first value is complete.
Against a `Stream` type every value is checked (`at: $[3].status`) and the
limit of 200 problems is per value; against any other type the first value is
checked, and a second one is an error (`not-one-value`). An excerpt shows
the value's last line up to its comma. A syntax error ends the check, since
nothing after it can be trusted.

#### `--json`

One JSON document on one line on standard output, whatever happened. It
comes once every file is checked: standard input is read to its end, not
value by value.

```json
{
  "ok": false,
  "files": [
    {
      "path": "adjacent/order-bad.haus",
      "kind": "data",
      "schema": "adjacent/order.schema.haus#Root",
      "ok": false,
      "diagnostics": [
        {
          "severity": "error",
          "code": "type-mismatch",
          "message": "expected Int, found the string \"7\"",
          "line": 3,
          "column": 7,
          "path": "$.id",
          "hint": "Write a value of the expected type; the message says which.",
          "docs": "https://haus-fmt.org/docs/errors#type-mismatch"
        }
      ]
    }
  ],
  "summary": { "files": 1, "errors": 1, "warnings": 0, "hints": 0, "unreadable": 0 }
}
```

| Member | |
|---|---|
| `ok` | no errors and no unreadable files: the exit code is 0 |
| `error` | only when nothing could be checked, such as a `--schema` file that doesn't exist (then the exit code is 2): `{ code, message, hint, docs }`, the error form of spec §17; `files` is then empty |
| `files[]` | every file checked, in the order checked |
| `files[].path` | as given or found (`./a.haus` when walking `.`); `<stdin>` for standard input |
| `files[].kind` | `"data"` or `"schema"` |
| `files[].schema` | the schema file and type a data file was checked against, if any |
| `files[].ok` | the file has no errors |
| `files[].error` | why the file couldn't be read (then the exit code is 2) |
| `files[].diagnostics[]` | the error form of spec §17, with `severity` first |
| `files[].stopped` | `true` when the check stopped after 200 problems: the file may have more; absent otherwise |
| `severity` | `"error"` (fails the check), `"warning"` (schema files) or `"hint"` (data files, and imports whose profiles aren't checked, in schema files) |
| `code`, `message`, `hint`, `docs` | always: the [error code](https://haus-fmt.org/docs/errors), the message, a fix, its documentation |
| `file` | when the place is in another file than the one checked: the data file's schema, when that schema is broken |
| `line`, `column` | the place in the text, when there is one |
| `path` | the place in the value, for schema checks: `$.items[2].price` |
| `expected`, `found` | for syntax errors, where natural |
| `summary` | counts over all files |

A check that can't start still prints the document, with `ok` false and
the reason in `error`:

```json
{
  "ok": false,
  "error": {
    "code": "import-not-found",
    "message": "--schema missing.schema.haus: no such file",
    "hint": "Fix the path given with --schema.",
    "docs": "https://haus-fmt.org/docs/errors#import-not-found"
  },
  "files": [],
  "summary": { "files": 0, "errors": 0, "warnings": 0, "hints": 0, "unreadable": 0 }
}
```

Only arguments the command line can't parse (an unknown option, a missing
path) are reported as text on standard error, with exit code 2, since
`--json` itself may not have been read.

Members that don't apply are left out. The shape is stable: members may be
added, never removed or renamed. Codes come from the catalogue (spec §17)
and never change after 1.0; messages may.

### `haus fmt`

```sh
haus fmt order.haus                # rewrite in place
haus fmt .                         # every data file below the current directory
haus fmt --check .                 # list what would change, write nothing
haus fmt - < in.haus > out.haus    # standard input to standard output
haus fmt --layout compact -        # one line per top-level value, no comments
haus fmt --layout minimised -      # the same without whitespace between tokens
```

Writes a standard layout (spec §11), keeping the key order and the spelling
of numbers, strings and byte strings (`0xFF` stays `0xFF`); formatting twice
changes nothing. Prints each file it rewrites (with `--check`, each file that
would change) on standard output, one path per line. A file with a syntax
error is never written: the error goes to standard error and the exit code
is 1.

| `--layout` | | For |
|---|---|---|
| `pretty` (default) | one entry per line; comments and blank lines kept | people who edit |
| `compact` | one line per top-level value, with spaces: `Person { name: "Ada", age: 36 },` | logs and streams people look at |
| `minimised` | one line per top-level value, no whitespace between tokens: `Person{name:"Ada",age:36},` | the wire and storage |

Standard input in the pretty layout is read to its end first: comments and
blank lines belong between values. In the compact and minimised layouts,
when standard input is a pipe (`tail -f events.haus | haus fmt --layout
compact -`), each value is written as soon as it is complete, followed by a
comma, as streams are written. So a lone value keeps its comma
(`{ a: 1 },`), which formatting the whole input drops; one that the input
ends without a comma stays without. Values before a syntax error are already
written.

Compact and minimised drop comments. So that a comment is never lost by
accident, `haus fmt` refuses to rewrite a file that has comments in one of
them (the exit code is 2, and the file stays as it was) unless you pass
`--drop-comments`. Formatting standard input to standard output needs no
option. `--style` is an older name for `--layout`.

Only data files are formatted. Directories are searched for `*.haus` files
that aren't `*.schema.haus`; a schema file named explicitly is a usage error.

Other options: `--indent N` (1–16, default 2), `--width N` (default 80; only
positional payloads such as `Money(7.90, EUR)` wrap). Both only affect the
pretty layout.

### `haus canonical` and `haus hash`

```sh
haus canonical events.haus         # one canonical form per line
haus hash events.haus              # hashAll: 64 hex digits
haus hash --each events.haus       # the hash of each value, one per line
curl -s https://example.org/feed.haus | haus hash
```

The file is read as a stream (spec §6), value by value, so memory stays
bounded by the largest value. Without a FILE (or with `-`) they read
standard input; without a FILE on a terminal, that's a usage error rather
than a wait. When the input is a pipe or a FIFO rather than a regular file,
each canonical form or hash is written as soon as its value is complete:
`tail -f events.haus | haus canonical`. A syntax error is reported on
standard error with exit code 1; canonical forms printed before it stay
printed. `haus hash` of a file with
one value is the hash of that value; of an empty file, the SHA-256 of the
empty text.

The hash is of the values, not of the text: the pretty, compact and
minimised layouts and the canonical form of the same data all have the same
hash, whatever their comments, key order, spelling or whitespace.

```sh
haus fmt --layout minimised - < order.haus | haus hash   # the same as `haus hash order.haus`
```

### Streams and `tail -f`

`haus check -`, `haus canonical`, `haus hash --each` and `haus fmt --layout
compact|minimised -` work on a stream that is still being written, such as
`tail -f events.haus | haus check --schema events.schema.haus -`: each value
is handled, and its output shown, as soon as it is complete.

A value is complete at the comma after it (spec §6), or at the end of the
input. So write a comma after every value, the last one too, as haus writers
do (`Heartbeat,`): a last value without one is only handled once the input
ends. `haus check --json` and `haus hash` without `--each` print once, at
the end; `haus fmt` in the pretty layout reads all of standard input first.

### Limits

`check`, `fmt`, `canonical` and `hash` parse with the limits of spec §7, and take
`--max-depth N` (at most 256, the deepest this binding supports),
`--max-number-length N` (which also sets the most hex digits in a hex
literal: 829 for the default 1000), `--max-exponent N` and
`--max-string-length N`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. Hints and warnings don't change it. |
| 1 | Invalid data: a syntax error, an error against the schema, a broken schema; or, with `fmt --check`, files that would change. |
| 2 | Usage error (unknown option, missing argument, an invalid limit, `--schema` file not found, `fmt` on a schema file, `fmt` that would drop a file's comments without `--drop-comments`) or I/O error (a file that doesn't exist or can't be read or written). Wins over 1. |

## Color

`--color auto|always|never` (default `auto`). `auto` colors only a terminal,
and not when `NO_COLOR` is set to a non-empty value. Each output is decided
on its own: diagnostics on standard error by standard error, haus text on
standard output by standard output, so `haus canonical x.haus > out.haus`
writes plain text. `--json` output and hashes are never colored.

The haus text that `haus canonical` and `haus fmt` print on standard output
is highlighted: tags cyan, record keys blue, strings green with their
escapes in bold, numbers yellow, byte strings magenta and comments dim.
Only color codes are added, never at a line break: without them the text is
the same, character for character.

## License

MIT
