# @haus-fmt/import

Import `.haus` files in TypeScript, with types:

```ts
import people from "./people.haus"              // no schema: typed by its data
import { Comment } from "./thread.schema.haus"  // a schema file: its types and schemas
import thread from "./thread.haus"              // typed by thread.schema.haus, checked against it
```

Two parts make an import work, and both come from one generator
([`generate.ts`](src/generate.ts)), so the types always match the values:

| Part | Gives | Set up |
|---|---|---|
| TypeScript 7.1 content mapper | the types, in the editor and in `tsc` | `tsconfig.json` |
| Node loader | the values when you run with Node or tsx | `--import @haus-fmt/import/register` |
| Vite plugin | the values in a Vite dev server or build | `vite.config.ts` |

## Targets

| Target | `.schema.haus` | data with a schema | data without a schema | needs |
|---|---|---|---|---|
| `"plain"` (default) | haus schemas (Standard Schemas) | decoded with them | plain JS values | nothing |
| `"effect"` | Effect schemas | decoded with Effect | plain JS values | `effect`, `@haus-fmt/effect` |

Plain, without a schema: strings, `bigint` for whole numbers, `string` for decimals
(exact), `boolean`, `Uint8Array`, string literal unions for tags without payload,
`{ _tag, … }` for other variants, `None` and `Some(x)` included (`{ _tag: "None" }`,
`{ _tag: "Some", value: x }`, so `Some(None)` stays apart from `None`), `key?:` for
fields only some records have.

Plain, with a schema: the same, plus `Int8` … `UInt32` and floats → `number`, std/time values → their text as written,
`Maybe a` → `Maybe<A>` (the same tagged form), `Map` → `ReadonlyMap`, open variants add `Unknown`, `Any` → `Value` (the parsed
value, unchanged) and `Secret a` → `Secret<A>`
(see [`@haus-fmt/haus`](../haus)).
With Effect: `Int` → `bigint`, `Decimal` → `string` (exact), std/time values → their text as written,
`Maybe` → `Option`, `Any` → `Haus.Value` and `Secret a` → `Redacted<A>`
(see [`@haus-fmt/effect`](../effect)). Every target keeps the value as
written; Effect's `BigDecimal` and `DateTime`, which don't, are codecs you
pass when decoding (`Haus.decimalAsBigDecimal`, `Haus.instantAsDateTime`).

A secret shows `<redacted>` when logged, and errors about one (at load time,
or in the editor) never show its value. Types, fields and tags marked
`@deprecated` in the schema are `@deprecated` in the declarations, so editors
strike them through.

Use the same target everywhere.

## Setup

```jsonc
// tsconfig.json (tsc 7.1: run it with --runExternalCode)
"contentMappers": [
  { "package": "@haus-fmt/import", "extensions": [".haus"], "options": { "target": "effect" } }
]
```

```sh
node --import @haus-fmt/import/register main.ts          # target "plain"
node --import @haus-fmt/import/register/effect main.ts   # target "effect"
```

```ts
// vite.config.ts
import haus from "@haus-fmt/import/vite"
export default { plugins: [haus({ target: "effect" })] }
```

With Vite, data without a schema is baked into the bundle as JavaScript values,
so no haus parser ships for it. Schema imports (`import @haus-fmt/money`) are resolved at
build time, and the schema files are watched.

In VS Code, typed imports need the TypeScript native preview extension, a trusted
workspace and permission to run content mappers.

## Schema packages

Schema imports (`import @acme/money (Money)`) find packages in `node_modules`,
from the real path of the importing file, when the nearest `package.json`
declares them. Packages outside `node_modules` (vendored, or from a Cargo or
Python project) are given with the same options everywhere:

| Option | |
|---|---|
| `packages` | package directories (with `package.haus` and `schema.haus`), used instead of an installed package with the same name |
| `folders` | folders whose direct subdirectories with a `package.haus` are packages; one also installed in `node_modules` must have the same files |
| `npm` | `false`: only `packages` and `folders`, never `node_modules` (default `true`) |

Paths are relative to the project root: the directory of `tsconfig.json` for
the content mapper, Vite's `root` for the plugin, the working directory for the
Node loader. Give the same packages to all three, so the types match the values.

```jsonc
// tsconfig.json
"contentMappers": [
  { "package": "@haus-fmt/import", "extensions": [".haus"], "options": { "packages": ["vendor/money"], "folders": ["schemas"] } }
]
```

```ts
// vite.config.ts
export default { plugins: [haus({ packages: ["vendor/money"], folders: ["schemas"] })] }

// register.ts, then: node --import ./register.ts main.ts
import { register } from "@haus-fmt/import/node"
await register({ packages: ["vendor/money"], folders: ["schemas"] })
```

A package directory or folder that doesn't exist is an error when the loader
starts, not at some import.

## Optimizing hot schemas

A schema read or written very often can use generated code instead of the
default closures (12–40% faster for one type used over and over). The
`optimize` option (plain target) builds that code ahead, into the schema
file's module, and switches the listed types to it when the module loads: no
`eval` (under a strict content security policy too), and no change to your code:

```ts
// vite.config.ts
export default { plugins: [haus({ optimize: { "src/github.schema.haus": ["Issue"] } })] }

// register.ts, then: node --import ./register.ts main.ts
import { register } from "@haus-fmt/import/node"
await register({ optimize: { "src/github.schema.haus": ["Issue"] } })
```

```ts
import { Issue } from "./github.schema.haus"
h.parse(Issue, text)   // the code built ahead for Issue
```

| `optimize` option | `h.optimize(Issue)` in the code | what runs for `Issue` |
|---|---|---|
| no | no | closures (the default); no generated code in the bundle |
| no | yes | code made at first use with `new Function` (needs `eval`) |
| yes, lists `Issue` | not needed | code built ahead, no `eval` |

Only the listed types, and the types they reach (`User` inside `Issue`), get
code in the module; a module without the option has none, so bundles stay
small. A reached type that isn't listed keeps the closures unless you call
`h.optimize(User)`, which then uses the code built ahead too. Code for a whole large schema file can run to megabytes, so list only
the types you measured as hot. Paths are relative to the project root (Vite's
`root`, the working directory for the Node loader); a schema file or type that
doesn't exist is an error when the loader starts. The content mapper ignores
the option: types are the same either way.

At first use, the code is generated again from the schemas and must be the
same as the code built ahead (the module carries it as text too); otherwise,
after a change the module didn't see, `new Function` or the closures take
over. Values, texts and errors are the same on every path.

## Without imports

To parse haus text yourself, use [`@haus-fmt/haus`](../haus): `parsePlain(text)` for the
plain values, or `parseWith(schema, text)` with any Standard Schema (Zod, Valibot,
ArkType, Effect Schema).
