# haus for VS Code

> ⚠️ Experimental, like [haus](https://github.com/betalyra/haus-fmt) itself.

Editor support for `.haus` data files and `.schema.haus` schemas. Learn the format at [haus-fmt.org](https://haus-fmt.org).

## Features

- 🎨 **Highlighting** for `.haus` and `.schema.haus`; raw bidi control characters are marked as errors.
- 🚨 **Errors as you type**, e.g. `{ ok: true }` → *booleans are the variants True / False*.
- 💡 **Missing imports in schemas:** use `Date` or `Money` without importing it and the quick fix (Cmd+.) adds `import std/time (Date)` or `import @haus-fmt/money (Money)`, or adds the name to the import you already have. Packages like `@haus-fmt/money` and `@haus-fmt/geo` also need installing with your package manager; the error says so.
- 🔍 **Hover with inferred types:** hover any key or value to see the type merged over the whole file. In `Person { type: Engineer }, Person { type: Designer }`, hovering `type` shows `< Engineer | Designer >`. Exact numbers warn when a `Float64` would round them.
- 🧭 **Outline** of fields, items and variants (Cmd+Shift+O).
- ✨ **Formatting:**
  - **Format Document** (Shift+Alt+F) or **haus: Pretty Print** gives one entry per line and keeps comments.
  - **haus: Compact** puts every item on one line and drops comments.
- 📝 **haus in Markdown:** ` ```haus ` and ` ```haus-schema ` code blocks are highlighted in the Markdown editor and the Markdown preview.
- 📐 **haus: Infer Schema from This File** opens a `.schema.haus` draft (command palette or the editor title bar).

Try it on [`person.haus`](https://github.com/betalyra/haus-fmt/blob/main/examples/person.haus), or on the recursive [`thread.haus`](https://github.com/betalyra/haus-fmt/blob/main/examples/thread.haus), [`filesystem.haus`](https://github.com/betalyra/haus-fmt/blob/main/examples/filesystem.haus) and [`settings-ui.haus`](https://github.com/betalyra/haus-fmt/blob/main/examples/settings-ui.haus).

## Settings

Format on save is not switched on by the extension. If you have it on globally and don't want it for haus:

```jsonc
"[haus]": { "editor.formatOnSave": false }
```

Schema packages are found in `node_modules`, from the real path of the schema file (pnpm and workspace links work), when the nearest `package.json` declares them. Packages outside `node_modules` (vendored, or from a Cargo or Python project) can be given with `haus.packages`, as paths relative to the workspace folder: a package's directory (with `package.haus`), or a folder whose subdirectories are packages.

```jsonc
"haus.packages": ["vendor/money", "schemas"]
```

Paths in workspace settings must stay inside the workspace folder (symbolic links resolved); only your user settings may point elsewhere on your computer. Network paths (`\\host\share`) are never used. In a workspace you haven't trusted, its `haus.packages` is ignored (Workspace Trust).

## Develop

Press **F5** in the repo root ("haus extension (dev host)" in `.vscode/launch.json`). A second window opens running the extension from this folder, with `examples/` open. Run `pnpm watch` alongside, and reload that window after changes.

To try a packaged build:

```sh
cd editors/vscode
pnpm install
pnpm run package                              # builds haus.vsix
code --install-extension haus.vsix --force
```

Don't symlink this folder into `~/.vscode/extensions`: VS Code caches the manifest and gets confused when the version changes.
