package org.hausfmt.bench.speed;

import static java.nio.charset.StandardCharsets.UTF_8;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.cfg.JsonNodeFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausJson;
import org.hausfmt.Schema;
import org.hausfmt.SchemaOptions;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;

/**
 * The inputs of one source, prepared once: each document's type looked up in the source's schema,
 * each haus document parsed and decoded with its type, each JSON document read by Jackson into a
 * {@link JsonNode} tree.
 */
final class Inputs {
  /** Jackson as it comes: the baseline of parse and write. */
  static final ObjectMapper JSON = new ObjectMapper();

  /**
   * Jackson writing every object's members sorted by name (JsonNodeFeature.WRITE_PROPERTIES_SORTED):
   * the nearest JSON counterpart of haus's canonical form. Numbers are written as Jackson holds
   * them, not normalized, and names sort by UTF-16 code units, where haus sorts keys by UTF-8 bytes.
   */
  static final ObjectMapper SORTED = JsonMapper.builder().enable(JsonNodeFeature.WRITE_PROPERTIES_SORTED).build();

  final Corpus corpus;
  /** Each document's type (the document's root in the source's schema). */
  final List<SchemaType> types;
  final List<Value> values;
  /** Each document decoded with its type: what the typed write writes. */
  final List<Value> decoded;
  final List<JsonNode> trees;

  private Inputs(Corpus corpus, List<SchemaType> types, List<Value> values, List<Value> decoded, List<JsonNode> trees) {
    this.corpus = corpus;
    this.types = types;
    this.values = values;
    this.decoded = decoded;
    this.trees = trees;
  }

  /** Reads a source's schema and documents. */
  static Inputs prepare(Corpus c) throws IOException {
    if (c.documents().isEmpty()) {
      throw new IllegalStateException(c.source() + ": no documents: run convert first");
    }
    Schema schema = Schema.parse(c.schema(), SchemaOptions.DEFAULT);
    Map<String, SchemaType> byRoot = new HashMap<>();
    List<SchemaType> types = new ArrayList<>();
    List<Value> values = new ArrayList<>();
    List<Value> decoded = new ArrayList<>();
    List<JsonNode> trees = new ArrayList<>();
    for (Corpus.Document d : c.documents()) {
      SchemaType t = byRoot.computeIfAbsent(d.root(), schema::type);
      Value v = Haus.parse(d.haus());
      types.add(t);
      values.add(v);
      decoded.add(t.decode(v));
      trees.add(JSON.readTree(d.json()));
    }
    return new Inputs(c, List.copyOf(types), List.copyOf(values), List.copyOf(decoded), List.copyOf(trees));
  }

  /**
   * Runs the checks before timing, and returns the number of documents Jackson writes back as
   * another document through its tree (by haus's equality: exact numbers, member order aside).
   */
  int check() throws IOException {
    Corpus c = corpus;
    int jsonNotStable = 0;
    for (int i = 0; i < values.size(); i++) {
      Corpus.Document d = c.documents().get(i);
      Value v = values.get(i);
      // write writes a file: the value and a line feed.
      String written = Haus.write(v, FormatOptions.MINIMISED);
      if (!written.equals(new String(d.haus(), UTF_8) + "\n")) {
        throw failure(d, "haus parse → write (minimised) is not the same text");
      }
      if (!Haus.write(Haus.parse(d.pretty()), FormatOptions.MINIMISED).equals(written)) {
        throw failure(d, "the pretty text reads as another value");
      }
      String canonical = Haus.canonical(v);
      if (!Haus.parse(canonical).equals(v) || !Haus.canonical(Haus.parse(canonical)).equals(canonical)) {
        throw failure(d, "the canonical form doesn't read back as the value and the same form");
      }
      // The typed write reads back as the decoded value, and decodes to it again.
      Value typed = decoded.get(i);
      Value back = Haus.parse(Haus.write(types.get(i).encode(typed), FormatOptions.MINIMISED));
      if (!back.equals(typed) || !types.get(i).decode(back).equals(typed)) {
        throw failure(d, "the typed write doesn't read back as the decoded value");
      }
      JsonNode tree = trees.get(i);
      JsonNode sorted = JSON.readTree(SORTED.writeValueAsString(tree));
      if (!sorted.equals(tree) || !membersSorted(sorted)) {
        throw failure(d, "Jackson's sorted writer doesn't write the same tree with its members sorted");
      }
      if (!HausJson.importJson(JSON.writeValueAsString(tree)).equals(HausJson.importJson(new String(d.json(), UTF_8)))) {
        jsonNotStable++;
      }
    }
    List<Value> stream = Haus.parseAll(c.allHaus());
    if (stream.size() != values.size()) {
      throw new IllegalStateException("all.haus holds " + stream.size() + " values, not " + values.size());
    }
    for (int i = 0; i < stream.size(); i++) {
      if (!stream.get(i).equals(values.get(i))) {
        throw new IllegalStateException("all.haus: value " + i + " is another value than " + c.documents().get(i).id());
      }
    }
    if (values.size() > 1 && !Haus.writeAll(values, FormatOptions.MINIMISED).equals(new String(c.allHaus(), UTF_8))) {
      throw new IllegalStateException("all.haus isn't what writeAll (minimised) writes for the documents");
    }
    JsonNode array = JSON.readTree(c.allJson());
    if (!array.isArray() || array.size() != values.size()) {
      throw new IllegalStateException("all.json holds " + array.size() + " documents, not " + values.size());
    }
    for (int i = 0; i < array.size(); i++) {
      if (!array.get(i).equals(trees.get(i))) {
        throw new IllegalStateException("all.json: document " + i + " is another document than " + c.documents().get(i).id());
      }
    }
    return jsonNotStable;
  }

