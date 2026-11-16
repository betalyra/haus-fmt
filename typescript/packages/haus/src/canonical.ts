/**
 * The canonical form, equality and hashing (spec §12): one exact text per
 * value, the same in every binding. Equal values (§2) have identical
 * canonical forms, so `hash` is the same whatever the layout, comments, key
 * order or spelling of the document the value came from.
 *
 *   canonical(parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }'))
 *   // 'Order{id:255,total:19.90,"x-y":1e5}'
 */
import { quote, toHex } from "./format.js"
import { Sha256 } from "./sha256.js"
import type { Value } from "./value.js"

const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/

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
      work.push(fields.get(k)!, `${i > 0 ? "," : ""}${BARE_KEY.test(k) ? k : quote(k)}:`)
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
        out.push(quote(v.value))
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
 * The canonical form of a value (spec §12). Every value has one: an integer
 * of any size is written with all its decimal digits.
 */
export function canonical(value: Value): string {
  const out: string[] = []
  write(value, out)
  return out.join("")
}

/** Whether two values are equal (spec §2): the same canonical form. */
export function equals(a: Value, b: Value): boolean {
  return canonical(a) === canonical(b)
}

/**
 * Orders values by the bytes of their canonical forms (spec §12): a total
 * order consistent with `equals`, for sorting (`values.sort(compare)`) and
 * ordered maps. Returns -1, 0 or 1. Not numeric order: `10` sorts before `9`.
 */
export function compare(a: Value, b: Value): -1 | 0 | 1 {
  return Math.sign(compareCodePoints(canonical(a), canonical(b))) as -1 | 0 | 1
}

/**
 * The SHA-256 digest of the canonical form, as 64 lowercase hex digits
 * (spec §12). Uses Web Crypto, so it is asynchronous.
 */
export async function hash(value: Value): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical(value)))
  return toHex(new Uint8Array(digest))
}

const encoder = new TextEncoder()
const COMMA = encoder.encode(",")

/**
 * Hashes a list of values as it grows, e.g. a stream while it is read (spec
 * §12): `add` each value, `digest` at any time gives `hashAll` of the values
 * added so far. Memory stays bounded by the largest value.
 *
 *   const hasher = new Hasher()
 *   for await (const v of parseStream(body)) hasher.add(v)
 *   hasher.digest() // the same as await hashAll(values)
 */
export class Hasher {
  private readonly sha = new Sha256()
  private count = 0

  /** Add the next value. */
  add(value: Value): this {
    if (this.count++ > 0) this.sha.update(COMMA)
    this.sha.update(encoder.encode(canonical(value)))
    return this
  }

  /** `hashAll` of the values added so far, as 64 lowercase hex digits. */
  digest(): string {
    return toHex(this.sha.digest())
  }
}

/**
 * The hash of a list of values, such as a whole file or stream (spec §12):
 * the SHA-256 digest of their canonical forms joined by `,`. A list of one
 * value hashes like the value: `hashAll([v])` is `hash(v)`.
 */
export async function hashAll(values: Iterable<Value>): Promise<string> {
  const hasher = new Hasher()
  for (const v of values) hasher.add(v)
  return hasher.digest()
}
