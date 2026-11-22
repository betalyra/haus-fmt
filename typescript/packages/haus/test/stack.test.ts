/**
 * The stack this binding needs at MAX_SUPPORTED_DEPTH (spec §7,
 * limits.depth.stack-documented and small-stack-tested): every path that
 * recurses per level, run at the maximum in a worker thread with
 * STACK_NEEDED_MB of stack, called from 200 frames deep. Runs the built
 * package (dist/), as a worker can't load the TypeScript sources.
 */
import { existsSync } from "node:fs"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { Worker } from "node:worker_threads"
import { describe, expect, it } from "vitest"
import { MAX_SUPPORTED_DEPTH, STACK_NEEDED_MB } from "../src/index.js"

const DIST = join(import.meta.dirname, "../dist")

/** The paths, run in a worker with `stackSizeMb`: the name of each, and "ok" or its error. */
const runPaths = (stackSizeMb: number, depth: number): Promise<Record<string, string>> => {
  const code = `
const { parentPort, workerData } = require("node:worker_threads")
;(async () => {
  const H = await import(workerData.index)
  const h = await import(workerData.schema)
  const N = workerData.depth
  const limits = { maxDepth: N }
  const nested = (n) => "[".repeat(n) + "]".repeat(n)
  const tagged = (n) => "T { a: ".repeat(n) + "1" + " }".repeat(n)
  const Nest = h.Recursive("Nest", (self) => h.Array(self))
  const nestedArray = (n) => Array.from({ length: n - 1 }).reduce((inner) => [inner], [])
  const Tree = h.Recursive("Tree", (self) => h.Variant({ Node: h.Record({ kids: h.Array(self) }) }))
  const tree = (n) => Array.from({ length: n - 1 }).reduce((inner) => ({ _tag: "Node", kids: [inner] }), { _tag: "Node", kids: [] })
  // Built in code, not parsed: on a stack too small for parsing, the writers still get their value.
  const value = Array.from({ length: N }).reduce((inner) => H.variant("T", [H.rec({ a: inner })]), H.num("1"))
  const paths = {
    "parse": () => H.parse(nested(N), limits),
    "parse a record payload": () => H.parse(tagged(N), limits),
    "parse a payload": () => H.parse("A(".repeat(N) + "1" + ")".repeat(N), limits),
    "parse with locations": () => H.parseWithLocations(nested(N), limits),
    "stringify": () => H.stringify(value, { limits }),
    "format": () => { const s = "// d\\n" + tagged(N); const d = H.parseDocument(s, limits); return H.format(d.values, { source: s, comments: d.comments, limits }) },
    "canonical": () => H.canonical(value),
    "decode with a schema": () => h.decode(Nest, H.parse(nested(N), limits), limits),
    "parse with a schema": () => h.parse(Nest, nested(N), limits),
    "encode with a schema": () => h.encode(Nest, nestedArray(N), limits),
    "stringify with a schema": () => h.stringify(Nest, nestedArray(N), limits),
    "schema-based JSON": () => h.fromJson(Tree, h.toJson(Tree, tree(N / 2), limits), limits),
    "self-describing JSON (4·d+2 levels)": () => H.fromHausJson(H.toHausJson(value, limits), limits),
    "raw JSON": () => H.stringifyJson(H.parseJson(nested(H.hausJsonDepth(N)), { maxDepth: H.hausJsonDepth(N) })),
    "import JSON": () => H.importJson(nested(N), limits),
  }
  const deep = (k, f) => (k === 0 ? f() : deep(k - 1, f))
  const out = {}
  for (const [name, f] of Object.entries(paths)) {
    try { deep(200, f); out[name] = "ok" } catch (e) { out[name] = String(e && e.name) + " (" + String(e && e.code) + "): " + String(e && e.message) }
  }
  parentPort.postMessage(out)
})().catch((e) => parentPort.postMessage({ setup: String(e) }))
`
  return new Promise((resolve, reject) => {
    const worker = new Worker(code, {
      eval: true,
      workerData: { index: pathToFileURL(join(DIST, "index.js")).href, schema: pathToFileURL(join(DIST, "schema.js")).href, depth },
      resourceLimits: { stackSizeMb },
    })
    worker.once("message", (m: Record<string, string>) => {
      void worker.terminate()
      resolve(m)
    })
    worker.once("error", reject)
  })
}

describe(`the stack needed at MAX_SUPPORTED_DEPTH (${MAX_SUPPORTED_DEPTH})`, () => {
  it(`is at most ${STACK_NEEDED_MB} MiB: every path that recurses works in a worker with that stack`, async () => {
    expect(existsSync(join(DIST, "index.js")), "build the package first (pnpm build): the worker loads dist/").toBe(true)
    const results = await runPaths(STACK_NEEDED_MB, MAX_SUPPORTED_DEPTH)
    expect(Object.entries(results).filter(([, r]) => r !== "ok")).toEqual([])
    expect(Object.keys(results)).toHaveLength(15)
  })

  it("on a 512 KiB thread (spec §7: a secondary thread's default on macOS), every path works to 128 levels", async () => {
    const results = await runPaths(0.5, 128)
    expect(Object.entries(results).filter(([, r]) => r !== "ok")).toEqual([])
  })

  it("on a stack too small for the depth, every path fails with nesting-too-deep, never with the engine's RangeError (spec §7)", async () => {
    const results = await runPaths(0.5, MAX_SUPPORTED_DEPTH)
    expect(Object.keys(results)).toHaveLength(15)
    const failed = Object.entries(results).filter(([, r]) => r !== "ok")
    // The stack is too small for most paths at 512 levels: the guard is what is tested.
    expect(failed.length).toBeGreaterThan(5)
    for (const [name, r] of failed) expect(`${name}: ${r}`).toMatch(/^[^:]+: Haus(Syntax|Decode|Encode)Error \(nesting-too-deep\): /)
    // The values built in code have no depth limit and don't recurse (spec §7, limits.depth.canonical-any-depth).
    expect(results["canonical"]).toBe("ok")
  })
})
