/**
 * Token counts per document, form and tokenizer, with tokenizers.js
 * (@huggingface/tokenizers) and the tokenizer files fetch.ts pinned.
 * No special tokens are added: the count is that of the text alone.
 *
 *   node tokens.ts [--tokenizers o200k,gemma4]     default: every tokenizer in sources.haus
 *
 * Writes .out/tokens.json.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { parseArgs } from "node:util"
import { Tokenizer } from "@huggingface/tokenizers"
import { readManifest } from "./lib/manifest.ts"
import { CORPUS_OUT, tokenizerDir, TOKENS_OUT } from "./lib/paths.ts"
import { FORMS, type CorpusOut, type Form, type TokensOut } from "./lib/results.ts"

/** The number of distinct token ids: the model's vocabulary and the added tokens. */
const vocabSize = (tokenizerJson: { model?: { vocab?: unknown }; added_tokens?: { id: number }[] }): number => {
  const ids = new Set<number>()
  const vocab = tokenizerJson.model?.vocab
  if (Array.isArray(vocab)) vocab.forEach((_, i) => ids.add(i))
  else if (vocab && typeof vocab === "object") for (const id of Object.values(vocab)) if (typeof id === "number") ids.add(id)
  for (const t of tokenizerJson.added_tokens ?? []) ids.add(t.id)
  return ids.size
}

const { values: args } = parseArgs({ args: process.argv.slice(2).filter((a) => a !== "--"), options: { tokenizers: { type: "string" } } })
const only = args.tokenizers?.split(",")
const sources = readManifest().tokenizers.filter((t) => only === undefined || only.includes(t.name))
if (only) for (const name of only) if (!sources.some((t) => t.name === name)) throw new Error(`no tokenizer ${name} in sources.haus`)

const corpus = JSON.parse(readFileSync(CORPUS_OUT, "utf8")) as CorpusOut
const out: { tokenizers: TokensOut["tokenizers"][number][]; documents: string[]; counts: Record<string, Record<Form, number[]>> } = {
  tokenizers: [],
  documents: corpus.documents.map((d) => d.id),
  counts: {},
}
for (const source of sources) {
  const start = performance.now()
  const dir = tokenizerDir(source.name)
  const tokenizerJson = JSON.parse(readFileSync(`${dir}tokenizer.json`, "utf8"))
  const tokenizer = new Tokenizer(tokenizerJson, JSON.parse(readFileSync(`${dir}tokenizer_config.json`, "utf8")))
  const count = (text: string) => tokenizer.encode(text, { add_special_tokens: false }).ids.length
  const counts = Object.fromEntries(FORMS.map((f) => [f, corpus.documents.map((d) => count(d[f]))])) as Record<Form, number[]>
  const seconds = (performance.now() - start) / 1000
  out.tokenizers.push({ name: source.name, family: source.family, repo: source.repo, revision: source.revision, vocab: vocabSize(tokenizerJson), seconds })
  out.counts[source.name] = counts
  const total = (f: Form) => counts[f].reduce((a, b) => a + b, 0)
  console.log(`${source.name.padEnd(12)} ${seconds.toFixed(1).padStart(6)} s   JSON min ${total("json_min")}, haus min ${total("haus_min")}, JSON pretty ${total("json_pretty")}, haus pretty ${total("haus_pretty")}`)
}
writeFileSync(TOKENS_OUT, JSON.stringify(out))
