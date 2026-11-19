/**
 * The benchmark as one command line program, runtime-neutral: each entry
 * (main.node.ts, main.bun.ts) runs `cli` with its platform layer.
 *
 *   haus-bench fetch                         download and check what sources.haus pins
 *   haus-bench convert [--limit N]           every document → haus, round trip checked
 *   haus-bench tokens [--tokenizers a,b]     token counts
 *   haus-bench speed [--quick]               tinybench
 *   haus-bench report                        tables, results.md, results.haus
 *   haus-bench all                           every step, in order
 *   haus-bench smoke                         every step on a sample (40 documents, o200k, --quick)
 *
 * Every command takes --data-dir and --out-dir (or HAUS_BENCH_DATA,
 * HAUS_BENCH_OUT): where downloads and results go; every command but fetch
 * takes --sources (names from sources.haus, comma-separated; default all).
 */
import { Config, Effect, Layer, Option } from "effect"
import { Command, Flag } from "effect/cli"
import { Manifest } from "./manifest.ts"
import { BenchPaths, type Dirs } from "./paths.ts"
import { Results } from "./results.ts"
import type { Selection } from "./sources.ts"
import { convert } from "./steps/convert.ts"
import { fetchSources } from "./steps/fetch.ts"
import { report } from "./steps/report.ts"
import { speed } from "./steps/speed.ts"
import { tokens } from "./steps/tokens.ts"

const dirs = {
  data: Flag.String("data-dir").pipe(
    Flag.withDescription("Where downloads go (default bench/.data)"),
    Flag.withFallbackConfig(Config.String("HAUS_BENCH_DATA")),
    Flag.optional,
  ),
  out: Flag.String("out-dir").pipe(
    Flag.withDescription("Where results go (default bench/.out)"),
    Flag.withFallbackConfig(Config.String("HAUS_BENCH_OUT")),
    Flag.optional,
  ),
}

const commaList = (s: string): readonly string[] => s.split(",")

const sources = Flag.String("sources").pipe(
  Flag.withDescription("Only these corpus sources (names from sources.haus, comma-separated)"),
  Flag.map(commaList),
  Flag.optional,
)
const limit = Flag.Int("limit").pipe(Flag.withDescription("A fixed sample of N documents (every k-th) of each source instead of all"), Flag.optional)
const tokenizerNames = Flag.String("tokenizers").pipe(
  Flag.withDescription("Only these tokenizers (names from sources.haus, comma-separated)"),
  Flag.map(commaList),
  Flag.optional,
)
const quick = Flag.Boolean("quick").pipe(Flag.withDescription("A 50 ms budget per task: checks the harness, not for publishing"), Flag.withDefault(false))

/** The services every step uses, from the directories on the command line. */
const benchLayer = (d: Dirs) =>
  Layer.mergeAll(Manifest.layer, Results.layer).pipe(Layer.provideMerge(BenchPaths.layer(d)))

/** Runs a step with the benchmark's services, for these directories. */
const inBench = (d: Dirs) => Effect.provide(benchLayer(d))

const all = (s: Selection) =>
  Effect.gen(function* () {
    yield* fetchSources()
    yield* convert({ sources: s, limit: Option.none() })
    yield* tokens({ sources: s, tokenizers: Option.none() })
    yield* speed({ sources: s, quick: false })
    yield* report({ sources: s })
  })

const smoke = (s: Selection) =>
  Effect.gen(function* () {
    yield* fetchSources()
    yield* convert({ sources: s, limit: Option.some(40) })
    yield* tokens({ sources: s, tokenizers: Option.some(["o200k"]) })
    yield* speed({ sources: s, quick: true })
    yield* report({ sources: s })
  })

const subcommands = [
  Command.make("fetch", { dirs }, (c) => fetchSources().pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Download and check what sources.haus pins"),
  ),
  Command.make("convert", { dirs, sources, limit }, (c) => convert(c).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Every document to haus, the round trip checked"),
  ),
  Command.make("tokens", { dirs, sources, tokenizers: tokenizerNames }, (c) => tokens(c).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Token counts per document, form and tokenizer"),
  ),
  Command.make("speed", { dirs, sources, quick }, (c) => speed(c).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Parse and write speed against JSON (tinybench)"),
  ),
  Command.make("report", { dirs, sources }, (c) => report(c).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("The tables: results.md and results.haus"),
  ),
  Command.make("all", { dirs, sources }, (c) => all(c.sources).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Every step, in order"),
  ),
  Command.make("smoke", { dirs, sources }, (c) => smoke(c.sources).pipe(inBench(c.dirs))).pipe(
    Command.withDescription("Every step on a sample (40 documents per source, o200k, quick speed): checks the pipeline; not for publishing"),
  ),
] as const

export const command = Command.make("haus-bench").pipe(
  Command.withDescription("haus against JSON: size, tokens and TypeScript speed on real data"),
  Command.withSubcommands(subcommands),
)

export const cli = Command.run(command, { version: "0.1.0" })
