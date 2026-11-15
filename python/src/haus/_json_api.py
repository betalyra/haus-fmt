"""The JSON mappings that need no schema (spec §16.1, §16.2), and JSON Lines of them.

The plain mapping with a type is `haus.schema.SchemaType.to_json` and `from_json`.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator

from ._decode import checked
from ._json import Json, from_lossless, lossless, mapped_depth, read_json, read_lines, schemaless, write_json
from ._parser import DEFAULT_LIMITS, Limits, make_room
from ._stream import DEFAULT_MAX_VALUE_LENGTH, Readable
from ._value import Value


def from_json(text: str | bytes, *, limits: Limits = DEFAULT_LIMITS) -> Value:
    """Any JSON text as a haus value (spec §16.1), read strictly as I-JSON within `limits`.

    Objects are records, `true`/`false`/`null` are `True`/`False`/`None`, and numbers keep
    their text (normalized): `19.90` stays `19.90`, never a float.

        >>> from_json('{"price": 19.90, "ok": true}')
        Record(fields={'price': Number(text='19.90'), 'ok': Variant(tag='True', args=())})

    Raises `HausJsonError`, with a line and column.
    """
    make_room(limits.max_depth)
    return schemaless(read_json(text, limits))


def from_json_lines(
    source: str | bytes | Readable | Iterable[str | bytes],
    *,
    limits: Limits = DEFAULT_LIMITS,
    max_line_length: int = DEFAULT_MAX_VALUE_LENGTH,
) -> Iterator[Value]:
    """Each line of JSON Lines as a haus value (spec §16.1), from a text, a file or chunks split anywhere."""

    def convert(j: Json, _: int) -> Value:
        make_room(limits.max_depth)
        return schemaless(j)

    return read_lines(source, limits, limits.max_depth, convert, max_line_length)


def to_lossless_json(value: Value, *, limits: Limits = DEFAULT_LIMITS) -> str:
    """The lossless JSON of a haus value (spec §16.2), on one line: every value has exactly one.

        >>> import haus
        >>> haus.to_lossless_json(haus.parse('Circle { r: 1.50 }'))
        '{"tag":"Circle","args":[{"rec":{"r":{"num":"1.50"}}}]}'

    Raises `haus.schema.HausEncodeError` if a value built in code isn't valid haus within `limits`.
    """
    value = checked(value, limits)
    make_room(limits.max_depth)
    return write_json(lossless(value))


def from_lossless_json(text: str | bytes, *, limits: Limits = DEFAULT_LIMITS) -> Value:
    """The haus value of a lossless JSON text (spec §16.2). Every other JSON is rejected.

    Raises `HausJsonError`: with a line and column for text that isn't I-JSON, with a path
    for JSON that isn't a lossless form (a bare number, `null`, `{"num": "01"}`).
    """
    make_room(limits.max_depth)
    return from_lossless(read_json(text, limits, mapped_depth(limits)), limits)


def to_lossless_json_lines(values: Iterable[Value], *, limits: Limits = DEFAULT_LIMITS) -> Iterator[str]:
    """Each value's lossless JSON followed by a line feed: JSON Lines."""
    for i, v in enumerate(values):
        value = checked(v, limits, i)
        make_room(limits.max_depth)
        yield write_json(lossless(value)) + "\n"


def from_lossless_json_lines(
    source: str | bytes | Readable | Iterable[str | bytes],
    *,
    limits: Limits = DEFAULT_LIMITS,
    max_line_length: int = DEFAULT_MAX_VALUE_LENGTH,
) -> Iterator[Value]:
    """Each line of lossless JSON Lines as a haus value. Errors in a line's form carry its index first in their path."""

    def convert(j: Json, i: int) -> Value:
        make_room(limits.max_depth)
        return from_lossless(j, limits, 0, (i,))

    return read_lines(source, limits, mapped_depth(limits), convert, max_line_length)
