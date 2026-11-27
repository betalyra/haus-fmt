# Changelog

## Unreleased

- Packages are never looked for in `node_modules` any more (packages 0.2): the official packages (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`) are built in, with their rules checked (`Money(1, Eur)` is an error), and every other package comes from `haus.packages`. An import of a package whose manifest names rules the editor has no implementation of gets a hint (`missing-codec`) that they are not checked here; official packages no longer do.

- Formatting a data file whose schema next to it (`x.schema.haus` for `x.haus`) has a `Stream` root writes it as a stream: a comma after a single item too, so that the next can be appended (spec §11). Other files format as before.
- Comments are read left to right: a control or bidi character or a lone carriage return in a block comment that is never closed is the error shown, at its place, instead of the missing `*/`.
- Data files checked with a schema: a `Stream` file is checked item by item, so a syntax error shows together with the errors of the items before it. Each missing field is an error of its own. The check stops after 200 errors (hints don't count) and says so with a note at the start of the file.

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
