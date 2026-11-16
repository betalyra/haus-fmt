/**
 * Decode haus data with Effect schemas.
 *
 *   const Event = Haus.OpenUnion([
 *     Schema.TaggedStruct("UserCreated", { id: Schema.Number, email: Schema.String }),
 *     Schema.TaggedStruct("Heartbeat", {}),
 *   ])
 *   const events = Haus.decodeStream(Event)(response.body!)   // Stream<Event, HausError>
 *
 * The schema is compiled once into a converter from haus values to the
 * schema's encoded shape; Effect's own decoder then validates and transforms
 * it, so filters, transformations, brands and classes all work as usual.
 *
 * haus → Effect mapping:
 *   Circle { radius: 5 }     → TaggedStruct("Circle", { radius })
 *   Point(1, 2)              → TaggedStruct("Point", { x, y })     positional args fill fields in order
 *   EUR                      → Literal "EUR"  or  TaggedStruct("EUR", {})
 *   True / False             → Boolean
 *   None / Some(x)           → Option(X)   (a missing field is not None: `x?: T` is optionalKey(T))
 *   19.90                    → Haus.Decimal (the exact text, "19.90"), Number (Float64), Haus.Float32, BigInt
 *   Instant("…")             → Haus.Instant (the text as written)
 *   ZonedDateTime("…")       → Haus.ZonedDateTime (the text as written)
 *   unknown tag in OpenUnion → { _tag: "@unknown", tag, value }
 *   any value                → Haus.Any: the parsed haus Value, unchanged
 *   a secret (Secret a)      → Schema.Redacted(A): errors inside never show the value
 *
 * The defaults keep the value: encoding what they decoded writes an equal
 * haus value (spec §13.4). Host types that keep less are a choice:
 * `Haus.DecimalAsBigDecimal`, `Haus.InstantAsDateTime` and
 * `Haus.ZonedDateTimeAsDateTime` in hand-written schemas, and the codecs
 * `Haus.decimalAsBigDecimal`, `Haus.instantAsDateTime` and
 * `Haus.zonedDateTimeAsDateTime` for schema files (`Schema.BigDecimal`,
 * `Schema.DateTimeUtc` and `Schema.DateTimeZoned` work as well, with the same losses).
 */
import { errorCode, HausSyntaxError, parseAll, parseStream, stringify, type ChunkSource, type FormatOptions, type Value } from "@haus-fmt/haus"
import { checkStdTime, normalizeNumber, type StdTimeType } from "@haus-fmt/haus"
import {
  fromHausJson as valueOfHausJson, fromSchemaBasedJson, HausDecodeError, HausEncodeError, importJson as importedValue, jsonDepth, limitsIssue, MAX_DEPTH, MAX_SUPPORTED_DEPTH,
  parseJson, parseJsonLines, stringifyJson, toHausJson as hausJsonOf, toSchemaBasedJson, type Json, type JsonType,
} from "@haus-fmt/haus"
import type { Limits } from "@haus-fmt/haus/schema"
import { BigDecimal, DateTime as EffectDateTime, Effect, Option, Schema, SchemaAST, SchemaIssue, SchemaTransformation, Stream } from "effect"
import { codec, entries, isCodec, setId, type AnyCodec, type Checked, type Decoded, type Named } from "./codec.js"
import {
  atIndex as errorAt, CODE, conversionError, HausLimitsError, HausParseError, HausSchemaError, invalidUtf8Error, issueError, jsonError, limitsError, parseError,
  schemaErrorOf,
  type HausError,
} from "./errors.js"
import { withCodecs } from "./schema-file.js"
import {
  checkSchema, compile, compileEncoder, ConversionError, dateTimeText, DECIMAL, decimalText, decoding, encoding, NUMBER, POSITIONAL, PRELUDE_TAG, UNKNOWN_TAG, VALUE,
} from "./convert.js"
import { jsonTypeOf } from "./json.js"

export type { Json, Value }

/**
 * Limits for one call (spec §7), as in the core's `h.decode`: the parser's
 * `maxDepth` (256 by default, at most `MAX_SUPPORTED_DEPTH`, 512),
 * `maxNumberLength`, `maxExponent` and `maxStringLength`, and `maxSteps` for
 * the conversion. Unset ones keep their defaults. Every decoder takes them
 * with its input, every encoder with its value (`Haus.encode` and
 * `Haus.encodeStream` as `limits` in their options):
 * `Haus.decode(Root)(text, { maxDepth: 512 })`. Encode with the limits you
 * decode with, and a decoded value always encodes again. A `maxDepth` above
 * 512 fails with a HausLimitsError.
 */
export type { Limits }

/**
 * The deepest nesting this binding supports (spec §7): 512 levels. The core
 * parser, the converters and Effect's own schema decoder recurse, so a
 * `maxDepth` above this fails with a HausLimitsError instead of overflowing
 * the stack on deep input. (Effect's decoder, the shallowest path, overflows
 * near 800 levels of Node's default stack.)
 */
export { MAX_SUPPORTED_DEPTH }

