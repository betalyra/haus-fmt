package org.hausfmt.bench.speed;

import static java.nio.charset.StandardCharsets.UTF_8;

import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * The machine the benchmark runs on, in the words the TypeScript step uses (Node's os): Apple M1
 * Max, 10 cores, darwin 25.5.0 arm64.
 *
 * @param runtime the JVM the forks run on: {@code java 25.0.1+8-LTS (OpenJDK 64-Bit Server VM, Eclipse Adoptium)}
 * @param gc true: JMH collects garbage between iterations (shouldDoGC)
 */
record Machine(String cpu, int cores, long memoryGb, String os, String runtime, boolean gc) {

  /** Describes this machine. */
  static Machine detect() {
    boolean darwin = System.getProperty("os.name").toLowerCase().startsWith("mac");
    String cpu = darwin ? sysctl("machdep.cpu.brand_string") : procField("/proc/cpuinfo", "model name");
    String release = darwin ? sysctl("kern.osrelease") : read("/proc/sys/kernel/osrelease");
    String os = darwin ? "darwin" : System.getProperty("os.name").toLowerCase();
    // Node's names for the architecture, so every language's results read the same.
    String arch = Map.of("aarch64", "arm64", "amd64", "x64", "x86_64", "x64", "x86", "ia32")
        .getOrDefault(System.getProperty("os.arch"), System.getProperty("os.arch"));
    long memory = ((com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean()).getTotalMemorySize();
    return new Machine(
        cpu.isEmpty() ? "unknown" : cpu,
        Runtime.getRuntime().availableProcessors(),
        Math.round(memory / (double) (1L << 30)),
        String.join(" ", release.isEmpty() ? List.of(os, arch) : List.of(os, release, arch)),
        "java " + Runtime.version() + " (" + System.getProperty("java.vm.name") + ", " + System.getProperty("java.vm.vendor") + ")",
        true);
  }

  /** A sysctl value, as Node's os reads it on macOS; empty when it can't be read (in a sandbox, say). */
  private static String sysctl(String name) {
    try {
      Process p = new ProcessBuilder("sysctl", "-n", name).redirectErrorStream(true).start();
      String out = new String(p.getInputStream().readAllBytes(), UTF_8).trim();
      return p.waitFor() == 0 ? out : "";
    } catch (IOException e) {
      return "";
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return "";
    }
  }

  /** The value of a line {@code key : value} of a /proc file (Linux; empty elsewhere). */
  private static String procField(String file, String key) {
    for (String line : read(file).split("\n")) {
      int colon = line.indexOf(':');
      if (colon >= 0 && line.substring(0, colon).trim().equals(key)) {
        return line.substring(colon + 1).trim();
      }
    }
    return "";
  }

  private static String read(String file) {
    try {
      return Files.readString(Path.of(file)).trim();
    } catch (IOException e) {
      return "";
    }
  }
}
