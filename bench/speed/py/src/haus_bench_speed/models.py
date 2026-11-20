"""The JSON baselines of the typed tasks: pydantic v2 models and msgspec Structs,
generated from the JSON Schema convert exports beside the haus schema
(`corpus/<source>.schema.json`, bench/size/src/jsonschema.ts: the haus schema's
types, said for the source's JSON through convert's JSON mapping), the way the
TypeScript benchmark builds Zod and Ajv from it (bench/speed/ts/validators.ts).
Each reads exactly that subset and raises on anything else.

    JSON Schema                 pydantic v2 (validated with strict=True)           msgspec (strict by default)
    string, integer, number,    str, int, float, bool                              the same
      boolean
    format date-time, date      AwareDatetime, date                                datetime with Meta(tz=True), date
    enum                        Literal[…]                                         Literal[…]
    T or null                   T | None                                           T | None
    items, additionalProperties list[T], dict[str, T]                              the same
    record (open)               a BaseModel (members it doesn't list ignored);     a Struct (unknown members ignored);
                                `field?` defaults to None, written with             `field?` defaults to UNSET, which is
                                exclude_unset                                      never written
    variant by a member         Annotated[A | B, Field(discriminator=member)],     tagged Structs (tag_field=member)
                                the member a Literal in each case
    variant by keys             Annotated[Union[…], Discriminator(f)]: f picks     a wrapper type that dec_hook builds:
                                the one case whose keys are all there              msgspec.convert to the one case whose
                                                                                   keys are all there
    {}                          Any                                                Any

The models are written as Python source and run as a module of their own, so
recursive types are plain forward references; a named variant is a `type`
statement (lazily evaluated). Member names that aren't plain identifiers are
renamed, with the JSON name as the alias (pydantic) or the field's name (msgspec).
"""

from __future__ import annotations

import keyword
import re
import sys
import types
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, Literal

import msgspec
import pydantic

DEFINITIONS = "#/definitions/"

JsonSchema = dict[str, Any]
Flavour = Literal["pydantic", "msgspec"]


def _name_of(ref: object) -> str:
    if not isinstance(ref, str) or not ref.startswith(DEFINITIONS):
        raise ValueError(f"a $ref outside the definitions: {ref!r}")
    return ref.removeprefix(DEFINITIONS)


def _is_null_schema(s: JsonSchema) -> bool:
    return s == {"type": "null"}


def keyed_cases(s: JsonSchema) -> list[tuple[tuple[str, ...], JsonSchema]] | None:
    """A variant by keys: `oneOf: [{ required }…], allOf: [{ if: { required }, then }…]`."""
    if "allOf" not in s:
        return None
    return [(tuple(c["if"]["required"]), c["then"]) for c in s["allOf"]]


def _identifier(text: str) -> str:
    return re.sub(r"\W", "_", text)


_RESERVED = frozenset(dir(pydantic.BaseModel)) | frozenset(dir(msgspec.Struct))


def _field_name(key: str, i: int) -> str:
    """The Python name of a member: the member itself where it can be."""
    plain = key.isidentifier() and not keyword.iskeyword(key) and key not in _RESERVED
    if plain and not key.startswith(("_", "model_")):
        return key
    return f"f{i}_{_identifier(key)}"


