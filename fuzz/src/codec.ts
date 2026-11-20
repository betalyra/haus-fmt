/**
 * The compiled codecs of @haus-fmt/haus (closures, codec.ts; generated code,
 * codegen.ts, made at runtime and built ahead by @haus-fmt/import) against
 * its generic path, for the schema fuzzer's `typescript-codec` runner
 * (schema-runners.ts): the same values (types, prototypes, own keys in
 * order), the same texts and the same errors (class, message, code, place,
 * details), on a case's text, on texts near it and on values near the
 * decoded one. And a compiled codec gives up (falling back to the generic
 * path) only where there is an error.
 */
import { decodeCompiled, encodeCompiled } from "../../typescript/packages/haus/dist/codec.js"
import { generatedOrigin, readerFor, writerFor } from "../../typescript/packages/haus/dist/codegen.js"
import * as h from "../../typescript/packages/haus/dist/schema.js"
import { Secret } from "../../typescript/packages/haus/dist/secret.js"

/** The first difference between two values, or undefined. */
export const difference = (a: unknown, b: unknown, at = "$"): string | undefined => {
  if (typeof a !== typeof b) return `${at}: ${typeof a} vs ${typeof b}`
  if (typeof a !== "object" || a === null || b === null) return Object.is(a, b) ? undefined : `${at}: ${String(a)} vs ${String(b)}`
  const x = a as object
  const y = b as object
  if (Object.getPrototypeOf(x) !== Object.getPrototypeOf(y)) return `${at}: another prototype`
  if (Object.isFrozen(x) !== Object.isFrozen(y) || Object.isExtensible(x) !== Object.isExtensible(y)) return `${at}: frozen or not`
  if (x instanceof Secret) return difference(x.expose(), (y as Secret<unknown>).expose(), `${at}.expose()`)
  if (x instanceof Uint8Array) return Buffer.from(x).equals(Buffer.from(y as Uint8Array)) ? undefined : `${at}: other bytes`
  if (x instanceof Map) {
    const xs = [...x]
    const ys = [...(y as Map<unknown, unknown>)]
    if (xs.length !== ys.length) return `${at}: ${xs.length} vs ${ys.length} entries`
    for (let i = 0; i < xs.length; i++) {
      const d = difference(xs[i]![0], ys[i]![0], `${at}.keys[${i}]`) ?? difference(xs[i]![1], ys[i]![1], `${at}.get(${String(xs[i]![0])})`)
      if (d !== undefined) return d
    }
    return undefined
  }
  const kx = Reflect.ownKeys(x)
  const ky = Reflect.ownKeys(y)
  if (kx.join("\u0000") !== ky.join("\u0000")) return `${at}: keys ${kx.map(String).join(",")} vs ${ky.map(String).join(",")}`
  for (const k of kx) {
    const dx = Object.getOwnPropertyDescriptor(x, k)!
    const dy = Object.getOwnPropertyDescriptor(y, k)!
    if (dx.writable !== dy.writable || dx.enumerable !== dy.enumerable || dx.configurable !== dy.configurable || "get" in dx || "get" in dy) return `${at}.${String(k)}: another descriptor`
    const d = difference(dx.value, dy.value, `${at}.${String(k)}`)
    if (d !== undefined) return d
  }
  return undefined
}

type Outcome = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly error: unknown }

const outcome = (f: () => unknown): Outcome => {
  try {
    return { ok: true, value: f() }
  } catch (error) {
    return { ok: false, error }
  }
}

/** An error as a caller sees it: its class, message and own properties (code, path, place, details). */
const errorView = (e: unknown): string =>
  JSON.stringify(e instanceof Error ? { class: e.constructor.name, message: e.message, ...Object.fromEntries(Object.entries(e)) } : { thrown: String(e) })

/** Why the two paths' outcomes differ, or undefined. */
const differ = (compiled: Outcome, generic: Outcome): string | undefined => {
  if (compiled.ok && generic.ok) return difference(compiled.value, generic.value)
  if (compiled.ok !== generic.ok) return compiled.ok ? `only the generic path fails: ${String((generic as { error: unknown }).error)}` : `only the compiled path fails: ${String((compiled as { error: unknown }).error)}`
  const a = errorView((compiled as { error: unknown }).error)
  const b = errorView((generic as { error: unknown }).error)
  return a === b ? undefined : `other errors: ${a} vs ${b}`
}

/** A small deterministic generator (mulberry32). */
const random = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

const seedOf = (text: string): number => {
  let s = 2166136261
  for (let i = 0; i < text.length; i++) s = Math.imul(s ^ text.charCodeAt(i), 16777619)
  return s
}

const PIECES = ["{", "}", "[", "]", "(", ")", ",", ":", '"', " ", "\n", "/", "x", "A", "a", "_", "0", "-", ".", "Some", "None", "{}"]

/** Texts near `text`: a character deleted, a piece inserted, a slice doubled or cut off. */
const nearTexts = (text: string, n: number): string[] => {
  const next = random(seedOf(text))
  const at = () => Math.floor(next() * (text.length + 1))
  return Array.from({ length: n }, () => {
    const i = at()
    switch (Math.floor(next() * 4)) {
      case 0: return text.slice(0, i) + text.slice(i + 1)
      case 1: return text.slice(0, i) + PIECES[Math.floor(next() * PIECES.length)]! + text.slice(i)
      case 2: {
        const j = at()
        return text.slice(0, Math.max(i, j)) + text.slice(Math.min(i, j))
      }
      default: return text.slice(0, i)
    }
  })
}

