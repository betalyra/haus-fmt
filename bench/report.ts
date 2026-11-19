/**
 * Prints the results as markdown tables and writes them as data:
 *
 *   .out/results.md     the tables printed here
 *   .out/results.haus   every number, for tools (one record)
 *
 * Reads .out/corpus.json (convert.ts) and, when present, .out/tokens.json
 * (tokens.ts) and .out/speed.json (speed.bench.ts).
 *
 * Ratios are haus / JSON: below 1 means haus is smaller or faster. "total"
 * is the ratio of the sums over all documents (large documents weigh
 * more); "median" and "geomean" are over the per-document ratios (every
 * document weighs the same).
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { arr, format, normalizeNumber, num, rec, str, variant, type Value } from "@haus-fmt/haus"
import { CORPUS_OUT, RESULTS_MD, RESULTS_OUT, SPEED_OUT, TOKENS_OUT } from "./lib/paths.ts"
import type { CorpusOut, Form, SpeedOut, TokensOut } from "./lib/results.ts"

const readJson = <T>(path: string): T | undefined => (existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : undefined)
const corpus = readJson<CorpusOut>(CORPUS_OUT)
if (!corpus) throw new Error("no .out/corpus.json: run convert.ts first")
/** Results of an earlier convert run (another sample) don't belong to these documents: left out, with a warning. */
const current = <T>(what: string, results: T | undefined, ids: readonly string[] | undefined): T | undefined => {
  const same = ids !== undefined && ids.length === corpus.documents.length && ids.every((id, i) => id === corpus.documents[i]!.id)
  if (results !== undefined && !same) console.error(`warning: ${what} are from another convert run; run them again (left out)`)
  return same ? results : undefined
}
const tokensRead = readJson<TokensOut>(TOKENS_OUT)
const tokens = current("token counts", tokensRead, tokensRead?.documents)
const speedRead = readJson<SpeedOut>(SPEED_OUT)
const speed = current("speed results", speedRead, speedRead?.documents)

// ── statistics ───────────────────────────────────────────────

const sum = (xs: readonly number[]) => xs.reduce((a, b) => a + b, 0)
const median = (xs: readonly number[]) => {
  const s = [...xs].sort((a, b) => a - b)
  const m = s.length >> 1
  return s.length === 0 ? NaN : s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2
}
const geomean = (xs: readonly number[]) => Math.exp(sum(xs.map(Math.log)) / xs.length)
const mean = (xs: readonly number[]) => sum(xs) / xs.length

interface Ratio {
  readonly total: number
  readonly median: number
  readonly geomean: number
  /** Share of documents where haus is larger. */
  readonly larger: number
}
const ratio = (haus: readonly number[], json: readonly number[]): Ratio => {
  const r = haus.map((x, i) => x / json[i]!)
  return { total: sum(haus) / sum(json), median: median(r), geomean: geomean(r), larger: r.filter((x) => x > 1).length / r.length }
}

/** The comparisons reported, haus form against JSON form. */
const PAIRS = [
  ["haus_min", "json_min", "haus minimised / JSON minified (idiomatic, enums as tags)"],
  ["haus_compact", "json_min", "haus compact / JSON minified"],
  ["haus_pretty", "json_pretty", "haus pretty / JSON pretty (2 spaces)"],
  ["str_min", "json_min", "haus minimised, enums as strings / JSON minified"],
  ["str_pretty", "json_pretty", "haus pretty, enums as strings / JSON pretty"],
  ["plain_min", "json_min", "plain haus minimised (no schema) / JSON minified"],
  ["plain_pretty", "json_pretty", "plain haus pretty (no schema) / JSON pretty"],
] as const satisfies readonly (readonly [Form, Form, string])[]

const docs = corpus.documents
const bytesOf = (f: Form) => docs.map((d) => Buffer.byteLength(d[f]))
const pct = (r: number) => `${r >= 1 ? "+" : "−"}${(Math.abs(r - 1) * 100).toFixed(1)}%`
const fmt = (r: number) => r.toFixed(3)