// ── errors ───────────────────────────────────────────────────

export { errorJson, HausLimitsError, HausParseError, HausSchemaError, type HausError } from "./errors.js"
export type { ErrorCode, ErrorJson } from "@haus-fmt/haus"

/**
 * Where a decode error is in the haus value: the innermost value the error's
 * path leads to (parse with `parseWithLocations` to get offsets).
 */
export const locateIssue = (value: Value, path: ReadonlyArray<string | number>): Value => {
  let v = value
  for (let i = 0; i < path.length; i++) {
    const key = path[i]!
    let next: Value | undefined
    if (v.kind === "array" && typeof key === "number") next = v.items[key]
    else if (v.kind === "record") next = v.fields.get(String(key))
    else if (v.kind === "variant") {
      const [first] = v.args
      const payload = v.args.length === 1 && first!.kind === "record" ? first! : undefined
      if (v.tag === "Some" && v.args.length === 1 && key === "value") next = first
      else if (typeof key === "number") next = v.args[key]
      else if (payload?.fields.has(key)) next = payload.fields.get(key)
      else if (key === "values" && typeof path[i + 1] === "number") next = v.args[path[++i] as number]
      // A payload `{ value: { … } }` (a record with a field `_tag`) is the record itself.
      else if (payload !== undefined && key === "value") next = payload
    }
    if (next === undefined) return v
    v = next
  }
  return v
}

/** Fail with a HausLimitsError for limits the binding can't honour (see `HausLimitsError`). */
const checkLimits = (limits: Limits): Effect.Effect<void, HausLimitsError> => {
  const issue = limitsIssue(limits)
  return issue === undefined ? Effect.void : Effect.fail(limitsError(issue))
}

/** `effect`, after checking `limits`. */
const withLimits = <A, E, R>(limits: Limits, effect: Effect.Effect<A, E, R>): Effect.Effect<A, E | HausLimitsError, R> =>
  Effect.andThen(checkLimits(limits), effect)

/** Re-index a HausSchemaError of a stream element; other errors pass unchanged. */
const atIndex = (index: number) => <E>(e: E | HausSchemaError): E | HausSchemaError => (e instanceof HausSchemaError ? errorAt(e, index) : e)

// ── Any ──────────────────────────────────────────────────────

/**
 * `Any` (spec §15): any value, kept exactly as parsed, as the haus `Value`
 * tree. Encoding writes it back unchanged, after checking that it is a haus
 * value within the limits. Treat its content as untrusted data.
 */
export const Any = Schema.Any.annotate({ [VALUE]: true }) as unknown as Schema.Codec<Value>

/** A syntax error of the core parser as a HausParseError; so is invalid UTF-8 in a byte stream (without a position). */
const parseErrorOf = (e: unknown): Option.Option<HausParseError> =>
  e instanceof HausSyntaxError ? Option.some(parseError(e))
  : errorCode(e) === "invalid-utf8" ? Option.some(invalidUtf8Error())
  : Option.none()

/** A conversion error as a HausSchemaError, decoding `input` or encoding. */
const conversionErrorOf = (input?: Value) => (e: unknown): Option.Option<HausSchemaError> =>
  e instanceof ConversionError ? Option.some(conversionError(e, input)) : Option.none()

/**
 * A synchronous step of the core or the converters (which report errors by
 * throwing), at the boundary to Effect: the exceptions `expected` recognizes
 * fail with its typed error; any other exception is a bug and stays a defect.
 */
const fromSync = <A, E>(f: () => A, expected: (e: unknown) => Option.Option<E>): Effect.Effect<A, E> =>
  Effect.sync(f).pipe(
    Effect.catchDefect((defect) => Option.match(expected(defect), { onNone: () => Effect.die(defect), onSome: Effect.fail })),
  )

// ── open unions ──────────────────────────────────────────────

/** What an OpenUnion produces for a tag none of its members knows. */
export const Unknown = Schema.TaggedStruct(UNKNOWN_TAG, {
  tag: Schema.String,
  /** The raw haus value, for logging or forwarding. */
  value: Schema.Any as Schema.Codec<Value>,
})
export type Unknown = typeof Unknown.Type

/**
 * `< A | B | _ >`: a union of tagged structs (or literals) that accepts any
 * other tag as `Unknown` instead of failing.
 */
export const OpenUnion = <const Members extends ReadonlyArray<Schema.Top>>(members: Members) =>
  Schema.Union([...members, Unknown])

/**
 * Allow positional arguments for a tagged struct: `Money(19.99, EUR)` fills
 * `{ amount, currency }` in declaration order. Opt-in, because reordering the
 * fields later would silently swap values of the same type.
 */
export const Positional = <S extends Schema.Top>(schema: S): S["Rebuild"] =>
  schema.annotate({ [POSITIONAL]: true })

// ── numbers ──────────────────────────────────────────────────

/**
 * haus `Float32` as a JS number: a number decodes to the nearest binary32
 * value, rounded directly from its exact decimal (spec §15), and is written
 * in the fewest digits that read back as that binary32 value. `Schema.Number`
 * is a `Float64`.
 */
