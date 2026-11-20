/**
 * Where the benchmark reads and writes. `data` (downloads) and `out`
 * (results) default to bench/.data/ and bench/.out/ (both git-ignored), and
 * can be moved with `--data-dir` / `--out-dir` or HAUS_BENCH_DATA /
 * HAUS_BENCH_OUT, e.g. to fetch from scratch into an empty directory.
 */
import { Context, Effect, Layer, Option, Path } from "effect"

export interface Dirs {
  readonly data: Option.Option<string>
  readonly out: Option.Option<string>
}

export interface BenchPathsShape {
  /** bench/ */
  readonly root: string
  /** bench/sources.haus */
  readonly manifest: string
  readonly data: string
  readonly out: string
  /** Where fetch puts a corpus source's file (the last segment of its path). */
  readonly corpusFile: (name: string, path: string) => string
  /** Where fetch puts a corpus source's directory of documents (its last segment). */
  readonly corpusDir: (name: string, dir: string) => string
  /** The bare git repository fetch uses for a corpus source. */
  readonly gitDir: (name: string) => string
  /** A file of an npm package bench/ depends on (bench/node_modules/<package>/<file>). */
  readonly packageFile: (pkg: string, file: string) => string
  /** Where fetch puts a tokenizer's file. */
  readonly tokenizerFile: (name: string, file: string) => string
  /** A file in the results directory: `outFile("results.md")`, or a source's, `outFile("vega-lite", "corpus.json")`. */
  readonly outFile: (...segments: readonly string[]) => string
}

export class BenchPaths extends Context.Service<BenchPaths, BenchPathsShape>()("haus-bench/BenchPaths") {
  static readonly layer = (dirs: Dirs): Layer.Layer<BenchPaths, never, Path.Path> =>
    Layer.effect(
      BenchPaths,
      Effect.gen(function* () {
        const path = yield* Path.Path
        const root = yield* path.fromFileUrl(new URL("../", import.meta.url)).pipe(Effect.orDie)
        const data = path.resolve(Option.getOrElse(dirs.data, () => path.join(root, ".data")))
        const out = path.resolve(Option.getOrElse(dirs.out, () => path.join(root, ".out")))
        return BenchPaths.of({
          root,
          manifest: path.join(root, "sources.haus"),
          data,
          out,
          corpusFile: (name, file) => path.join(data, "corpus", name, path.basename(file)),
          corpusDir: (name, dir) => path.join(data, "corpus", name, dir === "." || dir === "" ? "repo" : path.basename(dir)),
          gitDir: (name) => path.join(data, "git", `${name}.git`),
          packageFile: (pkg, file) => path.join(root, "node_modules", pkg, file),
          tokenizerFile: (name, file) => path.join(data, "tokenizers", name, file),
          outFile: (...segments) => path.join(out, ...segments),
        })
      }),
    )
}
