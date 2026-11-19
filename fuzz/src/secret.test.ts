/**
 * The schema fuzzer's check that errors inside a `Secret` don't show it
 * (schema.ts, `shownSecret`): words of a binding's own message aren't leaks,
 * data in a message is.
 *
 *   node --test fuzz/src/
 */
import assert from "node:assert/strict"
import { test } from "node:test"
import { disguise, secretParts, shownSecret } from "./schema.ts"
import type { Env } from "./schema-gen.ts"
import type { Outcome } from "./schema-runners.ts"

// Like fuzz.Hidden: a secret record.
const env: Env = new Map([["Hidden", { secret: { record: { closed: false, fields: [{ key: "user", optional: false, type: { builtin: "String" } }, { key: "pin", optional: false, type: { builtin: "UInt16" } }] } } }]])
const text = '{ user: "hello", pin: 70000, value: 12345 }'
const parts = secretParts(env, "Hidden", text)

/** A runner that fails with `message(text)`. */
const failing = (message: (text: string) => string) => (t: string): Extract<Outcome, { kind: "err" }> => ({ kind: "err", reason: message(t) })

test("the secret's parts include the key `value`", () => {
  assert.ok(parts.includes("value"))
  assert.ok(parts.includes("hello"))
  assert.ok(parts.includes("70000"))
})

test("a word of the message template isn't a leak", () => {
  // Every binding's message for a secret: "the value is not shown".
  const run = failing(() => "$.pin: out of range (the value is not shown)")
  const template = new Set<string>()
  assert.equal(shownSecret(text, run(text).reason, parts, run, template), undefined)
  assert.ok(template.has("value"))
})

test("data in the message is a leak", () => {
  const run = failing((t) => `$.pin: out of range: ${/pin: (\d+)/.exec(t)![1]} (the value is not shown)`)
  assert.equal(shownSecret(text, run(text).reason, parts, run, new Set()), "70000")
})

test("a key of the data in the message is a leak, even if it is a template word elsewhere", () => {
  const run = failing((t) => `unexpected field ${/(\w+): 12345/.exec(t)![1]}`)
  assert.equal(shownSecret(text, run(text).reason, parts, run, new Set()), "value")
})

test("a part written with escapes counts as shown", () => {
  const escaped = '{ user: "h\\u{65}llo", pin: 1 }'
  const run = failing(() => "bad user hello")
  assert.equal(shownSecret(escaped, run(escaped).reason, secretParts(env, "Hidden", escaped), run, new Set()), "hello")
})

test("disguise keeps the shape", () => {
  assert.equal(disguise("value"), "wbmvf")
  assert.equal(disguise("Zz-09"), "Aa-11")
})

test("a key of a Map above a secret is public, also when a secret holds the same string", () => {
  const env: Env = new Map([["Vault", { map: { secret: { record: { closed: false, fields: [{ key: "id", optional: false, type: { builtin: "Int" } }] } } } }]])
  // "Upper" is a key of the map (public) and a key inside one of the secrets.
  const parts = secretParts(env, "Vault", `{ Upper: { id: "x" }, other: { Upper: 1, id: 2 } }`)
  assert.equal(parts.includes("Upper"), false)
  assert.equal(parts.includes("other"), false)
})