class _Codegen:
    """Writes the models of a JSON Schema file as Python source; the flavours differ in a few lines."""

    flavour: Flavour

    def __init__(self, file: JsonSchema) -> None:
        self.defs: dict[str, JsonSchema] = file["definitions"]
        self.classes: list[str] = []
        """Class definitions, in the order they were finished (annotations are strings: order doesn't matter)."""
        self.aliases: list[str] = []
        """`type` statements: evaluated on first use."""
        self.registrations: list[str] = []
        """Run after everything above: what needs the classes and aliases themselves."""
        self.named: dict[str, str] = {}
        self.expanding: set[str] = set()
        self.taken: set[str] = set()

    # ── names ───────────────────────────────────────────────

    def fresh(self, hint: str) -> str:
        base = _identifier(hint) or "T"
        if not base[0].isalpha():
            base = "T" + base
        name, n = base, 2
        while name in self.taken:
            name, n = f"{base}_{n}", n + 1
        self.taken.add(name)
        return name

    def ref(self, name: str) -> str:
        if (done := self.named.get(name)) is not None:
            return done
        s = self.defs[name]
        if self._is_named(s):
            return self._named(name, s)
        # Anything else is written out where it is used (no class or alias of its own).
        if name in self.expanding:
            raise ValueError(f"{name}: a type that refers to itself without a record or variant in between")
        self.expanding.add(name)
        expr = self.of(s, name)
        self.expanding.discard(name)
        self.named[name] = expr
        return expr

    @staticmethod
    def _is_named(s: JsonSchema) -> bool:
        return "discriminator" in s or "allOf" in s or (s.get("type") == "object" and "properties" in s)

    def _named(self, name: str, s: JsonSchema) -> str:
        """A record or variant definition, named before its parts are written, so they can refer to it."""
        py = self.fresh(name)
        self.named[name] = py
        if "properties" in s and "discriminator" not in s and "allOf" not in s:
            self.record(s, py)
        else:
            self.alias(py, self.variant(s, py))
        return py

    def alias(self, name: str, expr: str) -> None:
        self.aliases.append(f"type {name} = {expr}")

    # ── types ───────────────────────────────────────────────

    def of(self, s: JsonSchema, hint: str) -> str:
        if "$ref" in s:
            return self.ref(_name_of(s["$ref"]))
        if not s:
            return "Any"
        if "anyOf" in s:
            match s["anyOf"]:
                case [null, item] if _is_null_schema(null):
                    return self.nullable(self.of(item, hint))
                case _:
                    raise ValueError(f"anyOf other than [null, T]: {s}")
        if isinstance(s.get("type"), list):
            types_ = [t for t in s["type"] if t != "null"]
            if len(types_) != 1 or len(s["type"]) != 2:
                raise ValueError(f"type {s['type']}")
            single = {**s, "type": types_[0]}
            if "enum" in s:
                single["enum"] = [v for v in s["enum"] if v is not None]
            return self.nullable(self.of(single, hint))
        if "discriminator" in s or "allOf" in s:
            name = self.fresh(hint)
            self.alias(name, self.variant(s, name))
            return name
        match s.get("type"):
            case "string":
                if "enum" in s:
                    return f"Literal[{', '.join(repr(v) for v in s['enum'])}]"
                match s.get("format"):
                    case None:
                        return "str"
                    case "date-time":
                        return self.datetime
                    case "date":
                        return "date"
                    case f:
                        raise ValueError(f"format {f}")
            case "integer":
                return "int"
            case "number":
                return "float"
            case "boolean":
                return "bool"
            case "array":
                return f"list[{self.of(s['items'], hint + '_item')}]"
            case "object" if "additionalProperties" in s:
                return f"dict[str, {self.of(s['additionalProperties'], hint + '_value')}]"
            case "object" if "properties" in s:
                return self.record(s, self.fresh(hint))
            case _:
                raise ValueError(f"a schema the models don't read: {str(s)[:200]}")

    @staticmethod
    def nullable(expr: str) -> str:
        return expr if expr == "Any" else f"{expr} | None"

    def fields(self, s: JsonSchema, cls: str, skip: str | None = None) -> list[str]:
        required = set(s.get("required", ()))
        lines: list[str] = []
        for i, (key, p) in enumerate(s.get("properties", {}).items()):
            if key == skip:
                continue
            lines.append(self.field(key, _field_name(key, i), self.of(p, f"{cls}_{key}"), key in required))
        return lines

    def variant(self, s: JsonSchema, name: str) -> str:
        if "discriminator" in s:
            member = s["discriminator"]["propertyName"]
            cases = [
                self.case(b, f"{name}_{b['properties'][member]['const']}", member, b["properties"][member]["const"])
                for b in s["oneOf"]
            ]
            return self.discriminated(cases, member)
        keyed = keyed_cases(s)
        assert keyed is not None
        cases = [
            self.any_case(keys, f"{name}_{i}") if self.is_any(then) else self.of(then, f"{name}_{i}")
            for i, (keys, then) in enumerate(keyed)
        ]
        return self.by_keys(name, [keys for keys, _ in keyed], cases)

    def is_any(self, s: JsonSchema) -> bool:
        for _ in range(64):
            if "$ref" not in s:
                break
            s = self.defs[_name_of(s["$ref"])]
        return not s

    def record(self, s: JsonSchema, cls: str) -> str:
        self.write_class(cls, self.class_head(cls), self.fields(s, cls))
        return cls

    def write_class(self, cls: str, head: str, body: list[str]) -> None:
        self.classes.append("\n".join([head, *(f"    {line}" for line in body or ["pass"])]))

    # ── per flavour ─────────────────────────────────────────

    datetime = ""
    header = ""

    def class_head(self, cls: str) -> str:
        raise NotImplementedError

    def field(self, key: str, name: str, ann: str, required: bool) -> str:
        raise NotImplementedError

    def case(self, s: JsonSchema, hint: str, member: str, value: str) -> str:
        raise NotImplementedError

    def discriminated(self, cases: list[str], member: str) -> str:
        raise NotImplementedError

    def any_case(self, keys: tuple[str, ...], hint: str) -> str:
        raise NotImplementedError

    def by_keys(self, name: str, keysets: list[tuple[str, ...]], cases: list[str]) -> str:
        raise NotImplementedError

    def source(self) -> str:
        return "\n\n".join([self.header, *self.classes, *self.aliases, *self.registrations]) + "\n"


