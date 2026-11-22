"""The canonical form, equality and hashing (spec §12): one exact text per
value, the same in every binding. Equal values (§2) have identical canonical
forms, so `hash` is the same whatever the layout, comments, key order or
spelling of the document the value came from.

    >>> import haus
    >>> haus.canonical(haus.parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }'))
    'Order{id:255,total:19.90,"x-y":1e5}'

Every value has a canonical form: the constructors build only haus values (spec §11, §12),
with their numbers normalized.

    >>> haus.canonical(haus.Number("1E+05")) == haus.canonical(haus.parse("1e5"))
    True

They have one limit, the node limit (spec §7, `Limits.max_nodes`): a value built in code whose
parts share each other (an array holding the same array twice, nested) is small in memory but
writes each shared part once for every place it is in. Above the limit, `HausEncodeError` with
the code `too-many-nodes`, at the value. No other limit applies: a value deeper or longer than a
writer's limits still has a canonical form. There is no maximum depth: `canonical`, `hash`,
`hash_all`, `equals` and `compare` walk a value with a stack of their own, not Python's call
stack, so any depth works (spec §7, §12).
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable, Iterator, Mapping
from itertools import chain, repeat
from typing import Final

from ._errors import HausEncodeError, PathKey
from ._parser import DEFAULT_LIMITS, Limits
from ._scan import ESCAPED, key_text, quote
from ._value import Array, Number, Record, String, Value, Variant

_Children = Iterator[tuple[str, Value]]
"""What is left to write of a container: each child with the text before it (`,`, `key:`, `,key:`)."""

_FIRST_KEYS: dict[str, str] = {}
"""`key:` of keys written before: field names repeat, from record to record and value to value."""
_NEXT_KEYS: dict[str, str] = {}
"""`,key:` the same way."""
_KEYS_KEPT: Final = 4096
"""At most this many keys in each of them (they start over when full), each at most `_KEY_KEPT` long."""
_KEY_KEPT: Final = 64


def _key_prefix(key: str, keys: dict[str, str], comma: str) -> str:
    text = keys.get(key)
    if text is None:
        text = f"{comma}{key_text(key)}:"
        if len(key) <= _KEY_KEPT:
            if len(keys) >= _KEYS_KEPT:
                keys.clear()
            keys[key] = text
    return text


def _fields(fields: Mapping[str, Value]) -> _Children:
    # `str` order is code point order, which is the order of the UTF-8 bytes.
    keys = sorted(fields)
    texts = [_NEXT_KEYS.get(k) or _key_prefix(k, _NEXT_KEYS, ",") for k in keys]
    if keys:
        texts[0] = _FIRST_KEYS.get(keys[0]) or _key_prefix(keys[0], _FIRST_KEYS, "")
    return zip(texts, map(fields.__getitem__, keys), strict=True)


def _items(values: tuple[Value, ...]) -> _Children:
    return zip(chain(("",), repeat(",")), values, strict=False)


def _numbers(values: tuple[Value, ...]) -> list[str] | None:
    """The texts of an array of numbers (a vector, coordinates), written at once; None for any other."""
    if not values or type(values[0]) is not Number:
        return None
    texts = [x.text for x in values if type(x) is Number]
    return texts if len(texts) == len(values) else None


def _too_many(max_nodes: int, path: tuple[PathKey, ...], operand: str) -> HausEncodeError:
    return HausEncodeError(
        f"{operand}more than {max_nodes} values to write (parts that share each other are written each time)",
        path,
        "too-many-nodes",
    )


def canonical(value: Value, *, limits: Limits = DEFAULT_LIMITS) -> str:
    """The canonical form of a value (spec §12): integers are written in decimal, however long.

    Iterative, with a stack of the open containers, so any depth works. Scalars are written where
    they are met; a container is opened, and its children are written before the rest of its parent's.

    Raises `HausEncodeError` (`too-many-nodes`) for a value that would write more values than
    `limits.max_nodes`, counting each place a shared part is in; no other limit applies.
    """
    return canonical_at(value, limits.max_nodes, ())


def canonical_at(value: Value, max_nodes: int, path: tuple[PathKey, ...], operand: str = "") -> str:
    """`canonical`, with the node limit, failing at `path`. The values are counted a container's children at a time.

    `operand` starts the error's message: which value of `equals` or `compare` it is."""
    nodes = 1  # the value itself
    if nodes > max_nodes:
        raise _too_many(max_nodes, path, operand)
    out: list[str] = []
    write = out.append
    escaped = ESCAPED.search
    stack: list[tuple[_Children, str]] = []
    children: _Children = iter((("", value),))
    closer = ""
    while True:
        for prefix, v in children:
            write(prefix)
            # The most common first.
            if type(v) is String:
                s = v.value
                write(f'"{s}"' if escaped(s) is None else quote(s))
                continue
            if type(v) is Number:
                write(v.text)
                continue
            if type(v) is Record:
                fields = v.fields
                nodes += len(fields)
                write("{")
                inner, inner_closer = _fields(fields), "}"
            elif type(v) is Array:
                items = v.items
                nodes += len(items)
                if (texts := _numbers(items)) is not None and nodes <= max_nodes:
                    write("[" + ",".join(texts) + "]")
                    continue
                write("[")
                inner, inner_closer = _items(items), "]"
            elif type(v) is Variant:
                match v.args:
                    case ():
                        write(v.tag)
                        continue
                    case (Record(fields),):
                        nodes += 1 + len(fields)  # the record, and its field values
                        write(v.tag + "{")
                        inner, inner_closer = _fields(fields), "}"
                    case args:
                        nodes += len(args)
                        write(v.tag + "(")
                        inner, inner_closer = _items(args), ")"
            else:
                write(f'x"{v.data.hex()}"')
                continue
            if nodes > max_nodes:
                raise _too_many(max_nodes, path, operand)
            stack.append((children, closer))
            children, closer = inner, inner_closer
            break
        else:
            write(closer)
            if not stack:
                return "".join(out)
            children, closer = stack.pop()