// @effect-diagnostics-next-line schemaNumber:off -- Float32 includes NaN and the infinities (spec §15)
export const Float32 = Schema.Number.annotate({ [NUMBER]: "Float32" })

/** The id codecs use for the prelude's `Decimal`. */
export const DECIMAL_ID = "prelude#Decimal"

/**
 * haus `Decimal` (the default): any number, as its exact literal text,
 * normalized as the parser does (spec §2): `19.90` → "19.90", `1.5e3` →
 * "1.5e3", `-0` → "-0". Encoding writes the text back, so nothing is lost;
 * text that isn't one number literal is an error. Pass it to a decimal
 * library, or use `Haus.DecimalAsBigDecimal`.
 */
export const Decimal = setId(
  Schema.String.annotate({ [DECIMAL]: true }).check(
    Schema.makeFilter((s: string) => normalizeNumber(s) !== undefined || "a number literal, like \"19.90\""),
  ),
  DECIMAL_ID,
) as Named<Schema.String, typeof DECIMAL_ID>

/** A `Haus.Decimal` read as a BigDecimal: the text → BigDecimal, and back with its scale. */
const asBigDecimal = <S extends Schema.Codec<string, string>>(base: S) =>
  base.pipe(
    Schema.decodeTo(
      Schema.BigDecimal,
      SchemaTransformation.transform({ decode: (text: string) => BigDecimal.fromStringUnsafe(text), encode: decimalText }),
    ),
  )

/**
 * haus `Decimal` as an Effect `BigDecimal`: an explicit, lossy choice (spec
 * §13.4). It keeps the amount and the scale (`19.90` stays `19.90`), but
 * drops exponent notation and the sign of zero: `-0` is written `0`, `15e2`
 * as `1.5e3`, `1.5e-3` as `0.0015`. A different haus value, with another
 * canonical form and hash. For schema files, the codec `Haus.decimalAsBigDecimal`.
 */
export const DecimalAsBigDecimal = asBigDecimal(Decimal)

/** Codec for schema files: their `Decimal`s as BigDecimals, with the losses of `Haus.DecimalAsBigDecimal`. */
export const decimalAsBigDecimal = codec(Decimal, asBigDecimal)

// ── std/time ─────────────────────────────────────────────────

const stdTime = <S extends Schema.Top>(name: StdTimeType, schema: S) => setId(schema, `std/time#${name}`)

/** A std/time type written as `Tag("…")`, kept as its validated string (the std/time profile, spec/std/time.md). */
const timeString = <const Name extends StdTimeType>(name: Name) =>
  stdTime(
    name,
    Schema.String.annotate({ [PRELUDE_TAG]: name }).check(Schema.makeFilter((s: string) => checkStdTime(name, s) ?? true, { [CODE]: "invalid-time" })),
  ) as Named<Schema.String, `std/time#${Name}`>

/** `Date("2026-11-07")` as the ISO date string; encodes back to `Date("…")`. */
export const Date = timeString("Date")
/** `Time("14:30:00")` as the ISO time string. */
export const Time = timeString("Time")
/** `DateTime("2026-11-07T14:30:00")` (no zone) as the ISO string. */
export const DateTime = timeString("DateTime")
/** `Duration("PT30S")` as the ISO 8601 duration string. */
export const Duration = timeString("Duration")
/** `YearMonth("2026-11")` as the ISO string. */
export const YearMonth = timeString("YearMonth")
/** `TimeZone("Europe/Lisbon")` as the IANA name (not looked up). */
export const TimeZone = timeString("TimeZone")
/** `Instant("2026-11-07T10:00:00.250+01:00")` as its validated text, exactly as written (offset and fraction included). */
export const Instant = timeString("Instant")
/** `ZonedDateTime("2026-11-07T10:00:00+01:00[Europe/Lisbon]")` as its validated text, exactly as written. */
export const ZonedDateTime = timeString("ZonedDateTime")

/** An Effect DateTime as std/time text; a DateTime that std/time can't write (a year beyond 9999) is an encoding error. */
const writeDateTime = (d: EffectDateTime.DateTime) =>
  Effect.try({
    try: () => dateTimeText(d).text,
    catch: (e) => new SchemaIssue.InvalidValue({ message: e instanceof ConversionError ? e.message : String(e) }),
  })

const asDateTimeUtc = <S extends Schema.Codec<string, string>>(base: S) =>
  base.pipe(
    Schema.decodeTo(
      Schema.DateTimeUtc,
      SchemaTransformation.transformEffect({
        decode: (s: string) =>
          Option.match(EffectDateTime.make(s), {
            onNone: () => Effect.fail(new SchemaIssue.InvalidValue({ message: `${s} is not a DateTime.Utc` })),
            onSome: (d) => Effect.succeed(EffectDateTime.toUtc(d)),
          }),
        encode: writeDateTime,
      }),
    ),
  )

