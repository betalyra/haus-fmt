# haus in OCaml (clean-room test implementation)

An implementation of the haus text core (spec §1–§12), written from
[`spec/`](../spec) and the [conformance suite](../test-suite) only, without
looking at any other binding. Its purpose is to test the specification: where
the spec text was ambiguous or silent, the choice made is a finding in
[`plans/ocaml-findings.md`](../plans/ocaml-findings.md). It is not published.

Phase 1 covers: the parser (every syntax and limit error with its code and
line and column), the chunked stream reader with strict mode and the value
limit, the pretty, compact and minimised layouts of documents (comments kept
in pretty) and of values built in code, checking constructors, the canonical
form, `hash`, `hashAll`, `equals` and `compare`. Schemas, decoding, packages
and JSON are not implemented.

The parser and the writers recurse once per nesting level. OCaml 5 runs OCaml
code on stacks that grow on demand, on every domain, so the supported depth
limit is 100,000 (`Limits.max_supported_depth`; a larger one is
`unsupported-depth`). The canonical form, hashing, `equals` and `compare` don't
recurse and take any depth.

Needs OCaml 5 with dune and [digestif](https://github.com/mirage/digestif)
(SHA-256), its only dependency.

```sh
cd ocaml
dune build                    # library (src/), tests (test/), fuzz runner (fuzz/)
dune test                     # the conformance suite's text-core directories and unit tests
./_build/default/test/suite.exe   # the suite alone, pass counts per directory (VERBOSE=1 for every failure)
```

The fuzz runner, `_build/default/fuzz/runner.exe`, follows
[`fuzz/README.md`](../fuzz/README.md): `DIR N`, `--stream`, `--canonical`,
`--format STYLE` and `--write STYLE` (with `--indent N --width N`, and
`--stream` for the stream option of spec §11: `Layout.options ~stream:true`,
taken by `Layout.format` and `Layout.write_all`, writes a comma after a single
item too; `--write` applies it to its `"file"`). Every mode's
error line is `err LINE COLUMN CODE REASON`, `0 0` where there is no place.
