"""The codecs of the profile @haus-fmt/uuid/rfc9562: its vectors (profiles/rfc9562.vectors.haus) and its edge cases."""

from __future__ import annotations

import uuid
from collections.abc import Mapping
from typing import cast

import haus
import pytest
from haus import schema
from haus.schema import CodecGroup, HausDecodeError, HausEncodeError, Tagged

import haus_uuid

BASE = schema.load_schema(haus_uuid.PACKAGE / "schema.haus")

_VECTOR = schema.compile_schema("""
    type Vector = closed <
      Accept { type: String, value: String, output?: String, note?: String }
      | Reject { type: String, value: String, note?: String }
    >
""")["Vector"]
VECTORS = [
    cast(Tagged, _VECTOR.decode(v))
    for v in haus.parse_all((haus_uuid.PACKAGE / "profiles/rfc9562.vectors.haus").read_text())
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


@pytest.mark.parametrize("codecs", [haus_uuid.rfc9562, haus_uuid.rfc9562_as_uuid], ids=["str", "uuid.UUID"])
@pytest.mark.parametrize("vector", VECTORS, ids=_name)
def test_vector(vector: Tagged, codecs: CodecGroup) -> None:
    f = _fields(vector)
    coded, base = schema.load_schema(haus_uuid.PACKAGE / "schema.haus", codecs=codecs)[f["type"]], BASE[f["type"]]
    base.parse(f["value"])  # valid under the schema: what the codec rejects, the profile rejects
    if vector.tag == "Reject":
        with pytest.raises(HausDecodeError) as e:
            coded.parse(f["value"])
        assert e.value.code == "codec-rejected"
        return
    decoded = coded.parse(f["value"])
    encoded = coded.canonical(decoded)
    assert encoded == _normal(f["type"], f.get("output", f["value"]))
    # The codec changes no value: it writes what the schema alone decodes; decode, encode, decode is decode.
    assert encoded == _normal(f["type"], f["value"])
    assert coded.parse(encoded) == decoded


ID = "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"
RESOLVER = schema.FileResolver(".", [haus_uuid.PACKAGE])
USER = "import @haus-fmt/uuid (Uuid)\ntype User = { id: Uuid, friends: Array Uuid }"
TEXT = f'{{ id: Uuid("{ID}"), friends: [Uuid("00000000-0000-0000-0000-000000000000")] }}'
REJECTED = [
    ID.upper(),
    f"{{{ID}}}",
    f"urn:uuid:{ID}",
    ID.replace("-", ""),
    ID[1:],
    ID + "0",
    " " + ID,
    ID + "\n",
    ID[:35] + "\N{ARABIC-INDIC DIGIT SEVEN}",  # a digit that isn't ASCII
    "",
    "0190c7a-85b6e-7d3f-9a41-6c2e8f1b0d57",
    ID.replace("-", "0", 1),
    ID.replace("d", "g"),
]


CANONICAL = f'{{friends:[Uuid("00000000-0000-0000-0000-000000000000")],id:Uuid("{ID}")}}'


def _uuid_text(text: str) -> str:
    """`Uuid("…")` with the text quoted, as haus writes it."""
    return BASE["Uuid"].canonical(Tagged("Uuid", (text,)))


def test_the_text_as_a_str() -> None:
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562)["User"]
    assert user.parse(TEXT) == {"id": ID, "friends": ("00000000-0000-0000-0000-000000000000",)}
    assert user.canonical(user.parse(TEXT)) == CANONICAL


def test_the_text_as_a_uuid() -> None:
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562_as_uuid)["User"]
    v = user.parse(TEXT)
    assert v == {"id": uuid.UUID(ID), "friends": (uuid.UUID(int=0),)}
    assert user.canonical(v) == CANONICAL
    assert user.canonical({"id": uuid.UUID(int=2**128 - 1), "friends": ()}) == (
        '{friends:[],id:Uuid("ffffffff-ffff-ffff-ffff-ffffffffffff")}'
    )


@pytest.mark.parametrize("codecs", [haus_uuid.rfc9562, haus_uuid.rfc9562_as_uuid], ids=["str", "uuid.UUID"])
@pytest.mark.parametrize("text", REJECTED)
def test_every_other_spelling_is_rejected(text: str, codecs: CodecGroup) -> None:
    assert not haus_uuid.is_uuid(text)
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=codecs)["User"]
    with pytest.raises(HausDecodeError) as e:
        user.parse(f"{{ id: {_uuid_text(text)}, friends: [] }}")
    assert e.value.code == "codec-rejected"


def test_no_version_is_checked() -> None:
    for version in "0123456789abcdef":
        assert haus_uuid.is_uuid(f"0190c7a8-5b6e-{version}d3f-{version}a41-6c2e8f1b0d57")


def test_it_applies_inside_imported_types() -> None:
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562)["User"]
    with pytest.raises(HausDecodeError) as e:
        user.parse(f'{{ id: Uuid("{ID}"), friends: [Uuid("{ID.upper()}")] }}')
    assert (e.value.code, e.value.path) == ("codec-rejected", ("friends", 0))


def test_it_checks_what_it_encodes() -> None:
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562)["User"]
    with pytest.raises(HausEncodeError):
        user.encode({"id": ID.upper(), "friends": ()})
    as_uuid = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562_as_uuid)["User"]
    with pytest.raises(HausEncodeError):
        as_uuid.encode({"id": ID, "friends": ()})


def test_json_goes_through_the_codec() -> None:
    user = schema.compile_schema(USER, resolver=RESOLVER, codecs=haus_uuid.rfc9562_as_uuid)["User"]
    v = user.parse(TEXT)
    assert user.from_json(user.to_json(v)) == v


def test_a_group_takes_schemas_without_its_types() -> None:
    assert schema.compile_schema("type T = { n: Int }", codecs=haus_uuid.rfc9562)["T"].parse("{ n: 1 }") == {"n": 1}
