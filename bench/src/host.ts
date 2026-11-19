/**
 * The machine the benchmark runs on, and the one thing that differs between
 * runtimes for it: how to collect garbage before a speed task. Each entry
 * (main.node.ts, main.bun.ts) provides its garbage collector.
 *
 * `node:os` is the one Node module used here; Bun and Deno implement it.
 */
import { arch, cpus, platform, release, totalmem } from "node:os"
import { Context, Effect, Layer, Option } from "effect"

export interface HostShape {
  /** A full garbage collection, when the runtime exposes one (Node and Deno: `--expose-gc`; Bun: always). */
  readonly gc: Option.Option<() => void>
  readonly cpu: string
  readonly cores: number
  readonly memoryGb: number
  readonly os: string
}

export class Host extends Context.Service<Host, HostShape>()("haus-bench/Host") {
  static readonly layer = (gc: Option.Option<() => void>): Layer.Layer<Host> =>
    Layer.effect(
      Host,
      Effect.sync(() => {
        const cores = cpus()
        return Host.of({
          gc,
          cpu: cores[0]?.model ?? "unknown",
          cores: cores.length,
          memoryGb: Math.round(totalmem() / 2 ** 30),
          os: `${platform()} ${release()} ${arch()}`,
        })
      }),
    )

  /** Node and Deno: `globalThis.gc`, there with `--expose-gc` (Deno: `--v8-flags=--expose-gc`). */
  static readonly v8 = Layer.suspend(() => Host.layer(Option.fromUndefinedOr((globalThis as { gc?: () => void }).gc)))
}