  private static IllegalStateException failure(Corpus.Document d, String message) {
    return new IllegalStateException(d.id() + ": " + message);
  }

  /** Whether every object in a tree has its members in sorted order. */
  private static boolean membersSorted(JsonNode node) {
    if (node.isObject()) {
      String previous = null;
      for (Iterator<String> names = node.fieldNames(); names.hasNext(); ) {
        String name = names.next();
        if ((previous != null && previous.compareTo(name) > 0) || !membersSorted(node.get(name))) {
          return false;
        }
        previous = name;
      }
    } else if (node.isArray()) {
      for (JsonNode item : node) {
        if (!membersSorted(item)) {
          return false;
        }
      }
    }
    return true;
  }

  /**
   * The tasks, in the order of the other languages' benchmarks, each pair JSON first. Bytes are
   * those of the text read (the documents' files) or written, in UTF-8 (haus's write ends a file
   * with a line feed).
   */
  List<Task> tasks() throws IOException {
    Corpus c = corpus;
    List<Corpus.Document> docs = c.documents();
    ArrayNode corpusTree = JSON.createArrayNode().addAll(trees);
    List<Typed> typed = new ArrayList<>();
    for (int i = 0; i < decoded.size(); i++) {
      typed.add(new Typed(types.get(i), decoded.get(i)));
    }
    return List.of(
        new Task("parse-corpus-json", "parse", "corpus", "json", "ObjectMapper.readTree (JsonNode)", () -> c.allJson().length,
            out -> {
              JsonNode x = JSON.readTree(c.allJson());
              out.accept(x);
              return x.size();
            }),
        new Task("parse-corpus-haus", "parse", "corpus", "haus", "Haus.parseAll", () -> c.allHaus().length,
            out -> {
              List<Value> vs = Haus.parseAll(c.allHaus());
              out.accept(vs);
              return vs.size();
            }),
        new Task("parse-doc-json", "parse", "per doc", "json", "ObjectMapper.readTree (JsonNode)",
            () -> docs.stream().mapToLong(d -> d.json().length).sum(),
            out -> {
              for (Corpus.Document d : docs) {
                out.accept(JSON.readTree(d.json()));
              }
              return docs.size();
            }),
        new Task("parse-doc-haus", "parse", "per doc", "haus", "Haus.parse",
            () -> docs.stream().mapToLong(d -> d.haus().length).sum(),
            out -> {
              for (Corpus.Document d : docs) {
                out.accept(Haus.parse(d.haus()));
              }
              return docs.size();
            }),

        // Typed: parse and decode with the document's type (Go: haus.Parse + Type.Decode). Their
        // JSON baseline is the plain parse: there are no Java types of the schemas for Jackson's
        // databind to read into.
        new Task("typed-corpus-haus", "typed", "corpus", "haus", "Haus.parseAll + SchemaType.decode", () -> c.allHaus().length,
            out -> {
              List<Value> vs = Haus.parseAll(c.allHaus());
              for (int i = 0; i < vs.size(); i++) {
                out.accept(types.get(i).decode(vs.get(i)));
              }
              return vs.size();
            }),
        new Task("typed-doc-haus", "typed", "per doc", "haus", "Haus.parse + SchemaType.decode",
            () -> docs.stream().mapToLong(d -> d.haus().length).sum(),
            out -> {
              for (int i = 0; i < docs.size(); i++) {
                out.accept(types.get(i).decode(Haus.parse(docs.get(i).haus())));
              }
              return docs.size();
            }),

        new Task("write-corpus-json", "write", "corpus", "json", "ObjectMapper.writeValueAsString",
            () -> utf8Length(JSON.writeValueAsString(corpusTree)),
            out -> write(out, JSON.writeValueAsString(corpusTree))),
        new Task("write-corpus-haus", "write", "corpus", "haus", "Haus.writeAll (minimised, a stream)",
            () -> utf8Length(Haus.writeAll(values, FormatOptions.MINIMISED)),
            out -> write(out, Haus.writeAll(values, FormatOptions.MINIMISED))),
        new Task("write-doc-json", "write", "per doc", "json", "ObjectMapper.writeValueAsString",
            () -> writtenBytes(trees, JSON::writeValueAsString),
            out -> writeEach(out, trees, JSON::writeValueAsString)),
        new Task("write-doc-haus-minimised", "write", "per doc", "haus", "Haus.write (minimised)",
            () -> writtenBytes(values, v -> Haus.write(v, FormatOptions.MINIMISED)),
            out -> writeEach(out, values, v -> Haus.write(v, FormatOptions.MINIMISED))),
        new Task("write-doc-haus-compact", "write", "per doc", "haus", "Haus.write (compact)",
            () -> writtenBytes(values, v -> Haus.write(v, FormatOptions.COMPACT)),
            out -> writeEach(out, values, v -> Haus.write(v, FormatOptions.COMPACT))),
        // The typed write: the decoded value checked with its type (encode) and written.
        new Task("write-doc-haus-typed", "write", "per doc", "haus", "SchemaType.encode + Haus.write (minimised) (typed)",
            () -> writtenBytes(typed, Inputs::writeTyped),
            out -> writeEach(out, typed, Inputs::writeTyped)),
        // The canonical form, against Jackson writing members sorted.
        new Task("canonical-doc-json", "write", "per doc", "json", "ObjectMapper.writeValueAsString (members sorted)",
            () -> writtenBytes(trees, SORTED::writeValueAsString),
            out -> writeEach(out, trees, SORTED::writeValueAsString)),
        new Task("canonical-doc-haus", "write", "per doc", "haus", "Haus.canonical",
            () -> writtenBytes(values, Haus::canonical),
            out -> writeEach(out, values, Haus::canonical)));
  }

  /** A decoded value and its type. */
  private record Typed(SchemaType type, Value value) {}

  private static String writeTyped(Typed x) {
    return Haus.write(x.type().encode(x.value()), FormatOptions.MINIMISED);
  }

  /** A writer that may fail as Jackson's do. */
  @FunctionalInterface
  private interface Writer<T> {
    String write(T x) throws JsonProcessingException;
  }

  private static long write(Consumer<Object> out, String text) {
    out.accept(text);
    return text.length();
  }

  private static <T> long writeEach(Consumer<Object> out, List<T> xs, Writer<T> writer)
      throws JsonProcessingException {
    long n = 0;
    for (T x : xs) {
      String text = writer.write(x);
      out.accept(text);
      n += text.length();
    }
    return n;
  }

  /** The UTF-8 size of what {@code writer} writes for each of {@code xs}. */
  private static <T> long writtenBytes(List<T> xs, Writer<T> writer) throws JsonProcessingException {
    long n = 0;
    for (T x : xs) {
      n += utf8Length(writer.write(x));
    }
    return n;
  }

  private static long utf8Length(String text) {
    return text.getBytes(UTF_8).length;
  }
}
