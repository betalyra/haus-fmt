---
name: haus
description: Write, fix, validate and convert haus data files (.haus) and haus schemas (.schema.haus). Use when a task creates, edits, reviews or checks a .haus or .schema.haus file, converts JSON to haus, designs a haus schema, or runs the `haus` CLI. haus looks like JSON but breaks JSON habits (no null, True/False are tags, Maybe is always written), so load this before writing any.
---

# haus

haus is a text data format: JSON's records, arrays, strings and numbers, plus bytes, **variants** (a tag with optional payload: `True`, `None`, `Some(3)`, `Money(19.90, EUR)`, `Shipped { at: … }`) and **exact numbers** (`19.90` stays `19.90`). Data files end in `.haus`; a schema, if there is one, in `.schema.haus`.

## Before you write

Read [cheat-sheet.md](cheat-sheet.md) once per task: the syntax and every trap. The ones a JSON-trained model falls into:

- No `null`: leave the field out, or write `None` where the schema says `Maybe`.
- Booleans are the tags `True` and `False`.
- A payload starts on its tag's line: `Shipped { at: … }`, never `Shipped` then `{` on the next line.
- A `Maybe T` field is always written, `None` or `Some(x)`; a bare `x` is not `Some(x)`. An optional field `x?: T` is left out instead, never `None`.
- Integers have no fraction (`1`, not `1.0`); keep a number's spelling (`19.90`); never quote numbers, and wrap times in their tag: `Date("2026-11-08")`.
- Values in a stream (a file of many values) each end with a comma.

If the file has a schema, read it before writing data: it decides `Maybe` or optional, each tag's payload, and whether unknown fields are allowed. Writing or changing a schema: read [schemas.md](schemas.md). Converting JSON: read [json.md](json.md).

## The loop

1. Write the file.
2. Run `haus check path/to/file.haus --json`.
3. If `ok` is false, fix the **first** error (see below) and run the check again. Syntax errors stop the parser, so only the first one is reported; errors against the schema are all reported at once.
4. When it passes, run `haus fmt path/to/file.haus` for the standard layout (it keeps comments).

`haus check` also checks schema files: run it on a `.schema.haus` you wrote or changed, then on the data that uses it. `haus check .` checks a directory.

**Which schema.** The first that applies: `--schema s.schema.haus#Type` (type defaults to `Root`); `x.schema.haus` next to `x.haus`, type `Root`. A data file can't name its own schema, and comments in it mean nothing. Otherwise only the syntax is checked and `files[].schema` is absent: `ok: true` then says nothing about the schema. Data meant for a schema must show it in `files[].schema`: put `x.schema.haus` next to `x.haus`, or pass `--schema s.schema.haus#Type` on every check.

**Exit codes.** 0: valid (hints and warnings don't fail). 1: invalid. 2: usage or I/O error, such as a missing file or `--schema` file.

**No `haus` command?** Install it with `cargo install haus-fmt-cli`. If that isn't possible, tell the user the file is unchecked. Never call haus valid without a passing check.

Don't loosen the schema to make data pass unless the user asked for it: the data is usually what's wrong.

## Reading the diagnostics

```json
{ "ok": false, "files": [{ "path": "order.haus", "kind": "data", "schema": "order.schema.haus#Root", "ok": false,
  "diagnostics": [{ "severity": "error", "code": "type-mismatch", "message": "expected None or Some(…) (Maybe String), found the string \"Bo\"",
    "line": 5, "column": 9, "path": "$.nick", "hint": "…", "docs": "https://haus-fmt.org/docs/errors#type-mismatch" }] }],
  "summary": { "files": 1, "errors": 1, "warnings": 0, "hints": 0, "unreadable": 0 } }
```

- `severity`: `error` fails the check; `hint` (data) and `warning` (schema) don't, but read them: an `unlisted-field` or `unlisted-tag` hint is usually a typo.
- `code` says which mistake; `hint` says the fix; `message` gives the details, for schema errors as "expected X, found Y". `docs` explains the code with an example.
- `line`/`column` (1-based) point into the text; `path` points into the value: `$.items[2].price`. After a variant, `[n]` is its n-th argument: `$.status[0]`.
- `file` appears when the error is in another file, such as a broken schema; `files[].error` when a file couldn't be read.

The common codes and their fixes:

| `code` | Fix |
|---|---|
| `null-literal` | Leave the field out, or `None` if its type is `Maybe`. |
| `boolean-literal` | `True` / `False`. |
| `payload-newline` | Move the `{` or `(` up to the tag's line, or add the missing comma. |
| `missing-comma`, `expected-value`, `unclosed-bracket` | Look at `line`/`column` and what comes just before it. |
| `uppercase-key` | Quote the key: `"Name": 1`. Bare keys start lowercase or `_`. |
| `bare-identifier` | A lowercase word as a value: quote it (`"foo"`) or make it a tag (`Foo`). |
| `type-mismatch` | Read `message`. `expected None or Some(…)`: wrap, `Some(x)`. `found the tag None` on an optional field: delete the field. A string where a number or `Date` is expected: unquote, or wrap in the tag. |
| `not-an-integer` | `1`, not `1.0` or `1e3`. |
| `missing-field` | Add the field; `None` if it's a `Maybe`. |
| `unknown-field`, `unknown-tag` | The type is `closed`: fix the spelling or use a listed name (the message lists the tags). |
| `wrong-payload` | Give the tag exactly the payload its case says: a record (`Circle { r: 1 }`, not `Circle(1)`), its positional arguments (`Point(1, 2)`), or none. `hint` names the case. |
| `out-of-range`, `invalid-time` | Fix the value (see `message`), or ask before widening the type. |
| `import-not-found` | Schema packages come from `node_modules`: `npm install @haus-fmt/money`. |

For any other code, open its `docs` link or the catalogue at https://haus-fmt.org/docs/errors.

## Other commands

`haus fmt --check .` lists unformatted files; `haus fmt -` formats standard input. `haus canonical x.haus` and `haus hash x.haus` print the canonical form and hash. Reference: https://haus-fmt.org/docs/cli. Spec: https://haus-fmt.org/docs/spec.
