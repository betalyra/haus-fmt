# tree-sitter-haus

[Tree-sitter](https://tree-sitter.github.io) grammars for [haus](https://haus-fmt.org):

| Grammar | Files | Scope |
|---|---|---|
| `haus` ([`haus/grammar.js`](haus/grammar.js)) | data files, `*.haus` | `source.haus` |
| `haus_schema` ([`haus_schema/grammar.js`](haus_schema/grammar.js)) | schema files, `*.schema.haus` and a package's `schema.haus` | `source.haus.schema` |

They are two languages, as in the VS Code extension: a schema file is a list of
imports and type definitions, a data file a list of values, and the same text
(`{ id: Int }`) means different things in each. They share the lexical layer
(whitespace, comments, strings) and the data values, which schema files use
for attribute arguments: [`common/common.js`](common/common.js) and the external
scanner [`common/scanner.h`](common/scanner.h). The sources of truth are
[`spec/grammar.ebnf`](../../spec/grammar.ebnf) and [`spec/README.md`](../../spec/README.md)
§1–§6 and §13–§14.

## What the grammars check

Everything in `grammar.ebnf`, including the parts that need the external
scanner:

- **Comments**: block comments nest (`/* a /* b */ c */`); no control
  characters, bidirectional controls or invalid UTF-8 in comments or strings.
- **Line breaks**: LF or CR LF. A carriage return on its own is an error
  anywhere, also at the end of the file (the generated lexer would take it for
  the start of a line break there, so the scanner lexes it as a token no rule
  accepts).
- **Block strings**: the opening `"""` ends its line, the closing `"""` stands
  on a line of its own, and every content line that isn't blank starts with
  the closing line's indent (spec §4). `"""` inside a line is an error.
- **Payloads on the tag's line** (spec §5): right after a tag the scanner emits
  a zero-width token saying whether a payload follows with only spaces and tabs
  in between, so `Tag⏎{ … }` and `Tag /* c */ (1)` are errors, as in every
  parser.
- **Byte order mark**: only as the very first character. The tree-sitter
  runtime skips a byte order mark at byte 0 before any lexer runs, so the
  grammars don't mention it; anywhere else (a second one, one after a comment
  or a value) nothing lexes it, which is an error.
- **Escapes**: `\u{…}` must be a Unicode scalar value (no surrogates, at most
  `10FFFF`).
- **Files starting with `#`** (reserved for a version directive, spec §10) are
  an error, as in every parser of this version.

A grammar can't check what isn't syntax. These files parse without an error
node, and haus parsers reject them:

- data: duplicate keys, and the limits of spec §7 (nesting depth, characters in
  a number, string, key, tag or value, hex digits, exponent);
