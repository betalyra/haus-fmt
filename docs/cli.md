---
title: Command line
description: "The haus command: check data against its schema, format files, print canonical forms and hashes."
---

`haus` checks data files against their schemas, formats them, and prints
canonical forms and hashes. One static binary, no runtime, no network: files
never leave the machine.

Built for people and for agents: no prompts, deterministic output, `-` reads
standard input, stable exit codes, `--json` for programs, and every error
comes with a stable code, a fix hint and a link to its documentation.

## Install

```sh
cargo install haus-fmt-cli    # installs the `haus` command
```

`haus --version` prints the version and the spec version it implements:
`haus 0.1.0 (spec draft 0.1)`.

## Commands

| Command | What it does |
|---|---|
| `haus check PATH…` | syntax errors; then the schema's errors and hints, for data files; errors and warnings, for schema files |
| `haus fmt PATH…` | rewrites data files in the standard layout (spec §11); `--check` only lists them |
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
```

A **data file** is first parsed. If it is valid and has a schema, it is
checked against it: every error (up to 200 per file), and hints for fields
and tags an open type doesn't list and for deprecated ones the data uses.
Hints never fail a check. The schema is, in this order:

1. the one given with `--schema FILE[#Type]` (type default `Root`), for every data file checked;
2. the one named by a comment at the top of the file: `// schema: ./order.schema.haus` or `// schema: ./api.schema.haus#Order`, relative to the data file;
3. `x.schema.haus` next to `x.haus`, type `Root`;
4. none: syntax only. `--no-schema` always checks syntax only.

Imports in schemas resolve as in the other bindings: `std/time`, files next to
the schema (`import ./common (Address)`), and schema packages in
`node_modules/@org/name` in the schema's directory or above it.

A **schema file** (`*.schema.haus`) is loaded with its imports and checked
(spec §14): its errors, and its warnings (attributes this version doesn't
define, uses of deprecated types), which don't fail the check.

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

#### `--json`

One JSON document on one line on standard output, whatever happened:

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
| `severity` | `"error"` (fails the check), `"warning"` (schema files) or `"hint"` (data files) |
| `code`, `message`, `hint`, `docs` | always: the [error code](/docs/errors), the message, a fix, its documentation |
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
haus fmt --style compact -         # one line per top-level value, no comments
```

Writes the standard layout (spec §11), keeping comments, blank lines and the
spelling of numbers and strings; formatting twice changes nothing. Prints
each file it rewrites (with `--check`, each file that would change) on
standard output, one path per line. A file with a syntax error is never
written: the error goes to standard error and the exit code is 1.

Only data files are formatted. Directories are searched for `*.haus` files
that aren't `*.schema.haus`; a schema file named explicitly is a usage error.

Options: `--style pretty|compact` (default `pretty`), `--indent N` (1–16,
default 2), `--width N` (default 80; only positional payloads such as
`Money(7.90, EUR)` wrap).

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
than a wait. A syntax error is reported on standard error with exit code 1;
canonical forms printed before it stay printed. `haus hash` of a file with
one value is the hash of that value; of an empty file, the SHA-256 of the
empty text.

### Limits

`check`, `fmt`, `canonical` and `hash` parse with the limits of spec §7, and take
`--max-depth N` (at most 256, the deepest this binding supports),
`--max-number-length N`, `--max-exponent N` and `--max-string-length N`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK. Hints and warnings don't change it. |
| 1 | Invalid data: a syntax error, an error against the schema, a broken schema; or, with `fmt --check`, files that would change. |
| 2 | Usage error (unknown option, missing argument, an invalid limit, `--schema` file not found, `fmt` on a schema file) or I/O error (a file that doesn't exist or can't be read or written). Wins over 1. |

## Color

`--color auto|always|never` (default `auto`). `auto` colors only a terminal,
and not when `NO_COLOR` is set to a non-empty value. `--json` output is never
colored.
