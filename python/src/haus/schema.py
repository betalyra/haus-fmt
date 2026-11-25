"""Schema files, decoding with a schema, and the schema-based JSON of a type (spec §14, §15, §16.3).

    >>> from haus import schema
    >>> s = schema.compile_schema('''
    ...     type User = { id: Int, name: String, nick?: String, note?: Maybe String }
    ... ''')
    >>> user = s["User"].parse('{ id: 1, name: "Ada", note: None }')
    >>> user
    {'id': 1, 'name': 'Ada', 'note': Nothing()}
    >>> s["User"].canonical(user)
    '{id:1,name:"Ada",note:None}'
    >>> s["User"].to_json(user)
    '{"id":"1","name":"Ada","note":null}'
    >>> s["User"].from_json('{"id": "1", "name": "Ada", "note": null}') == user
    True

Host types (the defaults keep the value, spec §13.4):

    String → str               Int, Int8 … UInt64 → int        Float32, Float64 → float
    Bytes → bytes              Bool → bool                     Decimal → str ("19.90", "1.5e3")
    std/time types → str       Array a → tuple                 Map v → dict[str, V]
    { a: T, b?: T } → dict     (a missing optional field is a missing key, never None)
    Maybe a → Some(x) | Nothing()
    variants → Tagged(tag), Tagged(tag, {fields}), Tagged(tag, (args, …)); open ones also Unknown(raw)
    Any → the parsed Value     Secret a → Secret (shows <redacted>; expose())
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass, field
from typing import Any

from . import _decode
from ._canonical import canonical as _canonical
from ._canonical import canonical_at
from ._codecs import CodecGroup, DateCodec, DecimalCodec, InstantCodec, optional_codecs
from ._decode import CheckedCodec, Codec
from ._errors import HausDecodeError, HausEncodeError, HausJsonError, format_path
from ._host import Maybe, Nothing, Secret, Some, Tagged, Unknown
from ._json import Json, read_json, read_lines, schema_json_depth, write_json
from ._parser import DEFAULT_LIMITS, Limits, Parser
from ._resolve import (
    MANIFEST,
    MAX_FOLDER_ENTRIES,
    MAX_MANIFEST_SIZE,
    MAX_SCHEMA_SIZE,
    PACKAGE_SCHEMA,
    FileResolver,
    Manifest,
    Packages,
    PackageSource,
    StrPath,
    identify,
    installed_package,
    read_manifest,
    read_module,
    schema_path,
)
from ._schema_file import (
    ATTRIBUTES,
    BUILTINS,
    STD_MODULES,
    ArrayType,
    Attribute,
    BuiltinType,
    Case,
    Definition,
    Field,
    HausSchemaFileError,
    Instance,
    MapType,
    MaybeType,
    ModuleError,
    ModuleResolver,
    NoPayload,
    ParamType,
    Payload,
    PositionalPayload,
    RecordPayload,
    RecordType,
    RefType,
    ResolvedModule,
    SchemaFile,
    SchemaWarning,
    SecretType,
    StdType,
    Type,
    VariantType,
    deprecation,
    parse_schema_file,
    without_attributes,
)
from ._stream import DEFAULT_MAX_VALUE_LENGTH, Readable, parse_stream
from ._value import Value

__all__ = [
    "ATTRIBUTES",
    "BUILTINS",
    "MANIFEST",
    "MAX_FOLDER_ENTRIES",
    "MAX_MANIFEST_SIZE",
    "MAX_SCHEMA_SIZE",
    "PACKAGE_SCHEMA",
    "PROFILED_TYPES",
    "STD_MODULES",
    "ArrayType",
    "Attribute",
    "BuiltinType",
    "Case",
    "CheckedCodec",
    "Codec",
    "CodecGroup",
    "DateCodec",
    "DecimalCodec",
    "Definition",
    "Field",
    "FileResolver",
    "HausDecodeError",
    "HausEncodeError",
    "HausJsonError",
    "HausSchemaFileError",
    "Instance",
    "InstantCodec",
    "Manifest",
    "MapType",
    "Maybe",
    "MaybeType",
    "ModuleError",
    "ModuleResolver",
    "NoPayload",
    "Nothing",
    "PackageSource",
    "Packages",
    "ParamType",
    "Payload",
    "PositionalPayload",
    "RecordPayload",
    "RecordType",
    "RefType",
    "ResolvedModule",
    "Schema",
    "SchemaFile",
    "SchemaType",
    "SchemaWarning",
    "Secret",
    "SecretType",
    "Some",
    "StdType",
    "StrPath",
    "Tagged",
    "Type",
    "Unknown",
    "VariantType",
    "compile_schema",
    "deprecation",
    "format_path",
    "from_schema_file",
    "identify",
    "installed_package",
    "load_schema",
    "missing_codecs",
    "parse_schema_file",
    "read_manifest",
    "read_module",
    "schema_path",
    "without_attributes",
]


@dataclass(frozen=True, slots=True)
class SchemaType:
    """A named type of a schema, ready to decode and encode with (spec §15).

    Every call has the parser's limits (`limits`, also used for the nesting depth and
    for raw values written again) and a work budget: by default 16 steps per value of
    the input when decoding, 16 Mi steps when encoding (`max_steps`).
    """

    name: str
    id: str
    """The type's identity (spec §13.3): `@haus-fmt/money@1#Money`, or its name in a file without an id."""
    stream: bool
    """`type Events = Stream Event`: the type describes a whole file; each value decodes as `Event`."""
    _node: _decode._Node = field(repr=False)  # pyright: ignore[reportPrivateUsage]

    def decode(self, value: Value, *, limits: Limits = DEFAULT_LIMITS, max_steps: int | None = None) -> Any:
        """A parsed value as its Python value. Raises `HausDecodeError` with the place of the failing value."""
        return _decode.decode(self._node, value, limits, max_steps)

    def parse(self, text: str, *, limits: Limits = DEFAULT_LIMITS, max_steps: int | None = None) -> Any:
        """Parse a text holding exactly one value and decode it.

        Raises `HausSyntaxError` for text that isn't haus, `HausDecodeError` for a value the type rejects.
        """
        values = Parser(text, limits).parse_sequence()
        if len(values) != 1:
            n = len(values)
            raise HausDecodeError(
                f"expected exactly one value, found {n}", (), "not-one-value", expected="one value", found=f"{n} values"
            )
        return self.decode(values[0], limits=limits, max_steps=max_steps)

    def encode(self, value: object, *, limits: Limits = DEFAULT_LIMITS, max_steps: int | None = None) -> Value:
        """A Python value as a haus value of this type. Raises `HausEncodeError`."""
        return _decode.encode(self._node, value, limits, max_steps)

    def canonical(self, value: object, *, limits: Limits = DEFAULT_LIMITS) -> str:
        """Encode, and write the result in canonical form (spec §12): valid haus text, on one line."""
        return _canonical(self.encode(value, limits=limits), limits=limits)

    def decode_all(self, values: Iterable[Value], *, limits: Limits = DEFAULT_LIMITS) -> Iterator[Any]:
        """Decode each value of a stream on its own; errors carry its index first in their path."""
        for i, v in enumerate(values):
            yield _decode.decode(self._node, v, limits, None, i)

    def parse_stream(
        self,
        source: Readable | Iterable[str | bytes],
        *,
        limits: Limits = DEFAULT_LIMITS,
        max_value_length: int = DEFAULT_MAX_VALUE_LENGTH,
        require_terminator: bool = False,
    ) -> Iterator[Any]:
        """Read a stream (spec §6) and decode each value as it arrives (spec §15, `Stream a`)."""
        values = parse_stream(
            source, limits=limits, max_value_length=max_value_length, require_terminator=require_terminator
        )
        return self.decode_all(values, limits=limits)

    def encode_all(self, values: Iterable[object], *, limits: Limits = DEFAULT_LIMITS) -> Iterator[str]:
        """Encode values as stream items, each in canonical form followed by `,\\n`."""
        for i, v in enumerate(values):
            yield canonical_at(_decode.encode(self._node, v, limits, None, i), limits.max_nodes, (i,)) + ",\n"

    # ── JSON (spec §16.3) ──

    def to_json(self, value: object, *, limits: Limits = DEFAULT_LIMITS, max_steps: int | None = None) -> str:
        """A Python value as its schema-based JSON (spec §16.3), on one line. Raises `HausEncodeError`.

        Integers beyond 32 bits, decimals and `NaN`/`Infinity` are strings, bytes are base64,
        `Maybe` is `null` or the value where that is unambiguous, variants carry `"_tag"`.
        """
        return write_json(_decode.to_schema_json(self._node, value, limits, max_steps))

    def from_json(self, text: str | bytes, *, limits: Limits = DEFAULT_LIMITS, max_steps: int | None = None) -> Any:
        """Read a JSON text of this type's schema-based JSON (spec §16.3) as its Python value.

        Raises `HausJsonError` for text that isn't I-JSON within the limits (duplicate names,
        lone surrogates, numbers too long), `HausDecodeError` for JSON the type rejects.
        Numbers are read from their text, never through a float unless the type is one.
        """
        j = read_json(text, limits, schema_json_depth(limits))
        return _decode.from_schema_json(self._node, j, limits, max_steps)

    def to_json_lines(self, values: Iterable[object], *, limits: Limits = DEFAULT_LIMITS) -> Iterator[str]:
        """Each value's schema-based JSON followed by a line feed: JSON Lines.

        Errors carry its index first in their path.
        """
        for i, v in enumerate(values):
            yield write_json(_decode.to_schema_json(self._node, v, limits, None, i)) + "\n"

    def from_json_lines(
        self,
        source: str | bytes | Readable | Iterable[str | bytes],
        *,
        limits: Limits = DEFAULT_LIMITS,
    ) -> Iterator[Any]:
        """Read JSON Lines (a text, a file, or chunks split anywhere) and decode each line as it arrives.

        Syntax errors give the line number; decoding errors carry the line's index first in their path.
        """

        def convert(j: Json, i: int) -> Any:
            return _decode.from_schema_json(self._node, j, limits, None, i)

        return read_lines(source, limits, schema_json_depth(limits), convert)