class _Pydantic(_Codegen):
    flavour: Flavour = "pydantic"
    datetime = "AwareDatetime"
    header = "\n".join(
        [
            "from __future__ import annotations",
            "from datetime import date",
            "from typing import Annotated, Any, Literal, Union",
            "from pydantic import AwareDatetime, BaseModel, ConfigDict, Discriminator, Field, Tag",
            "from haus_bench_speed.models import keyed_discriminator",
        ]
    )

    def class_head(self, cls: str) -> str:
        return f"class {cls}(BaseModel):"

    def field(self, key: str, name: str, ann: str, required: bool) -> str:
        alias = "" if name == key else f"alias={key!r}"
        if required:
            return f"{name}: {ann}" + (f" = Field({alias})" if alias else "")
        return f"{name}: {ann} = " + (f"Field(default=None, {alias})" if alias else "None")

    def case(self, s: JsonSchema, hint: str, member: str, value: str) -> str:
        cls = self.fresh(hint)
        head = self.field(member, _field_name(member, 0), f"Literal[{value!r}]", True)
        self.write_class(cls, self.class_head(cls), [head, *self.fields(s, cls, skip=member)])
        return cls

    def discriminated(self, cases: list[str], member: str) -> str:
        if len(cases) == 1:
            return cases[0]
        return f"Annotated[Union[{', '.join(cases)}], Field(discriminator={_field_name(member, 0)!r})]"

    def any_case(self, keys: tuple[str, ...], hint: str) -> str:
        cls = self.fresh(hint)
        body = ['model_config = ConfigDict(extra="allow")']
        body += [self.field(k, _field_name(k, i), "Any", True) for i, k in enumerate(keys)]
        self.write_class(cls, self.class_head(cls), body)
        return cls

    def by_keys(self, name: str, keysets: list[tuple[str, ...]], cases: list[str]) -> str:
        pick = f"_pick_{name}"
        self.registrations.append(f"{pick} = keyed_discriminator({keysets!r}, ({', '.join(cases)},))")
        tagged = ", ".join(f"Annotated[{c}, Tag({str(i)!r})]" for i, c in enumerate(cases))
        return f"Annotated[Union[{tagged}], Discriminator({pick})]"


class _Msgspec(_Codegen):
    flavour: Flavour = "msgspec"
    datetime = "Annotated[datetime, Meta(tz=True)]"
    header = "\n".join(
        [
            "from __future__ import annotations",
            "from datetime import date, datetime",
            "from typing import Annotated, Any, Literal",
            "import msgspec",
            "from msgspec import UNSET, Meta, Struct, UnsetType",
            "from haus_bench_speed.models import KEYED, Keyed",
        ]
    )

    def class_head(self, cls: str, tag: str = "") -> str:
        return f"class {cls}(Struct, kw_only=True{tag}):"

    def field(self, key: str, name: str, ann: str, required: bool) -> str:
        rename = "" if name == key else f"name={key!r}"
        if required:
            return f"{name}: {ann}" + (f" = msgspec.field({rename})" if rename else "")
        ann = ann if ann == "Any" else f"{ann} | UnsetType"
        return f"{name}: {ann} = " + (f"msgspec.field(default=UNSET, {rename})" if rename else "UNSET")

    def case(self, s: JsonSchema, hint: str, member: str, value: str) -> str:
        cls = self.fresh(hint)
        self.write_class(
            cls, self.class_head(cls, f", tag_field={member!r}, tag={value!r}"), self.fields(s, cls, skip=member)
        )
        return cls

    def discriminated(self, cases: list[str], member: str) -> str:
        return " | ".join(cases)

    def any_case(self, keys: tuple[str, ...], hint: str) -> str:
        return "dict[str, Any]"  # the keys are checked by the hook that picks the case

    def by_keys(self, name: str, keysets: list[tuple[str, ...]], cases: list[str]) -> str:
        wrapper = self.fresh(f"{name}_keyed")
        self.classes.append(f"class {wrapper}(Keyed):\n    __slots__ = ()")
        pairs = ", ".join(f"({keys!r}, {case})" for keys, case in zip(keysets, cases, strict=True))
        self.registrations.append(f"KEYED[{wrapper}] = ({pairs},)")
        return wrapper


