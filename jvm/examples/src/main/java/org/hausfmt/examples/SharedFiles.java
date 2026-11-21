package org.hausfmt.examples;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/** The shared example files of the repository, in examples/, found from the working directory up. */
public final class SharedFiles {
  private SharedFiles() {}

  /** The bytes of examples/{@code name}. */
  public static byte[] read(String name) {
    try {
      return Files.readAllBytes(dir().resolve(name));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /** The path of examples/{@code name}. */
  public static Path path(String name) {
    return dir().resolve(name);
  }

  /** The repository's directory, which holds examples/ and extensions/. */
  public static Path root() {
    return dir().getParent();
  }

  private static Path dir() {
    for (Path p = Paths.get("").toAbsolutePath(); p != null; p = p.getParent()) {
      if (Files.exists(p.resolve("examples/thread.haus"))) {
        return p.resolve("examples");
      }
    }
    throw new IllegalStateException("examples/ not found above " + Paths.get("").toAbsolutePath());
  }
}