const asDateTimeZoned = <S extends Schema.Codec<string, string>>(base: S) =>
  base.pipe(
    Schema.decodeTo(
      Schema.DateTimeZoned,
      SchemaTransformation.transformEffect({
        decode: (s: string) =>
          Option.match(EffectDateTime.makeZonedFromString(s), {
            onNone: () => Effect.fail(new SchemaIssue.InvalidValue({ message: `${s}: a zone that Intl doesn't know` })),
            onSome: Effect.succeed,
          }),
        encode: writeDateTime,
      }),
    ),
  )

/**
 * std/time `Instant` as an Effect `DateTime.Utc`: an explicit, lossy choice
 * (spec §13.4). It keeps the instant to the millisecond, and drops digits
 * below the millisecond, the offset and the fraction as written:
 * `…10:00:00.250+01:00` is written `…09:00:00.250Z`, `…10:00:00.000Z` is
 * written `…10:00:00Z`. A different haus value, with another canonical form
 * and hash. A DateTime outside the years 0000–9999 can't be written (an
 * encoding error). For schema files, the codec `Haus.instantAsDateTime`.
 */
export const InstantAsDateTime = asDateTimeUtc(Instant)

/**
 * std/time `ZonedDateTime` as an Effect `DateTime.Zoned`: an explicit, lossy
 * choice (spec §13.4). It keeps the instant to the millisecond and the zone,
 * and drops digits below the millisecond, the offset and the fraction as
 * written (the offset is written as the zone has it at that instant). Zone
 * names are looked up with Intl: an unknown zone is an error (std/time
 * accepts any well-formed name), and a name Intl canonicalises is written
 * that way (`Etc/UTC` → `UTC`). A zone that is an offset is written in
 * brackets, `…+01:00[+01:00]`. For schema files, the codec `Haus.zonedDateTimeAsDateTime`.
 */
export const ZonedDateTimeAsDateTime = asDateTimeZoned(ZonedDateTime)

/** Codec for schema files: their `Instant`s as `DateTime.Utc`, with the losses of `Haus.InstantAsDateTime`. */
export const instantAsDateTime = codec(Instant, asDateTimeUtc)

/** Codec for schema files: their `ZonedDateTime`s as `DateTime.Zoned`, with the losses of `Haus.ZonedDateTimeAsDateTime`. */
export const zonedDateTimeAsDateTime = codec(ZonedDateTime, asDateTimeZoned)

// ── decoding ─────────────────────────────────────────────────

const decodeOptions = { onExcessProperty: "ignore", errors: "first" } as const

/** The schema with codecs applied (cached); the schema itself without codecs. */
const target = <S extends Schema.Top>(schema: S, codecs: ReadonlyArray<AnyCodec>): S => {
  if (codecs.length === 0) return schema
  entries(codecs) // two codecs for one type fail here, before anything is built
  return withCodecs(schema, codecs) as S
}

/**
 * Decode an already-parsed haus value. With codecs, their types replace the
 * named types they target (`Haus.decodeValue(Root, cents)`). The value is
 * held to the limits (a value built in code may nest deeper than parsed text).
 */
export const decodeValue = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const s = target(schema, codecs)
  const ast = SchemaAST.toEncoded(s.ast)
  checkSchema(ast)
  const convert = compile(ast)
  const decode = Schema.decodeUnknownEffect(s)
  return (value: Value, limits: Limits = {}): Effect.Effect<Decoded<S, C>, HausSchemaError | HausLimitsError, S["DecodingServices"]> =>
    withLimits(
      limits,
      // Conversion work is bounded by the size of the input (see convert.ts).
      fromSync(() => decoding(value, limits, convert), conversionErrorOf(value)).pipe(
        Effect.flatMap((encoded) => decode(encoded, decodeOptions)),
        Effect.mapError((e) => (e instanceof HausSchemaError ? e : issueError(e, value, "decode"))),
      ),
    ) as Effect.Effect<Decoded<S, C>, HausSchemaError | HausLimitsError, S["DecodingServices"]>
}

/** `decodeValue` for codecs already checked by the caller's signature. */
const valueDecoder = <S extends Schema.Top, C extends ReadonlyArray<AnyCodec>>(schema: S, codecs: ReadonlyArray<AnyCodec>) =>
  (decodeValue as (s: S, ...c: ReadonlyArray<AnyCodec>) => (v: Value, limits?: Limits) => Effect.Effect<Decoded<S, C>, HausSchemaError | HausLimitsError, S["DecodingServices"]>)(
    schema,
    ...codecs,
  )

/**
 * Parse a text holding exactly one value and decode it:
 *
 *   Haus.decode(Root)(text)                         // the types of the schema
 *   Haus.decode(Root, cents, geojson)(text)         // with the codecs' types for Money and LatLng
 *   Haus.decode(Root)(text, { maxDepth: 512 })      // other limits than the defaults (spec §7)
 */
export const decode = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const fromValue = valueDecoder<S, C>(schema, codecs)
  return Effect.fn("Haus.decode")(function* (text: string, limits: Limits = {}) {
    yield* checkLimits(limits)
    const values = yield* fromSync(() => parseAll(text, limits), parseErrorOf)
    if (values.length !== 1) {
      return yield* schemaErrorOf(`expected exactly one value, found ${values.length}`, "not-one-value")
    }
    return yield* fromValue(values[0]!, limits)
  })
}