# ── support code the generated modules import ───────────────


def keyed_discriminator(keysets: Sequence[tuple[str, ...]], cases: Sequence[object]) -> Callable[[object], str | None]:
    """pydantic's callable discriminator of a variant by keys: the one case whose keys are all there.

    Writing, it is given the case's model instead: its type picks the case.
    """
    by_type = {c: str(i) for i, c in enumerate(cases) if isinstance(c, type)}

    def pick(v: object) -> str | None:
        if isinstance(v, dict):
            found = [i for i, keys in enumerate(keysets) if all(k in v for k in keys)]
            return str(found[0]) if len(found) == 1 else None
        return by_type.get(type(v))

    return pick


class Keyed:
    """msgspec: a value of a variant by keys, decoded by `dec_hook` (msgspec has no such unions)."""

    __slots__ = ("value",)

    def __init__(self, value: object) -> None:
        self.value = value

    def __eq__(self, other: object) -> bool:
        return type(other) is type(self) and other.value == self.value  # type: ignore[attr-defined]

    __hash__ = None  # type: ignore[assignment]


KEYED: dict[type[Keyed], tuple[tuple[tuple[str, ...], Any], ...]] = {}
"""Each wrapper type's cases: their keys and type."""


def dec_hook(t: type, obj: Any) -> Any:
    cases = KEYED.get(t)
    if cases is None:
        raise NotImplementedError(t)
    if not isinstance(obj, dict):
        raise TypeError(f"expected an object, got {type(obj).__name__}")
    found = [case for keys, case in cases if all(k in obj for k in keys)]
    if len(found) != 1:
        raise ValueError(f"expected the keys of exactly one case, found {len(found)}")
    return t(msgspec.convert(obj, found[0], dec_hook=dec_hook))


def enc_hook(x: Any) -> Any:
    if isinstance(x, Keyed):
        return x.value
    raise NotImplementedError(type(x))


# ── building ─────────────────────────────────────────────────

_GENERATORS: dict[Flavour, type[_Codegen]] = {"pydantic": _Pydantic, "msgspec": _Msgspec}


def generate(file: JsonSchema, roots: Sequence[str], flavour: Flavour) -> tuple[str, dict[str, str]]:
    """The module's source, and the Python expression of each root type."""
    gen = _GENERATORS[flavour](file)
    exprs = {root: gen.ref(root) for root in roots}
    return gen.source(), exprs


def load(file: JsonSchema, roots: Sequence[str], flavour: Flavour, module_name: str) -> dict[str, Any]:
    """Each root's Python type, from the generated module (run as `module_name`)."""
    source, exprs = generate(file, roots, flavour)
    module = types.ModuleType(module_name)
    sys.modules[module_name] = module
    exec(compile(source, f"<{module_name}>", "exec"), module.__dict__)
    return {root: eval(expr, module.__dict__) for root, expr in exprs.items()}


@dataclass(frozen=True, slots=True)
class Baselines:
    """The JSON baselines of one source: a reader and a writer per root type and library."""

    pydantic: dict[str, pydantic.TypeAdapter[Any]]
    msgspec_decoders: dict[str, msgspec.json.Decoder[Any]]
    msgspec_encoder: msgspec.json.Encoder


def baselines(file: JsonSchema, roots: Sequence[str], source: str) -> Baselines:
    unique = sorted(set(roots))
    tag = _identifier(source)
    py = load(file, unique, "pydantic", f"haus_bench_models_pydantic_{tag}")
    ms = load(file, unique, "msgspec", f"haus_bench_models_msgspec_{tag}")
    return Baselines(
        pydantic={r: pydantic.TypeAdapter(t) for r, t in py.items()},
        msgspec_decoders={r: msgspec.json.Decoder(t, dec_hook=dec_hook) for r, t in ms.items()},
        msgspec_encoder=msgspec.json.Encoder(enc_hook=enc_hook),
    )
