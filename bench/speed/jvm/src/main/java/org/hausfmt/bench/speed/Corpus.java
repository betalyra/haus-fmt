package org.hausfmt.bench.speed;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.hausfmt.Haus;
import org.hausfmt.Value;

/**
 * One source's export, as {@code bench convert} writes it:
 *
 * <pre>
 * &lt;out&gt;/&lt;source&gt;/corpus/
 *   index.haus             { source, schema, documents: [{ id, root, file }] }
 *   &lt;source&gt;.schema.haus   the schema; root is a type of it
 *   NNNN.haus              document NNNN, minimised haus
 *   NNNN.pretty.haus       the same, pretty
 *   NNNN.json              the same document, minified JSON
 *   all.haus               every document as one haus stream, minimised
 *   all.json               every document as one JSON array, minified
 * </pre>
 *
 * @param allHaus every document as one haus stream: each item followed by {@code ,} and a line feed
 * @param allJson every document as one JSON array
 */
record Corpus(String source, byte[] schema, List<Document> documents, byte[] allHaus, byte[] allJson) {

  /**
   * One document of a source, in the forms that are read.
   *
   * @param root the document's type in the schema
   * @param haus minimised haus (the wire form); {@code pretty} the same, pretty; {@code json} minified JSON
   */
  record Document(String id, String root, byte[] haus, byte[] pretty, byte[] json) {}

  /** The bench/ directory: the one that holds sources.haus, {@code dir} or one above it. */
  static Path benchDir(Path dir) {
    for (Path d = dir.toAbsolutePath(); d != null; d = d.getParent()) {
      if (Files.exists(d.resolve("sources.haus"))) {
        return d;
      }
    }
    throw new IllegalStateException("no sources.haus in " + dir + " or above it");
  }

  /** The names of the corpus sources in the manifest (bench/sources.haus), in its order. */
  static List<String> sources(Path manifest) throws IOException {
    Value m = readValue(manifest);
    return array(m, "corpus", manifest).items().stream().map(s -> string(s, "name", manifest)).toList();
  }

  /** Reads a source's export from the results directory {@code out}. */
  static Corpus load(Path out, String source) throws IOException {
    Path dir = out.resolve(source).resolve("corpus");
    Path indexPath = dir.resolve("index.haus");
    if (!Files.exists(indexPath)) {
      throw new IllegalStateException("no corpus for " + source + " in " + dir
          + ": run `pnpm --filter haus-bench convert` (from typescript/) first");
    }
    Value index = readValue(indexPath);
    List<Document> docs = new ArrayList<>();
    for (Value d : array(index, "documents", indexPath).items()) {
      String file = string(d, "file", indexPath);
      docs.add(new Document(string(d, "id", indexPath), string(d, "root", indexPath),
          Files.readAllBytes(dir.resolve(file + ".haus")),
          Files.readAllBytes(dir.resolve(file + ".pretty.haus")),
          Files.readAllBytes(dir.resolve(file + ".json"))));
    }
    return new Corpus(string(index, "source", indexPath),
        Files.readAllBytes(dir.resolve(string(index, "schema", indexPath))),
        List.copyOf(docs),
        Files.readAllBytes(dir.resolve("all.haus")),
        Files.readAllBytes(dir.resolve("all.json")));
  }

  /** The one value of a haus file. */
  private static Value readValue(Path path) throws IOException {
    return Haus.parse(Files.readAllBytes(path));
  }

  private static Value field(Value v, String key, Path path) {
    if (!(v instanceof Value.Record r)) {
      throw new IllegalStateException(path + ": not a record");
    }
    Value x = r.get(key);
    if (x == null) {
      throw new IllegalStateException(path + ": no " + key);
    }
    return x;
  }

  private static Value.Array array(Value v, String key, Path path) {
    if (field(v, key, path) instanceof Value.Array a) {
      return a;
    }
    throw new IllegalStateException(path + ": " + key + " is not an array");
  }

  private static String string(Value v, String key, Path path) {
    if (field(v, key, path) instanceof Value.Text t) {
      return t.value();
    }
    throw new IllegalStateException(path + ": " + key + " is not a string");
  }
}
