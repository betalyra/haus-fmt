/**
 * Running a fuzz runner that is a separate program, with a timeout that
 * can't be ignored and a budget for hangs.
 *
 * A hang on one input is a finding: the fuzzers split a batch that hangs to
 * find the input. But a runner that is stuck as a whole hangs on every
 * part, and splitting then costs one timeout per part: hours, with nothing
 * in the log. So the time a runner spends in timeouts is counted, and past
 * the budget the fuzzer stops with an error that names the runner.
 *
 * The same holds for a runner that fails fast (it can't start, a missing
 * library, a bad flag): every case then "crashes", the fuzzers run cases one
 * by one or split batches down to single cases, and the run takes hours
 * without a timeout. So failed runs are counted too, the first one is
 * printed at once, and past a budget the fuzzer stops.
 */
import { spawnSync, type SpawnSyncReturns } from "node:child_process"

/** The most time one runner may spend in timeouts in one fuzzer run. */
const HANG_BUDGET = 10 * 60_000

/**
 * The most failed runs (exit not 0, a signal, not started) of one runner in
 * one fuzzer run. Finding one input that crashes a runner takes about
 * 2·log2(batch) failed runs (the batch is split in halves), so this is
 * several such inputs.
 */
const FAILURE_BUDGET = 200

const spentInHangs = new Map<string, number>()
const failedRuns = new Map<string, number>()

/** Why a run failed, in one line. */
const failure = (p: SpawnSyncReturns<string>): string => {
  const why = p.error ? String(p.error) : p.signal ? `signal ${p.signal}` : `exit ${p.status}`
  const err = (p.stderr ?? "").trim().split("\n").slice(0, 3).join(" | ").slice(0, 300)
  return err ? `${why}: ${err}` : why
}

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
  } else if (p.status !== 0) {
    const n = (failedRuns.get(name) ?? 0) + 1
    failedRuns.set(name, n)
    if (n === 1 || n % 50 === 0) console.error(`${name}: run failed (${n} so far): ${failure(p)}`)
    if (n > FAILURE_BUDGET)
      throw new Error(
        `${name}: more than ${FAILURE_BUDGET} failed runs; stopping. Last: ${failure(p)}. ` +
          "A runner that fails on every part is usually broken as a whole (it can't start, its environment), not on one input.",
      )
  }
  return Object.assign(p, { hung })
}
