---
title: Python
description: Parse haus into values you can match on, or decode it with a schema into dicts, tuples and tagged values.
---

Parse haus into frozen dataclasses you can `match` on, or decode it with a schema file into `dict`s, `tuple`s, `int`s and `Tagged` values. Pure Python, no dependencies, Python 3.11 or later.

## Install

```sh
pip install haus-fmt
```

## Read and write

```python
import haus
from haus import Record, Variant

order = haus.parse('{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }')

match order:
    case Record({"status": Variant("Shipped", (Record(fields),))}):
        print(fields["tracking"])  # String(value='DE-4711')

haus.parse("19.90").to_decimal()  # Decimal('19.90'): numbers are exact, never floats
haus.stringify(order, style="compact")  # '{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }'
```

`haus.parse_all` reads a file of several values (a stream); `haus.format` reformats text and keeps its comments.

## With a schema

```python
from haus import schema

s = schema.compile_schema("""
    type Line = { sku: String, qty: UInt16 }
    type Order = { id: Int, lines: Array Line, note?: Maybe String }
""")

order = s["Order"].parse('{ id: 7, lines: [{ sku: "TEA-01", qty: 2 }], note: None }')
# {'id': 7, 'lines': ({'sku': 'TEA-01', 'qty': 2},), 'note': Nothing()}
haus.stringify(s["Order"].encode(order), style="compact")  # back to haus text
```

`schema.load_schema("order.schema.haus")` reads a schema file and the files it imports. A value that doesn't fit raises `HausDecodeError` with its place and code:

```python
s["Order"].parse('{ id: 7, lines: [{ sku: "TEA-01", qty: -1 }] }')
# HausDecodeError: -1 is out of range for UInt16 (0 to 65535) at $.lines[0].qty   (e.code == "out-of-range")
```

`Maybe` is `Some(x)` or `Nothing()`, never Python's `None`: a missing optional field is a missing key, and `None` in the data is `Nothing()`. Variants are `Tagged("Shipped", {"tracking": …})`, and a tag an open variant doesn't list is `Unknown(raw)`. All of them: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Packages and codecs.** Python never searches for schema packages: give their directories. The official ones ship their profiles' codecs:

```python
import haus_geo, haus_money  # pip install haus-fmt-money haus-fmt-geo

s = schema.load_schema(
    "order.schema.haus",
    packages=[haus_money.PACKAGE, haus_geo.PACKAGE],
    codecs=haus_money.iso | haus_geo.wgs84,
)
s["Root"].parse(text)  # Money(44.40, Eur): HausDecodeError, codec-rejected at $.total[1]
```

Without the codecs, `s.warnings` ends with a [`missing-codec`](/docs/errors#missing-codec) warning for each profiled type, and only the shape is checked. A codec of your own is any object with `decode` and `encode`. [What haus checks](/docs/checks)

- **Other host types.** `DecimalCodec` gives `decimal.Decimal`, `DateCodec` `datetime.date`, `InstantCodec` an aware `datetime`. They keep less than the haus value, so they are opt-in: `codecs={"std/time#Date": schema.DateCodec()}`.
- **Streams.** `haus.parse_stream(f)` yields each value as its comma arrives; `s["Events"].parse_stream(f)` decodes them too. `haus.StreamReader` does no I/O, for sockets and event loops. [Logs and streams](/docs/tours/streams)
- **JSON.** `s["Order"].to_json(order)` gives `{"id":"7","lines":[…],"note":null}`; `from_json` reads it back with the same checks. `haus.import_json` reads any JSON as haus. [Coming from JSON](/docs/from-json)
- **Secrets.** `Secret a` decodes to a `Secret`: `str`, `repr` and logs show `<redacted>`, `expose()` gives the value. [Config and secrets](/docs/tours/secrets)
- **Limits.** `haus.Limits(max_depth=…)` sets the spec's limits; the depth is at most 512.
- **Errors.** Every error is a `haus.HausError` (a `ValueError`) with `code`, `hint` and `to_json()`. [Error codes](/docs/errors)

## More

- [README of `haus-fmt`](https://github.com/betalyra/haus-fmt/tree/main/python): formatting, JSON, imports and packages in full.
- The [money](https://github.com/betalyra/haus-fmt/tree/main/extensions/money/python) and [geo](https://github.com/betalyra/haus-fmt/tree/main/extensions/geo/python) packages for Python.
- [A tour of haus](/docs/tour). Python has no `quickstart` and `order` examples yet.
