---
title: Using haus with agents
description: The haus plugin and skill for coding agents, the docs as llms.txt, the check loop, and an AGENTS.md snippet for your project.
---

haus looks like JSON, so models trained on JSON write it almost right: `null`, `true`, a payload on the next line, a bare value where the schema says `Maybe`. Three things get an agent from almost right to valid: the traps written down, a checker it can run, and errors that say what to write instead. Everything here runs locally; your data never leaves the machine.

## The Claude Code plugin

The `haus` plugin adds a skill that Claude loads whenever a task touches `.haus` or `.schema.haus` files, or asks to turn JSON into haus. In Claude Code:

```text
/plugin marketplace add betalyra/haus-fmt
/plugin install haus@haus-fmt
```

The skill holds the [cheat sheet](/docs/cheat-sheet), the check loop below, how to read `haus check --json`, a guide to designing schemas, and what to watch when converting JSON. It runs the [`haus` command](/docs/cli), so install that too:

```sh
brew install betalyra/tap/haus     # or: cargo install haus-fmt-cli
```

The plugin also checks every `.haus` and `.schema.haus` file Claude writes or edits: after each change it runs `haus check` and hands any errors straight back to Claude, so invalid data can't slip through. It stays quiet when the file is valid or the `haus` command isn't installed.

## Other agents

The skill follows the [Agent Skills](https://agentskills.io) format. To install it into Codex, Cursor, Copilot, Gemini, Windsurf, Zed and the other agents the [skills](https://www.skills.sh) command knows:

```sh
npx skills add betalyra/haus-fmt --skill haus
```

Or copy the folder [`claude-plugin/skills/haus`](https://github.com/betalyra/haus-fmt/tree/main/claude-plugin/skills/haus) into your agent's skills directory.

## The docs as text

For agents without the skill, the whole documentation is available as plain text:

- [haus-fmt.org/llms.txt](https://haus-fmt.org/llms.txt): an index of the docs
- [haus-fmt.org/llms-full.txt](https://haus-fmt.org/llms-full.txt): everything in one file, the specification included

The [cheat sheet](/docs/cheat-sheet) alone (about 2,000 tokens) is the best single page to give a model.

## The loop

1. Write the `.haus` file.
2. Run `haus check file.haus --json`. The file is checked against the schema given with `--schema s.schema.haus#Type`, or else `file.schema.haus` next to it.
3. Fix the first error and check again. Every error has a stable `code`, a `hint` with the fix, the place (`line`, `column`, and `path` for schema errors) and a `docs` link to the [error catalogue](/docs/errors).
4. Run `haus fmt file.haus`.

Exit code 0 means valid, 1 invalid, 2 a usage or I/O error. The [command line](/docs/cli#--json) page documents the JSON output.

## An AGENTS.md snippet

Copy this into the `AGENTS.md` (or `CLAUDE.md`) of a project that uses haus, and add where your data and schemas live:

```markdown
## haus files

Data in this repository is written in haus (`*.haus`), with schemas in `*.schema.haus`: https://haus-fmt.org.
haus is not JSON. The traps:

- No `null`: leave the field out, or write `None` where the schema says `Maybe`.
- Booleans are `True` and `False`.
- A tag's payload starts on the tag's line: `Shipped { at: … }`.
- A `Maybe` field is always written, `None` or `Some(x)`; an optional field (`x?: T`) is left out instead.
- Integers have no fraction (`1`, not `1.0`); numbers keep their spelling (`19.90`); never quote numbers or dates (`Date("2026-11-08")`).

Cheat sheet: https://haus-fmt.org/docs/cheat-sheet

After changing a `.haus` or `.schema.haus` file:

1. Run `haus check <file> --json`. Fix the first error using its `code`, `message` and `hint` (more under its `docs` link), and repeat until `ok` is true.
2. Run `haus fmt <file>`.

`x.haus` is checked against `x.schema.haus` next to it; for another schema, pass `--schema file.schema.haus#Type`.
Fix the data, not the schema, unless the task is to change the schema.
Install the checker with `brew install betalyra/tap/haus` or `cargo install haus-fmt-cli`.
```
