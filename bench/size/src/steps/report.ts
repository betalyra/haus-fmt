/**
 * Prints the results as markdown tables and writes them as data:
 *
 *   results.md     the tables printed here, one section per source
 *   results.haus   every number, for tools (`{ sources: [...] }`, one record per source)
 *
 * Reads each source's corpus.json (convert) and, when present, tokens.json
 * (tokens), compression.json (compress) and every language's
 * speed-<lang>.json (bench/speed/ts: the speed step; bench/speed/rust: cargo
 * bench; bench/speed/go, bench/speed/jvm and bench/speed/zig: their runners). Results of another convert run (another sample) are left out, with
 * a warning. Sources are never merged.
 *
 * Size and token ratios are haus / JSON: below 1 means haus is smaller.
 * "total" is the ratio of the sums over all documents (large documents weigh
 * more); "median" and "geomean" are over the per-document ratios (every
 * document weighs the same). Speed is shown from haus's side, "2.8× slower",
 * "1.4× faster" or "≈ equal" (within 5%); the results data keeps the times.
 *
 * `renderReport` is pure; the step reads the results and writes the files.
 */
import { arr, format, normalizeNumber, num, rec, str, variant, type Value } from "@haus-fmt/haus"
import { Console, Effect, Option } from "effect"
import { COMPRESSION, CORPUS, LANGS, Results, speedFile, TOKENS, type CompressionOut, type CorpusOut, type Form, type Lang, type SpeedOut, type SpeedRow, type TokensOut } from "../results.ts"
import { streamText, type CompressedForm } from "../compress.ts"
import { selectSources, type Selection } from "../sources.ts"
import { countBy, fixed3, mean, pct, ratio, sum, table, tally, utf8Length, type Ratio } from "../stats.ts"

/** The comparisons reported, haus form against JSON form. */
export const PAIRS = [
  ["haus_min", "json_min", "haus minimised / JSON minified (idiomatic, enums as tags)"],
  ["haus_compact", "json_min", "haus compact / JSON minified"],
  ["haus_pretty", "json_pretty", "haus pretty / JSON pretty (2 spaces)"],
  ["str_min", "json_min", "haus minimised, enums as strings / JSON minified"],
  ["str_pretty", "json_pretty", "haus pretty, enums as strings / JSON pretty"],
  ["plain_min", "json_min", "plain haus minimised (no schema) / JSON minified"],
  ["plain_pretty", "json_pretty", "plain haus pretty (no schema) / JSON pretty"],
  ["haus_min", "plain_min", "typed haus / plain haus, minimised (what the schema's types cost or save)"],
] as const satisfies readonly (readonly [Form, Form, string])[]

/** Plain data as a haus value: objects → records, null → None, booleans → True/False. */
export const toValue = (x: unknown): Value => {
  if (x === null || x === undefined) return variant("None")
  if (typeof x === "boolean") return variant(x ? "True" : "False")
  if (typeof x === "number") return num(normalizeNumber(Number.isInteger(x) ? String(x) : String(Number(x.toPrecision(6)))) ?? "0")
  if (typeof x === "string") return str(x)
  if (Array.isArray(x)) return arr(x.map(toValue))
  return rec(new Map(Object.entries(x as object).filter(([, v]) => v !== undefined).map(([k, v]) => [k, toValue(v)])))
}

/** How the unions came out: variants (by how they're told apart) and `Any` fallbacks. Pure. */
export const unions = (decisions: Readonly<Record<string, number>>): string => {
  const n = (key: string) => decisions[key] ?? 0
  const keyed = n("variant (records told apart by required keys)")
  const variants = n("variant (discriminated union)") + n("variant (const discriminator)") + keyed
  const byKind = [
    ["union of non-records (string | number, …)", "of non-records"],
    ["union mixing records and other types (string | ExprRef, …)", "mixing records and other types"],
    ["union of records not told apart by required keys", "of records not told apart by keys"],
    ["union of records whose tags collide", "of records whose tags collide"],
  ].map(([key, label]) => [n(`Any: ${key}`), label] as const)
  const kinds = byKind.reduce((a, [k]) => a + k, 0)
  const any = n("Any: oneOf without a discriminator") + n("Any: anyOf without a discriminator") + kinds
  return `${variants} closed variants (${n("variant (discriminated union)")} by an OpenAPI discriminator, ${n("variant (const discriminator)")} by a const property, ${keyed} by required keys), ` +
    `${any} \`Any\` (` +
    (kinds > 0 ? byKind.map(([k, label]) => `${k} ${label}`).join(", ") : `no discriminator: ${n("Any: oneOf without a discriminator")} oneOf, ${n("Any: anyOf without a discriminator")} anyOf`) +
    ")"
}