/**
 * Apply codecs to a value already decoded without them, e.g. a typed data
 * import (`import order from "./order.haus"`): `Haus.convert(Root, cents)(order)`.
 */
export const convert = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const encode = Schema.encodeEffect(schema as unknown as Schema.Codec<S["Type"], S["Encoded"]>)
  const decode = Schema.decodeUnknownEffect(target(schema, codecs))
  return (value: S["Type"]): Effect.Effect<Decoded<S, C>, HausSchemaError> =>
    encode(value).pipe(
      Effect.mapError((e) => issueError(e, undefined, "encode")),
      Effect.flatMap((encoded) => decode(encoded, decodeOptions).pipe(Effect.mapError((e) => issueError(e, undefined, "decode")))),
    ) as Effect.Effect<Decoded<S, C>, HausSchemaError>
}

/** An error of the source stream, carried through the parser unchanged. */
class SourceFailure<E> {
  constructor(readonly error: E) {}
}

/** Decodes a source of text or bytes into a stream of values, each within the limits (spec §7). */
export interface SourceDecoder<A, R> {
  (source: ChunkSource, limits?: Limits): Stream.Stream<A, HausError, R>
  <E, R2>(source: Stream.Stream<string | Uint8Array, E, R2>, limits?: Limits): Stream.Stream<A, HausError | E, R | R2>
}

/**
 * Items read from a source as they arrive (`read`: haus values, JSON
 * lines), each decoded as it is emitted. The source's own errors pass
 * through; syntax errors are HausParseErrors; anything else is a bug.
 */
const decodeSource = <X, A, R>(
  read: (chunks: ChunkSource, limits: Limits) => AsyncIterable<X>,
  decodeItem: (item: X, limits: Limits) => Effect.Effect<A, HausSchemaError | HausLimitsError, R>,
  span: string,
): SourceDecoder<A, R> => {
  const decodeChunks = <E>(chunks: ChunkSource, limits: Limits): Stream.Stream<A, HausError | E, R> =>
    Stream.fromAsyncIterable(read(chunks, limits), (e) => e).pipe(
      Stream.catch((e): Stream.Stream<never, HausParseError | E> =>
        e instanceof SourceFailure ? Stream.fail(e.error as E)
        : Option.match(parseErrorOf(e), { onNone: () => Stream.die(e), onSome: Stream.fail })),
      Stream.zipWithIndex,
      Stream.mapEffect(([item, index]) => decodeItem(item, limits).pipe(Effect.mapError(atIndex(index)))),
    )
  function decode(source: ChunkSource, limits?: Limits): Stream.Stream<A, HausError, R>
  function decode<E, R2>(source: Stream.Stream<string | Uint8Array, E, R2>, limits?: Limits): Stream.Stream<A, HausError | E, R | R2>
  function decode<E, R2>(source: ChunkSource | Stream.Stream<string | Uint8Array, E, R2>, limits: Limits = {}): Stream.Stream<A, HausError | E, R | R2> {
    const issue = limitsIssue(limits)
    if (issue !== undefined) return Stream.fail(limitsError(issue))
    const decoded = Stream.isStream(source)
      ? Stream.unwrap(
        Stream.toAsyncIterableEffect(
          (source as Stream.Stream<string | Uint8Array, E, R2>).pipe(Stream.mapError((e) => new SourceFailure(e))),
        ).pipe(Effect.map((chunks) => decodeChunks<E>(chunks, limits))),
      )
      : decodeChunks<never>(source as ChunkSource, limits)
    return decoded.pipe(Stream.withSpan(span))
  }
  return decode
}

/**
 * Parse and decode a stream of values as they arrive. The source is an Effect
 * Stream of text or bytes (e.g. `FileSystem.stream(path)`; its errors pass
 * through), an async iterable or a web ReadableStream. Parsing stays in the
 * optimized core reader; each completed value is decoded as it is emitted.
 * Limits go with the source: `Haus.decodeStream(Event)(body, { maxDepth: 64 })`.
 */
export const decodeStream = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(
  schema: S,
  ...codecs: C & Checked<S, C>
): SourceDecoder<Decoded<S, C>, S["DecodingServices"]> => {
  const fromValue = valueDecoder<S, C>(schema, codecs)
  return decodeSource((chunks, limits) => parseStream(chunks, { limits }), fromValue, "Haus.decodeStream")
}

// ── encoding ─────────────────────────────────────────────────

/**
 * Encode a typed value into a haus `Value` (Effect's encoder runs first:
 * transformations, filters…), within the limits: the value nests at most
 * `maxDepth` levels, so that the parser reads it again.
 */
