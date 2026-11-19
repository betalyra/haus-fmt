# haus-fmt-money

The haus schema package [`@haus-fmt/money`](https://github.com/betalyra/haus-fmt/tree/main/extensions/money)
(`Money`, `Currency`) for Python, with the codecs of its profile `iso`. Imported as `haus_money`.

```sh
pip install haus-fmt-money
```

```haus-schema
// order.schema.haus
import @haus-fmt/money (Money)
type Order = { total: Money }
```

```python
import haus_money
from haus import schema

s = schema.load_schema("order.schema.haus", packages=[haus_money.PACKAGE], codecs=haus_money.iso)
s["Order"].parse("{ total: Money(19.90, EUR) }")  # {'total': Tagged(tag='Money', payload=('19.90', 'EUR'))}
s["Order"].parse("{ total: Money(19.90, Eur) }")  # HausDecodeError: Eur is not a currency of the iso profile
```

`haus_money.PACKAGE` is the package's directory (`package.haus`, `schema.haus`, `profiles/`).
`haus_money.iso` is the profile's codecs (a `schema.CodecGroup`; combine groups with `|`): a
`Currency` is accepted when its tag is three letters `A`–`Z` without payload, wherever it occurs,
so a `Money` is accepted exactly when its currency is. The codec keeps the value: the amount is
its exact `Decimal` text (`"19.90"`), and a currency is its tag (`"EUR"`) instead of the
`Unknown` the schema alone gives. The rule: [`profiles/iso.md`](https://github.com/betalyra/haus-fmt/tree/main/extensions/money/profiles/iso.md).
