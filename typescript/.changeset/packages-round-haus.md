---
"@haus-fmt/haus": minor
"@haus-fmt/import": minor
---

The packages round (packages 0.2) and values checked when built: a new API, breaking (0.x minor).

- **Results, no exceptions.** Every fallible function gives a `Result` (`Result.succeed`, `fail`, `map`, `flatMap`, `match`, `isSuccess`, `isFailure`, the shape of Effect 4's) and `pipe`; `parse`, `parseAll`, `formatText`, `importJson`, `fromHausJson`, `parsePlain`, `parseWith` and every schema call included. The throwing functions live on in `@haus-fmt/haus/internal`, for first-party tools only.
- **Values checked when built.** `Value.number`, `string`, `bytes`, `array`, `record`, `variant` give Results and apply the default limits of spec §7 (string, key, tag and number lengths, 256 levels, 64 Mi values written out); each container records its `size` and `depth`. The writers, `canonical`, `equals`, `compare` and `toHausJson` are total and take no limits; `hash` and `hashAll` give a Promise that never rejects. A value changed after it was built throws `value-changed` from them. Writer options are checked when made (`WriteOptions.make`).
- **Schemas from files, read apart from compiling.** `readSources(path, { packages, folders, root })` (`@haus-fmt/haus/node`) or `Sources.make(entry, files)` from data, then `Schema.compile`. Types are decoded and encoded with typed handles: `Schema.decode(schema, Order)(text)`, `Schema.encode`, `Schema.stringify`, `Schema.toJson`, `Schema.fromJson`, `Schema.decodeStream`, `Schema.standard` (a Standard Schema).
- **Packages as values, nothing looked for.** No `node_modules` search anywhere (`nodeResolver`, `schemaOptions`, `readSchemaFile` and the `npm` option are gone). The official packages are built in (`@haus-fmt/haus/money`, `/geo`, `/uuid`, with their handles and rules) and can't be replaced; other packages are given as values (`Sources.withPackage`, `Package.make`) or directories (`readPackage`, `readPackages`).
- **Rules on by default.** A package's rules (its manifest's `rules` field) are checked on every value of their type, before any codec: `Money(1, Eur)` is `codec-rejected`. A reached rule without an implementation is `missing-codec` at compile; `Package.withRule` supplies one, `Package.shapeOnly` opts out.
- **Codecs as typed pairs.** `Codec.make(type, { decode, encode })` and `Schema.withCodec`; the declarations `@haus-fmt/import` generates take the codecs' host types (`Order<H>`). Two codecs for one id, or one for a generic or Stream type, are a `HausConfigError`.
- **Secrets.** Encoding refuses a `Secret` (`cannot-encode` at the secret) unless `revealSecrets: true`.
- **`h.*` is gone** as a way to write schemas in code (`@haus-fmt/haus/schema` and `@haus-fmt/haus/plain` are no longer exported): schemas come from `.schema.haus` files, typed by `@haus-fmt/import`; for schemas in code, use `@haus-fmt/effect`.
- **`@haus-fmt/import`**: the plain target exports a schema file's compiled `schema` and a handle per type; the `npm` option is gone, `bundles` imports a library's package value; packages are never looked for.
