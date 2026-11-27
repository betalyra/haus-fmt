# Official extensions

Ordinary haus schemas, maintained with haus (spec §13). Each one is a
language-neutral package:

| File | What it is |
|---|---|
| `package.haus` | The manifest: name and version, and `rules`, which of its types have a rule (spec/packages.md §4). Name and version make the identity of its types, the same in every language: `@haus-fmt/money@1#Money`. |
| `schema.haus` | The schema, the package's one schema file. Shape only, like every haus schema. |
| `profiles/<name>.md` | A rule: a definition of the package's types, beyond the shape, which every binding checks (spec/packages.md §6). The directory becomes `rules/` when the bindings read it there. |
| `profiles/<name>.vectors.haus` | The rule's test vectors: examples of the rule that every implementation must pass. They test the rule and don't define it. |
| `lean/` | The rule's reference model in Lean, built by `spec/lean` and run by its `haus-rules` executable. |

The manifest's version is the package's version. Today `package.json`,
`Cargo.toml` and `python/pyproject.toml` carry the same version, which
changesets bumps in `package.json` and `typescript/scripts/sync-versions.mts`
copies into the others (and `package.haus`); that changes when the official
packages move into the bindings' libraries (packages round).

The same schema is published for each language from this one source: the
`package.json` publishes it to npm, the `Cargo.toml` makes it a crate (its
build script generates the Rust types), `python/` is a Python package (its
build copies the files into the module), and `roc/` is a Roc package with the
module generated from it (`roc/examples/gen.sh`).

Each package also ships the codecs of its profiles, tested against the vectors:

| Language | Package | Codecs |
|---|---|---|
| TypeScript, `h.*` schemas | `@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid` (`ts/`) | `import { iso } from "@haus-fmt/money"`, `{ wgs84 }` from `"@haus-fmt/geo"`, `{ rfc9562 }` from `"@haus-fmt/uuid"`: `compileSchemaFile(text, { …, codecs: [...iso, ...wgs84, ...rfc9562] })` |
| TypeScript, Effect | the same, `/effect` | `import { iso } from "@haus-fmt/money/effect"`: `Haus.decode(Order, iso, wgs84, rfc9562)` |
| Python | `haus-fmt-money`, `haus-fmt-geo`, `haus-fmt-uuid` (`python/`), imported as `haus_money`, `haus_geo`, `haus_uuid` | `load_schema(path, packages=[haus_money.PACKAGE], codecs=haus_money.iso \| haus_geo.wgs84 \| haus_uuid.rfc9562)` |
| Rust | the crates `haus-fmt-money`, `haus-fmt-geo`, `haus-fmt-uuid` (`src/`), imported as `haus_money`, `haus_geo`, `haus_uuid` | in `build.rs`: `.codec("@haus-fmt/money@1#Money", "haus_money::Iso")`, `haus_money::IsoCurrency`, `haus_geo::Wgs84`, `haus_geo::Wgs84BBox`, `haus_uuid::Rfc9562` ([rust/README.md](../rust/README.md)) |
| Roc | the Roc packages (`roc/`) | modules `Iso`, `IsoCurrency`, `Wgs84`, `Wgs84BBox`, `Rfc9562`: `haus-gen roc … --codec "@haus-fmt/money@1#Money=money.Iso"` ([roc/README.md](../roc/README.md)) |
| Go | `github.com/betalyra/haus-fmt/go/ext/money`, `…/ext/geo`, `…/ext/uuid` (in the Go module, `go/ext/`) | `schema.NewCodecs(money.Iso, money.IsoCurrency, geo.Wgs84, geo.Wgs84BBox, uuid.Rfc9562)`, passed as `DecodeOptions{Codecs: …}` ([go/README.md](../go/README.md)); the schemas are found like any package's |
| JVM | in the `haus` library (`org.hausfmt.ext.*`) | `Codecs.of(MoneyCodecs.ISO, MoneyCodecs.ISO_CURRENCY, GeoCodecs.WGS84, GeoCodecs.WGS84_BBOX, UuidCodecs.RFC9562)`, passed as `DecodeOptions.DEFAULT.withCodecs(…)` ([jvm/README.md](../jvm/README.md)) |
| Zig | in the Zig package (`zig/src/codecs.zig`) | `haus.Codecs.init(gpa, &(haus.codecs.money.iso ++ haus.codecs.geo.wgs84))`, passed as `.codecs = &codecs` ([zig/README.md](../zig/README.md)); the schemas are given as packages (`packages.Options.folders`, or embedded as a `packages.Tree`); none for `@haus-fmt/uuid` yet |

There is no haus registry (spec §13.3, *Distribution*). Anyone can publish a
schema package as an ordinary dependency: to npm, crates.io, PyPI or a private
registry, as a git dependency, or as a copy in the project. Name it after
something you own (`@your-domain/…`, `@your-github-org/…`), give it no install
scripts, and publish every language from one source.

| Package | Types | Rules |
|---|---|---|
| [`@haus-fmt/money`](money) | `Money`, `Currency` | `iso`: currency codes are three letters A–Z |
| [`@haus-fmt/geo`](geo) | `LatLng`, `BBox` | `wgs84`: latitude and longitude in range |
| [`@haus-fmt/uuid`](uuid) | `Uuid` | `rfc9562`: the RFC 9562 text form in lowercase, any version |