/** Results that belong to these documents (same ids, same order). */
const sameDocuments = (corpus: CorpusOut, ids: readonly string[]): boolean =>
  ids.length === corpus.documents.length && ids.every((id, i) => id === corpus.documents[i]!.id)

const LANG_NAMES: Record<Lang, string> = { typescript: "TypeScript", rust: "Rust", go: "Go", python: "Python", jvm: "JVM", zig: "Zig" }

/**
 * haus's time against a JSON task's time on the same documents, from haus's
 * side: "2.8× slower", "1.4× faster", or "≈ equal" within 5%. Pure.
 */
export const speedRatio = (hausMs: number, jsonMs: number): string => {
  const t = hausMs / jsonMs
  const factor = Math.max(t, 1 / t)
  if (factor < 1.05) return "≈ equal"
  return `${factor < 2 ? factor.toFixed(2) : factor.toFixed(1)}× ${t > 1 ? "slower" : "faster"}`
}

/**
 * The JSON task a row is compared with: the language's plain JSON task of the
 * same input, parse (for typed too) or write: the first JSON row of that
 * group (JSON.parse, JSON.stringify; serde_json; Jackson).
 */
const baselineOf = (rows: readonly SpeedRow[], r: SpeedRow): SpeedRow | undefined =>
  rows.find((x) => x.input === r.input && x.group === (r.group === "typed" ? "parse" : r.group) && x.format === "json")

const versus = (rows: readonly SpeedRow[], r: SpeedRow): string => {
  const b = baselineOf(rows, r)
  return b === r ? "baseline" : b ? speedRatio(r.mean_ms, b.mean_ms) : ""
}

const JSON_NOTES: Record<Lang, (n: number) => string> = {
  typescript: (n) => `JSON.parse → JSON.stringify changed the text of ${n} documents (numbers a JS number can't hold exactly).`,
  rust: (n) => `serde_json's \`Value\` wrote ${n} documents back as another document (numbers in another spelling; it also sorts members, which isn't counted).`,
  go: (n) => `encoding/json through \`any\` wrote ${n} documents back as another document (numbers as float64; it also sorts members, which isn't counted).`,
  python: (n) => `json.loads → json.dumps wrote ${n} documents back as another document (numbers as float).`,
  jvm: (n) => `Jackson's \`JsonNode\` tree wrote ${n} documents back as another document (floating-point numbers as double).`,
  zig: (n) => `std.json's \`Value\` wrote ${n} documents back as another document (numbers as i64 or f64).`,
}

const SAMPLE_NOTES: Record<Lang, string> = {
  typescript: "",
  rust: "p75 and p99 are over criterion's samples (each the mean of a batch of calls). ",
  go: "p75 and p99 are over the samples (each the mean of one testing.Benchmark run); allocations are testing's (-benchmem). ",
  python: "p75 and p99 are over the samples (each the mean of a batch of calls). The Python binding has no compact or minimised writer yet: haus's write is `haus.canonical` (minimised, keys sorted). ",
  jvm: "p75 and p99 are over the samples (each the mean of one JMH iteration, of every round); bytes allocated are JMH's gc profiler's (gc.alloc.rate.norm), the number of allocations isn't counted. ",
  zig: "p75 and p99 are over the samples (each the mean of a batch of calls). gh-archive is not measured (personal data). ",
}

/** The schema-compiled JSON writers of the typed write, where a language has them. */
const JSON_WRITERS: Partial<Record<Lang, string>> = { typescript: "fast-json-stringify", python: "pydantic or msgspec" }

