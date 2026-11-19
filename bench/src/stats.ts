/** Statistics and markdown, pure. */

/** UTF-8 bytes of a string (a lone surrogate counts as U+FFFD, 3 bytes, as an encoder writes it). */
export const utf8Length = (s: string): number => {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
      n += 4
      i++
    } else n += 3
  }
  return n
}

export const sum = (xs: readonly number[]): number => xs.reduce((a, b) => a + b, 0)
export const mean = (xs: readonly number[]): number => sum(xs) / xs.length
export const geomean = (xs: readonly number[]): number => Math.exp(sum(xs.map(Math.log)) / xs.length)
export const median = (xs: readonly number[]): number => {
  const s = [...xs].sort((a, b) => a - b)
  const m = s.length >> 1
  return s.length === 0 ? NaN : s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2
}

/** Counts by value, in order of first appearance. */
export const countBy = (xs: readonly string[]): [string, number][] => [...xs.reduce((m, x) => m.set(x, (m.get(x) ?? 0) + 1), new Map<string, number>())]

/** Counts by value, most common first. */
export const tally = (xs: readonly string[]): [string, number][] => countBy(xs).sort((a, b) => b[1] - a[1])

export interface Ratio {
  readonly total: number
  readonly median: number
  readonly geomean: number
  /** Share of documents where haus is larger. */
  readonly larger: number
}

/** haus against JSON, per document and in total. */
export const ratio = (haus: readonly number[], json: readonly number[]): Ratio => {
  const r = haus.map((x, i) => x / json[i]!)
  return { total: sum(haus) / sum(json), median: median(r), geomean: geomean(r), larger: r.filter((x) => x > 1).length / r.length }
}

/** `+1.5%`, `−3.0%` */
export const pct = (r: number): string => `${r >= 1 ? "+" : "−"}${(Math.abs(r - 1) * 100).toFixed(1)}%`
export const fixed3 = (r: number): string => r.toFixed(3)

/** A markdown table, numbers right-aligned, text left; ends with a blank line. */
export const table = (head: readonly string[], rows: readonly (readonly string[])[]): string[] => {
  const numeric = head.map((_, i) => i > 0 && rows.every((r) => r[i] === "" || /^\**[\d.]/.test(r[i]!)))
  return [
    `| ${head.join(" | ")} |`,
    `|${numeric.map((n) => (n ? "---:" : "---")).join("|")}|`,
    ...rows.map((r) => `| ${r.join(" | ")} |`),
    "",
  ]
}
