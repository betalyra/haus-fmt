import { mkdirSync } from "node:fs"
import { fileURLToPath } from "node:url"

/** bench/ */
export const BENCH = fileURLToPath(new URL("../", import.meta.url))
/** Downloads (git-ignored). */
export const DATA = `${BENCH}.data/`
/** Results (git-ignored). */
export const OUT = `${BENCH}.out/`

export const ensureDir = (dir: string): string => {
  mkdirSync(dir, { recursive: true })
  return dir
}

/** Where `fetch.ts` puts a corpus source's file. */
export const corpusFile = (name: string, path: string): string => `${DATA}corpus/${name}/${path.split("/").at(-1)}`
/** Where `fetch.ts` puts a tokenizer's files. */
export const tokenizerDir = (name: string): string => `${DATA}tokenizers/${name}/`

/** Written by convert.ts, read by tokens.ts, speed.bench.ts and report.ts. */
export const CORPUS_OUT = `${OUT}corpus.json`
export const TOKENS_OUT = `${OUT}tokens.json`
export const SPEED_OUT = `${OUT}speed.json`
export const RESULTS_OUT = `${OUT}results.haus`
export const RESULTS_MD = `${OUT}results.md`
