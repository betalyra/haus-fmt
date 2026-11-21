package org.hausfmt.bench.speed;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;
import org.openjdk.jmh.profile.GCProfiler;
import org.openjdk.jmh.results.BenchmarkResult;
import org.openjdk.jmh.results.IterationResult;
import org.openjdk.jmh.results.Result;
import org.openjdk.jmh.results.RunResult;
import org.openjdk.jmh.runner.Runner;
import org.openjdk.jmh.runner.RunnerException;
import org.openjdk.jmh.runner.options.ChainedOptionsBuilder;
import org.openjdk.jmh.runner.options.OptionsBuilder;
import org.openjdk.jmh.runner.options.TimeValue;
import org.openjdk.jmh.util.Version;

/**
 * Times the haus JVM binding against Jackson on the exported corpus and writes
 * bench/.out/&lt;source&gt;/speed-jvm.json for the report ({@code pnpm --filter haus-bench speed-jvm},
 * or {@code ../../../jvm/gradlew run} in bench/speed/jvm). Options come from the environment (see
 * {@link Settings}).
 *
 * <p>For each source the corpus is checked first ({@link Inputs#check}) and each task runs once
 * untimed (its output's size goes into the checksum). Then JMH runs the tasks in rounds: each round
 * runs every task in order, each in a fork of its own, so a haus task and its JSON baseline
 * alternate and a disturbance of the machine falls on both. Every measured iteration is one sample.
 * The terminal shows, for each haus task, its time against its baseline round by round: the median
 * of the rounds' ratios and their range.
 */
public final class Speed {
  private Speed() {}

  public static void main(String[] args) throws Exception {
    Settings settings = Settings.fromEnv();
    Machine machine = Machine.detect();
    for (String source : settings.sources()) {
      bench(settings, machine, source);
    }
  }

  /** A task's samples over all rounds: each iteration's time, each round's score and allocation. */
  private record Samples(List<Double> iterations, List<Double> rounds, List<Double> allocBytes) {
    Samples() {
      this(new ArrayList<>(), new ArrayList<>(), new ArrayList<>());
    }
  }

  private static void bench(Settings settings, Machine machine, String source) throws Exception {
    Inputs in = Inputs.prepare(Corpus.load(settings.out(), source));
    int jsonNotStable = in.check();
    List<Task> tasks = in.tasks().stream()
        .filter(t -> settings.tasks().isEmpty() || settings.tasks().contains(t.id()))
        .toList();
    if (tasks.isEmpty()) {
      throw new IllegalArgumentException("no task of " + settings.tasks() + " in " + source);
    }
    long checksum = 0;
    for (Task t : tasks) {
      checksum += t.body().run(x -> {});
    }

    Map<String, Samples> samples = new LinkedHashMap<>();
    tasks.forEach(t -> samples.put(t.id(), new Samples()));
    Settings.Options o = settings.options();
    for (int round = 1; round <= o.rounds(); round++) {
      System.out.printf("%n%s: round %d of %d%n", source, round, o.rounds());
      for (RunResult r : run(settings, source, tasks)) {
        Samples s = samples.get(r.getParams().getParam("task"));
        for (BenchmarkResult b : r.getBenchmarkResults()) {
          for (IterationResult i : b.getIterationResults()) {
            s.iterations().add(i.getPrimaryResult().getScore());
          }
        }
        s.rounds().add(r.getPrimaryResult().getScore());
        Result<?> alloc = r.getSecondaryResults().get("gc.alloc.rate.norm");
        if (alloc != null) {
          s.allocBytes().add(alloc.getScore());
        }
      }
    }

    int docs = in.corpus.documents().size();
    List<Results.Row> rows = tasks.stream().map(t -> {
      Samples s = samples.get(t.id());
      Double alloc = s.allocBytes().isEmpty() ? null : s.allocBytes().stream().mapToDouble(Double::doubleValue).average().orElseThrow();
      return Results.Row.of(t, docs, s.iterations(), alloc);
    }).toList();

    System.out.printf("%n%s: %s, %s%s%n", source, machine.cpu(), machine.runtime(), o.quick() ? " (quick)" : "");
    for (int i = 0; i < tasks.size(); i++) {
      System.out.println(rows.get(i).line() + versus(tasks, samples, tasks.get(i)));
    }
    System.out.printf("Jackson wrote %d documents back as another document%n", jsonNotStable);
    if (!settings.writesResults()) {
      System.out.println("only some tasks, a profiler or other JVM options: no results file written");
      return;
    }
    Results results = new Results("jvm", harness(o), machine,
        new Results.OptionsOut(o.timeMs(), o.totalWarmupMs(), o.quick()),
        in.corpus.documents().stream().map(Corpus.Document::id).toList(),
        jsonNotStable, rows, checksum);
    System.out.printf("wrote %s%n%n", results.write(settings.out(), source));
  }

