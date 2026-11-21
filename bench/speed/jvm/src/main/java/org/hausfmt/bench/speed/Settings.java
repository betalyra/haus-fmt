package org.hausfmt.bench.speed;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

/**
 * What to run, from the environment (like the Go and Rust benchmarks):
 *
 * <pre>
 * HAUS_BENCH_SOURCES=vega-lite,geojson   only these sources (default: every source in sources.haus)
 * HAUS_BENCH_QUICK=1                     a short budget: checks the harness, not for publishing
 * HAUS_BENCH_OUT=/elsewhere              the results directory convert wrote to (default bench/.out)
 * HAUS_BENCH_ROUNDS=3                    rounds instead of the default 1 (each round a fork per task)
 * HAUS_BENCH_TASKS=parse-doc-json,parse-doc-haus   only these tasks (no results file is written)
 * HAUS_BENCH_PROFILERS=stack:lines=3     JMH profilers to add, comma-separated, each with its options as on
 *                                        JMH's command line (no results file is written)
 * HAUS_BENCH_JVM_ARGS=-XX:StartFlightRecording=filename=x.jfr   more options for the forks, space-separated
 *                                        (no results file is written)
 * </pre>
 *
 * @param tasks the tasks to run, or empty for all
 * @param profilers JMH profilers beside the gc profiler, which always runs
 * @param jvmArgs more options for the forks
 */
record Settings(Path bench, Path out, List<String> sources, Options options, List<String> tasks, List<String> profilers,
    List<String> jvmArgs) {

  /**
   * The timing options. Every task runs in {@code rounds} forks, one per round, each round running
   * every task in order (so a haus task and its JSON baseline alternate); each fork warms up for
   * {@code warmupIterations} iterations of {@code warmupMs}, then measures {@code iterations} of
   * {@code iterationMs}, each one sample.
   */
  record Options(int rounds, int warmupIterations, int warmupMs, int iterations, int iterationMs, boolean quick) {
    /** The measured time per task, over all rounds. */
    long timeMs() {
      return (long) rounds * iterations * iterationMs;
    }

    /** The warm-up per task, over all rounds. */
    long totalWarmupMs() {
      return (long) rounds * warmupIterations * warmupMs;
    }
  }

  /** Whether the run is a measurement whose results are written: every task, no profiler but gc, no other options. */
  boolean writesResults() {
    return tasks.isEmpty() && profilers.isEmpty() && jvmArgs.isEmpty();
  }

  /** Reads the settings, finding bench/ from the working directory. */
  static Settings fromEnv() throws IOException {
    Path bench = Corpus.benchDir(Path.of(""));
    List<String> all = Corpus.sources(bench.resolve("sources.haus"));
    String outEnv = System.getenv("HAUS_BENCH_OUT");
    Path out = outEnv == null || outEnv.isEmpty() ? bench.resolve(".out") : Path.of(outEnv);
    List<String> sources = list("HAUS_BENCH_SOURCES");
    for (String name : sources) {
      if (!all.contains(name)) {
        throw new IllegalArgumentException("no corpus source " + name + " in sources.haus");
      }
    }
    String quick = System.getenv("HAUS_BENCH_QUICK");
    Options options = quick != null && !quick.isEmpty() && !quick.equals("0")
        ? new Options(1, 2, 100, 3, 100, true)
        : new Options(1, 4, 500, 6, 500, false);
    String rounds = System.getenv("HAUS_BENCH_ROUNDS");
    if (rounds != null && !rounds.isEmpty()) {
      options = new Options(Integer.parseInt(rounds), options.warmupIterations(), options.warmupMs(),
          options.iterations(), options.iterationMs(), options.quick());
    }
    String jvmArgs = System.getenv("HAUS_BENCH_JVM_ARGS");
    return new Settings(bench, out, sources.isEmpty() ? all : sources, options, list("HAUS_BENCH_TASKS"), list("HAUS_BENCH_PROFILERS"),
        jvmArgs == null || jvmArgs.isBlank() ? List.of() : List.of(jvmArgs.trim().split("\\s+")));
  }

  /** A comma-separated list in the environment, empty when unset. */
  private static List<String> list(String name) {
    String value = System.getenv(name);
    return value == null || value.isEmpty() ? List.of() : Arrays.stream(value.split(",")).map(String::trim).toList();
  }
}
