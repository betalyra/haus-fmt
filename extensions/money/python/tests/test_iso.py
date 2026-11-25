"""The codecs of the profile @haus-fmt/money/iso: its vectors (profiles/iso.vectors.haus) and its edge cases."""

from __future__ import annotations

from collections.abc import Mapping
from typing import cast

import haus
import pytest
from haus import schema
from haus.schema import HausDecodeError, HausEncodeError, Tagged

import haus_money

BASE = schema.load_schema(haus_money.PACKAGE / "schema.haus")
CODED = schema.load_schema(haus_money.PACKAGE / "schema.haus", codecs=haus_money.iso)

_VECTOR = schema.compile_schema("""
    type Vector = closed <
      Accept { type: String, value: String, output?: String, note?: String }
      | Reject { type: String, value: String, looser?: Array String, note?: String }
    >
""")["Vector"]


class _Looser:
    """An application's codec that accepts every value of its type's schema: looser than the profile."""

    def decode(self, value: object, /) -> object:
        return value

    def encode(self, value: object, /) -> object:
        return value


def _with_looser(types: tuple[str, ...]) -> schema.Schema:
    """The iso codecs, with a looser codec of the application's for each type named (`looser`)."""
    looser = {f"@haus-fmt/money@1#{t}": _Looser() for t in types}
    codecs = {i: c for i, c in haus_money.iso.items() if i not in looser} | looser
    return schema.load_schema(haus_money.PACKAGE / "schema.haus", codecs=codecs)


VECTORS = [
    cast(Tagged, _VECTOR.decode(v))
    for v in haus.parse_all((haus_money.PACKAGE / "profiles/iso.vectors.haus").read_text())
]


def _fields(v: Tagged) -> Mapping[str, str]:
    return cast(Mapping[str, str], v.payload)


def _name(v: Tagged) -> str:
    return f"{v.tag} {_fields(v)['type']} {_fields(v)['value']}"


def _normal(type: str, text: str) -> str:
    """The value's canonical text, decoded with the schema alone (spec §15)."""
    return BASE[type].canonical(BASE[type].parse(text))


def test_the_vectors_are_read() -> None:
    assert {v.tag for v in VECTORS} == {"Accept", "Reject"}


@pytest.mark.parametrize("vector", VECTORS, ids=_name)
def test_vector(vector: Tagged) -> None:
    f = _fields(vector)
    coded, base = CODED[f["type"]], BASE[f["type"]]
    base.parse(f["value"])  # valid under the schema: what the codec rejects, the profile rejects
    if vector.tag == "Reject":
        with pytest.raises(HausDecodeError) as e:
            coded.parse(f["value"])
        assert e.value.code == "codec-rejected"
        if looser := cast(tuple[str, ...], f.get("looser", ())):
            # A profile's rule is checked on the values the schema decoded (spec §13.4).
            with pytest.raises(HausDecodeError) as e:
                _with_looser(looser)[f["type"]].parse(f["value"])
            assert e.value.code == "codec-rejected"
        return
    decoded = coded.parse(f["value"])
    encoded = coded.canonical(decoded)
    assert encoded == _normal(f["type"], f.get("output", f["value"]))
    # The codec changes no value: it writes what the schema alone decodes; decode, encode, decode is decode.
    assert encoded == _normal(f["type"], f["value"])
    assert coded.parse(encoded) == decoded


ORDER = schema.compile_schema(
    "import @haus-fmt/money (Money)\ntype Order = { total: Money, refunds: Array Money }",
    resolver=schema.FileResolver(".", [haus_money.PACKAGE]),
    codecs=haus_money.iso,
)["Order"]


def test_the_currency_is_its_tag() -> None:
    assert ORDER.parse("{ total: Money(19.90, EUR), refunds: [] }") == {
        "total": Tagged("Money", ("19.90", "EUR")),
        "refunds": (),
    }


@pytest.mark.parametrize("amount", ["19.90", "-3", "0.00005", "1.5e3", "15e2", "-0", "-0.00"])
def test_the_amount_is_kept_exactly(amount: str) -> None:
    text = f"{{ total: Money({amount}, EUR), refunds: [] }}"
    assert ORDER.canonical(ORDER.parse(text)) == f"{{refunds:[],total:Money({amount},EUR)}}"


def test_it_applies_inside_imported_types() -> None:
    with pytest.raises(HausDecodeError, match="Usd is not a currency of the iso profile") as e:
        ORDER.parse("{ total: Money(1, EUR), refunds: [Money(1, Usd)] }")
    assert (e.value.code, e.value.path) == ("codec-rejected", ("refunds", 0, 1))


@pytest.mark.parametrize("currency", ["Eur", "EURO", "EU", "E1R", "EUR(1)", "EUR { x: 1 }", "E_R"])
def test_it_rejects_other_shapes(currency: str) -> None:
    with pytest.raises(HausDecodeError):
        ORDER.parse(f"{{ total: Money(1, {currency}), refunds: [] }}")


def test_it_checks_what_it_encodes() -> None:
    with pytest.raises(HausEncodeError):
        ORDER.encode({"total": Tagged("Money", ("1", "eur")), "refunds": ()})
    with pytest.raises(HausEncodeError):
        ORDER.encode({"total": Tagged("Money", ("1", 978)), "refunds": ()})


def test_json_goes_through_the_codec() -> None:
    order = ORDER.parse("{ total: Money(19.90, EUR), refunds: [] }")
    assert ORDER.from_json(ORDER.to_json(order)) == order


def test_a_group_takes_schemas_without_its_types() -> None:
    assert schema.compile_schema("type T = { n: Int }", codecs=haus_money.iso)["T"].parse("{ n: 1 }") == {"n": 1}
