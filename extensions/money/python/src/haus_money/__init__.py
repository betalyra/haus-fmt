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
from haus.schema import CodecGroup, Tagged, Unknown

__all__ = ["CURRENCY", "MONEY", "PACKAGE", "IsoCurrency", "IsoMoney", "is_currency", "iso"]


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
        if reason := _currency_error(value):
            raise ValueError(reason)
        assert isinstance(value, Unknown)
        return value.value.tag

    def encode(self, value: object, /) -> Unknown:
        if not is_currency(value):
            raise ValueError("expected a currency of the iso profile: a str of three letters A to Z")
        assert isinstance(value, str)
        return Unknown(Variant(value, ()))


def _currency_error(value: object) -> str:
    """Why a `Currency` the schema decoded (an `Unknown`) breaks the iso rule, or `""`."""
    if not isinstance(value, Unknown):
        return "expected a currency tag"
    tag, args = value.value.tag, value.value.args
    if args or not is_currency(tag):
        shown = tag if len(tag) <= 20 else tag[:20] + "…"
        return f"{shown}{'(…)' if args else ''} is not a currency of the iso profile: three letters A to Z"
    return ""


class IsoMoney:
    """`Money` with the iso profile: its host value is unchanged, `Tagged("Money", (amount, currency))`
    with the currency as the codec for `Currency` made it.

    Its rule is checked on the value the schema decoded (`check`, spec §13.4): a `Money` is accepted
    exactly when its currency is a currency of the iso profile, whatever codec the application sets for
    `Currency`. With `IsoCurrency` the two agree; with a looser one of the application's, `Money(1, Bitcoin)`
    is still rejected.
    """

    def check(self, value: object, /) -> None:
        payload = value.payload if isinstance(value, Tagged) else None
        if not isinstance(payload, tuple) or len(payload) != 2:
            raise TypeError("expected a Money")
        if reason := _currency_error(payload[1]):
            raise ValueError(reason)

    def decode(self, value: object, /) -> object:
        return value

    def encode(self, value: object, /) -> object:
        return value


iso: CodecGroup = CodecGroup({CURRENCY: IsoCurrency(), MONEY: IsoMoney()})
"""The profile's codecs, by type id. A group: a schema without a `Money` or `Currency` takes it too."""
