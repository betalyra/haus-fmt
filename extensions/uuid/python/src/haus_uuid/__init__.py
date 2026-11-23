"""The haus schema package @haus-fmt/uuid (`Uuid`), with the codecs of its profile `rfc9562`.

    import haus_uuid
    from haus import schema

    s = schema.load_schema("user.schema.haus", packages=[haus_uuid.PACKAGE], codecs=haus_uuid.rfc9562)
    s["User"].parse('{ id: Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57") }')  # {'id': '0190c7a8-5b6e-…'}
    s["User"].parse('{ id: Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57") }')  # HausDecodeError: not a UUID

The profile's rule is `profiles/rfc9562.md` in the package directory: 32 digits `0`-`9`, `a`-`f` in groups
8-4-4-4-12, joined by hyphens, lowercase only, any version. The text is the UUID's one spelling, so both
codecs keep the value (spec §13.4): `rfc9562` gives the text as a `str`, `rfc9562_as_uuid` a `uuid.UUID`
(whose `str()` is that text).
"""

from __future__ import annotations

import re
import uuid as _uuid
from pathlib import Path

from haus.schema import CodecGroup, Tagged

__all__ = ["PACKAGE", "UUID", "Rfc9562AsUUID", "Rfc9562Uuid", "is_uuid", "rfc9562", "rfc9562_as_uuid"]


def _package() -> Path:
    here = Path(__file__).resolve().parent
    # A wheel has the package's files next to this module; a source checkout has them in the extension's directory.
    return here if (here / "package.haus").is_file() else here.parents[2]


PACKAGE: Path = _package()
"""The schema package's directory (`package.haus`, `schema.haus`, `profiles/`): pass it as one of `packages`."""

UUID = "@haus-fmt/uuid@1#Uuid"

_TEXT = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

_REJECTED = "not a UUID of the rfc9562 profile: 32 digits 0-9, a-f in groups of 8-4-4-4-12, joined by hyphens"


def is_uuid(text: object) -> bool:
    """Whether the rfc9562 profile accepts a UUID's text: 32 digits `0`-`9`, `a`-`f` in groups 8-4-4-4-12."""
    return isinstance(text, str) and _TEXT.fullmatch(text) is not None


def _text(value: object) -> str:
    """The text of a `Uuid` as the schema decodes it, `Tagged("Uuid", (text,))`, checked."""
    if not (isinstance(value, Tagged) and value.tag == "Uuid" and isinstance(value.payload, tuple)):
        raise TypeError("expected a Uuid")
    (text,) = value.payload
    if not is_uuid(text):
        raise ValueError(_REJECTED)
    assert isinstance(text, str)
    return text


class Rfc9562Uuid:
    """`Uuid` with the rfc9562 profile, as its text: a `str`, `"0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"`."""

    def decode(self, value: object, /) -> str:
        return _text(value)

    def encode(self, value: object, /) -> Tagged:
        if not is_uuid(value):
            raise ValueError(f"expected a str: {_REJECTED}")
        return Tagged("Uuid", (value,))


class Rfc9562AsUUID:
    """`Uuid` with the rfc9562 profile, as a `uuid.UUID`. Keeps the value: the text is the UUID's one
    spelling, and `str()` of a `uuid.UUID` writes it."""

    def decode(self, value: object, /) -> _uuid.UUID:
        return _uuid.UUID(_text(value))

    def encode(self, value: object, /) -> Tagged:
        if not isinstance(value, _uuid.UUID):
            raise TypeError("expected a uuid.UUID")
        return Tagged("Uuid", (str(value),))


rfc9562: CodecGroup = CodecGroup({UUID: Rfc9562Uuid()})
"""The profile's codec, by type id, with the text as a `str`. A group: a schema without a `Uuid` takes it too."""

rfc9562_as_uuid: CodecGroup = CodecGroup({UUID: Rfc9562AsUUID()})
"""The profile's codec, by type id, with a `uuid.UUID`. A group: a schema without a `Uuid` takes it too."""
