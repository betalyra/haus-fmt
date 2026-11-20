/**
 * Compressed sizes of every source's documents (compress.ts): gzip, brotli
 * and zstd, per document and as one stream.
 *
 *   compress [--sources a,b]
 *
 * Writes <source>/compression.json. Reads the documents convert wrote. The
 * sizes depend on the compressors' builds: Node's, Bun's and Deno's differ a
 * little (gzip most), so the runtime is recorded.
 */
import { Console, Duration, Effect } from "effect"
import { CODECS, compressCorpus } from "../compress.ts"
import { COMPRESSION, CORPUS, Results } from "../results.ts"
import { selectSources, type Selection } from "../sources.ts"

export const compress = Effect.fn("bench.compress")(function* (options: { readonly sources: Selection }) {
  const results = yield* Results
  const sources = yield* selectSources(options.sources)
  yield* Effect.forEach(sources, (s) =>
    Effect.gen(function* () {
      const corpus = yield* results.read(s.name, CORPUS, "convert")
      const [elapsed, forms] = yield* Effect.timed(Effect.sync(() => compressCorpus(corpus.documents)))
      yield* results.write(s.name, COMPRESSION, { runtime: navigator.userAgent, codecs: CODECS.map((c) => c.name), documents: corpus.documents.map((d) => d.id), forms })
      const ratio = (codec: string) => (forms.haus_min.stream[codec]! / forms.json_min.stream[codec]!).toFixed(3)
      yield* Console.log(`${s.name.padEnd(12)} ${(Duration.toMillis(elapsed) / 1000).toFixed(1).padStart(6)} s   stream haus/JSON: ${CODECS.map((c) => `${c.name} ${ratio(c.name)}`).join(", ")}`)
    }), { discard: true })
})
