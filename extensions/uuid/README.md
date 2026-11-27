# @haus-fmt/uuid

A haus schema package: universally unique identifiers, RFC 9562.

```sh
npm install @haus-fmt/uuid @haus-fmt/haus
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/uuid (Uuid)

type Root = { id: Uuid }
```

The schema gives the shape. The profile `rfc9562` says which values are valid
(`profiles/rfc9562.md`). Pass its codecs when you compile and values that break the
rule are rejected; without them you get a `missing-codec` warning.

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import { rfc9562 } from "@haus-fmt/uuid"

const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: rfc9562 })
h.parse(schemas.Root!, `{ id: Uuid("0190b4f2-6c1e-7a3b-8d2f-4e5a6b7c8d9e") }`)   // ok
h.parse(schemas.Root!, `{ id: Uuid("0190B4F2-6C1E-7A3B-8D2F-4E5A6B7C8D9E") }`)   // HausDecodeError
```

With Effect: `@haus-fmt/effect` has the package built in, its rule rfc9562 on by default (`Haus.compile`); `@haus-fmt/effect/uuid` exports the package value (`uuid`, for `Haus.Package.shapeOnly`) and `uuidAsString`, a codec giving every `Uuid` as its text.

Other languages: [extensions](https://github.com/betalyra/haus-fmt/tree/main/extensions).
