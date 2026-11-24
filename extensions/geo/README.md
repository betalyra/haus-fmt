# @haus-fmt/geo

A haus schema package: points and boxes on the earth, WGS 84.

```sh
npm install @haus-fmt/geo @haus-fmt/haus
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/geo (LatLng)

type Root = { at: LatLng }
```

The schema gives the shape. The profile `wgs84` says which values are valid
(`profiles/wgs84.md`). Pass its codecs when you compile and values that break the
rule are rejected; without them you get a `missing-codec` warning.

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import { wgs84 } from "@haus-fmt/geo"

const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: wgs84 })
h.parse(schemas.Root!, `{ at: LatLng(52.52, 13.405) }`)   // ok
h.parse(schemas.Root!, `{ at: LatLng(95.0, 13.405) }`)   // HausDecodeError
```

With Effect: `import { wgs84 } from "@haus-fmt/geo/effect"`, then `Haus.decode(Root, wgs84)`.

Other languages: [extensions](https://github.com/betalyra/haus-fmt/tree/main/extensions).
