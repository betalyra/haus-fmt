# haus-fmt-uuid

The haus schema package [`@haus-fmt/uuid`](https://github.com/betalyra/haus-fmt/tree/main/extensions/uuid)
(`Uuid`) for Python, with the codecs of its profile `rfc9562`. Imported as `haus_uuid`.

```sh
pip install haus-fmt-uuid
```

```haus-schema
// user.schema.haus
import @haus-fmt/uuid (Uuid)
type User = { id: Uuid }
```

```python
import haus_uuid
from haus import schema

s = schema.load_schema("user.schema.haus", packages=[haus_uuid.PACKAGE], codecs=haus_uuid.rfc9562)
s["User"].parse('{ id: Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57") }')  # {'id': '0190c7a8-…'}
s["User"].parse('{ id: Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57") }')  # HausDecodeError: not a UUID
```

`haus_uuid.PACKAGE` is the package's directory (`package.haus`, `schema.haus`, `profiles/`).
`haus_uuid.rfc9562` is the profile's codec (a `schema.CodecGroup`; combine groups with `|`): a
`Uuid` is accepted when its text is 32 digits `0`-`9`, `a`-`f` in groups 8-4-4-4-12, joined by
hyphens, lowercase only, of any version, and it decodes to that text, a `str`.
`haus_uuid.rfc9562_as_uuid` checks the same and decodes to a `uuid.UUID` instead. Both keep the
value: the text is the UUID's one spelling, and `str()` of a `uuid.UUID` writes it. The rule:
[`profiles/rfc9562.md`](https://github.com/betalyra/haus-fmt/tree/main/extensions/uuid/profiles/rfc9562.md).