@dataclass(frozen=True, slots=True)
class Schema:
    """A checked schema file, with its types ready to decode with: `schema["Order"].parse(text)`."""

    file: SchemaFile
    types: Mapping[str, SchemaType]
    """The types without parameters, own and imported, by name."""
    codec_warnings: tuple[SchemaWarning, ...] = ()
    """`missing-codec` (spec §13.4): a type an official profile has a rule for that the file's own
    definitions reach, with no codec for its id, so its values are checked for their shape only. One per
    id, sorted by id, at no place in the file (`line` 0)."""

    def __getitem__(self, name: str) -> SchemaType:
        try:
            return self.types[name]
        except KeyError:
            raise KeyError(f"no type {name} without parameters here (there is {', '.join(self.types)})") from None

    def __contains__(self, name: object) -> bool:
        return name in self.types

    @property
    def warnings(self) -> tuple[SchemaWarning, ...]:
        """The schema file's warnings (unknown attributes, uses of deprecated types, cases without a
        schema-based JSON form), then `missing-codec` for the codecs it was built with."""
        return self.file.warnings + self.codec_warnings


PROFILED_TYPES: Mapping[str, tuple[str, ...]] = {
    "@haus-fmt/money@1#Currency": ("iso",),
    "@haus-fmt/geo@1#LatLng": ("wgs84",),
    "@haus-fmt/geo@1#BBox": ("wgs84",),
    "@haus-fmt/uuid@1#Uuid": ("rfc9562",),
}
"""The types official profiles have a rule for, by id, with the profiles (spec §13.4). `iso`'s rule for
`Money` is its currency's, so `Currency` stands for it. A build reads only a package's `package.haus` and
`schema.haus`, so the binding keeps this table itself."""


