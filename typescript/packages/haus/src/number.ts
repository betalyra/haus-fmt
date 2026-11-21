/**
 * Number literals as values (spec §2, §3): the normalized text the parser
 * gives every number, and the checks a number built in code passes before it
 * is written (spec §9.8: the same limits as when parsing).
 */
import { HausSyntaxError, START, type Problem } from "./errors.js"
import { DEFAULT_LIMITS, Parser, type Limits } from "./parser.js"

/** A normalized literal that is a whole number: digits with an optional `-` (`-0` included). */
export const INTEGER = /^-?\d+$/

/**
 * A normalized literal, exactly as the parser writes one: no `_`, `+`, `E`,
 * hex or binary, and no leading zeros in the exponent. `1e5`, `-0`, `19.90`.
 */
const NORMALIZED = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:e(?:0|-?[1-9]\d*))?$/

/** Whether `text` is a normalized literal, exactly as the parser writes one (spec §2). */
export const isNormalizedNumber = (text: string): boolean => NORMALIZED.test(text)

/**
 * The normalized text of a number literal (`1_000` → "1000", `0xFF` → "255",
 * `1E+05` → "1e5"), or undefined when `text` is not exactly one number
 * literal within `limits`.
 */
export const normalizeNumber = (text: string, limits: Limits = DEFAULT_LIMITS): string | undefined => {
  if (NORMALIZED.test(text)) return text
  try {
    return new Parser(text, START, limits).parseNumberLiteral()
  } catch (e) {
    if (e instanceof HausSyntaxError) return undefined
    throw e
  }
}

/** No limits: the canonical form has none (spec §12). */
const UNLIMITED: Limits = { ...DEFAULT_LIMITS, maxNumberLength: Infinity, maxExponent: Infinity }

/**
 * The canonical form of a number built in code (spec §12): its normalized
 * literal, whatever its length or exponent, or undefined when `text` is not
 * exactly one number literal (`"01"`, `"NaN"`, `""`).
 */
export const canonicalNumber = (text: string): string | undefined => normalizeNumber(text, UNLIMITED)

/**
 * Why the normalized number `text` is outside `limits` (spec §9.8), or
 * undefined: a literal longer than `maxNumberLength` (always decimal, so an
 * integer within the limit has at most that many characters, sign included),
 * or an exponent larger than `maxExponent`. A number the parser produced
 * within `limits` is always within them.
 */
export const numberLimitIssue = (text: string, limits: Limits): Problem | undefined => {
  // The length first, as a parser meets it (spec §7): a literal too long with an exponent too large is too long.
  if (text.length > limits.maxNumberLength) return { code: "number-too-long", reason: `number literal longer than ${limits.maxNumberLength} characters` }
  const exponent = /e-?(\d+)$/.exec(text)?.[1]
  if (exponent !== undefined && (exponent.length > 15 || Number(exponent) > limits.maxExponent)) return { code: "exponent-too-large", reason: `exponent larger than ${limits.maxExponent}` }
  return undefined
}
