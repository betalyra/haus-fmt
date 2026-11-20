# haus for the JVM

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** This is the core: the parser, the formatter, the stream reader, the canonical form and hashing, and the two JSON forms that need no schema. Schemas, typed codecs and a benchmark come next.

Two modules, for the JVM and Android:

| Module | | Depends on |
|---|---|---|
| `haus` | the Java library, package `org.hausfmt` | nothing |
| `haus-kotlin` | Kotlin extensions over it, package `org.hausfmt.kotlin` | `haus`, `kotlin-stdlib` |

They follow the [specification](../spec): exact numbers, limits enforced while parsing, error positions in code points, and an error code from the catalogue on every error. The code is Java 17 (bytecode and APIs), built and tested with JDK 25; the Kotlin wrapper targets JVM 17 and calls the Java code, so it is as fast.

## Java

```java
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.Value;

Value order = Haus.parse("{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: \"DE-4711\" } }");
Value.Record r = (Value.Record) order;
if (r.get("status") instanceof Value.Variant status && status.tag().equals("Shipped")) {
    System.out.println("shipped: " + status.payload().get("tracking"));   // shipped: "DE-4711"
}

Value.Number total = (Value.Number) ((Value.Variant) r.get("total")).get(0);
total.literal();        // "44.40": exact, never a float
total.toBigDecimal();   // 44.40

List<Value> values = Haus.parseAll("Log { a: 1 },\nHeartbeat,\n");   // a stream: every top-level value
String text = Haus.write(order, FormatOptions.COMPACT);               // one line, with a line break
```

Values are `Value.Number`, `Value.Text`, `Value.Bytes`, `Value.Array`, `Value.Record` and `Value.Variant`, the six kinds of spec §1, behind the sealed interface `Value`; `kind()` gives the kind for a `switch`. Values are immutable. A `Number` keeps its normalized literal (`0xFF` is `255`, `1E+05` is `1e5`, `19.90` stays `19.90`); `toBigInteger()` and `toBigDecimal()` convert it, and converting to a float is up to you. A `Record` keeps its fields in source order, with `get` (null for a missing key), `size`, `keys`, `fields` and `toMap`. `equals` is equality as in spec §2: field order doesn't matter, `1.0` and `1` differ, and `Tag { … }` equals `Tag({ … })`. `toString()` is the value in the compact layout.

Build values with `Value.number(…)`, `Value.string(…)`, `Value.bytes(…)`, `Value.array(…)`, `Value.record(Value.field(k, v), …)` and `Value.variant(tag, args…)`. A repeated key is `duplicate-key`, a tag that isn't `[A-Z][A-Za-z0-9_]*` is `invalid-tag`.

## Kotlin

```kotlin
import org.hausfmt.Value
import org.hausfmt.kotlin.*

val order = """{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }""".parseHaus()
val (tag, args) = order["total"] as Value.Variant     // "Money", [44.40, EUR]
println(order["id"]?.bigInteger)                       // 7

when (val status = order["status"]) {                  // exhaustive over the sealed Value
    is Value.Variant -> println(status.tag())
    else -> println("not a variant")
}

val built = hausRecord("id" to 7.haus, "tags" to hausArray("a".haus, "b".haus), "paid" to true.haus)
println(built.toHaus())                                // { id: 7, tags: ["a", "b"], paid: True }

File("events.haus").inputStream().use { input ->
    input.hausValues(strict = true).forEach { println(it) }   // a Sequence, one value at a time
}
```

`parseHaus`, `parseHausAll`, `formatHaus`, `toHaus`, `canonical`, `hash`, `hashAll`, `toHausJson`, `fromHausJson` and `importJson` are extensions over strings, byte arrays and values; `value["key"]` and `value[0]` look into records, arrays and payloads (null where there is nothing), and variants and fields destructure.

## Errors

Every error is a `HausException` (unchecked) with a `code()` (spec §17), a `reason()`, and for an error in text a 1-based `line()` and `column()`, counted in code points:

```java
try {
    Haus.parse("{ ok: true }");
} catch (HausException e) {
    e.code();        // BOOLEAN_LITERAL, whose code() is "boolean-literal"
    e.getMessage();  // 1:7: true is not a value: booleans are the tags True and False [boolean-literal]
    e.toJson();      // the JSON form of spec §17, with the hint and the docs URL
}
```

