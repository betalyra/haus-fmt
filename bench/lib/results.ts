/**
 * What the steps write to bench/.out/ and read back: convert.ts →
 * corpus.json, tokens.ts → tokens.json, speed.bench.ts → speed.json.
 */

/** One document in every form that is measured. */
export interface Converted {
  readonly id: string
  readonly kind: string
  /** The named type of the whole document, in both schema files. */
  readonly root: string
  readonly json_min: string
  readonly json_pretty: string
  /** Idiomatic haus, enums as tags. */
  readonly haus_min: string
  readonly haus_compact: string
  readonly haus_pretty: string
  /** The same with enums as strings. */
  readonly str_min: string
  readonly str_pretty: string
  /** Plain haus: the import, no schema. */
  readonly plain_min: string
  readonly plain_pretty: string
}

export interface CorpusOut {
  readonly source: { readonly name: string; readonly repo: string; readonly commit: string; readonly path: string; readonly license: string; readonly category: string }
  /** Example responses in the description, documents found, and the sample taken (`--limit`). */
  readonly examples: number
  readonly found: number
  readonly sample: number | undefined
  readonly skipped: Readonly<Record<string, number>>
  readonly documents: readonly Converted[]
  readonly excluded: readonly { readonly id: string; readonly reason: string; readonly path: string }[]
  readonly schemas: { readonly tags: string; readonly strings: string }
  /** Decisions the converter made, counted where they were made. */
  readonly decisions: Readonly<Record<string, number>>
  /** Types reachable from the documents' types, by what they are (each type once). */
  readonly positions: Readonly<Record<string, number>>
  /** Members in the examples that the description doesn't list (kept, as imported JSON). */
  readonly unlistedMembers: number
  readonly notes: readonly string[]
}

/** The forms of each document that are measured, in report order. */
export const FORMS = ["json_min", "json_pretty", "haus_min", "haus_compact", "haus_pretty", "str_min", "str_pretty", "plain_min", "plain_pretty"] as const satisfies readonly (keyof Converted)[]
export type Form = (typeof FORMS)[number]

export interface TokensOut {
  readonly tokenizers: readonly { readonly name: string; readonly family: string; readonly repo: string; readonly revision: string; readonly vocab: number; readonly seconds: number }[]
  readonly documents: readonly string[]
  /** counts[tokenizer][form][i]: tokens of document i. */
  readonly counts: Readonly<Record<string, Readonly<Record<Form, readonly number[]>>>>
}

export interface SpeedRow {
  readonly group: "parse" | "typed" | "write"
  readonly input: "corpus" | "per doc"
  readonly impl: string
  /** Bytes read (parse, typed) or written (write) per iteration. */
  readonly bytes: number
  readonly docs: number
  readonly hz: number
  readonly mean_ms: number
  readonly p75_ms: number
  readonly p99_ms: number
  readonly samples: number
  readonly mb_s: number
  readonly us_per_doc: number
}

export interface SpeedOut {
  readonly machine: { readonly cpu: string; readonly cores: number; readonly memory_gb: number; readonly os: string; readonly runtime: string; readonly gc: boolean }
  readonly options: { readonly time_ms: number; readonly warmup_ms: number; readonly quick: boolean }
  /** The documents measured (ids, in order), to match the results to a convert run. */
  readonly documents: readonly string[]
  /** Documents whose JSON.parse → JSON.stringify doesn't give the same text (numbers JS can't hold exactly). */
  readonly jsonNotStable: number
  readonly rows: readonly SpeedRow[]
  readonly checksum: number
}
