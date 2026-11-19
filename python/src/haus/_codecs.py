"""Opt-in host types (codecs, spec §13.4). Each keeps less than the haus value,
so encoding what it decoded can give a different value (another hash): the
application chooses them explicitly, by type id.

    schema.compile_schema(text, codecs={"prelude#Decimal": DecimalCodec()})
"""

from __future__ import annotations

import datetime as dt
import re
from collections.abc import Iterator, Mapping
from decimal import Decimal, InvalidOperation

from ._decode import Codec

_FRACTION = re.compile(r"(\.[0-9]{6})[0-9]+")


class DecimalCodec:
    """`Decimal` as `decimal.Decimal`. Drops the spelling of the exponent.

    `decimal.Decimal` keeps the scale (`19.90`) and `-0`, but not how the exponent was
    written: `15e2` and `1.5e3` are both `Decimal('1.5E+3')`, written back as `1.5e3`.
    Its `==` also ignores scale (`Decimal("19.90") == Decimal("19.9")`), unlike haus (§3).
    """

    def decode(self, value: object, /) -> Decimal:
        assert isinstance(value, str)
        try:
            return Decimal(value)
        except InvalidOperation:
            raise ValueError("not a decimal") from None

    def encode(self, value: object, /) -> object:
        if not isinstance(value, Decimal) or not value.is_finite():
            raise TypeError("expected a finite decimal.Decimal")
        return value


class DateCodec:
    """std/time `Date` as `datetime.date`. Keeps the value; rejects the year 0000, which Python lacks."""

    def decode(self, value: object, /) -> dt.date:
        assert isinstance(value, str)
        return dt.date.fromisoformat(value)

    def encode(self, value: object, /) -> object:
        if not isinstance(value, dt.date) or isinstance(value, dt.datetime):
            raise TypeError("expected a datetime.date")
        return value.isoformat()


class InstantCodec:
    """std/time `Instant` as an aware `datetime.datetime`. Keeps the instant and its offset.

    Drops: digits of the fraction beyond microseconds (truncated), the spelling of the
    fraction (`.25` is written `.250000`), and `Z` versus `+00:00` (written `Z`).
    Rejects the year 0000.
    """

    def decode(self, value: object, /) -> dt.datetime:
        assert isinstance(value, str)
        return dt.datetime.fromisoformat(_FRACTION.sub(r"\1", value))

    def encode(self, value: object, /) -> object:
        if not isinstance(value, dt.datetime) or value.utcoffset() is None:
            raise TypeError("expected an aware datetime.datetime")
        text = value.isoformat()
        return text.removesuffix("+00:00") + "Z" if value.utcoffset() == dt.timedelta(0) else text


class CodecGroup(Mapping[str, Codec]):
    """Codecs by type id that are given together, such as a profile's (spec §13.3): unlike in a plain
    mapping, a member for a type the schema doesn't have is not an error.

    `|` combines groups and mappings: a plain mapping's members stay checked, and two codecs for one
    type are a `ValueError`.

        schema.load_schema(path, packages=[...], codecs=haus_money.iso | haus_geo.wgs84)
    """

    __slots__ = ("_codecs", "_optional")

    def __init__(self, codecs: Mapping[str, Codec], /) -> None:
        self._codecs: dict[str, Codec] = dict(codecs)
        self._optional: frozenset[str] = frozenset(self._codecs)

    @property
    def optional(self) -> frozenset[str]:
        """The ids whose codecs a schema may lack: the members of groups."""
        return self._optional

    def __getitem__(self, id: str) -> Codec:
        return self._codecs[id]

    def __iter__(self) -> Iterator[str]:
        return iter(self._codecs)

    def __len__(self) -> int:
        return len(self._codecs)

    def __repr__(self) -> str:
        return f"CodecGroup({self._codecs!r})"

    def __or__(self, other: Mapping[str, Codec]) -> CodecGroup:
        return CodecGroup._merge(self, other)

    def __ror__(self, other: Mapping[str, Codec]) -> CodecGroup:
        return CodecGroup._merge(other, self)

    @staticmethod
    def _merge(a: Mapping[str, Codec], b: Mapping[str, Codec]) -> CodecGroup:
        if both := a.keys() & b.keys():
            raise ValueError(f"two codecs for {', '.join(sorted(both))}")
        merged = CodecGroup({**a, **b})
        merged._optional = optional_codecs(a) | optional_codecs(b)
        return merged


def optional_codecs(codecs: Mapping[str, Codec]) -> frozenset[str]:
    """The ids of `codecs` that a schema may lack (those of a `CodecGroup`)."""
    return codecs.optional if isinstance(codecs, CodecGroup) else frozenset()