`ErrorCode` is generated from the catalogue, [`spec/errors.haus`](../spec/errors.haus), by `node spec/scripts/errors.ts`; `hint()` is the usual fix and `docs()` its documentation.

## Limits

`Haus.parse(text, Limits.DEFAULT.withMaxDepth(64))` sets limits (spec §7): depth 256, 1000 characters per number literal (and so 829 hex digits), exponents up to ±6144, 16 Mi characters per string, key, tag or byte string, and 64 Mi characters per top-level value of a stream (which only the stream reader applies). `maxDepth` can be at most `Limits.MAX_SUPPORTED_DEPTH`, 1000: the parser, the writers and the canonical form recurse once per level, and 1000 levels stay within the default stack of a thread. A larger limit is rejected with the code `unsupported-depth`, and no value, parsed or built in code, is nested deeper. Duplicate keys are found in linear time also for keys made to collide: large records use a table with a hash seeded at random per process.

## Streams

`StreamReader` reads the values of an `InputStream` one at a time (spec §6), holding at most one value's text in memory:

```java
try (StreamReader reader = new StreamReader(in, StreamOptions.DEFAULT.withStrict(true))) {
    for (Value v; (v = reader.read()) != null; ) {
        handle(v);   // stream-truncated if the last value has no comma after it
    }
}
```

It is also an `Iterator<Value>`, and `stream()` gives a `java.util.stream.Stream`. Errors have the same codes and positions as when the whole input is parsed at once.

## Formatting

`Haus.format(text, FormatOptions.PRETTY)` rewrites text in one of the three layouts of spec §11: `PRETTY` keeps comments and blank lines, `COMPACT` writes one item per line, and `MINIMISED` drops the whitespace between tokens. Numbers, byte strings and `"…"` strings keep their spelling. Indent (default 2) and width (default 80) are the only options: `FormatOptions.PRETTY.withIndent(4)`. `Haus.hasComments` tells a tool that rewrites files in place whether compact or minimised would drop comments.

`Haus.write(value, options)` and `Haus.writeAll(values, options)` write values built in code: numbers normalized, byte strings in lowercase hex, strings with the fewest escapes, and a stream with a comma after every value.

## Canonical form and hashing

```java
Value v = Haus.parse("Order { total: 19.90, id: 0xFF, \"x-y\": 1e+5 }");
Haus.canonical(v);   // Order{id:255,total:19.90,"x-y":1e5}
Haus.hash(v);        // SHA-256 of the canonical form (java.security.MessageDigest), 64 hex digits
```

`Haus.hashAll(values)` hashes a whole file; `Haus.compare` orders values by their canonical forms. The hash is unkeyed: don't publish the hash of a document with private content (spec §9).

## JSON

```java
Value v = HausJson.importJson("{\"price\": 19.90, \"tags\": [\"a\"], \"note\": null}");   // { price: 19.90, tags: ["a"], note: None }
String json = HausJson.toHausJson(v);   // {"_haus":1,"_value":{"_rec":{"price":{"_num":"19.90"},…}}}
Value back = HausJson.fromHausJson(json);   // equal to v
```

The JSON import (§16.1) reads any JSON; self-describing JSON (§16.2) writes every haus value exactly and reads it back. Numbers keep their exact text, readers accept only I-JSON, and the limits of §7 count the haus value. JSON Lines: `toHausJsonLines`, `fromHausJsonLines`, `importJsonLines`, and `hausJsonLinesReader(in, limits)`, which holds one line at a time. Schema-based JSON (§16.3) comes with schemas.

## Examples

[`examples`](examples) has the `quickstart` and `order` examples of the other bindings, in Java and Kotlin, on the shared files in [`../examples`](../examples): `./gradlew :examples:quickstart`, `:examples:order`, `:examples:quickstartKotlin`, `:examples:orderKotlin`. Until the JVM binding has schemas, they read the files as plain values (the other bindings check them with their schemas and codecs), and their lines are compared with Go's in `ExamplesTest`.

## Building

```sh
./gradlew build   # compile, the conformance suite, the linearity tests, the Kotlin tests and the examples
```

The tests run the shared conformance suite in [`../test-suite`](../test-suite): the valid and invalid files, the format suite, the stream suite and the JSON suite (import and self-describing JSON), byte for byte. The differential fuzzer runs the JVM binding through [`../fuzz/jvm`](../fuzz/jvm) (`jvm-runner`), built by `fuzz/build.sh`.
