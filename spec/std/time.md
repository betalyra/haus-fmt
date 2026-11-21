# The std/time profile

Which strings each type of [`std/time`](time.schema.haus) accepts (spec §13.2).
Every schema binding checks exactly these rules: they are built-in rules, like
the range of `UInt8`. A parser does not check them (§13.1).

The profile is a strict subset of RFC 3339, RFC 9557 and ISO 8601 durations,
close to what JavaScript's Temporal and java.time parse. Each value has one
spelling, apart from the few listed under "Values" below, and
nothing depends on a registry.

## Types

<!-- rule: time.date.form -->
<!-- rule: time.time.form -->
<!-- rule: time.datetime.form -->
<!-- rule: time.instant.form -->
<!-- rule: time.zoned.form -->
<!-- rule: time.duration.form -->
<!-- rule: time.yearmonth.form -->
<!-- rule: time.timezone.form -->
| Type | Form | Example |
|---|---|---|
| `Date` | `YYYY-MM-DD` | `Date("2026-11-09")` |
| `Time` | `hh:mm:ss`, optional fraction of 1–9 digits | `Time("14:30:00.250")` |
| `DateTime` | `Date` `T` `Time`, no offset | `DateTime("2026-11-09T14:30:00")` |
| `Instant` | `DateTime` and an offset | `Instant("2026-11-09T14:30:00Z")` |
| `ZonedDateTime` | `Instant` and one zone in brackets | `ZonedDateTime("2027-03-29T10:00:00+01:00[Europe/Lisbon]")` |
| `Duration` | `-`? `P` [n`Y`] [n`M`] [n`W`] [n`D`] [`T` [n`H`] [n`M`] [n[.f]`S`]] | `Duration("PT1H30M")` |
| `YearMonth` | `YYYY-MM` | `YearMonth("2026-11")` |
| `TimeZone` | a zone name or an offset `±hh:mm` (not `Z` or `z`) | `TimeZone("Europe/Lisbon")`, `TimeZone("+01:00")` |

## Rules

<!-- rule: time.rules.year -->
<!-- rule: time.rules.day -->
<!-- rule: time.rules.month -->
<!-- rule: time.rules.clock -->
<!-- rule: time.rules.leap-seconds -->
<!-- rule: time.rules.fraction -->
<!-- rule: time.rules.separators -->
<!-- rule: time.rules.offset -->
<!-- rule: time.rules.zone -->
<!-- rule: time.rules.rfc9557-tags -->
<!-- rule: time.rules.duration -->
<!-- rule: time.rules.other-iso-forms -->
| Rule | Accepted | Rejected |
|---|---|---|
| Year | `0000`–`9999`, exactly 4 digits; `0000` is 1 BC, as in ISO 8601 | `+12026-11-09`, `-0001-01-01` |
| Day | the day exists in the proleptic Gregorian calendar | `2026-02-29`, `1900-02-29`, `2026-04-31` |
| Month | `01`–`12` | `2026-13-01`, `2026-00-10` |
| Hour, minute, second | `00`–`23`, `00`–`59`, `00`–`59`; seconds required | `14:30`, `24:00:00`, `12:60:00` |
| Leap seconds | — | `23:59:60` |
| Fraction | 1–9 digits (nanoseconds), on seconds only | `12:00:00.1234567890`, `PT1.5H` |
| Separators | upper-case `T` and `Z` | `t`, `z`, a space instead of `T` |
| Offset | `Z` or `±hh:mm`, up to `±23:59` | `-00:00` (write `Z`), `+24:00`, `+0100` |
| Zone | an IANA name by its syntax: at most 255 characters, parts of `A–Z a–z 0–9 . _ + -` separated by `/`, the first starting with a letter, no empty, `.` or `..` parts, and not `Z` or `z`, which is the offset letter (in either case), not a zone name; or an offset `±hh:mm` | `[!Europe/Lisbon]`, `[Europe/../etc]`, `[Europe//Lisbon]`, `TimeZone("Z")`, `TimeZone("z")`, `…Z[Z]`, `…Z[z]` |
| RFC 9557 tags | exactly one zone | `[Europe/Lisbon][u-ca=iso8601]`, other calendars |
| Duration | at least one component; `T` followed by at least one; numbers without leading zeros; no component that is zero (the zero duration is `PT0S`); `-` only before a duration that isn't zero; years, months and weeks below 2³²; days and time together below 2⁵³ seconds, a fraction of a second not counted (`PT9007199254740991.999999999S` is valid) and weeks counted only toward their own bound | `P`, `PT`, `P1DT`, `+PT1H`, `p1d`, `P01D`, `P0D`, `P1DT0S`, `-PT0S` |
| Other ISO 8601 forms | — | week dates (`2026-W45-1`), ordinal dates (`2026-313`), the basic format (`20261109`), intervals (`…/…`), repetitions (`R5/…`) |

