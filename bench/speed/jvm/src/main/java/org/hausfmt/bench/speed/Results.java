package org.hausfmt.bench.speed;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/**
 * One source's results: bench/.out/&lt;source&gt;/speed-jvm.json, the shape of speed-go.json and the
 * others (SpeedOut in bench/size/src/results.ts). Field names are written in snake case.
 *
 * @param jsonNotStable the documents Jackson writes back as another document through its tree
 *     (numbers in another spelling; member order isn't counted)
 * @param checksum the sum of the sizes of every task's output, once: it changes when an output changes
 */
record Results(
    String lang,
    String harness,
    Machine machine,
    OptionsOut options,
    List<String> documents,
    @JsonProperty("jsonNotStable") int jsonNotStable,
    List<Row> rows,
    long checksum) {

  /** The timing options as recorded: the time per task, over all rounds. */
  record OptionsOut(long timeMs, long warmupMs, boolean quick) {}

  /**
   * One task's results, in the shape every language writes (SpeedRow in bench/size/src/results.ts).
   *
   * @param bytes read (parse, typed) or written (write) per iteration
   * @param allocBytes bytes allocated per iteration (JMH's gc profiler, gc.alloc.rate.norm); the
   *     number of allocations isn't counted
   */
  @JsonInclude(JsonInclude.Include.NON_NULL)
  record Row(String group, String input, String format, String impl, long bytes, int docs, double hz, double meanMs,
      double p75Ms, double p99Ms, int samples, double mbS, double usPerDoc, Double allocs, Double allocBytes) {

    /**
     * Summarizes the samples of a task, each the mean time of one JMH iteration in milliseconds (as
     * criterion's samples are the means of batches). The mean is over the samples, as JMH's score
     * is.
     */
    static Row of(Task t, int docs, List<Double> samples, Double allocBytes) {
      double[] sorted = samples.stream().mapToDouble(Double::doubleValue).sorted().toArray();
      double meanMs = samples.stream().mapToDouble(Double::doubleValue).average().orElseThrow();
      return new Row(t.group(), t.input(), t.format(), t.impl(), t.bytes(), docs,
          1000 / meanMs, meanMs, quantile(sorted, 0.75), quantile(sorted, 0.99), samples.size(),
          t.bytes() / 1e6 / (meanMs / 1000), meanMs * 1000 / docs, null, allocBytes);
    }

    /** The row for the terminal, as the other languages print it. */
    String line() {
      String task = group + " | " + input + " | " + impl;
      return String.format("%-56s %8.1f MB/s %9.2f µs/doc  p99 %.3f ms  %8.1f KB/doc  (%d samples)",
          task, mbS, usPerDoc, p99Ms, allocBytes == null ? 0 : allocBytes / 1024 / docs, samples);
    }
  }

  /** The q quantile of sorted values, interpolated between the nearest ranks. */
  static double quantile(double[] sorted, double q) {
    double pos = q * (sorted.length - 1);
    int lo = (int) pos;
    int hi = Math.min(lo + 1, sorted.length - 1);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  private static final ObjectMapper WRITER = JsonMapper.builder()
      .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
      .enable(SerializationFeature.INDENT_OUTPUT)
      .build();

  /** Writes &lt;out&gt;/&lt;source&gt;/speed-jvm.json and returns its path. */
  Path write(Path out, String source) throws IOException {
    Path path = out.resolve(source).resolve("speed-jvm.json");
    Files.writeString(path, WRITER.writeValueAsString(this) + "\n");
    return path;
  }
}