/** One language's speed table, with the machine and harness. Pure. */
export const speedTable = (sp: SpeedOut): string[] => {
  const m = sp.machine
  // Go counts allocations and bytes, the JVM bytes only.
  const allocs = sp.rows.some((r) => r.allocs !== undefined)
  const allocBytes = sp.rows.some((r) => r.alloc_bytes !== undefined)
  const perDoc = (r: SpeedRow, x: number | undefined, digits: number) => (x === undefined ? "" : (x / r.docs).toFixed(digits))
  return [
    `### ${LANG_NAMES[sp.lang]}`,
    "",
    `${m.cpu} (${m.cores} cores, ${m.memory_gb} GB), ${m.os}, ${m.runtime}` + (sp.lang !== "rust" && sp.lang !== "zig" ? `, GC between tasks: ${m.gc ? "yes" : "no"}` : "") +
      `. ${sp.harness}, ${sp.options.time_ms} ms per task after ${sp.options.warmup_ms} ms warm-up.` +
      (sp.options.quick ? " **Quick run: a harness check, not a measurement.**" : ""),
    `${SAMPLE_NOTES[sp.lang]}${JSON_NOTES[sp.lang](sp.jsonNotStable)}`,
    "",
    ...table(
      ["Task", "Input", "Implementation", "MB/s", "µs / doc", "ops/s", "mean ms", "p75 ms", "p99 ms", ...(allocs ? ["allocs / doc"] : []), ...(allocBytes ? ["KB allocated / doc"] : []), "vs JSON"],
      sp.rows.map((r) => [
        r.group, r.input, r.impl, r.mb_s.toFixed(1), r.us_per_doc.toFixed(2), r.hz.toFixed(1), r.mean_ms.toFixed(3), r.p75_ms.toFixed(3), r.p99_ms.toFixed(3),
        ...(allocs ? [perDoc(r, r.allocs, 0)] : []),
        ...(allocBytes ? [perDoc(r, r.alloc_bytes === undefined ? undefined : r.alloc_bytes / 1024, 1)] : []),
        versus(sp.rows, r),
      ]),
    ),
    // TypeScript, Go and Python have JSON baselines that check or write with the schema.
    ...(sp.typedBaselines ? typedVersusTable(sp) : []),
  ]
}

/** What a haus row measures, the same in every language: `parse`, `typed`, `write minimised`, `write compact`; `write typed` (TypeScript's h.stringify, Python's SchemaType.canonical, the JVM's SchemaType.encode + Haus.write); `write canonical` (Python, JVM). */
const hausTask = (r: SpeedRow): string =>
  r.group !== "write" ? r.group
  : r.impl.includes("(typed)") ? "write typed"
  : r.impl.includes("canonical") ? "write canonical"
  : `write ${r.impl.includes("compact") ? "compact" : "minimised"}`

/**
 * The typed tasks against the JSON baselines that check or use the same
 * schema (TypeScript: JSON.parse + Zod, Ajv, TypeBox; fast-json-stringify; Go:
 * encoding/json and goccy/go-json into and from generated Go types; Python:
 * pydantic, msgspec),
 * and against the plain JSON task. "haus vs JSON" compares the times on the
 * same documents, so it is the comparison; MB/s is each format's own bytes. Pure.
 */