/** Values near `value`: one place inside it replaced by something else. */
const nearValues = (value: unknown, n: number, seed: number): unknown[] => {
  const next = random(seed)
  const others = [undefined, null, "x", 1, 1.5, 1n, true, [], {}, new Map(), h.Maybe.none, { _tag: "Nope" }]
  const replace = (v: unknown, depth: number): unknown => {
    if (depth > 0 && next() < 0.3) return others[Math.floor(next() * others.length)]
    if (Array.isArray(v) && v.length > 0) {
      const i = Math.floor(next() * v.length)
      return v.map((x, k) => (k === i ? replace(x, depth + 1) : x))
    }
    if (v instanceof Map && v.size > 0) {
      const i = Math.floor(next() * v.size)
      return new Map([...v].map(([k, x], j) => [k, j === i ? replace(x, depth + 1) : x]))
    }
    if (typeof v === "object" && v !== null && Object.getPrototypeOf(v) === Object.prototype && Object.keys(v).length > 0) {
      const keys = Object.keys(v)
      const k = keys[Math.floor(next() * keys.length)]!
      return { ...v, [k]: replace((v as Record<string, unknown>)[k], depth + 1) }
    }
    return others[Math.floor(next() * others.length)]
  }
  return Array.from({ length: n }, () => replace(value, 0))
}

/** Counts of what was compared, for the summary. */
export const codecStats = { decodes: 0, encodes: 0, compiledDecodes: 0, compiledEncodes: 0, builtAhead: 0 }

/**
 * A type's schemas to check: `schema` from compileSchemaFile, and `built`,
 * the same type from a module @haus-fmt/import generated (its codecs built
 * ahead, `prebuilt`).
 */
export interface Schemas {
  readonly schema: h.AnySchema
  readonly built: h.AnySchema
}

/** The compiled codecs checked against the generic path: generated (`new Function`), closures, and generated ahead of time (by default, as users get them). */
const paths = (s: Schemas) => [
  { name: "generated", schema: s.schema, codec: "generated" },
  { name: "closures", schema: s.schema, codec: "closures" },
  { name: "built ahead", schema: s.built, codec: "auto" },
] as const

const decodeAll = (s: Schemas, text: string): { readonly generic: Outcome; readonly problem?: string } => {
  const generic = outcome(() => h.parse(s.schema, text, { codec: "generic" }))
  codecStats.decodes++
  for (const path of paths(s)) {
    const d = differ(outcome(() => h.parse(path.schema, text, { codec: path.codec })), generic)
    if (d !== undefined) return { generic, problem: `decoding ${JSON.stringify(text.slice(0, 200))} (${path.name}): ${d}` }
    const read = readerFor(path.schema, path.codec)
    if (generic.ok && read !== undefined) {
      if (decodeCompiled(read, text, {}) === undefined) return { generic, problem: `the reader (${path.name}) gave up on ${JSON.stringify(text.slice(0, 200))}` }
      codecStats.compiledDecodes++
    }
  }
  if (generatedOrigin(s.built) !== "built ahead") return { generic, problem: `the codecs generated ahead of time are not used (${generatedOrigin(s.built) ?? "none"})` }
  codecStats.builtAhead++
  return { generic }
}

const encodeAll = (s: Schemas, value: unknown): { readonly generic: Outcome; readonly problem?: string } => {
  let first: Outcome | undefined
  for (const style of ["minimised", "compact"] as const) {
    const generic = outcome(() => h.stringify(s.schema, value, { style, codec: "generic" }))
    codecStats.encodes++
    first ??= generic
    for (const path of paths(s)) {
      const d = differ(outcome(() => h.stringify(path.schema, value, { style, codec: path.codec })), generic)
      if (d !== undefined) return { generic, problem: `encoding (${style}, ${path.name}): ${d}` }
      const write = writerFor(path.schema, path.codec)
      if (generic.ok && write !== undefined) {
        if (encodeCompiled(write, value, {}, style) === undefined) return { generic, problem: `the writer (${path.name}) gave up (${style})` }
        codecStats.compiledEncodes++
      }
    }
  }
  return { generic: first! }
}

/**
 * One case through every path: decode the text, encode the result
 * (minimised), and the same for texts and values near them. The case's
 * outcome on the generic path (for the comparison with Lean), or why a
 * compiled path differs from it.
 */
export const checkCase = (s: Schemas, text: string): { readonly decoded: Outcome; readonly encoded?: Outcome; readonly problem?: string } => {
  const { generic: decoded, problem } = decodeAll(s, text)
  if (problem !== undefined) return { decoded, problem }
  for (const near of nearTexts(text, 4)) {
    const p = decodeAll(s, near).problem
    if (p !== undefined) return { decoded, problem: p }
  }
  if (!decoded.ok) return { decoded }
  const { generic: encoded, problem: encodeProblem } = encodeAll(s, decoded.value)
  if (encodeProblem !== undefined) return { decoded, encoded, problem: encodeProblem }
  for (const near of nearValues(decoded.value, 2, seedOf(text))) {
    const p = encodeAll(s, near).problem
    if (p !== undefined) return { decoded, encoded, problem: `a value near the decoded one: ${p}` }
  }
  return { decoded, encoded }
}