export const encodeValue = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const s = target(schema, codecs)
  const ast = SchemaAST.toEncoded(s.ast)
  checkSchema(ast)
  const toValue = compileEncoder(ast)
  const encode = Schema.encodeUnknownEffect(s)
  return (value: Decoded<S, C>, limits: Limits = {}): Effect.Effect<Value, HausSchemaError | HausLimitsError, S["EncodingServices"]> =>
    withLimits(
      limits,
      encode(value, { errors: "first" }).pipe(
        Effect.mapError((e) => issueError(e, undefined, "encode")),
        Effect.flatMap((encoded) => fromSync(() => encoding(limits, () => toValue(encoded)), conversionErrorOf())),
      ),
    ) as Effect.Effect<Value, HausSchemaError | HausLimitsError, S["EncodingServices"]>
}

/** Options of the haus encoders: the format, and the limits the value is held to (spec §7). */
export interface EncodeOptions extends FormatOptions {
  /** The limits of the reader the text is for (its `maxNumberLength` is also the format's, unless that is set). */
  readonly limits?: Limits
}

/** Codecs, or options (the older form `encode(schema, options)`). */
const splitArgs = (args: ReadonlyArray<AnyCodec | EncodeOptions | undefined>): [ReadonlyArray<AnyCodec>, EncodeOptions] => {
  const codecs = args.filter(isCodec)
  const options = args.find((a): a is EncodeOptions => a !== undefined && !isCodec(a)) ?? {}
  return [codecs, options]
}

/** Options given when building an encoder, then with the value: the format, and the limits merged field by field. */
const withOptions = (defaults: EncodeOptions, options: EncodeOptions = {}): [FormatOptions, Limits] => {
  const { limits: baseLimits, ...baseFormat } = defaults
  const { limits: ownLimits, ...format } = options
  const limits: Limits = { ...baseLimits, ...ownLimits }
  const numbers = limits.maxNumberLength === undefined ? {} : { maxNumberLength: limits.maxNumberLength }
  return [{ ...numbers, ...baseFormat, ...format }, limits]
}

/** `encodeValue` for codecs already checked by the caller's signature. */
const valueEncoder = <S extends Schema.Top, C extends ReadonlyArray<AnyCodec>>(schema: S, codecs: ReadonlyArray<AnyCodec>) =>
  (encodeValue as (s: S, ...c: ReadonlyArray<AnyCodec>) => (v: Decoded<S, C>, limits?: Limits) => Effect.Effect<Value, HausSchemaError | HausLimitsError, S["EncodingServices"]>)(
    schema,
    ...codecs,
  )

/**
 * Encode a typed value as haus text in the standard format (no trailing
 * newline). Pass the same codecs as for decoding; options go with the
 * value: `Haus.encode(Root, cents)(order, { style: "compact" })` (or
 * `"minimised"`, without whitespace, for the wire and storage, spec §11),
 * and `{ limits: { maxDepth: 512 } }` for a reader with other limits (spec §7).
 */
export function encode<S extends Schema.Top>(schema: S, options?: EncodeOptions): (value: S["Type"], options?: EncodeOptions) => Effect.Effect<string, HausSchemaError | HausLimitsError, S["EncodingServices"]>
export function encode<S extends Schema.Top, const C extends ReadonlyArray<AnyCodec>>(schema: S, ...codecs: C & Checked<S, C>): (value: Decoded<S, C>, options?: EncodeOptions) => Effect.Effect<string, HausSchemaError | HausLimitsError, S["EncodingServices"]>
export function encode<S extends Schema.Top>(schema: S, ...args: ReadonlyArray<AnyCodec | EncodeOptions | undefined>) {
  const [codecs, defaults] = splitArgs(args)
  const toValue = valueEncoder<S, []>(schema, codecs)
  return Effect.fn("Haus.encode")(function* (value: S["Type"], options?: EncodeOptions) {
    const [format, limits] = withOptions(defaults, options)
    return stringify(yield* toValue(value, limits), format)
  })
}

/**
 * Encode a stream of values as haus stream chunks, each ending in ",\n".
 * Compact by default (one item per line); pass `{ style: "minimised" }` for
 * one item per line without whitespace, `{ style: "pretty" }` for multi-line items.
 */
export function encodeStream<S extends Schema.Top>(schema: S, options?: EncodeOptions): <E, R>(values: Stream.Stream<S["Type"], E, R>, options?: EncodeOptions) => Stream.Stream<string, E | HausSchemaError | HausLimitsError, R | S["EncodingServices"]>
export function encodeStream<S extends Schema.Top, const C extends ReadonlyArray<AnyCodec>>(schema: S, ...codecs: C & Checked<S, C>): <E, R>(values: Stream.Stream<Decoded<S, C>, E, R>, options?: EncodeOptions) => Stream.Stream<string, E | HausSchemaError | HausLimitsError, R | S["EncodingServices"]>
export function encodeStream<S extends Schema.Top>(schema: S, ...args: ReadonlyArray<AnyCodec | EncodeOptions | undefined>) {
  const [codecs, defaults] = splitArgs(args)
  const toValue = valueEncoder<S, []>(schema, codecs)
  return <E, R>(values: Stream.Stream<S["Type"], E, R>, options?: EncodeOptions): Stream.Stream<string, E | HausSchemaError | HausLimitsError, R | S["EncodingServices"]> => {
    const [format, limits] = withOptions(defaults, options)
    const issue = limitsIssue(limits)
    if (issue !== undefined) return Stream.fail(limitsError(issue))
    return values.pipe(
      Stream.zipWithIndex,
      Stream.mapEffect(([value, index]) =>
        toValue(value, limits).pipe(
          Effect.map((v) => stringify(v, { style: "compact", ...format }) + ",\n"),
          Effect.mapError(atIndex(index)),
        )),
      Stream.withSpan("Haus.encodeStream"),
    )
  }
}

