/**
 * Prints the results as markdown tables and writes them as data:
 *
 *   results.md     the tables printed here, one section per source
 *   results.haus   every number, for tools (`{ sources: [...] }`, one record per source)
 *
 * Reads each source's corpus.json (convert) and, when present, tokens.json
 * (tokens) and speed.json (speed). Results of another convert run (another
 * sample) are left out, with a warning. Sources are never merged.
 *
 * Ratios are haus / JSON: below 1 means haus is smaller or faster. "total"
 * is the ratio of the sums over all documents (large documents weigh
 * more); "median" and "geomean" are over the per-document ratios (every
 * document weighs the same).
 *
 * `renderReport` is pure; the step reads the results and writes the files.
 */
import { arr, format, normalizeNumber, num, rec, str, variant, type Value } from "@haus-fmt/haus"
import { Console, Effect, Option } from "effect"
import { CORPUS, Results, SPEED, TOKENS, type CorpusOut, type Form, type SpeedOut, type SpeedRow, type TokensOut } from "../results.ts"
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
  const variants = n("variant (discriminated union)") + n("variant (const discriminator)")
  const any = n("Any: oneOf without a discriminator") + n("Any: anyOf without a discriminator")
  return `${variants} closed variants (${n("variant (discriminated union)")} by an OpenAPI discriminator, ${n("variant (const discriminator)")} by a const property), ` +
    `${any} \`Any\` (no discriminator: ${n("Any: oneOf without a discriminator")} oneOf, ${n("Any: anyOf without a discriminator")} anyOf)`
}

/** Results that belong to these documents (same ids, same order). */
const sameDocuments = (corpus: CorpusOut, ids: readonly string[]): boolean =>
  ids.length === corpus.documents.length && ids.every((id, i) => id === corpus.documents[i]!.id)

export interface Report {
  readonly markdown: string
  /** Every number, as plain data (written as haus by `toValue`). */
  readonly data: unknown
  readonly warnings: readonly string[]
}

