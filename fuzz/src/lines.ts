/**
 * Runners that read a FILE of lines, one case each, and print one line per
 * case: the shape of the build, import and string-API fuzzers (build.ts,
 * imports.ts, strings.ts). A runner that crashes or hangs on a batch is run
 * on its halves until the cases that crash it are found; such a case's line
 * is `crash …`.
 */
import { writeFileSync } from "node:fs"
import { runProgram, timeoutFor } from "./spawn.ts"

export interface LineRunner {
  readonly name: string
  /** One output line per input line. */
  run(file: string, lines: readonly string[]): string[]
}

/** `program [...args] FILE`, FILE being `file.NAME` with the lines. */
export function external(name: string, program: string, args: readonly string[]): LineRunner {
  const run = (file: string, lines: readonly string[]): string[] => {
    if (lines.length === 0) return []
    const part = `${file}.${name}`
    writeFileSync(part, lines.map((l) => l + "\n").join(""))
    const p = runProgram(name, program, [...args, part], timeoutFor(lines.length))
    const out = (p.stdout ?? "").split("\n").filter((l) => l !== "")
    if (p.status === 0 && out.length === lines.length) return out
    if (lines.length === 1) {
      const why = p.error ? String(p.error) : p.signal ? `signal ${p.signal}` : `exit ${p.status}, ${out.length} lines`
      return [`crash (${why}): ${(p.stderr ?? "").trim().split("\n").slice(0, 3).join(" ").slice(0, 300)}`]
    }
    const mid = lines.length >> 1
    return [...run(file, lines.slice(0, mid)), ...run(file, lines.slice(mid))]
  }
  return { name, run }
}

/** A runner in this process: `one` for each line; an exception it throws is a crash. */
export function inProcess(name: string, one: (line: string) => string): LineRunner {
  return {
    name,
    run: (_file, lines) =>
      lines.map((l) => {
        try {
          return one(l).replace(/[\r\n]/g, " ")
        } catch (e) {
          return `crash ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300)
        }
      }),
  }
}

/** Text as hex of its generalized UTF-8 (WTF-8): a lone surrogate is the three bytes UTF-8 would give it. */
export function wtf8Hex(s: string): string {
  const out: number[] = []
  for (const ch of s) {
    const c = ch.codePointAt(0)!
    if (c < 0x80) out.push(c)
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  return Buffer.from(out).toString("hex")
}

/** The text of generalized UTF-8 in hex (wtf8Hex's inverse; well-formed input assumed). */
export function fromWtf8Hex(hex: string): string {
  const b = Buffer.from(hex, "hex")
  let s = ""
  for (let i = 0; i < b.length; ) {
    const x = b[i]!
    let c: number
    if (x < 0x80) (c = x), (i += 1)
    else if (x < 0xe0) (c = ((x & 31) << 6) | (b[i + 1]! & 63)), (i += 2)
    else if (x < 0xf0) (c = ((x & 15) << 12) | ((b[i + 1]! & 63) << 6) | (b[i + 2]! & 63)), (i += 3)
    else (c = ((x & 7) << 18) | ((b[i + 1]! & 63) << 12) | ((b[i + 2]! & 63) << 6) | (b[i + 3]! & 63)), (i += 4)
    s += String.fromCodePoint(c)
  }
  return s
}

/** Text as hex of its UTF-16 code units, big-endian: what a host string holds, lone surrogates included. */
export function utf16Hex(s: string): string {
  let out = ""
  for (let i = 0; i < s.length; i++) out += s.charCodeAt(i).toString(16).padStart(4, "0")
  return out
}

export function fromUtf16Hex(hex: string): string {
  let s = ""
  for (let i = 0; i < hex.length; i += 4) s += String.fromCharCode(parseInt(hex.slice(i, i + 4), 16))
  return s
}
