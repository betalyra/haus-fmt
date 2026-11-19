# Official extensions

Ordinary haus schemas, maintained with haus (spec §13). Each one is a
language-neutral package:

| File | What it is |
|---|---|
| `package.haus` | The manifest: name and version. They make the identity of its types, the same in every language: `@haus-fmt/money@1#Money`. |
| `schema.haus` | The schema, the package's one schema file. Shape only, like every haus schema. |
| `profiles/<name>.md` | A profile's rule: what a codec implementing it accepts, beyond the shape (spec §13.3). |
| `profiles/<name>.vectors.haus` | The profile's test vectors: examples of the rule that every codec must pass. |

The same schema is published for each language from this one source: the
`package.json` publishes it to npm, the `Cargo.toml` makes it a crate (its
build script generates the Rust types), `python/` is a Python package (its
build copies the files into the module), and `roc/` is a Roc package with the
module generated from it (`roc/examples/gen.sh`).

Each package also ships the codecs of its profiles, tested against the vectors:

| Language | Package | Codecs |
|---|---|---|
| TypeScript, `h.*` schemas | `@haus-fmt/money`, `@haus-fmt/geo` (`ts/`) | `import { iso } from "@haus-fmt/money"`, `{ wgs84 }` from `"@haus-fmt/geo"`: `compileSchemaFile(text, { …, codecs: [...iso, ...wgs84] })` |
| TypeScript, Effect | the same, `/effect` | `import { iso } from "@haus-fmt/money/effect"`: `Haus.decode(Order, iso, wgs84)` |
| Python | `haus-fmt-money`, `haus-fmt-geo` (`python/`), imported as `haus_money`, `haus_geo` | `load_schema(path, packages=[haus_money.PACKAGE], codecs=haus_money.iso \| haus_geo.wgs84)` |
| Rust | the crates `haus-fmt-money`, `haus-fmt-geo` (`src/`), imported as `haus_money`, `haus_geo` | in `build.rs`: `.codec("@haus-fmt/money@1#Money", "haus_money::Iso")`, `haus_money::IsoCurrency`, `haus_geo::Wgs84`, `haus_geo::Wgs84BBox` ([rust/README.md](../rust/README.md)) |
| Roc | the Roc packages (`roc/`) | modules `Iso`, `IsoCurrency`, `Wgs84`, `Wgs84BBox`: `haus-gen roc … --codec "@haus-fmt/money@1#Money=money.Iso"` ([roc/README.md](../roc/README.md)) |

There is no haus registry (spec §13.3, *Distribution*). Anyone can publish a
schema package as an ordinary dependency: to npm, crates.io, PyPI or a private
registry, as a git dependency, or as a copy in the project. Name it after
something you own (`@your-domain/…`, `@your-github-org/…`), give it no install
scripts, and publish every language from one source.

| Package | Types | Profiles |
|---|---|---|
| [`@haus-fmt/money`](money) | `Money`, `Currency` | `iso`: currency codes are three letters A–Z |
| [`@haus-fmt/geo`](geo) | `LatLng`, `BBox` | `wgs84`: latitude and longitude in range |
