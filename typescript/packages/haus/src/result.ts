/**
 * The outcome of a step that can fail, without exceptions: a `Success` with
 * a value or a `Failure` with an error. The shape and the names are Effect
 * 4's `Result`, so code moves between the two without surprises; this one is
 * small on purpose and stays as it is.
 *
 *   const order = pipe(
 *     parse(text),
 *     Result.flatMap((v) => Schema.decodeValue(schema, Order)(v)),
 *     Result.map((o) => o.total),
 *   )
 *   Result.match(order, { onSuccess: (total) => …, onFailure: (e) => console.error(e.message) })
 *
 * Every function takes its data first (`Result.map(r, f)`) or last
 * (`Result.map(f)`, for `pipe`).
 */

export interface Success<A> {
  readonly _tag: "Success"
  readonly success: A
}

export interface Failure<E> {
  readonly _tag: "Failure"
  readonly failure: E
}

export type Result<A, E = never> = Success<A> | Failure<E>

const succeed = <A>(success: A): Result<A, never> => Object.freeze({ _tag: "Success", success })
const fail = <E>(failure: E): Result<never, E> => Object.freeze({ _tag: "Failure", failure })
const isSuccess = <A, E>(r: Result<A, E>): r is Success<A> => r._tag === "Success"
const isFailure = <A, E>(r: Result<A, E>): r is Failure<E> => r._tag === "Failure"

/** Whether `u` is a Result (one of this module's, or of the same shape). */
const isResult = (u: unknown): u is Result<unknown, unknown> =>
  typeof u === "object" && u !== null &&
  (((u as { _tag?: unknown })._tag === "Success" && "success" in u) || ((u as { _tag?: unknown })._tag === "Failure" && "failure" in u))

/** Data-first with all `arity` arguments, data-last (a function of the Result) with one fewer. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const dual = <T>(arity: number, body: (...args: any[]) => unknown): T =>
  ((...args: unknown[]) => (args.length >= arity ? body(...args) : (self: unknown) => body(self, ...args))) as T

/** The success value mapped by `f`; a failure unchanged. */
const map: {
  <A, B>(f: (a: A) => B): <E>(self: Result<A, E>) => Result<B, E>
  <A, E, B>(self: Result<A, E>, f: (a: A) => B): Result<B, E>
} = dual(2, <A, E, B>(self: Result<A, E>, f: (a: A) => B): Result<B, E> => (isSuccess(self) ? succeed(f(self.success)) : (self as Failure<E>)))

/** The next step, run on a success; a failure unchanged. */
const flatMap: {
  <A, B, E2>(f: (a: A) => Result<B, E2>): <E>(self: Result<A, E>) => Result<B, E | E2>
  <A, E, B, E2>(self: Result<A, E>, f: (a: A) => Result<B, E2>): Result<B, E | E2>
} = dual(2, <A, E, B, E2>(self: Result<A, E>, f: (a: A) => Result<B, E2>): Result<B, E | E2> => (isSuccess(self) ? f(self.success) : (self as Failure<E>)))

/** One of two functions applied, by the outcome. */
const match: {
  <A, E, B, C = B>(cases: { readonly onSuccess: (a: A) => B; readonly onFailure: (e: E) => C }): (self: Result<A, E>) => B | C
  <A, E, B, C = B>(self: Result<A, E>, cases: { readonly onSuccess: (a: A) => B; readonly onFailure: (e: E) => C }): B | C
} = dual(2, <A, E, B, C>(self: Result<A, E>, cases: { readonly onSuccess: (a: A) => B; readonly onFailure: (e: E) => C }): B | C =>
  isSuccess(self) ? cases.onSuccess(self.success) : cases.onFailure(self.failure))

/** The Result functions, as a namespace: `Result.succeed`, `Result.map`, … */
export const Result = Object.freeze({ succeed, fail, map, flatMap, match, isSuccess, isFailure, isResult })

// ── pipe ─────────────────────────────────────────────────────

/** `a` passed through the functions from left to right: `pipe(x, f, g)` is `g(f(x))`. */
export function pipe<A>(a: A): A
export function pipe<A, B>(a: A, ab: (a: A) => B): B
export function pipe<A, B, C>(a: A, ab: (a: A) => B, bc: (b: B) => C): C
export function pipe<A, B, C, D>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D): D
export function pipe<A, B, C, D, E>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E): E
export function pipe<A, B, C, D, E, F>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E, ef: (e: E) => F): F
export function pipe<A, B, C, D, E, F, G>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E, ef: (e: E) => F, fg: (f: F) => G): G
export function pipe<A, B, C, D, E, F, G, H>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E, ef: (e: E) => F, fg: (f: F) => G, gh: (g: G) => H): H
export function pipe<A, B, C, D, E, F, G, H, I>(a: A, ab: (a: A) => B, bc: (b: B) => C, cd: (c: C) => D, de: (d: D) => E, ef: (e: E) => F, fg: (f: F) => G, gh: (g: G) => H, hi: (h: H) => I): I
export function pipe(a: unknown, ...fs: readonly ((x: unknown) => unknown)[]): unknown {
  return fs.reduce((x, f) => f(x), a)
}

// ── for this package ─────────────────────────────────────────

/**
 * @internal `run()` as a Result: the errors `isError` recognizes become its
 * failure; anything else (a bug, a stack overflow already reported, a
 * programming error such as `value-changed`) is thrown on.
 */
export const attempt = <A, E>(run: () => A, isError: (e: unknown) => e is E): Result<A, E> => {
  try {
    return succeed(run())
  } catch (e) {
    if (isError(e)) return fail(e)
    throw e
  }
}
