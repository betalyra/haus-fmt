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
| `haus package check [DIR…]` | a schema package before it is published: its manifest, schema and profiles, and its `package.json`, `Cargo.toml` and `pyproject.toml` |
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
The errors are those of spec §14, "Every error": each error once (a record
missing two fields has two `missing-field` errors), nothing below a value
that failed at its own level (a string where a record is expected is one
error, its contents aren't looked at), and an error inside a `Secret` once,
at the secret. A document with a syntax error has that one error; a file
checked against a `Stream` type is read item by item, so a syntax error ends
its check after the errors of the items before it. The check stops after 200
errors per file (hints don't count) and then says so (`note: order.haus:
stopped after 200 errors; there may be more`, and `"stopped": true` with
`--json`). `--first` stops at the first error of each file instead, keeping
the hints found before it; on standard input, at the first error of the
stream. The schema is, in this order:

1. the one given with `--schema FILE[#Type]` (type default `Root`), for every data file checked;
2. `x.schema.haus` next to `x.haus`, type `Root`;
3. none: syntax only. `--no-schema` always checks syntax only.

A data file never names its own schema (spec §14): the reader decides, so a
file can't make `haus check` read another file. Comments in it mean nothing.

Imports in schemas resolve as in the other bindings: `std/time`, files next to
the schema (`import ./common (Address)`), and schema packages. A package
`@org/name` is found in `node_modules/@org/name` in the directory of the
importing file's real path or above it, as Node finds packages, so pnpm and
workspace links work. It is never taken from `NODE_PATH` or npm's global
folder. In a Cargo or Python project, or for packages anywhere else, give
them explicitly:

```sh
haus check --package vendor/money order.haus              # a package's directory
haus check --package @acme/money=vendor/money order.haus  # the same; its manifest must say @acme/money
haus check --packages schemas/ order.haus                 # every subdirectory with a package.haus
```

Both options can be repeated. A package given with `--package` is used
instead of `node_modules` for its name. One found with `--packages` is not:
if `node_modules` holds a different copy, that's `duplicate-package`. A package given that can't be used (no
`package.haus`, an invalid manifest, two packages with one name) stops the
check with exit code 2.

A **schema file** (`*.schema.haus`) is loaded with its imports and checked
(spec §14): its errors, and its warnings (attributes this version doesn't
define, uses of deprecated types), which don't fail the check. An import of
an official package with profiles (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`) gets a
hint (`missing-codec`): `haus check` has no codecs, so it checks the
package's types for their shape only, not its profiles' rules (`the rules of
@haus-fmt/money (profiles: iso) are not checked here; your application checks
them by adding a codec`, spec §13.4).

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
limit of 200 errors is one for the whole stream; against any other type the first value is
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
| `files[].stopped` | `true` when the check stopped after 200 errors: the file may have more; absent otherwise |
| `severity` | `"error"` (fails the check), `"warning"` (schema files) or `"hint"` (data files, and imports whose profiles aren't checked, in schema files) |
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
haus fmt --layout compact -        # one line per top-level value, no comments
haus fmt --layout minimised -      # the same without whitespace between tokens
haus fmt --stream events.haus      # a stream: a comma after a single value too
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
ends without a comma stays without (with `--stream`, it gets one). Values
before a syntax error are already written.

A file with one value is written as a document, without a comma after it,
and one with more as a stream, a comma after every value. Counting can't tell
a log that holds one event so far from a document, and its comma is what lets
the next event be appended: `--stream` says the files are streams, so a
single value gets its comma too, in every layout. A file with more values, or
none, is written as without it. `haus fmt` takes no schema, so it never turns
this on by itself (the VS Code extension does, for a file whose schema next
to it has a `Stream` root).

Compact and minimised drop comments. So that a comment is never lost by
accident, `haus fmt` refuses to rewrite a file that has comments in one of
them (the exit code is 2, and the file stays as it was) unless you pass
`--drop-comments`. Formatting standard input to standard output needs no
option. `--style` is an older name for `--layout`.

Only data files are formatted. Directories are searched for `*.haus` files
that aren't `*.schema.haus`; a schema file named explicitly is a usage error.

Other options: `--indent N` (0–16, default 2), `--width N` (default 80; only
positional payloads such as `Money(7.90, EUR)` wrap). Both only affect the
pretty layout, and 0 means what it says: `--indent 0` writes every line
without indentation, and `--width 0` is a width nothing fits in, so every
positional payload gets one argument per line.

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

### `haus package check`

```sh
haus package check                       # the package in the current directory
haus package check extensions/*/         # several
haus package check --json . > report.json
```

Checks a schema package (spec §13.3) before it is published, as CI for
packages: everything a user of any language would trip over. The files are
only read: nothing is run, packed, built or fetched. `DIR` defaults to `.`.

| What | Checked |
|---|---|
| `package.haus` | a regular file of at most 64 KiB, one record with a lowercase `@org/name` and a semantic `version` (`package-manifest`); a former `schema` field is ignored (a warning) |
| `schema.haus` | a regular file next to it, not a link (`package-path`); loaded with its imports and checked like `haus check` does, errors and warnings |
| profiles | each `profiles/<name>.vectors.haus` has its rule, `profiles/<name>.md`, next to it; the vectors are haus, each `Accept { type, value, output?, note? }` or `Reject { type, value, note? }` with no other fields (only an Accept has an `output`); `type` names a type of the package without parameters; `value` and `output` are one haus value each, and an accepted one and its output are valid for `type`, since codecs run after the schema (`profile-vectors`) |
| versions | the `version` of `package.json`, `Cargo.toml` (also inherited from the workspace) and `pyproject.toml` is the manifest's (`package-version`) |
| npm | `package.json` is a regular file (`package-path`); its `name` is the manifest's (`package-name`); no `preinstall`, `install` or `postinstall` script and no `binding.gyp` (`package-install-script`) |
| Cargo | `links` is the library's name (`[lib] name`, or the package's with `_`), which crates that use the package's types name it by; a schema package it depends on isn't renamed (`package = …`) (`package-crate`) |
| files shipped | `files` of `package.json` (or, without it, `.npmignore`/`.gitignore`), `include` (or `exclude`) of `Cargo.toml`, and hatchling's wheel configuration (`force-include`, `only-include`, `packages`, `include`, `exclude`) ship `package.haus`, `schema.haus` and the profiles (vectors and rules) (`package-files`) |
| wrappers | each `package.json`, `Cargo.toml` and `pyproject.toml` present can be read: valid JSON or TOML, a `name` in `package.json`, a `[package]` in `Cargo.toml` (`package-wrapper`) |
| dependencies | every package `schema.haus` imports is declared in every wrapper present (`undeclared-package`): in `peerDependencies`, `dependencies` or `optionalDependencies` of `package.json` (not `devDependencies`; anything but `peerDependencies` is a warning), and among the dependencies of `Cargo.toml` and `pyproject.toml` |

Wrappers that aren't there aren't checked, and a `pyproject.toml` without a
`[project]` is not a Python distribution. Which package a Cargo or Python
dependency is can be told from the files only for path dependencies (`path
= "../money"`, `[tool.uv.sources]`): an import that only a registry or git
dependency could provide is a warning, not an error. Likewise the files a
wheel ships with another build backend than hatchling, and a dynamic
version.

Imports are found as in `haus check`: the packages given with `--package`
and `--packages`, then the path dependencies of the package's wrappers that
are schema packages (and theirs), then `node_modules`.

```text
error[package-version]: package.haus says version 1.0.0, package.json 1.0.1
 --> good/package.json:3:3
  |
3 |   "version": "1.0.1",
  |   ^^^^^^^^^
  |
  = hint: Release both with the same version: change them together.
  = docs: https://haus-fmt.org/docs/errors#package-version

error[package-crate]: links is "good", but the library is fixture_good: crates that use the package's types name its crate by its links
 --> good/Cargo.toml:7:9
  |
7 | links = "good"
  |         ^^^^^^
  |
  = hint: Set links = "fixture_good", the library's name.
  = docs: https://haus-fmt.org/docs/errors#package-crate

Checked 1 package: 2 errors.
```

Every finding has a code from the [error catalogue](/docs/errors), errors
and warnings alike. Warnings (an ignored manifest field, a dependency that
can't be told from the files, a build backend whose configuration isn't
read, a dynamic version, an npm dependency that isn't a peer dependency)
don't fail the check.

With `--json`, one document, like `haus check`'s:

```json
{
  "ok": false,
  "packages": [
    {
      "path": "good",
      "name": "@fixture/good",
      "version": "1.0.0",
      "ok": false,
      "diagnostics": [
        {
          "severity": "error",
          "code": "package-version",
          "message": "package.haus says version 1.0.0, package.json 1.0.1",
          "file": "good/package.json",
          "line": 3,
          "column": 3,
          "hint": "Release both with the same version: change them together.",
          "docs": "https://haus-fmt.org/docs/errors#package-version"
        }
      ]
    }
  ],
  "summary": { "packages": 1, "errors": 1, "warnings": 0, "unreadable": 0 }
}
```

`packages[]` has the directory as given (`path`), the manifest's `name` and
`version` when it is valid, `ok`, `error` when the directory can't be read,
and the diagnostics, each with the `file` it is about. A `--package` that can't be used gives the top-level
`error`, as with `haus check`.

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
| 1 | Invalid data: a syntax error, an error against the schema, a broken schema; or, with `fmt --check`, files that would change; or, with `package check`, an error in a package. |
| 2 | Usage error (unknown option, missing argument, an invalid limit, `--schema` file not found, `fmt` on a schema file, `fmt` that would drop a file's comments without `--drop-comments`, a `--package` that can't be used) or I/O error (a file or package directory that doesn't exist or can't be read or written). Wins over 1. |

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
