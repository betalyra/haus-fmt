# Changelog

## 0.2.0

- Schema files: an import of an official package with profiles (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`) gets a note (`missing-codec`, information) that the editor doesn't check the profiles' rules: your application checks them by adding a codec.
- Schema files: relative imports stay inside the workspace folder that has the schema file (before: the schema file's own directory), and the new setting `haus.root` gives another root, relative to the workspace folder. A relative import follows no symbolic link.
- Highlighting for ` ```haus ` and ` ```haus-schema ` code blocks in Markdown files, in the editor and the preview.
- Schema files: a type from a standard module or an official extension used without its import (`Date`, `Money`, `LatLng`, `Uuid`) gets a quick fix that adds the import, to the module's existing import if there is one. When more types of that module are missing, a second fix adds them all. For a package such as `@haus-fmt/money`, the error and the hover also say to install it with your package manager.

## 0.1.0

First Marketplace release.

- Highlighting for `.haus` and `.schema.haus`
- Errors as you type
- Inferred types on hover
- Outline
- Formatting: Format Document / Pretty Print, and Compact
- Infer Schema from This File