  /** The harness, as recorded in the results. */
  private static String harness(Settings.Options o) {
    return "JMH " + Version.getPlainVersion() + " (average time; " + o.rounds() + (o.rounds() == 1 ? " round" : " rounds")
        + ", a fork per task and round)";
  }

  /** One round: every task, in order, each in a fork of its own. */
  private static Collection<RunResult> run(Settings settings, String source, List<Task> tasks) throws RunnerException {
    Settings.Options o = settings.options();
    ChainedOptionsBuilder options = new OptionsBuilder()
        .include(SpeedBenchmark.class.getName() + ".run")
        .param("source", source)
        .param("task", tasks.stream().map(Task::id).toArray(String[]::new))
        .forks(1)
        .warmupIterations(o.warmupIterations())
        .warmupTime(TimeValue.milliseconds(o.warmupMs()))
        .measurementIterations(o.iterations())
        .measurementTime(TimeValue.milliseconds(o.iterationMs()))
        .timeUnit(TimeUnit.MILLISECONDS)
        .shouldDoGC(true)
        .shouldFailOnError(true)
        .addProfiler(GCProfiler.class)
        // A fixed heap, the same for every task.
        .jvmArgsAppend(Stream.concat(
            Stream.of("-D" + SpeedBenchmark.OUT + "=" + settings.out().toAbsolutePath(), "-Xms2g", "-Xmx2g"),
            settings.jvmArgs().stream()).toArray(String[]::new));
    // A profiler with options as on JMH's command line: stack:lines=3;top=20.
    for (String p : settings.profilers()) {
      int colon = p.indexOf(':');
      if (colon < 0) {
        options.addProfiler(p);
      } else {
        options.addProfiler(p.substring(0, colon), p.substring(colon + 1));
      }
    }
    return new Runner(options.build()).run();
  }

  /**
   * How much faster or slower a haus task is than its JSON baseline (the first JSON task of the
   * same group and input), from the rounds' ratios: their median, and their range.
   */
  private static String versus(List<Task> tasks, Map<String, Samples> samples, Task t) {
    if (!t.format().equals("haus")) {
      return "";
    }
    Task base = tasks.stream()
        .filter(x -> x.format().equals("json") && x.group().equals(t.group()) && x.input().equals(t.input()))
        .findFirst().orElse(null);
    if (base == null) {
      return "";
    }
    List<Double> haus = samples.get(t.id()).rounds();
    List<Double> json = samples.get(base.id()).rounds();
    double[] ratios = new double[haus.size()];
    for (int i = 0; i < ratios.length; i++) {
      ratios[i] = haus.get(i) / json.get(i);
    }
    Arrays.sort(ratios);
    return String.format("  %s (rounds %s to %s)", ratio(Results.quantile(ratios, 0.5)), ratio(ratios[0]), ratio(ratios[ratios.length - 1]));
  }

  /** A time ratio from haus's side, as the report says it: "2.8× slower", "1.4× faster", "≈ equal" within 5%. */
  static String ratio(double t) {
    double factor = Math.max(t, 1 / t);
    if (factor < 1.05) {
      return "≈ equal";
    }
    return String.format(factor < 2 ? "%.2f× %s" : "%.1f× %s", factor, t > 1 ? "slower" : "faster");
  }
}
