"""Mutated documents for the spot check before timing (bench/speed/ts/mutate.ts, ported): each
JSON baseline must reject them. A mutation is made where the document's JSON Schema types a
value, at a place where convert's reader rejects it too, so haus's typed parse would:

    type      a typed value replaced by one of another JSON type (a string by 12345, a
              number or boolean by "x", an object or array by "x")
    missing   a required member removed
    enum      an enum value replaced by one the enum doesn't list
    format    a date-time or date replaced by "not a date"
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Any, Literal

from .models import DEFINITIONS, JsonSchema

MutationKind = Literal["type", "missing", "enum", "format"]
MUTATION_KINDS: tuple[MutationKind, ...] = ("type", "missing", "enum", "format")

Path = tuple[str | int, ...]


@dataclass(frozen=True, slots=True)
class _Site:
    kind: MutationKind
    path: Path
    key: str | None = None
    value: Any = None


@dataclass(frozen=True, slots=True)
class Mutated:
    kind: MutationKind
    doc: int
    where: str
    value: Any


def _sites(file: JsonSchema, root: str, value: Any, limit: int = 4) -> list[_Site]:
    """The places in `value` where each kind of mutation can be made (the first few of each kind)."""
    defs: dict[str, JsonSchema] = file["definitions"]
    sites: list[_Site] = []

    def add(s: _Site) -> None:
        # (not the whole document replaced: too easy to reject)
        if sum(x.kind == s.kind for x in sites) < limit and (s.kind == "missing" or s.path):
            sites.append(s)

    def resolve(s: JsonSchema) -> JsonSchema:
        for _ in range(64):
            if not isinstance(s.get("$ref"), str):
                break
            s = defs[s["$ref"].removeprefix(DEFINITIONS)]
        return s

    def walk(schema: JsonSchema, v: Any, path: Path, depth: int) -> None:
        if depth > 40:
            return
        s = resolve(schema)
        if not s or v is None:
            return  # Any, or a null where null is allowed
        if isinstance(s.get("anyOf"), list):
            return walk(s["anyOf"][1], v, path, depth + 1)
        types = s["type"] if isinstance(s.get("type"), list) else [s.get("type")]
        t = next((x for x in types if x != "null"), None)
        if t == "string":
            if isinstance(s.get("enum"), list):
                add(_Site("enum", path, value="not-a-value-of-the-enum"))
            if "format" in s:
                add(_Site("format", path, value="not a date"))
            add(_Site("type", path, value=12345))
            return
        if t in ("integer", "number", "boolean"):
            return add(_Site("type", path, value="x"))
        if t == "array" and isinstance(v, list):
            add(_Site("type", path, value="x"))
            for i, x in enumerate(v[:3]):
                walk(s["items"], x, (*path, i), depth + 1)
            return
        if t != "object" or not isinstance(v, dict):
            return
        add(_Site("type", path, value="x"))
        if "additionalProperties" in s:
            for k, x in list(v.items())[:3]:
                walk(s["additionalProperties"], x, (*path, k), depth + 1)
            return
        if "discriminator" in s:
            member = s["discriminator"]["propertyName"]
            branch = next((b for b in s["oneOf"] if b["properties"][member]["const"] == v.get(member)), None)
            return None if branch is None else walk(branch, v, path, depth + 1)
        if isinstance(s.get("allOf"), list):
            case = next((c for c in s["allOf"] if all(k in v for k in c["if"]["required"])), None)
            return None if case is None else walk(case["then"], v, path, depth + 1)
        for k in s.get("required", ()):
            if k in v:
                add(_Site("missing", path, key=k))
        for k, p in s.get("properties", {}).items():
            if k in v:
                walk(p, v[k], (*path, k), depth + 1)
        return None

    walk({"$ref": f"{DEFINITIONS}{root}"}, value, (), 0)
    return sites


def _apply(value: Any, site: _Site) -> Any:
    out = copy.deepcopy(value)
    parent_path = site.path if site.kind == "missing" else site.path[:-1]
    parent = out
    for k in parent_path:
        parent = parent[k]
    if site.kind == "missing":
        del parent[site.key]
    else:
        parent[site.path[-1]] = site.value
    return out


def mutations(file: JsonSchema, roots: list[str], values: list[Any], per_kind: int = 5) -> list[Mutated]:
    """Up to `per_kind` mutated documents of each kind, from the first documents that have such a place."""
    out: list[Mutated] = []

    def count(kind: MutationKind) -> int:
        return sum(m.kind == kind for m in out)

    for doc, v in enumerate(values):
        if all(count(k) >= per_kind for k in MUTATION_KINDS):
            break
        for site in _sites(file, roots[doc], v):
            if count(site.kind) >= per_kind:
                continue
            where = "$" + "".join(f".{k}" for k in site.path) + (f".{site.key}" if site.key else "")
            out.append(Mutated(site.kind, doc, where, _apply(v, site)))
            break  # one mutation per document
    return out