def missing_codecs(file: SchemaFile, codecs: Iterable[str]) -> tuple[SchemaWarning, ...]:
    """`missing-codec` (spec §13.4): the types of `PROFILED_TYPES` that the file's own definitions reach
    without a codec in `codecs` (ids), once per id, sorted by id, at no place (`line` 0). A type reached
    only inside a type that has a codec doesn't count: that codec decides which values it holds (a codec
    for `Money` covers its `Currency`)."""
    coded = set(codecs)
    missing: set[str] = set()
    seen: set[int] = set()
    stack: list[Type] = [inst.body for d in file.definitions if (inst := file.instances.get(d.name)) is not None]
    # An explicit stack: types nest as deep as schema files allow, and instances form cycles.
    while stack:
        t = stack.pop()
        if id(t) in seen:
            continue
        seen.add(id(t))
        match t:
            case RefType(inst):
                if id(inst) in seen:
                    continue
                seen.add(id(inst))
                type_id = inst.definition.id
                if not inst.args and type_id in coded:
                    continue
                if not inst.args and type_id in PROFILED_TYPES:
                    missing.add(type_id)
                stack.append(inst.body)
            case ArrayType(item) | MaybeType(item) | SecretType(item):
                stack.append(item)
            case MapType(value):
                stack.append(value)
            case RecordType(fields):
                stack.extend(f.type for f in fields)
            case VariantType(cases):
                for c in cases:
                    match c.payload:
                        case RecordPayload(record):
                            stack.append(record)
                        case PositionalPayload(items):
                            stack.extend(items)
                        case NoPayload():
                            pass
            case _:
                pass
    return tuple(missing_codec(i) for i in sorted(missing))


