/**
 * Running a fuzz runner that is a separate program, with a timeout that
 * can't be ignored and a budget for hangs.
 *
 * A hang on one input is a finding: the fuzzers split a batch that hangs to
 * find the input. But a runner that is stuck as a whole hangs on every
 * part, and splitting then costs one timeout per part: hours, with nothing
 * in the log. So the time a runner spends in timeouts is counted, and past
 * the budget the fuzzer stops with an error that names the runner.
 */
import { spawnSync, type SpawnSyncReturns } from "node:child_process"

/** The most time one runner may spend in timeouts in one fuzzer run. */
const HANG_BUDGET = 10 * 60_000

const spentInHangs = new Map<string, number>()

/** A timeout for `cases` cases: 20 s and 100 ms per case, at most `max`. */
export const timeoutFor = (cases: number, max = 600_000): number => Math.min(max, 20_000 + cases * 100)

/**
 * `spawnSync(program, args)` with a timeout after which the program is
 * killed with SIGKILL (SIGTERM can be caught, and a stuck program would
 * then keep the fuzzer waiting). `hung` says whether it timed out.
 */
export function runProgram(
  name: string,
  program: string,
  args: readonly string[],
  timeout: number,
  options: { readonly maxBuffer?: number } = {},
): SpawnSyncReturns<string> & { readonly hung: boolean } {
  const p = spawnSync(program, args, { encoding: "utf8", maxBuffer: options.maxBuffer ?? 1 << 30, timeout, killSignal: "SIGKILL" })
  const hung = (p.error as NodeJS.ErrnoException | undefined)?.code === "ETIMEDOUT"
  if (hung) {
    const spent = (spentInHangs.get(name) ?? 0) + timeout
    spentInHangs.set(name, spent)
    console.error(`${name}: no answer within ${timeout / 1000} s (${Math.round(spent / 1000)} s in timeouts so far)`)
    if (spent > HANG_BUDGET)
      throw new Error(
        `${name}: more than ${HANG_BUDGET / 60_000} min in timeouts; stopping. ` +
          "A runner that hangs on every part is usually stuck as a whole (its start, its environment), not on one input.",
      )
  }
  return Object.assign(p, { hung })
}