/** The report of a convert run, with the token counts and speed results that belong to it. Pure. */
export const renderReport = (corpus: CorpusOut, tokensRead: Option.Option<TokensOut>, speedRead: Option.Option<SpeedOut>): Report => {
  const current = <T extends { readonly documents: readonly string[] }>(what: string, results: Option.Option<T>) => ({
    value: Option.filter(results, (r) => sameDocuments(corpus, r.documents)),
    warnings: Option.isSome(results) && !sameDocuments(corpus, results.value.documents) ? [`warning: ${what} are from another convert run; run them again (left out)`] : [],
  })
  const tokens = current("token counts", tokensRead)
  const speed = current("speed results", speedRead)

  const docs = corpus.documents
  const bytesOf = (f: Form) => docs.map((d) => utf8Length(d[f]))
  const reasons = tally(corpus.excluded.map((e) => e.reason))
  const s = corpus.source
  const ratioCells = (r: Ratio) => [`${fixed3(r.total)} (${pct(r.total)})`, fixed3(r.median), fixed3(r.geomean), `${(r.larger * 100).toFixed(0)}%`]

  const header = [
    `# haus vs JSON: ${s.name}`,
    "",
    `Source: ${s.repo} @ \`${s.commit.slice(0, 12)}\`, \`${s.path}\` (${s.license}). Category: ${s.category}.`,
    `${corpus.examples} ${s.unit}; ${corpus.found} documents (skipped: ${Object.entries(corpus.skipped).map(([k, v]) => `${v} ${k}`).join(", ") || "none"}).` +
      (corpus.sample ? ` **Sample of ${corpus.sample} documents** (\`--limit\`): not for publishing.` : ""),
    `Round trip: **${docs.length} documents measured**, ${corpus.excluded.length} excluded (they don't match the source's own schema).`,
    "",
    ...(reasons.length > 0
      ? ["Most common reasons for exclusion:", "", ...table(["Reason", "Documents"], reasons.slice(0, 10).map(([r, n]) => [r.replaceAll("|", "\\|"), String(n)]))]
      : []),
    "Schema (generated from the source's schema), types reachable from the documents:",
    "",
    ...table(["Type", "Count"], Object.entries(corpus.positions).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, String(v)])),
    `Unions reachable from the documents (oneOf/anyOf, each converted once): ${unions(corpus.decisions)}. In the whole schema (every named type converted): ${unions(corpus.schemaWide)}.`,
    "",
    `Converter decisions: ${Object.entries(corpus.decisions).map(([k, v]) => `${k}: ${v}`).join("; ")}. Members kept that the schema doesn't list: ${corpus.unlistedMembers}.`,
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

  const speedSection = Option.match(speed.value, {
    onNone: (): string[] => [],
    onSome: (sp) => {
      const m = sp.machine
      const baseline = (r: SpeedRow) => sp.rows.find((x) => x.input === r.input && (x.group === r.group || (r.group === "typed" && x.group === "parse")) && x.impl.startsWith("JSON"))
      return [
        "## Speed (TypeScript)",
        "",
        `${m.cpu} (${m.cores} cores, ${m.memory_gb} GB), ${m.os}, ${m.runtime}, GC between tasks: ${m.gc ? "yes" : "no"}. tinybench, ${sp.options.time_ms} ms per task after ${sp.options.warmup_ms} ms warm-up.` +
          (sp.options.quick ? " **Quick run: a harness check, not a measurement.**" : ""),
        `MB/s is against each format's own bytes. "vs JSON" is the time relative to the JSON task of the same group and input. JSON.parse → JSON.stringify changed the text of ${sp.jsonNotStable} documents (numbers a JS number can't hold exactly).`,
        "",
        ...table(
          ["Task", "Input", "Implementation", "MB/s", "µs / doc", "ops/s", "mean ms", "p75 ms", "p99 ms", "vs JSON"],
          sp.rows.map((r) => {
            const b = baseline(r)
            return [r.group, r.input, r.impl, r.mb_s.toFixed(1), r.us_per_doc.toFixed(2), r.hz.toFixed(1), r.mean_ms.toFixed(3), r.p75_ms.toFixed(3), r.p99_ms.toFixed(3), b ? `${(r.mean_ms / b.mean_ms).toFixed(1)}×` : ""]
          }),
        ),
      ]
    },
  })

  const results = {
    source: corpus.source,
    documents: { examples: corpus.examples, found: corpus.found, sample: corpus.sample ?? null, measured: docs.length, excluded: corpus.excluded.length, reasons: Object.fromEntries(countBy(corpus.excluded.map((e) => e.reason))) },
    schema: { positions: corpus.positions, decisions: corpus.decisions, unlistedMembers: corpus.unlistedMembers, schemaWide: corpus.schemaWide },
    bytes: Object.fromEntries(PAIRS.map(([a, b]) => [`${a}/${b}`, { ...ratio(bytesOf(a), bytesOf(b)), haus: sum(bytesOf(a)), json: sum(bytesOf(b)) }])),
    tokens: Option.match(Option.all({ t: tokens.value, ratios: tokenRatios }), {
      onNone: () => null,
      onSome: ({ t, ratios }) => ({ tokenizers: t.tokenizers.map(({ seconds: _, ...tk }) => tk), ratios }),
    }),
    speed: Option.match(speed.value, {
      onNone: () => null,
      onSome: (sp) => ({ machine: sp.machine, options: sp.options, jsonNotStable: sp.jsonNotStable, rows: sp.rows }),
    }),
  }

  return {
    markdown: [...header, ...size, ...tokenSection, ...speedSection].join("\n"),
    data: results,
    warnings: [...tokens.warnings, ...speed.warnings].map((w) => `${s.name}: ${w}`),
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
      return renderReport(corpus, yield* results.readOptional(s.name, TOKENS), yield* results.readOptional(s.name, SPEED))
    }))
  yield* Effect.forEach(reports.flatMap((r) => r.warnings), Console.error, { discard: true })
  const markdown = reports.map((r) => r.markdown).join("\n")
  yield* Console.log(markdown)
  const md = yield* results.writeText(["results.md"], markdown + "\n")
  const haus = yield* results.writeText(
    ["results.haus"],
    `// haus vs JSON benchmark results, one record per corpus source, written by bench/src/steps/report.ts\n${format([toValue({ sources: reports.map((r) => r.data) })])}`,
  )
  yield* Console.log(`\nwrote ${md} and ${haus}`)
})