def missing_codec(type_id: str) -> SchemaWarning:
    """The `missing-codec` warning for a type of `PROFILED_TYPES` that has no codec."""
    profiles = ", ".join(PROFILED_TYPES[type_id])
    message = (
        f"{type_id} has profiles ({profiles}), but no codec is set for it: its values are checked for their shape only"
    )
    return SchemaWarning("missing-codec", message, 0, 0, 0, 0)


def from_schema_file(file: SchemaFile, *, codecs: Mapping[str, Codec] | None = None) -> Schema:
    """The decoders of a checked schema file. `codecs` choose host types by type id (spec §13.4).

    A codec for a type the schema doesn't have is a `ValueError`, unless it is in a `CodecGroup`.
    A type an official profile has a rule for that the file's definitions reach without its codec
    gets a `missing-codec` warning in `Schema.warnings` (`missing_codecs`).
    """
    builder = _decode.Builder(codecs or {})
    types: dict[str, SchemaType] = {}
    for name in file.instances:
        if (inst := file.instance(name)) is not None:
            types[name] = SchemaType(name, inst.definition.id, inst.stream, builder.ref(inst))
    if unused := set(builder.codecs) - builder.used - optional_codecs(builder.codecs):
        raise ValueError(f"codecs for {', '.join(sorted(unused))}, but the schema has no such type")
    return Schema(file, types, missing_codecs(file, builder.codecs))


def compile_schema(
    text: str,
    *,
    resolver: ModuleResolver | None = None,
    key: str | None = None,
    id: str | None = None,
    codecs: Mapping[str, Codec] | None = None,
) -> Schema:
    """Parse and check a schema file (spec §14) and build its decoders.

    Without a `resolver`, only standard modules can be imported. Raises `HausSchemaFileError`.
    """
    return from_schema_file(parse_schema_file(text, resolver=resolver, key=key, id=id), codecs=codecs)


def load_schema(
    path: StrPath,
    *,
    packages: Packages | None = None,
    package_folders: Iterable[PackageSource] = (),
    codecs: Mapping[str, Codec] | None = None,
    root: StrPath | None = None,
) -> Schema:
    """Read a schema file, with its relative imports next to it and the schema packages it is given.

    `packages` are package directories, each named by its manifest, or a mapping
    from each package name to its directory (the name must be the manifest's).
    Each of `package_folders` is a directory whose direct subdirectories with a
    `package.haus` are packages. A package or a folder may also be a read-only
    file tree given in code, an `importlib.resources` `Traversable`. `root` is the
    build's root directory (spec §13.3): relative imports reach only files inside
    it (`import-outside-root`) and follow no symbolic link (`import-not-found`);
    by default the schema file's real directory, and it must contain the schema
    file. A relative `root` and relative directories are
    relative to the schema file's real directory. Raises `HausSchemaFileError`,
    also for a package directory without `package.haus`, a folder that doesn't
    exist or a `root` that doesn't contain the schema file (at 1:1, before any
    import), and `OSError` for a schema file that can't be read.

    schema = load_schema("order.schema.haus", packages=["vendor/money"], package_folders=["schemas"])
    """
    try:
        module, resolver = FileResolver.for_root(path, packages or (), folders=package_folders, root=root)
    except ModuleError as e:  # the root file (too large, not a file) or the configuration
        raise HausSchemaFileError(str(e), 0, 1, 1, e.code) from None
    return compile_schema(module.text, resolver=resolver, key=module.key, id=module.id, codecs=codecs)
