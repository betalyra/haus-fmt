/**
 * The canonical form, equality and hashing (spec §12): one exact text per
 * value, the same in every binding. Equal values (§2) have identical
 * canonical forms, so `hash` is the same whatever the layout, comments, key
 * order or spelling of the document the value came from.
 *
 *   canonical(parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }'))
 *   // 'Order{id:255,total:19.90,"x-y":1e5}'
 *
 * Every `Value` is a haus value (spec §12), checked when it was built
 * (value.ts) or read, with its numbers normalized. They have one limit, the
 * node limit (spec §7): a value whose parts share each other so much that its
 * canonical form would hold more than `maxNodes` values (default 64 Mi) fails
 * with HausEncodeError `too-many-nodes`, at `$` (`$[i]` in `hashAll`; from
 * `equals` and `compare` the message says which operand). No other limit
 * applies: a value deeper or longer than a writer's limits still has a
 * canonical form, and there is no maximum depth: they walk a value with a
 * stack of their own, not the call stack, so any depth works. A value
 * forged past the constructors (with a cast) is not one, and what they do
 * with it is undefined (spec §11, "Values built in code").
 */
import { escaped, toHex, writtenKey } from "./format.js"
import { DEFAULT_LIMITS, type Limits } from "./reader.js"
import type { Value } from "./value.js"
import { HausEncodeError } from "./errors.js"
import { checkNodes, nodesWithin, tooManyNodes } from "./written.js"

/** The one limit of the canonical form and hashing (spec §12): the node limit, default 64 Mi. */
export type CanonicalLimits = Partial<Pick<Limits, "maxNodes">>

/** The canonical form of `value`, its nodes checked first; `at` is its place for the error (`$`, or `$[i]` in `hashAll`). */
const canonicalAt = (value: Value, maxNodes: number, at: readonly number[]): string => {
  checkNodes(value, maxNodes, at)
  const out: string[] = []
  write(value, out)
  return out.join("")
}

/** The canonical form of an operand of `equals` or `compare`: `too-many-nodes` at `$`, the message saying which operand (spec §12). */
const operand = (value: Value, which: "first" | "second", limits: CanonicalLimits): string => {
  const maxNodes = limits.maxNodes ?? DEFAULT_LIMITS.maxNodes
  if (!nodesWithin(value, maxNodes)) throw new HausEncodeError(`the ${which} value: ${tooManyNodes(maxNodes)}`, [], "too-many-nodes")
  const out: string[] = []
  write(value, out)
  return out.join("")
}

/**
 * Orders strings by code point, which is the order of their UTF-8 bytes.
 * JavaScript's `<` compares UTF-16 units, which puts U+10000 and above
 * before U+E000–U+FFFF.
 */
export function compareCodePoints(a: string, b: string): number {
  const ia = a[Symbol.iterator]()
  const ib = b[Symbol.iterator]()
  for (;;) {
    const x = ia.next()
    const y = ib.next()
    if (x.done || y.done) return x.done ? (y.done ? 0 : -1) : 1
    const d = x.value.codePointAt(0)! - y.value.codePointAt(0)!
    if (d !== 0) return d
  }
}

/**
 * Write `root` into `out`. Iterative, with a stack of what is left to write
 * (values, and text between them), so any depth works without the call stack.
 */
function write(root: Value, out: string[]): void {
  const work: (Value | string)[] = [root]
  /** Push `items` to be written next, separated by commas, then `close`. */
  const items = (values: readonly Value[], close: string) => {
    work.push(close)
    for (let i = values.length - 1; i >= 0; i--) {
      work.push(values[i]!)
      if (i > 0) work.push(",")
    }
  }
  const record = (fields: ReadonlyMap<string, Value>) => {
    out.push("{")
    const keys = [...fields.keys()].sort(compareCodePoints)
    work.push("}")
    for (let i = keys.length - 1; i >= 0; i--) {
      const k = keys[i]!
      work.push(fields.get(k)!, `${i > 0 ? "," : ""}${writtenKey(k)}:`)
    }
  }
  while (work.length > 0) {
    const v = work.pop()!
    if (typeof v === "string") {
      out.push(v)
      continue
    }
    switch (v.kind) {
      case "number":
        // The normalized literal, always decimal: every integer has a canonical form (spec §12).
        out.push(v.text)
        break
      case "string":
        out.push(escaped(v.value))
        break
      case "bytes":
        out.push(`x"${toHex(v.bytes)}"`)
        break
      case "array":
        out.push("[")
        items(v.items, "]")
        break
      case "record":
        record(v.fields)
        break
      case "variant": {
        out.push(v.tag)
        const only = v.args.length === 1 ? v.args[0]! : undefined
        if (only?.kind === "record") record(only.fields)
        else if (v.args.length > 0) {
          out.push("(")
          items(v.args, ")")
        }
      }
    }
  }
}

/**
 * The canonical form of a value (spec §12). Every value has one within the
 * node limit (`limits.maxNodes`, default 64 Mi; beyond it HausEncodeError
 * `too-many-nodes`), and no other limit: an integer of any size is written
 * with all its decimal digits.
 */
export function canonical(value: Value, limits: CanonicalLimits = {}): string {
  return canonicalAt(value, limits.maxNodes ?? DEFAULT_LIMITS.maxNodes, [])
}

/** Whether two values are equal (spec §2): the same canonical form. Within the node limit, as `canonical`. */
export function equals(a: Value, b: Value, limits: CanonicalLimits = {}): boolean {
  return operand(a, "first", limits) === operand(b, "second", limits)
}

/**
 * Orders values by the bytes of their canonical forms (spec §12): a total
 * order consistent with `equals`, for sorting (`values.sort(compare)`) and
 * ordered maps. Returns -1, 0 or 1. Not numeric order: `10` sorts before `9`.
 */
export function compare(a: Value, b: Value, limits: CanonicalLimits = {}): -1 | 0 | 1 {
  return Math.sign(compareCodePoints(operand(a, "first", limits), operand(b, "second", limits))) as -1 | 0 | 1
}

/**
 * The SHA-256 digest of the canonical form, as 64 lowercase hex digits
 * (spec §12). Uses Web Crypto, so it is asynchronous. Within the node limit,
 * as `canonical`.
 */
export async function hash(value: Value, limits: CanonicalLimits = {}): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical(value, limits)))
  return toHex(new Uint8Array(digest))
}

/**
 * The hash of a list of values, such as a whole file (spec §12): the SHA-256
 * digest of their canonical forms joined by `,`. A list of one value hashes
 * like the value: `hashAll([v])` is `hash(v)`. Uses Web Crypto, so it is
 * asynchronous. The items of a stream are hashed one by one with `hash`.
 * The node limit applies to each value on its own (`too-many-nodes` at
 * `$[i]` for value i).
 */
export async function hashAll(values: Iterable<Value>, limits: CanonicalLimits = {}): Promise<string> {
  const maxNodes = limits.maxNodes ?? DEFAULT_LIMITS.maxNodes
  const text = Array.from(values, (v, i) => canonicalAt(v, maxNodes, [i])).join(",")
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return toHex(new Uint8Array(digest))
}
