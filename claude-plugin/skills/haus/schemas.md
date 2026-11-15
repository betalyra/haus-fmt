# Designing haus schemas

A schema file (`x.schema.haus`) is a list of imports and `type Name = …` definitions. A data file `x.haus` next to it is described by its type `Root`. Schemas describe **shape only**: there is no syntax for minimums, patterns or defaults. Write such rules in a comment, and enforce them in the application. Rules: [spec §13–§15](https://haus-fmt.org/docs/spec#14-schema-files).

After writing or changing a schema, run `haus check x.schema.haus`, then check some data against it.

## Types

| Type | Data | Use for |
|---|---|---|
| `String`, `Bytes`, `Bool` | `"a"`, `x"0b34ff"`, `True` | |
| `Int` | `42` | integers of any size |
| `Int8`…`Int64`, `UInt8`…`UInt64` | `42` | integers with a range; values outside it are errors |
| `Float32`, `Float64` | `1.5`, `NaN`, `Infinity`, `NegInfinity` | measurements where rounding is fine |
| `Decimal` | `19.90` | exact numbers; the spelling is kept (`19.90` ≠ `19.9`) |
| `Array a` | `[1, 2]` | lists: `Array Item` |
| `Map v` | `{ en: "Hi", "pt-BR": "Oi" }` | a record with any keys, values of one type |
| `Maybe a` | `None`, `Some(x)` | a value that must be stated, possibly as none |
| `Result e a` | `Ok(x)`, `Err(e)` | |
| `Any` | anything | a payload passed on unchanged, unchecked |
| `Secret a` | as `a` | API keys, passwords: hidden from logs and error messages (not encrypted) |
| `Stream a` | `a, a, …,` | a whole file of values: only as `type Root = Stream Event` |

Imported types:

```haus-schema
import std/time (Date, Instant)    // also Time, DateTime, ZonedDateTime, Duration, YearMonth, TimeZone
import @haus-fmt/money (Money)     // Money(19.90, EUR); needs `npm install @haus-fmt/money`
import ./common (Address)          // ./common.schema.haus, next to this file
```

Time values are the type's tag around a string: `Date("2026-11-08")`, `Instant("2026-11-08T09:12:00Z")`, `Duration("PT1H30M")`. Schema packages (`@org/name`) are found in `node_modules`, in the schema's directory or above it.

Type names start uppercase; type parameters lowercase.

## Fields: required, optional, Maybe

```haus-schema
type User = {
  id: UInt64,                // required
  nickname: Maybe String,    // always written: None or Some("Bo")
  bio?: String,              // may be left out; never None
  avatar?: Maybe Bytes,      // left out, None or Some(…)
}
```

- `x?: T` when "not given" is a normal state. The data leaves the field out.
- `x: Maybe T` when the data must say there is none. A missing field is an error, and `"Bo"` is not `Some("Bo")`.
- `x?: Maybe T` for partial updates: missing leaves the value as it is, `None` clears it, `Some(…)` sets it.

## Open or closed

Records and variants are **open** by default: a reader ignores fields the type doesn't list and keeps tags it doesn't list as unknown values (`haus check` shows a hint). `closed` makes them errors.

```haus-schema
type Config = closed { port: UInt16, host: String }                  // a typo is an error
type Event = < Created { id: UInt64 } | Deleted { id: UInt64 } >      // newer writers may add tags
type Currency = < >                                                   // any tag: EUR, USD
```

Use `closed` for files people write by hand, such as configuration, so typos are caught. Leave types open where writers and readers change at different times (events, API messages): new optional fields and new tags then don't break older readers. Closing a type later is a breaking change. `closed < >` is an error.

## Variants

```haus-schema
type Shape = closed <
  | Circle { r: Float64 }         // Circle { r: 1.5 }
  | Point Float64 Float64         // Point(1, 2)
  | Batch (Array Shape)           // Batch([Point(0, 0)]): an argument with type arguments needs parentheses
  | Empty                         // Empty
>
type Level = closed < Debug | Info | Warn >   // level: Info
```

The case in the schema decides the payload: a record, exactly its positional arguments, or none. Another payload is an error, also in an open variant. Use variants for:

- discriminated objects (`{"type": "circle", "r": 1}` → `Circle { r: 1 }`);
- string enums (`"debug"` → `Debug`);
- flags that exclude each other (`shipped` and `cancelled` → one `status` variant whose cases carry their own data: `Shipped { at: Instant }`).

## Generics, spreads, recursion

```haus-schema
import std/time (Instant)

type Page a = { items: Array a, next?: String }
type UserPage = { page: Page User }

type Base = { id: UInt64, createdAt: Instant }
type User = closed { ...Base, name: String }

type UserEvent = < UserCreated { id: UInt64 } | UserRenamed { id: UInt64, to: String } >
type AppEvent = closed < ...UserEvent | Heartbeat >

type Tree = { value: Int, children: Array Tree }
```

- `...Name` copies the fields of a named record, or the tags of a named variant. Only named types without parameters can be spread. The result is open or closed by its own `closed` alone.
- Recursion must pass through a record field, an array element or a variant payload: `type A = B` with `type B = A` is an error.

## Attributes

```haus-schema
@deprecated("use Customer")
type Client = { id: Int, @deprecated("use email") mail?: String, email?: String }
type Shape = < Circle { r: Float64 } | @deprecated Square { side: Float64 } >
```

`@deprecated` (with or without a reason) is the only attribute. It never changes what data is valid; `haus check` shows a hint where data uses a deprecated field or tag. There is no `@min`, `@pattern` or `@default`.

## Secrets and unknown payloads

```haus-schema
type Service = closed {
  apiKey: Secret String,    // written in full in the data; hidden in logs and error messages
  extra?: Any,              // any value, kept as written
}
```

## Streams

```haus-schema
import std/time (Instant)

type Root = Stream Event
type Event = < Login { user: String, at: Instant } | Logout { user: String, at: Instant } >
```

The data file is then a list of values, each followed by a comma. `Stream` is only allowed as the whole type of a definition, and nothing may refer to that definition.