// ── JSON (spec §16) ──────────────────────────────────────────

/** A JSON mapping error of the core (JSON that doesn't fit, a value without a JSON form) as a HausSchemaError. */
const jsonErrorOf = (e: unknown): Option.Option<HausSchemaError> =>
  e instanceof HausDecodeError || e instanceof HausEncodeError ? Option.some(jsonError(e)) : Option.none()

/** The schema-based JSON form of a schema with codecs: the form of its encoded side. */
const jsonForm = (schema: Schema.Top, codecs: ReadonlyArray<AnyCodec>): JsonType => jsonTypeOf(SchemaAST.toEncoded(target(schema, codecs).ast))

/**
 * The limits for reading the schema-based JSON of values within `limits`: JSON may nest
 * `jsonDepth(maxDepth)` levels, enough for every haus value within `maxDepth`
 * (spec §16); the value is then held to `maxDepth` itself.
 */
const jsonLimits = (limits: Limits): Limits => ({ ...limits, maxDepth: jsonDepth(limits.maxDepth ?? MAX_DEPTH) })

/**
 * Encode a typed value as schema-based JSON (spec §16.3), a JSON value
 * (`JsonNumber`s keep numbers exact; `Haus.toJson` writes the text).
 */
export const toJsonValue = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const type = jsonForm(schema, codecs)
  const toValue = valueEncoder<S, C>(schema, codecs)
  return (value: Decoded<S, C>, limits: Limits = {}): Effect.Effect<Json, HausSchemaError | HausLimitsError, S["EncodingServices"]> =>
    toValue(value, limits).pipe(Effect.flatMap((v) => fromSync(() => toSchemaBasedJson(type, v, limits), jsonErrorOf)))
}

/** `toJsonValue` for codecs already checked by the caller's signature. */
const jsonEncoder = <S extends Schema.Top, C extends ReadonlyArray<AnyCodec>>(schema: S, codecs: ReadonlyArray<AnyCodec>) =>
  (toJsonValue as (s: S, ...c: ReadonlyArray<AnyCodec>) => (v: Decoded<S, C>, limits?: Limits) => Effect.Effect<Json, HausSchemaError | HausLimitsError, S["EncodingServices"]>)(
    schema,
    ...codecs,
  )

/**
 * Encode a typed value as schema-based JSON text (spec §16.3), compact: what a JSON
 * consumer expects, with the schema saying what JSON can't. `BigInt` and the
 * 64-bit integers of schema files are strings, decimals strings (`"19.90"`),
 * bytes base64, an `Option` `null` or its value (tagged when its value can
 * be `null`), literal unions strings, tagged structs `{"_tag": …, …}`.
 *
 *   yield* Haus.toJson(Order)(order)   // '{"id":1,"total":"19.90","note":null}'
 */
export const toJson = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const toJsonOf = jsonEncoder<S, C>(schema, codecs)
  return Effect.fn("Haus.toJson")(function* (value: Decoded<S, C>, limits: Limits = {}) {
    const json = yield* toJsonOf(value, limits)
    return yield* fromSync(() => stringifyJson(json), jsonErrorOf)
  })
}

/** Decode schema-based JSON (spec §16.3) that is already parsed (with `parseJson`, which keeps numbers exact). */
export const fromJsonValue = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const type = jsonForm(schema, codecs)
  const fromValue = valueDecoder<S, C>(schema, codecs)
  return (json: Json, limits: Limits = {}): Effect.Effect<Decoded<S, C>, HausSchemaError | HausLimitsError, S["DecodingServices"]> =>
    withLimits(limits, fromSync(() => fromSchemaBasedJson(type, json, limits), jsonErrorOf).pipe(Effect.flatMap((value) => fromValue(value, limits))))
}

/** `fromJsonValue` for codecs already checked by the caller's signature. */
const jsonDecoder = <S extends Schema.Top, C extends ReadonlyArray<AnyCodec>>(schema: S, codecs: ReadonlyArray<AnyCodec>) =>
  (fromJsonValue as (s: S, ...c: ReadonlyArray<AnyCodec>) => (j: Json, limits?: Limits) => Effect.Effect<Decoded<S, C>, HausSchemaError | HausLimitsError, S["DecodingServices"]>)(
    schema,
    ...codecs,
  )

/**
 * Decode schema-based JSON text (spec §16.3): the forms `Haus.toJson` writes, with
 * the rules of decoding haus (open structs ignore other members, integers
 * must be whole numbers, an OpenUnion keeps other tags as `Unknown`).
 * Text that isn't I-JSON (duplicate members, unpaired surrogates) fails with
 * a HausParseError; JSON that doesn't fit the schema with a HausSchemaError.
 * Limits go with the text, as for `Haus.decode`.
 */