export const typedVersusTable = (sp: SpeedOut): string[] => {
  const pairs = sp.rows.flatMap((h) => {
    if (h.format !== "haus" || (h.group !== "typed" && hausTask(h) !== "write typed")) return []
    const read = h.group === "typed"
    const json = sp.rows.filter((x) => x.format === "json" && x.input === h.input && (read ? x.group === "parse" || x.group === "typed" : x.group === "write"))
    return json.map((j) => [read ? "typed (parse + check)" : "typed write", h.input, h.impl, j.impl, j.mb_s.toFixed(1), h.mb_s.toFixed(1), speedRatio(h.mean_ms, j.mean_ms)])
  })
  if (pairs.length === 0) return []
  const b = sp.typedBaselines
  // Go's baselines are Go types generated from the JSON Schema, which don't reject every mutated document (`mutated` says how many were made).
  const go = sp.lang === "go"
  const mutated = b?.mutated
  const rejected = (r: Readonly<Record<string, number>>) =>
    mutated ? `rejected ${Object.entries(mutated).map(([k, n]) => `${r[k] ?? 0} of ${n} mutated (${k})`).join(", ")}` : `rejected ${Object.entries(r).map(([k, n]) => `${n} mutated (${k})`).join(", ")}`
  const roundTrip = b?.roundTrip
    ? `; the typed JSON round trip (decode into the Go types, encode) gives the members the schema lists with the same values, but ${Object.entries(b.roundTrip).map(([lib, r]) =>
      `${lib} rounds numbers in ${r.numbersRounded}, respells date-times in ${r.timesRespelled} and drops optional members that are null in ${r.nullsDropped} documents`).join("; ")}`
    : ""
  return [
    `haus typed against JSON with the same schema (${LANG_NAMES[sp.lang]}): ` +
      (go ? "the Go types (decoded and encoded by encoding/json and by goccy/go-json) are generated from" : "the validators and the writer are built from") +
      ` the JSON Schema convert derives from the haus schema (\`corpus/<source>.schema.json\`).` +
      (b ? ` Before timing, every ${go ? "baseline" : "validator"} accepted every document and ${rejected(b.rejected)}; ` +
        `the typed haus write writes other text than the document (members in the schema's order, members it doesn't list dropped) for ${b.typedWriteOtherText} documents, ` +
        (go ? `encoding/json's write of the Go types other text than the document for ${b.jsonWriterOtherText}` : `${JSON_WRITERS[sp.lang]} writes other text than ${sp.lang === "python" ? "the document" : "JSON.stringify"} for ${b.jsonWriterOtherText}`) +
        (b.jsonWriterKeyedAsAny ? `; fast-json-stringify writes the unions told apart by keys as JSON.stringify does (it can't build them) for ${b.jsonWriterKeyedAsAny.join(", ")}` : "") +
        roundTrip +
        `. ${Object.entries(b.versions).map(([k, v]) => `${k} ${v}`).join(", ")}.` : ""),
    "",
    ...table(["Task", "Input", "haus", "JSON", "JSON MB/s", "haus MB/s", "haus vs JSON"], pairs),
  ]
}

/** haus in every language side by side: MB/s, and how fast against the language's JSON. Pure. */
export const speedSummary = (speed: readonly SpeedOut[]): string[] => {
  // (The typed writes are in the typed tables: Rust has none yet.)
  const keys = [...new Set(speed.flatMap((sp) => sp.rows.filter((r) => r.format === "haus" && hausTask(r) !== "write typed").map((r) => `${hausTask(r)}|${r.input}`)))]
  return [
    "haus in each language (MB/s of haus text; faster or slower than the language's JSON task of the same input):",
    "",
    ...table(
      ["Task", "Input", ...speed.flatMap((sp) => [`${LANG_NAMES[sp.lang]} MB/s`, `${LANG_NAMES[sp.lang]} vs JSON`])],
      keys.map((key) => {
        const [task, input] = key.split("|") as [string, string]
        return [task, input, ...speed.flatMap((sp) => {
          const r = sp.rows.find((x) => x.format === "haus" && x.input === input && hausTask(x) === task)
          return r ? [r.mb_s.toFixed(1), versus(sp.rows, r)] : ["", ""]
        })]
      }),
    ),
  ]
}

export interface Report {
  readonly markdown: string
  /** Every number, as plain data (written as haus by `toValue`). */
  readonly data: unknown
  readonly warnings: readonly string[]
}

