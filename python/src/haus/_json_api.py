"""The JSON forms that need no schema: the JSON import (spec §16.1) and self-describing
JSON (§16.2), and JSON Lines of them.

Schema-based JSON (§16.3) is `haus.schema.SchemaType.to_json` and `from_json`.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator

from ._decode import checked
from ._json import (
    Json,
    envelope,
    from_envelope,
    haus_json_depth,
    imported,
    read_json,
    read_lines,
    self_describing,
    write_json,
)
from ._parser import DEFAULT_LIMITS, Limits, make_room
from ._stream import DEFAULT_MAX_VALUE_LENGTH, Readable
from ._value import Value

# ── the JSON import (§16.1) ──────────────────────────────────


def import_json(text: str | bytes, *, limits: Limits = DEFAULT_LIMITS) -> Value:
    """Any JSON text as a haus value (spec §16.1), read strictly as I-JSON within `limits`.

    Objects are records, `true`/`false`/`null` are `True`/`False`/`None`, and numbers keep
    their text (normalized): `19.90` stays `19.90`, never a float. Nothing in the data is
    special: `{"_tag": "A"}` is a record.

        >>> import_json('{"price": 19.90, "ok": true}')
        Record(fields={'price': Number(text='19.90'), 'ok': Variant(tag='True', args=())})

    Raises `HausJsonError`: with a line and column for text that isn't I-JSON, with a path for a
    string or key beyond the string limit (counted on the haus value: after escapes are read).
    """
    make_room(limits.max_depth)
    return imported(read_json(text, limits), limits)


def import_json_lines(
    source: str | bytes | Readable | Iterable[str | bytes],
    *,
    limits: Limits = DEFAULT_LIMITS,
    max_line_length: int = DEFAULT_MAX_VALUE_LENGTH,
) -> Iterator[Value]:
    """Each line of JSON Lines as a haus value (spec §16.1), from a text, a file or chunks split anywhere."""

    def convert(j: Json, i: int) -> Value:
        make_room(limits.max_depth)
        return imported(j, limits, path=(i,))

    return read_lines(source, limits, limits.max_depth, convert, max_line_length)


# ── self-describing JSON (§16.2) ─────────────────────────────


def to_haus_json(value: Value, *, limits: Limits = DEFAULT_LIMITS) -> str:
    """The self-describing JSON of a haus value (spec §16.2), on one line: every value has exactly one.

        >>> import haus
        >>> haus.to_haus_json(haus.parse('Circle { r: 1.50 }'))
        '{"_haus":1,"_value":{"_tag":"Circle","_args":[{"_rec":{"r":{"_num":"1.50"}}}]}}'

    Raises `haus.schema.HausEncodeError` if a value built in code isn't valid haus within `limits`.
    """
    value = checked(value, limits, json=True)
    make_room(limits.max_depth)
    return write_json(envelope(self_describing(value)))


def from_haus_json(text: str | bytes, *, limits: Limits = DEFAULT_LIMITS) -> Value:
    """The haus value of a self-describing JSON text (spec §16.2). Every other JSON is rejected.

    The text must be the envelope `{"_haus": 1, "_value": …}`. Raises `HausJsonError`: with a
    line and column for text that isn't I-JSON (or holds raw DEL, C1 or bidi controls), with a
    path for JSON that isn't a self-describing form (no envelope, a bare number, `{"_num": "01"}`).
    """
    make_room(limits.max_depth)
    return from_envelope(read_json(text, limits, haus_json_depth(limits), strict=True), limits)


def to_haus_json_lines(values: Iterable[Value], *, limits: Limits = DEFAULT_LIMITS) -> Iterator[str]:
    """Each value's self-describing JSON (its own envelope) followed by a line feed: JSON Lines."""
    for i, v in enumerate(values):
        value = checked(v, limits, i, json=True)
        make_room(limits.max_depth)
        yield write_json(envelope(self_describing(value))) + "\n"


def from_haus_json_lines(
    source: str | bytes | Readable | Iterable[str | bytes],
    *,
    limits: Limits = DEFAULT_LIMITS,
    max_line_length: int = DEFAULT_MAX_VALUE_LENGTH,
) -> Iterator[Value]:
    """Each line of self-describing JSON Lines (an envelope each) as a haus value.

    Errors in a line's form carry its index first in their path.
    """

    def convert(j: Json, i: int) -> Value:
        make_room(limits.max_depth)
        return from_envelope(j, limits, (i,))

    return read_lines(source, limits, haus_json_depth(limits), convert, max_line_length, strict=True)
