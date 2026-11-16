# JSON ⇄ haus

Rules: [spec §16](https://haus-fmt.org/docs/spec#16-json). There is no `haus convert` command yet: convert by hand (or with a script), then `haus check` the result.

## JSON to haus

Every JSON text becomes valid haus with these changes:

| JSON | haus |
|---|---|
| `"name": 1` | `name: 1`. Keep the quotes for keys that don't match `[a-z_][A-Za-z0-9_]*`: `"Name"`, `"x-id"`, `"$type"`. |
| `true`, `false` | `True`, `False` |
| `null` | see below |
| `30.30`, `1e3`, `1.0` | the same text: numbers are exact and keep their spelling. Don't reformat them. |
| `"é"`, `"\/"`, `"\b"`, `"\f"` | `"\u{e9}"` (or `"é"`), `"/"`, `"\u{8}"`, `"\u{c}"` |
| JSON Lines, one value per line | a stream: each value followed by a comma |

**`null`.** Without a schema, `null` becomes `None`. With a schema, look at the field: leave it out for `x?: T`, write `None` for `x: Maybe T`. Values next to it in a `Maybe` field are wrapped: `"Bo"` → `Some("Bo")`.

**With a schema, match its types**, since a string is never a number or a date:

| JSON | Type | haus |
|---|---|---|
| `"19.90"`, `"9007199254740993"` | `Decimal`, `Int64` | `19.90`, `9007199254740993` |
| `"2026-11-08"` | `Date` | `Date("2026-11-08")` |
| `1.0` | `Int` | `1` |
| `"debug"` | `closed < Debug \| … >` | `Debug` |
| `{"type": "circle", "r": 1}` | `< Circle { r: Float64 } \| … >` | `Circle { r: 1 }` |
| `{"amount": "19.90", "currency": "EUR"}` | `Money` | `Money(19.90, EUR)` |

Tags start with an uppercase letter and contain only letters, digits and `_`: `"in-progress"` becomes `InProgress`.

**Designing a schema from JSON:** turn `"type"` discriminators, string enums and flags that exclude each other into variants; amounts into `Decimal` or `Money`; date and time strings into std/time types; then decide per field between `?:` and `Maybe` (see [schemas.md](schemas.md)).

## haus to JSON

- **For JSON consumers, with a schema** (schema-based JSON): `Int`, `Int64`, `UInt64` and `Decimal` become strings (`"19.90"`); smaller integers and floats numbers; `Bool` `true`/`false`; `Bytes` base64; time values their string; `Maybe` `null` or the value; a missing optional field a missing member. Closed variants without payloads become strings (`"Debug"`); other variants objects with `"_tag"`: `{"_tag": "Circle", "r": 1.5}`, positional arguments as `"value"` (one) or `"values"` (several).
- **Without a schema, exact** (self-describing JSON, for haus tools): `{"_haus": 1, "_value": …}` around `{"_num": "19.90"}`, `{"_rec": {…}}`, `{"_tag": "Some", "_args": […]}`, `{"_bytes": "0b34ff"}`; strings and arrays as themselves.
- A stream becomes JSON Lines.
