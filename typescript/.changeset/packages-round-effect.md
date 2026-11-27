---
"@haus-fmt/effect": minor
"@haus-fmt/haus": minor
---

`@haus-fmt/effect` is the recommended, full-featured way to use haus in TypeScript, on the packages round of `@haus-fmt/haus` (breaking, 0.x minor):

- **Schemas from files, read apart from compiling.** `Haus.readSources(path, { packages, folders, root })`, `Haus.readPackage` and `Haus.readPackages` are Effects that need the `SchemaFiles` service; `@haus-fmt/effect/node` provides it for Node (`NodeSchemaFiles.layer`, the core's reader with the file rules of spec §13.3). `Haus.compile(sources)` reads nothing and needs no service: the core compiles (packages, rules, `missing-codec`), and its types become Effect schemas. `Haus.Sources.make` and `Haus.Package.make` make sources and packages from plain data; `Haus.fromSchema` takes a schema `@haus-fmt/haus` compiled.
- **Rules on by default.** A package's rules are checks of their types, before any codec and whatever the codecs (`Money(1, Eur)` is `codec-rejected`); a reached rule without an implementation is `missing-codec` at compile. `Haus.Package.withRule(pkg, type, rule)` supplies one (a filter, as `Schema.makeFilter` takes), `Haus.Package.shapeOnly(pkg)` opts out.
- **Errors.** Reading and compiling fail with `HausCompileError` (a code; a line and column for a schema file's error) or `HausConfigError`.
- **Secrets.** Encoding refuses a `Redacted` (`cannot-encode` at the secret's place) unless `revealSecrets: true` (`Haus.encode`, `encodeStream`, `encodeValue`, `toJson`, `toJsonValue`, `encodeJsonLines`).
- **Values checked when built.** Encoding checks every limit of the call (string, key, tag, number and byte lengths, depth, nodes) as the core's encoder does; `Haus.toHausJson(value)` is total and takes no limits.
- **The official packages** move from `@haus-fmt/money/effect`, `@haus-fmt/geo/effect` and `@haus-fmt/uuid/effect` to `@haus-fmt/effect/money`, `/geo` and `/uuid`: the package values (for `Package.shapeOnly`) and codecs for host types (`currencyAsString`, `wgs84Types`, `uuidAsString`); their rules need no codec.
- `Haus.compileSchemaFile` and `Haus.fromSchemaFile` are no longer exported (they skipped packages' rules): compile `Sources`.

`@haus-fmt/haus`: the compact and minimised writers (the compiled closures and the generated code) check a map key's length, and every encoder a byte string's, as the generic path and the constructors do (`key-too-long`, `string-too-long`).