/** The report of a convert run, with the token counts and speed results that belong to it. Pure. */
export const renderReport = (corpus: CorpusOut, tokensRead: Option.Option<TokensOut>, speedRead: readonly SpeedOut[], compressionRead: Option.Option<CompressionOut> = Option.none()): Report => {
  const current = <T extends { readonly documents: readonly string[] }>(what: string, results: Option.Option<T>) => ({
    value: Option.filter(results, (r) => sameDocuments(corpus, r.documents)),
    warnings: Option.isSome(results) && !sameDocuments(corpus, results.value.documents) ? [`warning: ${what} are from another convert run; run them again (left out)`] : [],
  })
  const tokens = current("token counts", tokensRead)
  const speeds = speedRead.map((sp) => current(`${LANG_NAMES[sp.lang]} speed results`, Option.some(sp)))
  const speed = speeds.flatMap((sp) => Option.toArray(sp.value))
  const compression = current("compressed sizes", compressionRead)

  const docs = corpus.documents
  const bytesOf = (f: Form) => docs.map((d) => utf8Length(d[f]))
  const reasons = tally(corpus.excluded.map((e) => e.reason))
  const s = corpus.source
  const ratioCells = (r: Ratio) => [`${fixed3(r.total)} (${pct(r.total)})`, fixed3(r.median), fixed3(r.geomean), `${(r.larger * 100).toFixed(0)}%`]

  const header = [
    `# haus vs JSON: ${s.name}`,
    "",
    `Source: ${s.repo} @ \`${/^[0-9a-f]{40}$/.test(s.commit) ? s.commit.slice(0, 12) : s.commit}\`, \`${s.path}\` (${s.license}). Category: ${s.category}.`,
    `${corpus.examples} ${s.unit}; ${corpus.found} documents (skipped: ${Object.entries(corpus.skipped).map(([k, v]) => `${v} ${k}`).join(", ") || "none"}).` +
      (corpus.sample ? ` **Sample of ${corpus.sample} documents** (\`--limit\`): not for publishing.` : ""),
    `Round trip: **${docs.length} documents measured**, ${corpus.excluded.length} excluded (they don't match the source's own schema).`,
    "",
    ...(reasons.length > 0
      ? ["Most common reasons for exclusion:", "", ...table(["Reason", "Documents"], reasons.slice(0, 10).map(([r, n]) => [r.replaceAll("|", "\\|"), String(n)]))]
      : []),
    `Schema (\`${s.name}.schema.haus\`), types reachable from the documents:`,
    "",
    ...table(["Type", "Count"], Object.entries(corpus.positions).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, String(v)])),
    `Unions reachable from the documents (oneOf/anyOf, each converted once): ${unions(corpus.decisions)}. In the whole schema (every named type converted): ${unions(corpus.schemaWide)}.`,
    "",
    `Converter decisions: ${Object.entries(corpus.decisions).map(([k, v]) => `${k}: ${v}`).join("; ") || "none (a hand-written schema)"}. Members kept that the schema doesn't list: ${corpus.unlistedMembers}.` +
      (corpus.respelledNumbers ? ` Documents with a number haus spells its own way (\`1e-09\` → \`1e-9\`, the same number): ${corpus.respelledNumbers}.` : ""),
    "",
  ]

  const size = [
    "## Size (bytes, UTF-8)",
    "",
    ...table(
      ["Comparison", "haus", "JSON", "total", "median", "geomean", "docs where haus is larger"],
      PAIRS.map(([a, b, label]) => [label, String(sum(bytesOf(a))), String(sum(bytesOf(b))), ...ratioCells(ratio(bytesOf(a), bytesOf(b)))]),
    ),
  ]

  const r3 = (a: number, b: number) => `${fixed3(a / b)} (${pct(a / b)})`
  const streamBytes = (f: Form) => utf8Length(streamText(f, docs.map((d) => d[f])))
  const streamTokens = Option.map(tokens.value, (t) => t.tokenizers.map((tk) => [tk.name, t.stream[tk.name]!] as const))
  const streamRow = (label: string, haus: number, plain: number, json: number) => [label, String(haus), String(plain), String(json), r3(haus, json), r3(plain, json)]
  const stream = [
    "## The documents as one stream",
    "",
    "All documents as one file: JSON Lines (minified JSON, one per line) against a haus stream (minimised, every item followed by `,` and a line feed; spec §6, §11).",
    "",
    ...table(
      ["Measure", "haus stream", "plain haus stream", "JSON Lines", "haus / JSON", "plain / JSON"],
      [
        streamRow("bytes", streamBytes("haus_min"), streamBytes("plain_min"), streamBytes("json_min")),
        ...Option.getOrElse(Option.map(streamTokens, (rows) => rows.map(([name, st]) => streamRow(`tokens, ${name}`, st["haus_min"]!, st["plain_min"]!, st["json_min"]!))), () => []),
      ],
    ),
  ]

  const compressionSection = Option.match(compression.value, {
    onNone: (): string[] => [],
    onSome: (c) => {
      const form = (f: CompressedForm) => c.forms[f]!
      const cells = (pick: (f: CompressedForm) => { readonly per: number; readonly st: number }) => {
        const [jm, hm, pm, jp, hp] = (["json_min", "haus_min", "plain_min", "json_pretty", "haus_pretty"] as const).map(pick)
        return [String(jm!.per), String(hm!.per), r3(hm!.per, jm!.per), r3(pm!.per, jm!.per), String(jm!.st), String(hm!.st), r3(hm!.st, jm!.st), r3(pm!.st, jm!.st), r3(hp!.per, jp!.per), r3(hp!.st, jp!.st)]
      }
      return [
        "## Compressed",
        "",
        `Bytes after compression (node:zlib of ${c.runtime}; other runtimes' builds give slightly other sizes): each document alone (the sum over documents; small documents compress badly), and all documents as one stream (JSON Lines and a haus stream; for pretty, the texts one after the other). Ratios are haus / JSON; plain is plain haus (no schema).`,
        "",
        ...table(
          ["Codec", "JSON min, per doc", "haus min, per doc", "haus / JSON", "plain / JSON", "JSON Lines", "haus stream", "haus / JSON", "plain / JSON", "pretty, per doc: haus / JSON", "pretty, stream: haus / JSON"],
          [
            ["none", ...cells((f) => ({ per: form(f).bytes, st: form(f).streamBytes }))],
            ...c.codecs.map((name) => [name, ...cells((f) => ({ per: form(f).perDoc[name]!, st: form(f).stream[name]! }))]),
          ],
        ),
      ]
    },
  })

  const tokenRatios = Option.map(tokens.value, (t) =>
    Object.fromEntries(t.tokenizers.map((tk) => {
      const c = t.counts[tk.name]!
      return [tk.name, Object.fromEntries(PAIRS.map(([a, b]) => [`${a}/${b}`, { ...ratio(c[a], c[b]), haus: sum(c[a]), json: sum(c[b]) }]))]
    })) as Record<string, Record<string, Ratio & { readonly haus: number; readonly json: number }>>,
  )

  const tokenSection = Option.match(Option.all({ t: tokens.value, ratios: tokenRatios }), {
    onNone: (): string[] => [],
    onSome: ({ t, ratios }) => {
      const names = t.tokenizers.map((tk) => tk.name)
      const avg = (key: string, k: keyof Ratio) => mean(names.map((n) => ratios[n]![key]![k]))
      return [
        "## Tokens",
        "",
        "Tokenizers (tokenizers.js, no special tokens added):",
        "",
        ...table(["Name", "Stands for", "Hub repository @ revision", "Vocabulary"], t.tokenizers.map((tk) => [tk.name, tk.family, `${tk.repo} @ \`${tk.revision.slice(0, 12)}\``, String(tk.vocab)])),
        ...PAIRS.flatMap(([a, b, label]) => {
          const key = `${a}/${b}`
          return [
            `**${label}**`,
            "",
            ...table(
              ["Tokenizer", "haus tokens", "JSON tokens", "total", "median", "geomean", "docs where haus is larger"],
              [
                ...names.map((n) => {
                  const r = ratios[n]![key]!
                  return [n, String(r.haus), String(r.json), ...ratioCells(r)]
                }),
                ["**average**", "", "", `**${fixed3(avg(key, "total"))} (${pct(avg(key, "total"))})**`, `**${fixed3(avg(key, "median"))}**`, `**${fixed3(avg(key, "geomean"))}**`, `${(avg(key, "larger") * 100).toFixed(0)}%`],
              ],
            ),
          ]
        }),
      ]
    },
  })

  const speedSection = speed.length === 0 ? [] : [
    "## Speed",
    "",
    "Each language's own benchmark, on the same documents (the files convert exports to `corpus/`): parse (text → the binding's generic value), typed (parse and decode with the document's schema; in TypeScript also JSON.parse + a validator of the same schema, in Go also encoding/json and goccy/go-json into Go types generated from it, in Python pydantic and msgspec models of it), write (value → text; in TypeScript also typed: fast-json-stringify, h.stringify; in Go typed: the Go types, Type.Format; in Python typed: pydantic, msgspec, SchemaType.canonical; on the JVM typed: SchemaType.encode + Haus.write, and the canonical form beside Jackson writing members sorted; in Zig typed: decoding.encode + stringify). MB/s is against each format's own bytes; \"vs JSON\" says how much faster or slower haus is than the language's plain JSON task of the same input (its parse for parse and typed, its write for write: JSON.parse and JSON.stringify, serde_json, encoding/json into and from `any`, json.loads and json.dumps, Jackson, std.json into and from `std.json.Value`), \"≈ equal\" within 5%.",
    "",
    ...(speed.length > 1 ? speedSummary(speed) : []),
    ...speed.flatMap(speedTable),
  ]

  const results = {
    source: corpus.source,
    documents: { examples: corpus.examples, found: corpus.found, sample: corpus.sample ?? null, measured: docs.length, excluded: corpus.excluded.length, reasons: Object.fromEntries(countBy(corpus.excluded.map((e) => e.reason))) },
    schema: { positions: corpus.positions, decisions: corpus.decisions, unlistedMembers: corpus.unlistedMembers, schemaWide: corpus.schemaWide },
    bytes: Object.fromEntries(PAIRS.map(([a, b]) => [`${a}/${b}`, { ...ratio(bytesOf(a), bytesOf(b)), haus: sum(bytesOf(a)), json: sum(bytesOf(b)) }])),
    tokens: Option.match(Option.all({ t: tokens.value, ratios: tokenRatios }), {
      onNone: () => null,
      onSome: ({ t, ratios }) => ({ tokenizers: t.tokenizers.map(({ seconds: _, ...tk }) => tk), ratios, stream: t.stream }),
    }),
    compression: Option.getOrNull(compression.value),
    speed: speed.length === 0 ? null : Object.fromEntries(speed.map((sp) => [sp.lang, { harness: sp.harness, machine: sp.machine, options: sp.options, jsonNotStable: sp.jsonNotStable, ...(sp.typedBaselines ? { typedBaselines: sp.typedBaselines } : {}), rows: sp.rows }])),
  }

  return {
    markdown: [...header, ...size, ...tokenSection, ...stream, ...compressionSection, ...speedSection].join("\n"),
    data: results,
    warnings: [...tokens.warnings, ...compression.warnings, ...speeds.flatMap((sp) => sp.warnings)].map((w) => `${s.name}: ${w}`),
  }
}