## What is not checked

Nothing that depends on a registry:

<!-- rule: time.no-registry.zone-names -->
- whether a zone name exists in the tz database (`Europe/Atlantis` is valid);
  <!-- rule: time.no-registry.offset-match -->
- whether the offset of a `ZonedDateTime` matches its zone at that time. When
  the tz database changes, a stored `…+01:00[Europe/Lisbon]` may stop matching;
  it stays valid, and the application decides what to do (like Temporal's
  `offset: "reject" | "prefer" | "use" | "ignore"`);
- leap seconds, which only a registry could tell apart from seconds that never
  existed (and which end by 2035).

## Values

<!-- rule: time.values.haus-equality -->
std/time never changes what a haus value is. `Instant("…T10:00:00.250Z")` is
a tag with a string, and haus equality, the canonical form and `hash` (spec
§2, §12) compare that string as written: `.250` and `.25`, or `Z` and `+00:00`,
give different hashes, as `19.90` and `19.9` do. What std/time adds, for a schema that asks
for its types, is which strings are valid and which valid strings denote the
same time:

<!-- rule: time.values.fraction-zeros -->
- **Fractions of a second:** trailing zeros don't change the value, in every
  type with seconds. `.250` and `.25` are the same fraction, and `.0` or
  `.000` the same as none (`12:00:00.000` is `12:00:00`, `PT1.50S` is
  `PT1.5S`). They are accepted because common writers produce them
  (JavaScript's `toISOString` always writes three digits).
  <!-- rule: time.values.offset-kept -->
- **Offsets:** `…T14:30:00+01:00` and `…T13:30:00Z` are the same instant.
  The offset also says which local time was meant, so it isn't just a
  spelling: an encoder keeps it.
  <!-- rule: time.values.offset-zero -->
- **Offset zero:** `Z` and `+00:00` are both the offset zero, so
  `…T13:30:00Z` and `…T13:30:00+00:00` are the same std/time value: one
  offset, one instant. As haus values (spec §2) they are different strings,
  with different canonical forms and hashes (above). Both are accepted
  because common writers produce `+00:00` (Python's `isoformat`); `-00:00`
  is not (RFC 3339 gives it another meaning).
- Every other value has exactly one spelling: numbers have no leading zeros,
  letters and separators have one case, a duration leaves out components
  that are zero, and the zero duration is `PT0S`, without a sign.

<!-- rule: time.compare.semantics -->
How values compare:

- `Instant` is a point on the timeline with the offset it was written with:
  two are the same value only when both the instant and the offset are the
  same. `…T10:00:00+01:00` and `…T09:00:00Z` are the same instant but
  different values; `Z` and `+00:00` are one offset (above), and as haus
  values (spec §2) they still differ. Whether two values are the same
  instant is a question an application may ask, as for any other field.
- `ZonedDateTime` is an `Instant` (with its offset) and a zone: two are the
  same when both are.
  The zone decides the local time and the daylight-saving rules, so
  `…T10:00:00Z[Europe/Lisbon]` and `…T11:00:00+01:00[Europe/Paris]` are
  different values (as in Temporal).
- `Duration` compares component by component: `PT90M` and `PT1H30M` are
  different durations. Months have no fixed length, so durations have no total
  order.
- The other types compare by their fields (`Date` by year, month and day).

The rules are also a Lean model
([`spec/lean/Haus/Time/Spec.lean`](../lean/Haus/Time/Spec.lean)), with a
checker proven to compute them (`haus-ref --time TYPE TEXT`). The TypeScript
implementation's tests
([`std-time.test.ts`](../../typescript/packages/haus/test/std-time.test.ts))
cover every row above.

## Host types

<!-- rule: time.host.whole-range -->
<!-- rule: time.host.native-opt-in -->
Every binding accepts the same values: the whole range above, in every type.
How a program holds them is the binding's choice (spec §13.4). JavaScript's
Temporal, Go's `time.Time` and `java.time` hold the whole range. Python's
`datetime` and .NET's `DateTime` start at the year 1, and an offset can move
an instant across the ends of the range (`0001-01-01T00:00:00+01:00` is in
the year `0000` in UTC). A binding for such a language keeps the value
another way by default, such as the checked text, and offers the native type
as an opt-in codec that rejects what it can't hold.
