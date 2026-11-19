"""The haus schema package @haus-fmt/money (`Money`, `Currency`), with the codecs of its profile `iso`.

    import haus_money
    from haus import schema

    s = schema.load_schema("order.schema.haus", packages=[haus_money.PACKAGE], codecs=haus_money.iso)
    s["Order"].parse("{ total: Money(19.90, EUR) }")  # {'total': Tagged(tag='Money', payload=('19.90', 'EUR'))}
    s["Order"].parse("{ total: Money(19.90, Eur) }")  # HausDecodeError: not a currency of the iso profile

The profile's rule is `profiles/iso.md` in the package directory. The codec keeps the value (spec §13.4):
the amount is the default host type, the exact `Decimal` text (`"19.90"`), and a `Currency` is its tag (`"EUR"`),
where the schema alone gives an `Unknown`.
"""

from __future__ import annotations

import re
from pathlib import Path

from haus import Variant
from haus.schema import CodecGroup, Unknown

__all__ = ["CURRENCY", "MONEY", "PACKAGE", "IsoCurrency", "is_currency", "iso"]


def _package() -> Path:
    here = Path(__file__).resolve().parent
    # A wheel has the package's files next to this module; a source checkout has them in the extension's directory.
    return here if (here / "package.haus").is_file() else here.parents[2]


PACKAGE: Path = _package()
"""The schema package's directory (`package.haus`, `schema.haus`, `profiles/`): pass it as one of `packages`."""

MONEY = "@haus-fmt/money@1#Money"
CURRENCY = "@haus-fmt/money@1#Currency"

_CODE = re.compile(r"[A-Z]{3}")


def is_currency(tag: object) -> bool:
    """Whether the iso profile accepts a currency tag: three characters, each `A` to `Z`."""
    return isinstance(tag, str) and _CODE.fullmatch(tag) is not None


class IsoCurrency:
    """`Currency` with the iso profile, as its tag: a `str` of three letters `A` to `Z`.

    It rejects a tag of another shape and a tag with a payload (`CHF(1)`). Applied wherever a `Currency` occurs,
    it also decides which `Money` is accepted: exactly those whose currency is.
    """

    def decode(self, value: object, /) -> str:
        if not isinstance(value, Unknown):
            raise TypeError("expected a currency tag")
        tag, args = value.value.tag, value.value.args
        if args or not is_currency(tag):
            shown = tag if len(tag) <= 20 else tag[:20] + "…"
            raise ValueError(
                f"{shown}{'(…)' if args else ''} is not a currency of the iso profile: three letters A to Z"
            )
        return tag

    def encode(self, value: object, /) -> Unknown:
        if not is_currency(value):
            raise ValueError("expected a currency of the iso profile: a str of three letters A to Z")
        assert isinstance(value, str)
        return Unknown(Variant(value, ()))


iso: CodecGroup = CodecGroup({CURRENCY: IsoCurrency()})
"""The profile's codecs, by type id. A group: a schema without a `Currency` takes it too."""