// ── markdown ─────────────────────────────────────────────────

const md: string[] = []
const line = (s = "") => md.push(s)
const table = (head: readonly string[], rows: readonly (readonly string[])[]) => {
  line(`| ${head.join(" | ")} |`)
  // Numbers right, text left.
  const numeric = head.map((_, i) => i > 0 && rows.every((r) => r[i] === "" || /^\**[\d.]/.test(r[i]!)))
  line(`|${numeric.map((n) => (n ? "---:" : "---")).join("|")}|`)
  for (const r of rows) line(`| ${r.join(" | ")} |`)
  line()
}

const reasons = new Map<string, number>()
for (const e of corpus.excluded) reasons.set(e.reason, (reasons.get(e.reason) ?? 0) + 1)
const s = corpus.source
line(`# haus vs JSON: ${s.name}`)
line()
line(`Source: ${s.repo} @ \`${s.commit.slice(0, 12)}\`, \`${s.path}\` (${s.license}). Category: ${s.category}.`)
line(`${corpus.examples} example responses; ${corpus.found} documents (skipped: ${Object.entries(corpus.skipped).map(([k, v]) => `${v} ${k}`).join(", ")}).` +
  (corpus.sample ? ` **Sample of ${corpus.sample} documents** (\`--limit\`): not for publishing.` : ""))
line(`Round trip: **${docs.length} documents measured**, ${corpus.excluded.length} excluded (their example doesn't match GitHub's own schema).`)
line()
if (reasons.size > 0) {
  line("Most common reasons for exclusion:")
  line()
  table(["Reason", "Documents"], [...reasons].sort((a, b) => b[1] - a[1]).slice(0, 10).map(([r, n]) => [r.replaceAll("|", "\\|"), String(n)]))
}
line("Schema (generated from the OpenAPI description), types reachable from the documents:")
line()
table(["Type", "Count"], Object.entries(corpus.positions).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, String(v)]))
line(`Converter decisions: ${Object.entries(corpus.decisions).map(([k, v]) => `${k}: ${v}`).join("; ")}. Members kept that the description doesn't list: ${corpus.unlistedMembers}.`)
line()

line("## Size (bytes, UTF-8)")
line()
table(
  ["Comparison", "haus", "JSON", "total", "median", "geomean", "docs where haus is larger"],
  PAIRS.map(([a, b, label]) => {
    const r = ratio(bytesOf(a), bytesOf(b))
    return [label, String(sum(bytesOf(a))), String(sum(bytesOf(b))), `${fmt(r.total)} (${pct(r.total)})`, fmt(r.median), fmt(r.geomean), `${(r.larger * 100).toFixed(0)}%`]
  }),
)

const tokenRatios: Record<string, Record<string, Ratio & { haus: number; json: number }>> = {}
if (tokens) {
  line("## Tokens")
  line()
  line("Tokenizers (tokenizers.js, no special tokens added):")
  line()
  table(["Name", "Stands for", "Hub repository @ revision", "Vocabulary"], tokens.tokenizers.map((t) => [t.name, t.family, `${t.repo} @ \`${t.revision.slice(0, 12)}\``, String(t.vocab)]))
  for (const t of tokens.tokenizers) {
    const c = tokens.counts[t.name]!
    tokenRatios[t.name] = Object.fromEntries(PAIRS.map(([a, b]) => [`${a}/${b}`, { ...ratio(c[a], c[b]), haus: sum(c[a]), json: sum(c[b]) }]))
  }
  const names = tokens.tokenizers.map((t) => t.name)
  const avg = (key: string, k: keyof Ratio) => mean(names.map((n) => tokenRatios[n]![key]![k]))
  for (const [a, b, label] of PAIRS) {
    const key = `${a}/${b}`
    line(`**${label}**`)
    line()
    table(
      ["Tokenizer", "haus tokens", "JSON tokens", "total", "median", "geomean", "docs where haus is larger"],
      [
        ...names.map((n) => {
          const r = tokenRatios[n]![key]!
          return [n, String(r.haus), String(r.json), `${fmt(r.total)} (${pct(r.total)})`, fmt(r.median), fmt(r.geomean), `${(r.larger * 100).toFixed(0)}%`]
        }),
        ["**average**", "", "", `**${fmt(avg(key, "total"))} (${pct(avg(key, "total"))})**`, `**${fmt(avg(key, "median"))}**`, `**${fmt(avg(key, "geomean"))}**`, `${(avg(key, "larger") * 100).toFixed(0)}%`],
      ],
    )
  }
}

