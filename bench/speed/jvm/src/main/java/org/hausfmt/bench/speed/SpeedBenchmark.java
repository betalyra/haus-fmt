package org.hausfmt.bench.speed;

import java.io.IOException;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import org.openjdk.jmh.annotations.Benchmark;
import org.openjdk.jmh.annotations.BenchmarkMode;
import org.openjdk.jmh.annotations.Level;
import org.openjdk.jmh.annotations.Mode;
import org.openjdk.jmh.annotations.OutputTimeUnit;
import org.openjdk.jmh.annotations.Param;
import org.openjdk.jmh.annotations.Scope;
import org.openjdk.jmh.annotations.Setup;
import org.openjdk.jmh.annotations.State;
import org.openjdk.jmh.infra.Blackhole;

/**
 * The JMH benchmark: one task of one source per trial. {@link Speed} sets {@code source} and
 * {@code task} and runs each in a fork of its own; the fork reads the corpus from the results
 * directory in the system property {@value #OUT}.
 */
@State(Scope.Benchmark)
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
public class SpeedBenchmark {
  /** The system property with the results directory convert wrote to. */
  static final String OUT = "haus.bench.out";

  @Param("")
  public String source;

  @Param("")
  public String task;

  private Task.Body body;

  @Setup(Level.Trial)
  public void setup() throws IOException {
    Inputs in = Inputs.prepare(Corpus.load(Path.of(System.getProperty(OUT)), source));
    body = in.tasks().stream()
        .filter(t -> t.id().equals(task))
        .findFirst()
        .orElseThrow(() -> new IllegalArgumentException("no task " + task))
        .body();
  }

  @Benchmark
  public long run(Blackhole bh) throws Exception {
    return body.run(bh::consume);
  }
}
