/**
 * Typed handles of schema types (spec §13.3, "Identity"): a value naming a
 * type by its id, `@haus-fmt/money@1#Money`, that carries the type's
 * TypeScript type. `@haus-fmt/import` declares one per type of a schema file
 * (`import { Order } from "./order.schema.haus"`), the official packages
 * export theirs (`@haus-fmt/haus/money`), and `Prelude` and `StdTime` have the
 * built-in ones. Decoding, encoding, codecs and rules take handles, so a
 * codec for a type that can't have one doesn't compile.
 *
 * A type's TypeScript type depends on the codecs a schema has (a codec for
 * `std/time#Instant` makes every `Instant` a `Date`), so a handle carries a
 * type function, `F`, from the codecs' host types to the type:
 *
 *   interface Order$ extends TypeLambda { readonly type: Order<this["hosts"]> }
 *   declare const Order: Type<Order$, "app/order#Order">
 *   TypeOf<Order$, {}>                                     // the type without codecs
 *   TypeOf<Order$, { "std/time#Instant": Date }>           // with an Instant codec
 */

/** A type as a function of the host types the codecs choose (`hosts`, by type id). */
export interface TypeLambda {
  readonly hosts: unknown
  readonly type: unknown
}

/** The TypeScript type of `F` with the codecs' host types `H` (by type id; `{}` for none). */
export type TypeOf<F extends TypeLambda, H> = (F & { readonly hosts: H })["type"]

/** The host type of the type `Id` with the codecs `H`: the codec's, or `Default` without one. */
export type Host<H, Id extends string, Default> = Id extends keyof H ? H[Id] : Default

/** A handle of a named type without parameters, which can have a codec and a rule (spec §13.4). */
export interface Type<F extends TypeLambda = TypeLambda, Id extends string = string> {
  readonly _tag: "Type"
  /** The type's id: `@haus-fmt/money@1#Money`, `prelude#Decimal`, `app/order#Order`. */
  readonly id: Id
  /** The type's name: `Money`. */
  readonly name: string
  /** Type-level only: the type function. */
  readonly "~F"?: F
}

/** A handle of a type that describes a whole file as a stream (`type Log = Stream Entry`): no codec, no rule. */
export interface StreamType<F extends TypeLambda = TypeLambda, Id extends string = string> {
  readonly _tag: "StreamType"
  readonly id: Id
  readonly name: string
  readonly "~F"?: F
}

/** The name of a type id: `Money` of `@haus-fmt/money@1#Money`. */
const nameOf = (id: string): string => id.slice(id.lastIndexOf("#") + 1)

/** A type function giving `A` whatever the codecs: for handles made by hand. */
export interface Const<A> extends TypeLambda {
  readonly type: A
}

/** A type function of a built-in type: `A`, or the host type of a codec for `Id`. */
export interface Builtin<Id extends string, A> extends TypeLambda {
  readonly type: Host<this["hosts"], Id, A>
}

export const Type = Object.freeze({
  /**
   * The handle of the type `id`. Generated code makes them; by hand, give its
   * TypeScript type: `Type.make<Const<MyRecord>>("app/x#MyRecord")`.
   */
  make: <F extends TypeLambda, Id extends string = string>(id: Id): Type<F, Id> => Object.freeze({ _tag: "Type", id, name: nameOf(id) }),
  /** The handle of a stream type (`type Log = Stream Entry`). */
  stream: <F extends TypeLambda, Id extends string = string>(id: Id): StreamType<F, Id> => Object.freeze({ _tag: "StreamType", id, name: nameOf(id) }),
  /** Whether `u` is a type handle. */
  is: (u: unknown): u is Type => typeof u === "object" && u !== null && (u as { _tag?: unknown })._tag === "Type",
})

const builtin = <A>() => <Id extends string>(id: Id): Type<Builtin<Id, A>, Id> => Type.make<Builtin<Id, A>, Id>(id)

/**
 * The handles of the prelude's named types without parameters (spec §13):
 * codecs can choose their host types (`Codec.make(Prelude.Decimal, …)`).
 * Their default host types are those of the decoders: `Decimal` the exact
 * literal text, `Int` a bigint of any size, `Int8` … `UInt32` numbers.
 */
export const Prelude = Object.freeze({
  String: builtin<string>()("prelude#String"),
  Bytes: builtin<Uint8Array>()("prelude#Bytes"),
  Bool: builtin<boolean>()("prelude#Bool"),
  Decimal: builtin<string>()("prelude#Decimal"),
  Int: builtin<bigint>()("prelude#Int"),
  Int8: builtin<number>()("prelude#Int8"),
  Int16: builtin<number>()("prelude#Int16"),
  Int32: builtin<number>()("prelude#Int32"),
  Int64: builtin<bigint>()("prelude#Int64"),
  UInt8: builtin<number>()("prelude#UInt8"),
  UInt16: builtin<number>()("prelude#UInt16"),
  UInt32: builtin<number>()("prelude#UInt32"),
  UInt64: builtin<bigint>()("prelude#UInt64"),
  Float32: builtin<number>()("prelude#Float32"),
  Float64: builtin<number>()("prelude#Float64"),
})

/** The handles of `std/time`'s types (spec §13.2): each the text as written, checked (`Instant` → "2026-11-07T10:00:00Z"). */
export const StdTime = Object.freeze({
  Date: builtin<string>()("std/time#Date"),
  Time: builtin<string>()("std/time#Time"),
  DateTime: builtin<string>()("std/time#DateTime"),
  Instant: builtin<string>()("std/time#Instant"),
  ZonedDateTime: builtin<string>()("std/time#ZonedDateTime"),
  Duration: builtin<string>()("std/time#Duration"),
  YearMonth: builtin<string>()("std/time#YearMonth"),
  TimeZone: builtin<string>()("std/time#TimeZone"),
})
