/**
 * Token counts per document, form and tokenizer, with tokenizers.js
 * (@huggingface/tokenizers) and the tokenizer files fetch pinned.
 * No special tokens are added: the count is that of the text alone.
 *
 *   tokens [--tokenizers o200k,gemma4] [--sources a,b]     default: every tokenizer and source in sources.haus
 *
 * Writes <source>/tokens.json. Each tokenizer is loaded once and counts every
 * source. Tokenizers run one after the other: counting is synchronous,
 * CPU-bound work on one thread, so running several at once would only hold
 * more tokenizers in memory (and blur each one's time).
 */
import { Tokenizer } from "@huggingface/tokenizers"
import { Console, Duration, Effect, FileSystem, Option } from "effect"
import { messageOf, TokenizerLoadError, UnknownTokenizerError } from "../errors.ts"
import { Manifest, type TokenizerSource } from "../manifest.ts"
import { BenchPaths } from "../paths.ts"
import { CORPUS, FORMS, Results, TOKENS, type Converted, type CorpusOut, type Form, type FormCounts, type TokenizerInfo } from "../results.ts"
import { selectSources, type Selection } from "../sources.ts"
import { sum } from "../stats.ts"
import { streamText } from "../compress.ts"

interface TokenizerJson {
  readonly model?: { readonly vocab?: unknown }
  readonly added_tokens?: readonly { readonly id: number }[]
}

/** The number of distinct token ids: the model's vocabulary and the added tokens. Pure. */
export const vocabSize = (tokenizerJson: TokenizerJson): number => {
  const vocab = tokenizerJson.model?.vocab
  const ids = new Set<number>([
    ...(Array.isArray(vocab) ? vocab.map((_, i) => i) : vocab && typeof vocab === "object" ? Object.values(vocab).filter((id): id is number => typeof id === "number") : []),
    ...(tokenizerJson.added_tokens ?? []).map((t) => t.id),
  ])
  return ids.size
}

/** Tokens of every document in every form. */
export const countForms = (count: (text: string) => number, documents: readonly Converted[]): FormCounts =>
  Object.fromEntries(FORMS.map((f) => [f, documents.map((d) => count(d[f]))])) as Record<Form, number[]>

/** The forms counted as one stream too: the wire forms (JSON Lines against a haus stream). */
export const STREAM_FORMS = ["json_min", "haus_min", "plain_min"] as const satisfies readonly Form[]

/** Tokens of all documents as one stream (compress.ts `streamText`), per wire form. */
export const countStreams = (count: (text: string) => number, documents: readonly Converted[]): Record<string, number> =>
  Object.fromEntries(STREAM_FORMS.map((f) => [f, count(streamText(f, documents.map((d) => d[f])))]))

/** The tokenizers to run: all, or those `--tokenizers` names (each must be in the manifest). */
const select = Effect.fn("tokens.select")(function* (all: readonly TokenizerSource[], only: Option.Option<readonly string[]>) {
  if (Option.isNone(only)) return all
  const unknown = only.value.find((name) => !all.some((t) => t.name === name))
  if (unknown !== undefined) return yield* new UnknownTokenizerError({ tokenizer: unknown, message: `no tokenizer ${unknown} in sources.haus` })
  return all.filter((t) => only.value.includes(t.name))
})

const readJson = Effect.fn("tokens.readJson")(function* (name: string, path: string) {
  const fs = yield* FileSystem.FileSystem
  const text = yield* fs.readFileString(path)
  return yield* Effect.try({ try: () => JSON.parse(text) as unknown, catch: (e) => new TokenizerLoadError({ tokenizer: name, message: `${path}: ${messageOf(e)}` }) })
})

/** A tokenizer, loaded: its token counter and vocabulary size. */
const load = Effect.fn("tokens.load")(function* (t: TokenizerSource) {
  const paths = yield* BenchPaths
  const tokenizerJson = yield* readJson(t.name, paths.tokenizerFile(t.name, "tokenizer.json"))
  const config = yield* readJson(t.name, paths.tokenizerFile(t.name, "tokenizer_config.json"))
  const tokenizer = yield* Effect.try({
    try: () => new Tokenizer(tokenizerJson as object, config as object),
    catch: (e) => new TokenizerLoadError({ tokenizer: t.name, message: messageOf(e) }),
  })
  return { count: (text: string) => tokenizer.encode(text, { add_special_tokens: false }).ids.length, vocab: vocabSize(tokenizerJson as TokenizerJson) }
})

const seconds = (d: Duration.Duration) => Duration.toMillis(d) / 1000

/** One tokenizer over every selected source: loaded once, then each source's documents counted. */
const runTokenizer = Effect.fn("tokens.run")(function* (t: TokenizerSource, corpora: readonly (readonly [string, CorpusOut])[]) {
  const [loading, { count, vocab }] = yield* Effect.timed(load(t))
  return yield* Effect.forEach(corpora, ([source, corpus]) =>
    Effect.gen(function* () {
      const [counting, [counts, stream]] = yield* Effect.timed(Effect.sync(() => [countForms(count, corpus.documents), countStreams(count, corpus.documents)] as const))
      const info: TokenizerInfo = { name: t.name, family: t.family, repo: t.repo, revision: t.revision, vocab, seconds: seconds(loading) + seconds(counting) }
      const total = (f: Form) => sum(counts[f])
      yield* Console.log(`${source.padEnd(12)} ${t.name.padEnd(12)} ${info.seconds.toFixed(1).padStart(6)} s   JSON min ${total("json_min")}, haus min ${total("haus_min")}, JSON pretty ${total("json_pretty")}, haus pretty ${total("haus_pretty")}`)
      return { source, info, counts, stream }
    }))
})

export const tokens = Effect.fn("bench.tokens")(function* (options: { readonly sources: Selection; readonly tokenizers: Option.Option<readonly string[]> }) {
  const manifest = yield* Manifest
  const results = yield* Results
  const tokenizers = yield* select(manifest.tokenizers, options.tokenizers)
  const sources = yield* selectSources(options.sources)
  const corpora = yield* Effect.forEach(sources, (s) => results.read(s.name, CORPUS, "convert").pipe(Effect.map((c) => [s.name, c] as const)))
  const runs = (yield* Effect.forEach(tokenizers, (t) => runTokenizer(t, corpora))).flat()
  yield* Effect.forEach(corpora, ([source, corpus]) => {
    const mine = runs.filter((r) => r.source === source)
    return results.write(source, TOKENS, {
      tokenizers: mine.map((r) => r.info),
      documents: corpus.documents.map((d) => d.id),
      counts: Object.fromEntries(mine.map((r) => [r.info.name, r.counts])),
      stream: Object.fromEntries(mine.map((r) => [r.info.name, r.stream])),
    })
  }, { discard: true })
})
