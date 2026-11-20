/**
 * Compressed sizes, as the documents travel: gzip (levels 6 and 9), brotli
 * (quality 4, typical for dynamic responses, and 11, for static files) and
 * zstd (level 3), with the zlib of the runtime (node:zlib; Bun and Deno have
 * it too). Each form is compressed per document (the sum over documents:
 * small responses compress badly) and as one stream of all documents (JSON
 * Lines, a haus stream), since a large stream compresses very differently.
 *
 * Pure (the compressors are deterministic for a given zlib build).
 */
import { brotliCompressSync, constants, gzipSync, zstdCompressSync } from "node:zlib"
import type { Converted, Form } from "./results.ts"

export interface Codec {
  readonly name: string
  readonly size: (data: Uint8Array) => number
}

const brotli = (quality: number) => (data: Uint8Array) =>
  brotliCompressSync(data, { params: { [constants.BROTLI_PARAM_QUALITY]: quality, [constants.BROTLI_PARAM_SIZE_HINT]: data.length } }).length

export const CODECS: readonly Codec[] = [
  { name: "gzip 6", size: (d) => gzipSync(d, { level: 6 }).length },
  { name: "gzip 9", size: (d) => gzipSync(d, { level: 9 }).length },
  { name: "brotli 4", size: brotli(4) },
  { name: "brotli 11", size: brotli(11) },
  { name: "zstd 3", size: (d) => zstdCompressSync(d, { params: { [constants.ZSTD_c_compressionLevel]: 3 } }).length },
]

/** The forms compressed: the wire forms and the pretty ones. */
export const COMPRESSED_FORMS = ["json_min", "haus_min", "plain_min", "json_pretty", "haus_pretty"] as const satisfies readonly Form[]
export type CompressedForm = (typeof COMPRESSED_FORMS)[number]

/**
 * The documents of a form as one file: JSON Lines for minified JSON (spec
 * §16: a stream is JSON Lines), concatenated texts for pretty JSON, a haus
 * stream (spec §6, §11: every item followed by a comma; a blank line after
 * each pretty item) for haus.
 */
export const streamText = (form: Form, texts: readonly string[]): string => {
  if (form.startsWith("json_")) return texts.map((t) => `${t}\n`).join("")
  if (form.endsWith("_pretty")) return texts.map((t) => `${t},\n`).join("\n")
  return texts.map((t) => `${t},\n`).join("")
}

export interface FormCompression {
  /** Uncompressed UTF-8 bytes: the sum over documents, and the stream. */
  readonly bytes: number
  readonly streamBytes: number
  /** By codec: the sum of each document compressed alone, and the stream compressed. */
  readonly perDoc: Readonly<Record<string, number>>
  readonly stream: Readonly<Record<string, number>>
}

const encoder = new TextEncoder()

/** Every compressed form, every codec. Pure. */
export const compressCorpus = (documents: readonly Converted[]): Record<CompressedForm, FormCompression> =>
  Object.fromEntries(COMPRESSED_FORMS.map((form) => {
    const docs = documents.map((d) => encoder.encode(d[form]))
    const stream = encoder.encode(streamText(form, documents.map((d) => d[form])))
    const by = (f: (c: Codec) => number) => Object.fromEntries(CODECS.map((c) => [c.name, f(c)]))
    const result: FormCompression = {
      bytes: docs.reduce((n, d) => n + d.length, 0),
      streamBytes: stream.length,
      perDoc: by((c) => docs.reduce((n, d) => n + c.size(d), 0)),
      stream: by((c) => c.size(stream)),
    }
    return [form, result]
  })) as Record<CompressedForm, FormCompression>