export const fromJson = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const fromJsonOf = jsonDecoder<S, C>(schema, codecs)
  return Effect.fn("Haus.fromJson")(function* (text: string, limits: Limits = {}) {
    yield* checkLimits(limits)
    const json = yield* fromSync(() => parseJson(text, jsonLimits(limits)), parseErrorOf)
    return yield* fromJsonOf(json, limits)
  })
}

/**
 * Decode a JSON Lines stream (one schema-based JSON text per line, spec §16) as the
 * lines arrive, from the same sources as `Haus.decodeStream`, with limits per
 * line. Errors carry the line's index.
 */
export const decodeJsonLines = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(
  schema: S,
  ...codecs: C & Checked<S, C>
): SourceDecoder<Decoded<S, C>, S["DecodingServices"]> =>
  decodeSource((chunks, limits) => parseJsonLines(chunks, { limits: jsonLimits(limits) }), jsonDecoder<S, C>(schema, codecs), "Haus.decodeJsonLines")

/** Encode a stream of values as JSON Lines of their schema-based JSON (spec §16): one line per value, each ending in a line feed. */
export const encodeJsonLines = <S extends Schema.Top, const C extends ReadonlyArray<AnyCodec> = []>(schema: S, ...codecs: C & Checked<S, C>) => {
  const toJsonOf = jsonEncoder<S, C>(schema, codecs)
  return <E, R>(values: Stream.Stream<Decoded<S, C>, E, R>, limits: Limits = {}): Stream.Stream<string, E | HausSchemaError | HausLimitsError, R | S["EncodingServices"]> => {
    const issue = limitsIssue(limits)
    if (issue !== undefined) return Stream.fail(limitsError(issue))
    return values.pipe(
      Stream.zipWithIndex,
      Stream.mapEffect(([value, index]) =>
        toJsonOf(value, limits).pipe(
          Effect.flatMap((json) => fromSync(() => stringifyJson(json) + "\n", jsonErrorOf)),
          Effect.mapError(atIndex(index)),
        )),
      Stream.withSpan("Haus.encodeJsonLines"),
    )
  }
}

/** A JSON reading error of the core: text that isn't I-JSON as a HausParseError, JSON that isn't the form as a HausSchemaError. */
const readErrorOf = (e: unknown) => Option.orElse(parseErrorOf(e), () => jsonErrorOf(e))

/**
 * Import JSON text without a schema (spec §16.1), as a haus `Value`: objects
 * as records, `true`/`false`/`null` as `True`/`False`/`None`, numbers exact.
 * Nothing in the data is special: `{"_tag": "Circle"}` is a record.
 */
export const importJson = Effect.fn("Haus.importJson")(function* (text: string, limits: Limits = {}) {
  yield* checkLimits(limits)
  return yield* fromSync(() => importedValue(text, limits), readErrorOf)
})

/**
 * The self-describing JSON text of a haus `Value` (spec §16.2),
 * `{"_haus":1,"_value":…}`: every haus value exactly, without a schema. For a
 * typed value, encode it first (`Haus.encodeValue`).
 *
 *   yield* Haus.toHausJson(value)   // '{"_haus":1,"_value":{"_rec":{"total":{"_num":"19.90"}}}}'
 */
export const toHausJson = Effect.fn("Haus.toHausJson")(function* (value: Value, limits: Limits = {}) {
  yield* checkLimits(limits)
  return yield* fromSync(() => hausJsonOf(value, limits), jsonErrorOf)
})

/**
 * Read self-describing JSON text (spec §16.2) as a haus `Value`: the envelope
 * `{"_haus": 1, "_value": …}` and exactly the forms `Haus.toHausJson` writes.
 * Text that isn't I-JSON (or holds raw DEL, C1 or bidi controls) fails with a
 * HausParseError, any other JSON with a HausSchemaError.
 */
export const fromHausJson = Effect.fn("Haus.fromHausJson")(function* (text: string, limits: Limits = {}) {
  yield* checkLimits(limits)
  return yield* fromSync(() => valueOfHausJson(text, limits), readErrorOf)
})

export { jsonTypeOf } from "./json.js"

// ── codecs ───────────────────────────────────────────────────

export {
  codec, codecs, CodecTypeId, idOf, isCodec, type AnyCodec, type Codec, type CodecMap, type Checked, type Decoded, type Kind, type Lookup,
  type Named, type NamedInfo, type NotInSchema, type TypeLambda,
} from "./codec.js"

// ── equality and order ───────────────────────────────────────

export { HausKey, key, ValueEquivalence, ValueOrder } from "./equal.js"

// ── schema files ─────────────────────────────────────────────

export { compileSchemaFile, definitionDoc, fromSchemaFile, schemaDeclarations, withCodecs, type CompiledSchemaFile, type DeclarationOptions, type FromSchemaFileOptions } from "./schema-file.js"