if (speed) {
  line("## Speed (TypeScript)")
  line()
  const m = speed.machine
  line(`${m.cpu} (${m.cores} cores, ${m.memory_gb} GB), ${m.os}, ${m.runtime}, GC between tasks: ${m.gc ? "yes" : "no"}. tinybench, ${speed.options.time_ms} ms per task after ${speed.options.warmup_ms} ms warm-up.` +
    (speed.options.quick ? " **Quick run: a harness check, not a measurement.**" : ""))
  line(`MB/s is against each format's own bytes. "vs JSON" is the time relative to the JSON task of the same group and input. JSON.parse → JSON.stringify changed the text of ${speed.jsonNotStable} documents (numbers a JS number can't hold exactly).`)
  line()
  const baseline = (r: SpeedOut["rows"][number]) => speed.rows.find((x) => x.input === r.input && (x.group === r.group || (r.group === "typed" && x.group === "parse")) && x.impl.startsWith("JSON"))
  table(
    ["Task", "Input", "Implementation", "MB/s", "µs / doc", "ops/s", "mean ms", "p75 ms", "p99 ms", "vs JSON"],
    speed.rows.map((r) => {
      const b = baseline(r)
      return [r.group, r.input, r.impl, r.mb_s.toFixed(1), r.us_per_doc.toFixed(2), r.hz.toFixed(1), r.mean_ms.toFixed(3), r.p75_ms.toFixed(3), r.p99_ms.toFixed(3), b ? `${(r.mean_ms / b.mean_ms).toFixed(1)}×` : ""]
    }),
  )
}

const text = md.join("\n")
console.log(text)
writeFileSync(RESULTS_MD, text + "\n")

// ── results.haus ─────────────────────────────────────────────

/** Plain data as a haus value: objects → records, null → None, booleans → True/False. */
const toValue = (x: unknown): Value => {
  if (x === null || x === undefined) return variant("None")
  if (typeof x === "boolean") return variant(x ? "True" : "False")
  if (typeof x === "number") return num(normalizeNumber(Number.isInteger(x) ? String(x) : String(Number(x.toPrecision(6)))) ?? "0")
  if (typeof x === "string") return str(x)
  if (Array.isArray(x)) return arr(x.map(toValue))
  return rec(new Map(Object.entries(x as object).filter(([, v]) => v !== undefined).map(([k, v]) => [k, toValue(v)])))
}
const results = {
  source: corpus.source,
  documents: { examples: corpus.examples, found: corpus.found, sample: corpus.sample ?? null, measured: docs.length, excluded: corpus.excluded.length, reasons: Object.fromEntries(reasons) },
  schema: { positions: corpus.positions, decisions: corpus.decisions, unlistedMembers: corpus.unlistedMembers },
  bytes: Object.fromEntries(PAIRS.map(([a, b]) => [`${a}/${b}`, { ...ratio(bytesOf(a), bytesOf(b)), haus: sum(bytesOf(a)), json: sum(bytesOf(b)) }])),
  tokens: tokens ? { tokenizers: tokens.tokenizers.map(({ seconds: _, ...t }) => t), ratios: tokenRatios } : null,
  speed: speed ? { machine: speed.machine, options: speed.options, jsonNotStable: speed.jsonNotStable, rows: speed.rows } : null,
}
writeFileSync(RESULTS_OUT, `// haus vs JSON benchmark results, written by bench/report.ts\n${format([toValue(results)])}`)
console.log(`\nwrote ${RESULTS_MD} and ${RESULTS_OUT}`)
