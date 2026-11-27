/**
 * The stack (spec §7): on a stack too small for the depth (a worker thread's,
 * which JavaScript can't choose), decoding and encoding fail with
 * `nesting-too-deep`, never with the engine's RangeError or a defect. Runs
 * the built packages (dist/), as a worker can't load the TypeScript sources.
 */
import { existsSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { Worker } from "node:worker_threads"
import { describe, expect, it } from "vitest"

const DIST = join(import.meta.dirname, "../dist")
const require = createRequire(import.meta.url)

/** Each path in a worker with `stackSizeMb`: "ok", or the error's code (or what failed otherwise). */
const runPaths = (stackSizeMb: number, depth: number): Promise<Record<string, string>> => {
  const code = `
const { parentPort, workerData } = require("node:worker_threads")
;(async () => {
  const { Effect, Schema } = await import(workerData.effect)
  const H = await import(workerData.haus)
  const Haus = await import(workerData.index)
  const N = workerData.depth
  const limits = { maxDepth: N }
  const Nest = Schema.Array(Schema.suspend(() => Nest))
  // As a reader builds it with raised limits: the constructors build values within the default limits only.
  const nestedValue = (n) => Array.from({ length: n - 1 }).reduce((inner) => H.uncheckedArr([inner]), H.uncheckedArr([]))
  const nestedArray = (n) => Array.from({ length: n - 1 }).reduce((inner) => [inner], [])
  const paths = {
    "decode": () => Haus.decode(Nest)("[".repeat(N) + "]".repeat(N), limits),
    "decodeValue": () => Haus.decodeValue(Nest)(nestedValue(N), limits),
    "encodeValue": () => Haus.encodeValue(Nest)(nestedArray(N), limits),
  }
  const out = {}
  for (const [name, f] of Object.entries(paths)) {
    try {
      const exit = Effect.runSync(Effect.exit(f()))
      out[name] = exit._tag === "Success" ? "ok" : String(exit.cause.reasons?.[0]?.error?.code ?? exit.cause)
    } catch (e) {
      out[name] = "threw " + String(e && e.name) + ": " + String(e && e.message)
    }
  }
  parentPort.postMessage(out)
})().catch((e) => parentPort.postMessage({ setup: String(e) }))
`
  return new Promise((resolve, reject) => {
    const worker = new Worker(code, {
      eval: true,
      workerData: {
        effect: pathToFileURL(require.resolve("effect")).href,
        haus: pathToFileURL(require.resolve("@haus-fmt/haus/internal")).href,
        index: pathToFileURL(join(DIST, "index.js")).href,
        depth,
      },
      resourceLimits: { stackSizeMb },
    })
    worker.once("message", (m: Record<string, string>) => {
      void worker.terminate()
      resolve(m)
    })
    worker.once("error", reject)
  })
}

describe("the stack (spec §7)", () => {
  it("on a stack too small for 512 levels, decoding and encoding fail with nesting-too-deep, never a RangeError", async () => {
    expect(existsSync(join(DIST, "index.js")), "build the package first (pnpm build): the worker loads dist/").toBe(true)
    const results = await runPaths(0.5, 512)
    expect(Object.keys(results)).toEqual(["decode", "decodeValue", "encodeValue"])
    for (const [name, r] of Object.entries(results)) expect(`${name}: ${r}`).toMatch(/: (ok|nesting-too-deep)$/)
    expect(Object.values(results)).toContain("nesting-too-deep")
  })

  it("with the stack it needs, the same values decode and encode", async () => {
    expect(await runPaths(2, 512)).toEqual({ decode: "ok", decodeValue: "ok", encodeValue: "ok" })
  })
})
