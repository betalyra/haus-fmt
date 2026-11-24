# @haus-fmt/money

A haus schema package: exact amounts with a currency.

```sh
npm install @haus-fmt/money @haus-fmt/haus
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/money (Money)

type Root = { total: Money }
```

The schema gives the shape. The profile `iso` says which values are valid
(`profiles/iso.md`). Pass its codecs when you compile and values that break the
rule are rejected; without them you get a `missing-codec` warning.

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import { iso } from "@haus-fmt/money"

const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: iso })
h.parse(schemas.Root!, `{ total: Money(19.90, EUR) }`)   // ok
h.parse(schemas.Root!, `{ total: Money(19.90, Eur) }`)   // HausDecodeError
```

With Effect: `import { iso } from "@haus-fmt/money/effect"`, then `Haus.decode(Root, iso)`.

Other languages: [extensions](https://github.com/betalyra/haus-fmt/tree/main/extensions).
