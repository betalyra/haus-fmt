# haus for Python

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> ⚠️ **Highly experimental.** This package has the parser, the stream reader, the canonical form, decoding with schemas and the JSON mappings. The formatter is on its way.

```sh
pip install haus-fmt
```

The parser follows the [specification](https://github.com/betalyra/haus-fmt/tree/main/spec): exact numbers, limits enforced while parsing, and error positions in code points. It needs Python 3.11 or later and has no dependencies.

```python
import haus
from haus import Number, Record, Variant

order = haus.parse('{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }')

match order:
    case Record({"status": Variant("Shipped", (Record(fields),))}):
        print("shipped:", fields["tracking"])  # String(value='DE-4711')

haus.parse("19.90")  # Number(text='19.90'): exact, never a float
haus.parse("19.90").to_decimal()  # Decimal('19.90')
haus.parse_all("Log { a: 1 },\nHeartbeat,\n")  # a stream: every top-level value
haus.parse_bytes(open("data.haus", "rb").read())  # UTF-8 checked, BOM skipped
```

Values are `Number`, `String`, `Bytes`, `Array`, `Record` and `Variant`, frozen dataclasses you can `match` on. Equality follows the spec: record field order doesn't matter, `1.0 != 1`, and `Tag { … }` equals `Tag({ … })`.

Errors are `haus.HausSyntaxError`, a `ValueError` with a `code`, `reason`, `line` and `column` (see [Error codes](#error-codes)):

```python
haus.parse("{ ok: true }")
# HausSyntaxError: unexpected identifier 'true': lowercase identifiers can only be
# record keys (booleans are the variants True / False) at 1:7; its code is boolean-literal
```

Limits are configurable with `haus.Limits(max_depth=…, max_number_length=…, max_exponent=…, max_string_length=…)` (spec §7); the string limit counts record keys and tags too. A hex literal has at most as many hex digits as keep its decimal form within the number limit: 829 for 1000. `max_depth` is at most `haus.MAX_SUPPORTED_DEPTH`, 512: a larger one is a `haus.HausLimitsError` (a `ValueError`, code `unsupported-depth`) naming the maximum when the `Limits` are made. The parser, the decoders and the JSON mappings recurse, a few Python frames per level, so they raise Python's recursion limit when it is too low for the depth (never lowering it): 512 levels work even when called from deep inside an application. The canonical form doesn't recurse.

## Streams

A stream is a file of values, each followed by a comma. `haus.parse_stream` yields each value as soon as its comma arrives, from a file or any iterable of `bytes` or `str` chunks, split anywhere:

```python
with open("events.haus", "rb") as f:
    for event in haus.parse_stream(f):
        print(event)
```

`haus.StreamReader` does no I/O, for sockets and event loops: `push(chunk)` returns the values the chunk completed, `finish()` the last one if it had no comma after it. Memory is bounded by the largest single value (`max_value_length`, 64 Mi characters by default), errors have positions in the whole stream, and `require_terminator=True` reports a stream that ends without a comma after its last value as cut off.

```python
reader = haus.StreamReader(require_terminator=True)
reader.push(b"Heartbeat,\nUserCreated { id")  # [Variant(tag='Heartbeat', args=())]
reader.push(b": 1 },\n")  # [Variant(tag='UserCreated', args=(Record(...),))]
reader.finish()  # []
```

## Canonical form and hashing

`haus.canonical` writes a value as one exact text, the same in every haus binding: layout, comments, key order and spelling don't change it. `haus.hash` is the SHA-256 of that text, for signing, deduplication and content addressing:

```python
order = haus.parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }')
haus.canonical(order)  # 'Order{id:255,total:19.90,"x-y":1e5}'
haus.hash(order)  # 64 lowercase hex digits
haus.equals(haus.parse("1.0"), haus.parse("1"))  # False: different numbers
sorted(values, key=functools.cmp_to_key(haus.compare))  # by canonical form, not numeric: 10 before 9
```

Every value has a canonical form, and `canonical` and `hash` never fail: an integer is written in decimal with all its digits, however long (a parser with a larger number limit, or code, can make one longer than 1000 characters).

A whole file or stream has one hash too: `haus.hash_all(values)` hashes the canonical forms joined by `,` (a file of one value hashes like the value). `haus.Hasher` computes it while a stream is read:

```python
hasher = haus.Hasher()
with open("events.haus", "rb") as f:
    for event in haus.parse_stream(f):
        hasher.add(event)
hasher.digest()  # == haus.hash_all(all events)
```

## JSON

Three forms connect haus and JSON (spec §16), and the caller always says which one it reads:

- **Schema-based JSON** is the JSON a JSON consumer expects, written and read with a schema type: `s["Order"].to_json(order)` and `from_json(text)` (below).
- **Self-describing JSON** carries every haus value exactly, without a schema, through systems that only store JSON: `haus.to_haus_json(value)` and `haus.from_haus_json(text)`.
- **JSON import** reads any JSON as a haus value, without a schema: `haus.import_json(text)`. It only reads.

```python
haus.import_json('{"price": 19.90, "ok": true, "note": null}')  # any JSON as a haus value (§16.1)
# Record(fields={'price': Number(text='19.90'), 'ok': Variant(tag='True', ...), 'note': Variant(tag='None', ...)})

haus.to_haus_json(haus.parse("Circle { r: 1.50 }"))  # every value, without a schema (§16.2)
# '{"_haus":1,"_value":{"_tag":"Circle","_args":[{"_rec":{"r":{"_num":"1.50"}}}]}}'
haus.from_haus_json('{"_haus": 1, "_value": {"_num": "19.90"}}')  # Number(text='19.90'); any other form is an error
```

Self-describing JSON is an envelope, `{"_haus": 1, "_value": …}`: every value has exactly one, and reading it gives an equal value. `from_haus_json` requires the envelope (`haus-json-form` without it, `haus-json-version` for a `_haus` other than 1); `import_json` and schema-based reading never look for one, so to them it is an ordinary object.

JSON is read strictly, as I-JSON within the limits: UTF-8 (a leading byte order mark is ignored; in JSON Lines only at the start of the stream), no duplicate member names, no unpaired surrogates, and numbers keep their exact text, never a float. Writers escape C0, DEL, C1 and bidi controls in strings and member names, so written JSON can't display differently from what it holds, and U+2028 and U+2029, at which some software splits lines (readers accept those raw); `from_haus_json` rejects them raw (only haus writes that form), the other readers accept them. Errors are `haus.HausJsonError`, a `ValueError` with `reason` and either `line` and `column` (text that isn't JSON) or `path` (JSON that isn't the expected form).

Streams are JSON Lines, one JSON text per line (in self-describing JSON, an envelope each): `haus.import_json_lines(source)`, `haus.to_haus_json_lines(values)` and `haus.from_haus_json_lines(source)` read a text, a file, or chunks split anywhere.

## Schemas

`haus.schema` reads schema files (`.schema.haus`, spec §14), checks them, and decodes and encodes values with their types (spec §15):

```python
from haus import schema
from haus.schema import Nothing, Secret, Some, Tagged, Unknown

s = schema.load_schema("order.schema.haus")  # imports ./files next to it; packages: see below
# or: schema.compile_schema(text)            # std/time imports only, without a resolver

order = s["Order"].parse('{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }')
# {'id': 7, 'total': '44.40', 'status': Tagged(tag='Shipped', payload={'tracking': 'DE-4711'})}
s["Order"].decode(value)  # a parsed haus.Value
s["Order"].encode(order)  # back to a haus.Value
s["Order"].canonical(order)  # … written in canonical form: valid haus text
s.warnings  # unknown attributes, uses of @deprecated types
```

Errors are `HausSchemaFileError` (a `HausSyntaxError`, with line and column in the schema file), `HausDecodeError` and `HausEncodeError` (`ValueError`s with `reason` and `path`): `expected Decimal, found string "3" at $.items[2].price`.

### What values decode to

The defaults keep the value: encoding what they decoded gives back an equal haus value (spec §13.4), except where §15 drops something by design (fields an open record ignores, the spelling of a float, `-0` as an integer).

| Schema | Python | Notes |
|---|---|---|
| `String` | `str` | kept exactly, no normalization |
| `Bytes` | `bytes` | |
| `Bool` | `bool` | |
| `Int`, `Int8` … `UInt64` | `int` | any size for `Int`; out of range is an error, never clamped |
| `Float32`, `Float64` | `float` | the nearest value (binary32 rounded directly from the decimal), `nan`, `inf`; written in one spelling |
| `Decimal` | `str`, the literal: `"19.90"`, `"1.5e3"` | `decimal.Decimal` can't tell `15e2` from `1.5e3`, so it is opt-in (codecs below); encoding also accepts a `Decimal` |
| `Date`, `Instant`, … (std/time) | `str`, the checked text: `"2026-11-13"` | |
| `Array a` | `tuple` | encoding accepts a `list` too |
| `Map v` | `dict[str, V]` | |
| `{ a: T, b?: T }` | `dict` | a missing optional field is a missing key, never `None`; `None` is never a value |
| `Maybe a` | `Some(x)` or `Nothing()` | not Python's `None`: `Some(Nothing())` and `Nothing()` stay apart |
| `< Empty \| Circle { r: Float64 } \| Point Float64 Float64 >` | `Tagged("Empty")`, `Tagged("Circle", {"r": 1.0})`, `Tagged("Point", (1.0, 2.0))` | `Result e a` is `Tagged("Ok", (x,))` / `Tagged("Err", (e,))` |
| a tag an open variant doesn't list (and every tag of `< >`) | `Unknown(raw)` | the parsed `Variant`, untrusted; written back unchanged |
| `Any` | the parsed `haus.Value` | written back unchanged, after checking it is a value within the limits |
| `Secret a` | `Secret`, holding what `a` decodes to | `str`, `repr`, f-strings and logs show `<redacted>`; `expose()` gives the value |

All of them are frozen dataclasses (except `Secret`) and work with `match`:

```python
match s["Shape"].parse(text):
    case Tagged("Circle", {"r": r}):
        ...
    case Tagged("Point", (x, y)):
        ...
    case Unknown(raw):
        ...  # a newer sender's shape: forward or log raw
match user.get("note"):
    case None:
        ...  # the field was not given
    case Nothing():
        ...  # None: clear it
    case Some(text):
        ...  # Some(text): set it
```

A secret's errors give its place and type, never the value or a path into it (a map key could be the secret), when decoding and when encoding: `expected String (a Secret: the value is not shown) at $.apiKey`. Secrets are equal only to themselves. Encode one with `Secret("sk-…")`.

### Limits

Decoding is linear in the input whatever the schema (spec §9.8): a variant's case is one lookup on its tag, the nesting depth is limited (`limits=haus.Limits(max_depth=…)`, 256 by default and at most 512, for recursive types too), and every call has a work budget (`max_steps`; by default 16 steps per value when decoding and 16 Mi when encoding). Encoding detects values that contain themselves, and checks raw values (`Any`, `Unknown`) against the parser's limits and the value syntax before writing them.

### Streams

`type Events = Stream Event` describes a file. `s["Events"].parse_stream(source)` reads it (a file or chunks, as `haus.parse_stream`) and decodes each value as it arrives; an error's path starts with the value's index. `encode_all(values)` writes stream items, each followed by `,\n`.

### Schema-based JSON

`to_json` and `from_json` map a type's values to the JSON a JSON consumer expects (spec §16.3). The schema carries what JSON can't say, so reading checks everything decoding does:

```python
s = schema.compile_schema("""
    type Order = { id: Int64, qty: UInt16, total: Decimal, note?: Maybe String, shape: Shape }
    type Shape = < Circle { r: Float64 } | Point Float64 Float64 | Empty >
""")
order = s["Order"].parse("{ id: 7, qty: 2, total: 44.40, note: None, shape: Point(1, 2) }")
s["Order"].to_json(order)
# '{"id":"7","qty":2,"total":"44.40","note":null,"shape":{"_tag":"Point","values":[1,2]}}'
s["Order"].from_json('{"id": "7", "qty": 2, "total": "44.40", "shape": {"_tag": "Empty"}}')
s["Order"].to_json_lines(orders)  # JSON Lines; from_json_lines(source) reads them
```

| Type | JSON |
|---|---|
| `String`, std/time types | a string |
| `Bytes` | a string, base64 with padding |
| `Bool` | `true` or `false` |
| `Int8` … `Int32`, `UInt8` … `UInt32` | a number |
| `Int`, `Int64`, `UInt64` | a string (`"-12"`): many JSON parsers round integers beyond 2⁵³ |
| `Float32`, `Float64` | a number in the spelling of §15; `"NaN"`, `"Infinity"`, `"-Infinity"` |
| `Decimal` | a string, the literal (`"19.90"`) |
| `Any` | its self-describing form, without the envelope |
| `Secret a` | as `a`; errors never show the value |
| `Array a`, `Map v`, records | an array, an object; a missing optional field is a missing member |
| `Maybe a` | `null` or the value when `a`'s JSON can't be `null`; otherwise `{"_tag": "None"}`, `{"_tag": "Some", "value": …}` |
| a closed variant without payloads | the tag as a string (`"Debug"`) |
| other variants | `{"_tag": "Circle", "r": 1.5}`, `{"_tag": "Wrap", "value": 3}`, `{"_tag": "Point", "values": [1, 2]}` |
| an unknown value | `{"_tag": "Hexagon"}`, or with arguments `{"_tag": "Hexagon", "_args": [<self-describing>, …]}` |

Reading follows §15: an open record or payload ignores members it doesn't list and a closed one rejects them, an integer type accepts only whole numbers by spelling (`1.0` is not one), and an open variant reads a `"_tag"` it doesn't list as an `Unknown`: alone, the bare tag; with only `"_args"`, its arguments as self-describing values; otherwise, from a newer writer's case, its other members as a record payload read by the import (`{"_tag": "Hexagon", "sides": 6}` is `Hexagon { sides: 6 }`, and `{"_tag": "Run", "args": [1]}` is `Run { args: [1] }`). A `Maybe` whose JSON would depend on itself (`type T = Maybe T`) is always tagged. A record payload with a field named `_tag` or `_args` has no schema-based form: writing or reading a value of that case is an error (`no-json-form`).

### Imports and packages

`import ./common (Address)` reads `common.schema.haus` next to the importing file. Python has no scoped package names, so schema packages are never searched for (spec §13.3): give them explicitly. A package is a directory holding a `package.haus` manifest and the package's `schema.haus`, and its manifest names it. `packages` lists package directories (or maps each name to its directory), and each of `package_folders` is a directory whose subdirectories with a `package.haus` are packages. `installed_package` finds the directory of an installed Python package that ships one, without importing it:

```python
s = schema.load_schema(
    "order.schema.haus",
    packages=["../extensions/money", schema.installed_package("acme_ids")],
    package_folders=["../schemas"],
)
```

Relative directories are relative to the schema file. Given packages count as declared dependencies; nothing else is searched (no `node_modules`, no global folders). A package directory without `package.haus`, or a folder that doesn't exist, fails before any import (`import-not-found`). A folder's packages are its direct subdirectories (links to directories too), at most 4096 entries (`too-many-files`). A manifest given by its directory is checked when the first package is imported (`package-manifest`: one record, a lowercase `@org/name` without `~` or a part `node_modules`, a semantic version, at most 64 KiB); one in a folder that isn't valid is ignored, and named when an import isn't found. A mapping's name must be the manifest's (`import-not-found` otherwise), and `@haus-fmt/money@1` checks the major version. A package given by its directory is used instead of one in a folder with its name. One schema reaches one package per name: two different packages with one name, also two versions of it, are `duplicate-package`, while copies whose `package.haus` and `schema.haus` are byte for byte the same are one package.

Files are read as spec §13.3 says. A package's `package.haus` and `schema.haus` are regular files, never symbolic links (`package-path`; the package's directory may be a link); they are opened without following links and checked on the opened file. A relative import spells each name as its directory lists it, also on file systems that ignore case, and reads only a file whose real name ends in `.schema.haus` (`import-not-found` otherwise). A schema file is at most 1 MiB (`file-too-large`), a schema reaches at most 256 schema files, the root included (`too-many-files`), and each file is read once. Text that messages quote from files is escaped and at most 40 characters long. Types have the ids of spec §13.3: `@haus-fmt/money@1#Money` in a package, `<project name>/<path>#Name` for other files (the nearest `pyproject.toml`'s `[project] name`), or without a project their path from the root schema file's directory (`billing/common#Address`). Two imports reach the same file when its real path is the same. `schema.FileResolver(base, packages, folders=…)` is the resolver `load_schema` uses; any other way of finding files is a `ModuleResolver`: an object with `resolve(module, from_key) -> ResolvedModule`, passed to `compile_schema(text, resolver=…, key=…, id=…)`.

### Codecs: other host types

A codec chooses the host type of a named type, by its id (spec §13.4). It runs after the type's own decoding, so it can reject more values but never fewer. The ones here keep less than the haus value, so they are opt-in:

```python
s = schema.compile_schema(
    text,
    codecs={
        "prelude#Decimal": schema.DecimalCodec(),  # decimal.Decimal
        "std/time#Date": schema.DateCodec(),  # datetime.date
        "std/time#Instant": schema.InstantCodec(),  # aware datetime.datetime
    },
)
```

| Codec | Drops |
|---|---|
| `DecimalCodec` | the spelling of the exponent: `15e2` and `1.5e3` are both `Decimal('1.5E+3')`, written `1.5e3`. `Decimal`'s `==` also ignores scale (`19.90 == 19.9`), unlike haus |
| `DateCodec` | nothing; it rejects the year 0000, which `datetime.date` lacks |
| `InstantCodec` | fraction digits beyond microseconds, the fraction's spelling (`.25` → `.250000`), `Z` versus `+00:00` (written `Z`); rejects the year 0000 |

A codec is any object with `decode(value)` and `encode(value)` working on the default host type; raise `ValueError` to reject. Codecs for your own types use their ids (`my-app/order#Money`).

### Schema files for tools

`schema.parse_schema_file(text, …)` gives the checked file without building decoders: its definitions (with `doc`, `source`, `attributes` and `id`), the resolved types, imports and warnings. `schema.without_attributes(text)` blanks every attribute out (positions stay), which never changes decoding (spec §15).

## Error codes

Every error has a **code** from the spec's catalogue (§17, [`errors.md`](https://github.com/betalyra/haus-fmt/tree/main/spec/errors.md)): a short name such as `payload-newline`, `null-literal` or `missing-field` that says which mistake was made. Messages are for people and may change; codes are for programs, tools and agents, never change and are the same in every haus binding. Match on them:

```python
try:
    order = schema["Order"].parse(text)
except haus.HausError as e:
    if e.code == "missing-field":
        ...
    print(json.dumps(e.to_json()))
```

All errors derive from `haus.HausError` (a `ValueError`): `HausSyntaxError` (haus text, and `HausSchemaFileError` for schema files), `haus.HausJsonError` (JSON), `haus.schema.HausDecodeError` and `HausEncodeError` (values that don't fit a type), and `haus.HausLimitsError`. Each has

| Attribute | |
|---|---|
| `code` | the code, e.g. `payload-newline` |
| `reason` | what went wrong, without the position |
| `line`, `column` | the position, for errors in text (haus, a schema file, JSON text) |
| `path` | the place in the value, for decoding errors: `("items", 2, "price")`, written `$.items[2].price` |
| `expected`, `found` | what should be there and what is, where that is natural (else `None`) |
| `hint` | a concrete fix: the catalogue's fix for the code, or a better one for the case at hand |
| `docs` | `https://haus-fmt.org/docs/errors#<code>` |

and `to_json()`, the JSON form of §17, with the members that apply:

```python
try:
    haus.parse_all("Heartbeat\n{ at: 1 }")  # a forgotten comma: the payload must be on the tag's line
except haus.HausSyntaxError as e:
    e.to_json()
# {"code": "payload-newline", "message": "expected ',' between top-level values, found '{'",
#  "line": 2, "column": 1, "expected": "','", "found": "'{'",
#  "hint": "Put the payload on the same line as Heartbeat, or add a comma if they are two values.",
#  "docs": "https://haus-fmt.org/docs/errors#payload-newline"}
```

An error inside a `Secret` has the code `invalid-secret` and nothing of the value in any member. Schema warnings (`SchemaWarning`) have a `code` (`unknown-attribute`, `deprecated`), `hint`, `docs` and `to_json()` too. `haus.ERROR_CODES` maps every code to its category and fix (`haus.ErrorCode` is their `Literal` type, `haus.is_error_code(s)` checks a string). It is generated from the catalogue's source, [`spec/errors.haus`](../spec/errors.haus): after changing that, run `uv run python tests/test_error_codes.py`; the tests fail while the table and the catalogue differ.

## Development

```sh
uv sync
uv run pytest            # unit tests and the shared conformance suites in ../test-suite (parser, schema, JSON)
uv run ruff check . && uv run mypy && uv run pyright
```

The parser, the stream reader and `canonical` also run in the [differential fuzzer](../fuzz) against the Lean reference and the Rust, Roc and TypeScript bindings, error codes included, and so do the std/time check (`node fuzz/src/time.ts`) and schema decoding (`node fuzz/src/main.ts --schema`, through [`fuzz/schema_runner.py`](fuzz/schema_runner.py)). The std/time profile (`haus._time`) and float rounding and spelling (`haus._float`, spec §15) are the building blocks of schema decoding; floats are rounded to binary32 exactly, from the decimal, never through binary64.