/**
 * The report of every source that has results: one markdown section and one
 * record each, never merged (each source is its own population of documents).
 */
export const report = Effect.fn("bench.report")(function* (options: { readonly sources: Selection }) {
  const results = yield* Results
  const sources = yield* selectSources(options.sources)
  const reports = yield* Effect.forEach(sources, (s) =>
    Effect.gen(function* () {
      const corpus = yield* results.read(s.name, CORPUS, "convert")
      const speeds = yield* Effect.forEach(LANGS, (lang) => results.readOptional(s.name, speedFile(lang)))
      return renderReport(corpus, yield* results.readOptional(s.name, TOKENS), speeds.flatMap(Option.toArray), yield* results.readOptional(s.name, COMPRESSION))
    }))
  yield* Effect.forEach(reports.flatMap((r) => r.warnings), Console.error, { discard: true })
  const markdown = reports.map((r) => r.markdown).join("\n")
  yield* Console.log(markdown)
  const md = yield* results.writeText(["results.md"], markdown + "\n")
  const haus = yield* results.writeText(
    ["results.haus"],
    `// haus vs JSON benchmark results, one record per corpus source, written by bench/size/src/steps/report.ts\n${format([toValue({ sources: reports.map((r) => r.data) })])}`,
  )
  yield* Console.log(`\nwrote ${md} and ${haus}`)
})