- schema files: everything spec §14 lists beyond the syntax (unknown types,
  arity, prelude redefinitions, spreads, recursion, attribute arguments,
  `closed < >`, imports that can't be resolved).

Tree-sitter recovers from errors by design: an invalid file gives a tree with
`ERROR` or `MISSING` nodes, never a refusal. Every closing delimiter is a
visible token (a block string's closing `"""` too, which the scanner lexes),
so a missing one is a `MISSING` node that editors and `tree-sitter parse` can
show; a hidden one would be a `MISSING` node nothing reports. `tree-sitter
parse` prints only named nodes in the tree, so a missing `}`, `)`, `]`, `"` or
`"""` shows only on the summary line after it: `(MISSING "}" [0, 6] - [0, 6])`.

## Nodes

Data files: `source_file`, `record` (`field` with `key:` and `value:`),
`array`, `variant` (`tag:` and an optional `payload:`, which is `arguments` or a
`record`), `string` (`string_content`, `escape_sequence`), `block_string`,
`bytes`, `number`, `identifier`, `tag`, `line_comment`, `block_comment`.

Schema files: `schema_file`, `import` (`module:`, `name:`), `type_definition`
(`attribute`s, `name:`, `parameter:`, `type:`), `type_application`
(`constructor:`, `argument:`), `parenthesized_type`, `record_type`
(`field_declaration` with `key:` and `type:`, `spread`), `variant_type`
(`case` with `tag:` and `argument:`, `spread`), `attribute` (`name:`,
`arguments:`), `type_name`, `type_parameter`, and the data nodes in attribute
arguments.

## Layout

```
tree-sitter.json          both grammars, their scopes and query paths
common/common.js          rules both grammars share
common/scanner.h          the external scanner both grammars include
haus/                     data files
  grammar.js
  src/                    generated (parser.c, …) and scanner.c, which includes common/scanner.h
  queries/                highlights.scm, folds.scm, indents.scm
  test/corpus/            tree-sitter test cases
haus_schema/              schema files, laid out like haus/ (queries add locals.scm)
queries/helix/            Helix's own copies of the queries, per grammar
scripts/check.mjs         every haus file in the repository, against the reference parser
```

## Development

This package is part of the pnpm workspace in `typescript/`, so install from
there; that also downloads the tree-sitter CLI's binary from GitHub and builds
nothing else. Run its scripts through the workspace (`pnpm --filter`):
`pnpm run` inside this folder would treat it as a project of its own.

```sh
(cd ../../typescript && pnpm install && pnpm --filter ./packages/haus build)
(cd ../../typescript && pnpm --filter tree-sitter-haus run generate)   # haus/src, haus_schema/src
(cd ../../typescript && pnpm --filter tree-sitter-haus test)           # each grammar's test/corpus
node scripts/check.mjs       # the rest of the repository, against the reference parser
```

`src/` of each grammar is generated and committed, as Tree-sitter grammars
usually do, so editors can build the parsers without the CLI. Run the generate line
above after changing a grammar or `common/`; CI fails if the committed
`src/` differs from what it generates.

### With a tree-sitter CLI from cargo

Any tree-sitter CLI of the version in `package.json` (0.27.1) works, for
example one from `cargo install tree-sitter-cli --version 0.27.1`. Run it in
each grammar's directory, and point `scripts/check.mjs` at it with
`TREE_SITTER`:

```sh
TS=$HOME/.cargo/bin/tree-sitter
(cd haus && $TS generate && $TS test)
(cd haus_schema && $TS generate && $TS test)
TREE_SITTER=$TS node scripts/check.mjs
```

The CLI compiles parsers into its cache directory (`~/.cache/tree-sitter/lib`,
or under `$XDG_CACHE_HOME`; `$TREE_SITTER_LIBDIR` overrides it). Where that
isn't writable (a sandbox, a read-only home), point both elsewhere:

```sh
export XDG_CACHE_HOME=$TMPDIR/xdg-cache TREE_SITTER_LIBDIR=$TMPDIR/ts-lib
```

The warning "You have not configured any parser directories" is harmless:
`generate`, `test`, `build` and `parse` in a grammar's directory don't need
any.

[`scripts/check.mjs`](scripts/check.mjs) needs the built TypeScript package
(the first line above). It
parses every `.haus` file in the repository (the conformance suite, the format
suite with its expected outputs, examples, fixtures) with tree-sitter and with
the TypeScript reference parser, and compares:

- where the reference accepts a file, the tree must have no error and give the
  same values (strings unescaped, block strings dedented by spec §4, numbers
  normalised, compared by canonical form, spec §12);
- where it rejects a file, the tree must have an error (an `ERROR` or
  `MISSING` node anywhere in the output, the summary line included), unless
  the reason is one a grammar can't check (above);
- schema files must parse without error, except in
  `test-suite/schema/invalid`, where files with a syntax error code must give
  an error and the others must not (`unknown-module` may do either: the
  grammar rules out `@Haus/money`, not `std/money`).

`--fuzz N [--seed S] [--mutate]` adds N documents from the differential
fuzzer's generator ([`fuzz/src/generate.ts`](../../fuzz/src/generate.ts)),
compared the same way; `--mutate` mutates half of them first, as the fuzzer
does. `--verbose` lists the files accepted only because their errors are
beyond the syntax. `TREE_SITTER` sets the CLI command (default
`node_modules/.bin/tree-sitter`, which pnpm installs).

`tree-sitter parse --scope source.haus` would need a parser directory
configured with `tree-sitter init-config`, and `--grammar-path` rebuilds the
parser on every call. So the script first compiles each grammar once into a
shared library in a temporary directory (`tree-sitter build -o`) and parses
every file with `--lib-path` and `--lang-name`.

`tree-sitter.json` enables no bindings. To publish a package for a language
(Node, Rust, Python, Go, Swift, C), turn it on there and run `pnpm exec tree-sitter
init --update`.

## Queries

| | Neovim, Zed, `tree-sitter highlight` | Helix |
|---|---|---|
| data | [`haus/queries`](haus/queries) | [`queries/helix/haus`](queries/helix/haus) |
| schema | [`haus_schema/queries`](haus_schema/queries) | [`queries/helix/haus_schema`](queries/helix/haus_schema) |

Each grammar's queries sit next to it, where editors that build a grammar from
its directory look for them; `tree-sitter.json` points at them too.

`highlights.scm`, `folds.scm` (Neovim), `indents.scm` and, for schema files,
`locals.scm` (type names and parameters). The capture names are
nvim-treesitter's; Helix has its own names, and takes the first matching
pattern where Neovim takes the last, so it has its own copies.

## Editors

The grammars live in a subdirectory of the haus repository. Editors that build
grammars from git take the repository and the path to the grammar. The scanner
of each grammar includes `../../common/scanner.h`, which the checkout
contains.

### Neovim

With [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
(`main` branch):

```lua
vim.filetype.add({
  extension = { haus = 'haus' },
  filename = { ['schema.haus'] = 'haus_schema' },
  pattern = { ['.*%.schema%.haus'] = { 'haus_schema', { priority = 10 } } },
})

vim.api.nvim_create_autocmd('User', {
  pattern = 'TSUpdate',
  callback = function()
    local parsers = require('nvim-treesitter.parsers')
    for _, lang in ipairs({ 'haus', 'haus_schema' }) do
      parsers[lang] = {
        install_info = {
          url = 'https://github.com/betalyra/haus-fmt',
          location = 'editors/tree-sitter-haus/' .. lang,
          queries = 'editors/tree-sitter-haus/' .. lang .. '/queries',
        },
      }
    end
  end,
})
```

Then `:TSInstall haus haus_schema`. On nvim-treesitter's older `master`
branch, set `install_info = { url = …, location = …, files = { 'src/parser.c',
'src/scanner.c' } }` in `get_parser_configs()` instead, and copy
`haus/queries` and `haus_schema/queries` to `~/.config/nvim/queries/haus` and
`~/.config/nvim/queries/haus_schema`.

### Helix

In `~/.config/helix/languages.toml` (pin `rev` to a commit):

```toml
[[language]]
name = "haus"
scope = "source.haus"
file-types = ["haus"]
comment-tokens = "//"
block-comment-tokens = { start = "/*", end = "*/" }
indent = { tab-width = 2, unit = "  " }

[[language]]
name = "haus_schema"
scope = "source.haus.schema"
file-types = [{ glob = "*.schema.haus" }, { glob = "schema.haus" }]
comment-tokens = "//"
block-comment-tokens = { start = "/*", end = "*/" }
indent = { tab-width = 2, unit = "  " }

[[grammar]]
name = "haus"
source = { git = "https://github.com/betalyra/haus-fmt", rev = "COMMIT", subpath = "editors/tree-sitter-haus/haus" }

[[grammar]]
name = "haus_schema"
source = { git = "https://github.com/betalyra/haus-fmt", rev = "COMMIT", subpath = "editors/tree-sitter-haus/haus_schema" }
```

Then `hx --grammar fetch && hx --grammar build`, and copy
`queries/helix/haus` and `queries/helix/haus_schema` to
`~/.config/helix/runtime/queries/`.

### Zed

A Zed extension names the grammars in `extension.toml`:

```toml
[grammars.haus]
repository = "https://github.com/betalyra/haus-fmt"
rev = "COMMIT"
path = "editors/tree-sitter-haus/haus"

[grammars.haus_schema]
repository = "https://github.com/betalyra/haus-fmt"
rev = "COMMIT"
path = "editors/tree-sitter-haus/haus_schema"
```

and has a directory per language, `languages/haus/` and
`languages/haus_schema/`, each with a `config.toml` and the queries.
`highlights.scm` is the one in `haus/queries/` or `haus_schema/queries/`; Zed's indents and brackets use
their own captures:

```toml
# languages/haus/config.toml (haus_schema: grammar "haus_schema", path_suffixes ["schema.haus"])
name = "haus"
grammar = "haus"
path_suffixes = ["haus"]
line_comments = ["// "]
block_comment = ["/* ", " */"]
tab_size = 2
brackets = [
  { start = "{", end = "}", close = true, newline = true },
  { start = "[", end = "]", close = true, newline = true },
  { start = "(", end = ")", close = true, newline = true },
  { start = "\"", end = "\"", close = true, newline = false, not_in = ["string"] },
]
```

```scheme
; languages/*/brackets.scm
("{" @open "}" @close)
("[" @open "]" @close)
("(" @open ")" @close)

; languages/*/indents.scm
(_ "{" "}" @end) @indent
(_ "[" "]" @end) @indent
(_ "(" ")" @end) @indent
```

For schema files add `("<" @open ">" @close)` and `(_ "<" ">" @end) @indent`.
A file named `x.schema.haus` ends in both suffixes; if Zed opens it as `haus`,
map it in the settings: `"file_types": { "haus_schema": ["*.schema.haus"] }`.