def equals(a: Value, b: Value, *, limits: Limits = DEFAULT_LIMITS) -> bool:
    """Whether two values are equal (spec §2): the same normalized literals, and so the same canonical form.

    Compares canonical forms, so it has their node limit (`too-many-nodes` at `$`, its message
    saying which value, see `canonical`).
    """
    max_nodes = limits.max_nodes
    return canonical_at(a, max_nodes, (), "the first value: ") == canonical_at(b, max_nodes, (), "the second value: ")


def compare(a: Value, b: Value, *, limits: Limits = DEFAULT_LIMITS) -> int:
    """Orders values by the bytes of their canonical forms (spec §12): -1, 0 or 1.

    A total order consistent with `equals`, for sorting
    (`sorted(values, key=functools.cmp_to_key(compare))`) and ordered maps.
    Not numeric order: `10` sorts before `9`. Has the node limit of `canonical` (as `equals`).
    """
    max_nodes = limits.max_nodes
    x, y = canonical_at(a, max_nodes, (), "the first value: "), canonical_at(b, max_nodes, (), "the second value: ")
    return (x > y) - (x < y)


def hash(value: Value, *, limits: Limits = DEFAULT_LIMITS) -> str:
    """The SHA-256 digest of the canonical form, as 64 lowercase hex digits (spec §12).

    Has the node limit of `canonical` (`too-many-nodes`).
    """
    return hashlib.sha256(canonical(value, limits=limits).encode("utf-8")).hexdigest()


def hash_all(values: Iterable[Value], *, limits: Limits = DEFAULT_LIMITS) -> str:
    """The hash of a list of values, such as a whole file (spec §12).

    The SHA-256 digest of their canonical forms joined by `,`. A list of one
    value hashes like the value: `hash_all([v]) == hash(v)`. The items of a
    stream are hashed one by one with `hash`. The node limit of `canonical`
    applies to each value on its own (`too-many-nodes` at its index).
    """
    max_nodes = limits.max_nodes
    text = ",".join(canonical_at(v, max_nodes, (i,)) for i, v in enumerate(values))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()
