/** The manifest, `sources.haus`, read with a schema. */
import { readFileSync } from "node:fs"
import * as h from "@haus-fmt/haus/schema"
import { BENCH } from "./paths.ts"

const Sha256 = h.refine(h.String, (s) => (/^[0-9a-f]{64}$/.test(s) ? undefined : "a SHA-256 in lowercase hex"))

const CorpusSource = h.Record({
  name: h.String,
  title: h.String,
  category: h.Enum("ApiResponses", "Config", "Events", "ToolCalls", "Tabular", "Geo"),
  license: h.String,
  repo: h.String,
  commit: h.String,
  committed: h.StdTime("Instant"),
  path: h.String,
  sha256: Sha256,
})

const TokenizerSource = h.Record({
  name: h.String,
  family: h.String,
  repo: h.String,
  revision: h.String,
  files: h.Array(h.Record({ file: h.String, sha256: Sha256 })),
})

const Manifest = h.Record({
  corpus: h.Array(CorpusSource),
  tokenizers: h.Array(TokenizerSource),
})

export type CorpusSource = h.Infer<typeof CorpusSource>
export type TokenizerSource = h.Infer<typeof TokenizerSource>
export type Manifest = h.Infer<typeof Manifest>

export const readManifest = (): Manifest => h.parse(Manifest, readFileSync(`${BENCH}sources.haus`, "utf8"))
