# haus for the JVM

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** The parser, the formatter, the stream reader, the canonical form and hashing, the three JSON forms, schemas (with std/time, schema packages and the official profiles), and typed codecs for records, sealed interfaces and Kotlin data classes, with a benchmark against Jackson.

Two modules, for the JVM and Android:

| Module | | Depends on |
|---|---|---|
| `haus` | the Java library, package `org.hausfmt`; the official profiles in `org.hausfmt.ext.money` and `org.hausfmt.ext.geo` | nothing |
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

Build values with `Value.number(…)`, `Value.string(…)`, `Value.bytes(…)`, `Value.array(…)`, `Value.record(Value.field(k, v), …)` and `Value.variant(tag, args…)`. A repeated key is `duplicate-key`, a tag that isn't `[A-Z][A-Za-z0-9_]*` is `invalid-tag`, and `Value.number("01")` is `invalid-number`. The constructors check only that a value is valid, never a limit (spec §11): `Value.number` takes a literal of any length and exponent, normalized as the parser does, and the writers apply the limits.

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

Typed codecs take data classes and sealed interfaces (`data object` for a tag without payload), with `schema.codec<Order>("Order")`; the Kotlin compiler must keep parameter names (`kotlin { compilerOptions { javaParameters.set(true) } }`), which the codec maps data classes by. `"…".decodeHaus(type)` decodes text with a schema type.

`parseHaus`, `parseHausAll`, `formatHaus`, `toHaus`, `canonical`, `hash`, `hashAll`, `toHausJson`, `fromHausJson` and `importJson` are extensions over strings, byte arrays and values; `value["key"]` and `value[0]` look into records, arrays and payloads (null where there is nothing), and variants and fields destructure.

## Schemas

```java
Schema schema = Schema.load(Path.of("order.schema.haus"),
    SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().folder(Path.of("extensions"))));
SchemaType root = schema.type("Root");
Value order = root.decode(Haus.parse(text));   // the value an encoder writes back
Value checked = root.encode(builtInCode);      // checks a value built in code, the same way
```

`Schema.load` reads a schema file (spec §14), its relative imports (`import ./common (Address)`) and the packages it imports (§13.3); `Schema.parse` reads one from text. Every rule of §13.3 and §14 is checked when a schema loads, so its types decode in time linear in the input; an error in an imported file is reported at the import, with its place in that file. Packages are found only where the application says (§9.2): `PackageLocator.explicit()` with `packageDir(dir)` for one package, `folder(dir)` for a folder of them and `resources(classLoader, "schemas/orders")` for a package published as classpath resources (its `package.haus` and `schema.haus` in a jar, under that prefix), combined with `PackageLocator.or`. There is no `node_modules` lookup on the JVM, and there won't be: only implementations of the npm ecosystem read `node_modules` (§13.3).

Relative imports stay inside the build's root (§13.3): by default the directory of the schema file's real path, or `SchemaOptions.withRoot(dir)`, a directory that contains it (such as a repository's schema directory whose folders share files; a relative one is from the schema file's directory). The schema file and the root are resolved to real paths once, and may be reached through links; a relative import follows none: a symbolic link anywhere on its path is `import-not-found`, and the message doesn't say where it points. An import whose `..` goes above the root is `import-outside-root`, and nothing outside is looked at. A path in an import is `./` or `../…` followed by names that start with a letter, digit, `_` or `-` (no `.` or empty names, no `..` after a name, no `/` at the end). Every file read is a regular file opened without following a link at its last name, and the names the build looks up (`package.haus`, `schema.haus`, `package.json`, each name of a relative import) must be spelled as their directory lists them, also on file systems that ignore case. Java can't open a file without blocking or ask an open channel for its type, so the type is checked just before the open: a file swapped for a FIFO in between can still block the load, which only someone who may write to the schema's directories can do. Messages show paths relative to the root (`../vendor/orders` for a package outside it), never absolute ones; a package's errors when it is given (`packageDir`, `folder`) show its directory as the application gave it. A file's id never has the form of a package's id (`@org/name@N`): one that would start with `@` gets `./` in front. `schema.warnings()` lists unknown attributes, uses of deprecated types and record cases without a schema-based JSON form; `definitions()`, `imported()` and `packages()` describe the schema.

`SchemaType.decode` follows §15: integers in decimal (`-0` is `0`), floats rounded from the exact decimal and written in their one spelling, the fields an open record doesn't list left out, the tags an open variant doesn't list kept as they are. Errors are `HausException`s with the code (spec §17) and the path of the failing value, `$.items[2].price`; an error inside a `Secret` is at the secret and never shows the value. The value of a `Secret` type comes back hidden in a `Value.Secret` (kind `SECRET`): its `toString` is `<redacted>`, `reveal()` gives it out, `Haus.write`, `canonical`, `hash` and `HausJson` refuse it (`cannot-encode`), and `SchemaType.encode` and `toJson` write it in full. The typed `Secret<T>` hides its value from `toString` only: a JSON library that serializes fields by reflection (Gson) would write it. `decodeAll` and `decodeStream` read files and streams of a `Stream` definition, with the item's index in the path (`$[3].total`). std/time's types are checked by their profile, also on their own: `StdTime.check("Date", "2026-02-30")`.

Codecs (§13.4) let the application choose host types for named types, selected by the type's id: `Codec.of("@haus-fmt/money@1#Money", Amount.class, decode, encode)`, given in `DecodeOptions.DEFAULT.withCodecs(Codecs.of(...))`. A codec runs after the schema and may reject more values (a `HausException` keeps its code, any other exception is `codec-rejected`); its error when encoding is `cannot-encode`. Any named type without arguments can have one: of your files, of a package, of std/time (`std/time#Instant`) or of the prelude (`prelude#Decimal`, which then applies to every `Decimal`, in packages' types too). An outer codec gets the value the schema decoded for a part with a codec of its own, so a looser codec for `Currency` can't make a `Money` pass `MoneyCodecs.ISO`. `schema.unusedCodecs(codecs)` lists an `unused-codec` warning for each codec whose id no type has (a typo, or `@haus-fmt/money@2#Money` with a schema importing major 1): it would never run. The official profiles are codecs too: `MoneyCodecs.ISO` and `ISO_CURRENCY` (`@haus-fmt/money`'s iso profile), `GeoCodecs.WGS84` and `WGS84_BBOX` (`@haus-fmt/geo`'s wgs84), `UuidCodecs.RFC9562` (`@haus-fmt/uuid`'s rfc9562, the text as a `String`) and `RFC9562_AS_UUID` (the same rule, a `java.util.UUID`, which keeps the value too: the profile allows one spelling, the one `toString()` writes). A package's rule is checked only where its codec is set: `type.missingCodecs(codecs)` (or `schema.missingCodecs(codecs)` for every type of the file) lists a `missing-codec` warning, like those of `schema.warnings()`, for each type an official profile has a rule for (`Profiles.PROFILED_TYPES`: `@haus-fmt/money@1#Currency`, `@haus-fmt/geo@1#LatLng`, `@haus-fmt/geo@1#BBox`, `@haus-fmt/uuid@1#Uuid`) that the type reaches without a codec, whose values are then checked for their shape only (§13.4). A type reached only inside a type with a codec doesn't count (`MoneyCodecs.ISO` covers the `Currency` of a `Money`).

Schema-based JSON (§16.3): `root.toJson(value)` and `root.fromJson(json)`, and JSON Lines with `toJsonLines`, `fromJsonLines` and `jsonLinesReader`.

## Typed codecs

A `HausCodec<T>` decodes and encodes a schema type as the application's own types, checked against each other once, when the codec is built:

```java
record Line(String sku, BigDecimal price, int qty) {}
record Order(long id, List<Line> lines, Optional<String> note, Status status) {}
sealed interface Status permits Pending, Shipped {}
record Pending() implements Status {}
record Shipped(String tracking) implements Status {}

HausCodec<Order> orders = schema.codec("Order", Order.class);
Order o = orders.decode(text);                          // parse, check with the schema, build the records
String back = orders.encode(o, FormatOptions.COMPACT);  // build the value, check it, write it
String json = orders.toJson(o);                         // schema-based JSON
```

A record is a Java record (or a Kotlin data class) whose components are its fields, by name (`@HausName("pt-BR")` where the key isn't a Java name). A variant is a sealed interface with a record per tag, named like the tag, or an enum for a closed variant of tags without payload; in an open variant, a record with one `Value.Variant` component keeps the tags the schema doesn't list. `Maybe a` is `Optional<A>`, or `A` with null for `None`; an optional field (`note?: String`) is null when it is missing. Integers are `long`, `int`, `short`, `byte` or `BigInteger` (a value the host type can't hold is `out-of-range`), floats `double` or `float`, `Decimal` a `BigDecimal` or a `Value.Number` (which keeps `-0` and exponents as written), `Secret a` a `Secret<A>`, `Any` a `Value`. std/time values are their text, a `String`, which keeps them exactly; `LocalDate`, `YearMonth`, `LocalTime`, `LocalDateTime`, `OffsetDateTime`, `java.time.Instant` and `ZoneId` keep what they mean but not how they were written (spec §13.4), and a value they can't hold (`ZoneId` of a zone name the JDK doesn't know) is `codec-rejected`. Generic types take a parameterized `Type` (`HausCodec.of(type, Envelope<Event>'s Type, options)`), recursive types work, and a component of a codec's host type uses the codec.

The codec is built by reflection, once; decoding runs the schema's decoder and then builds the objects, so every rule, error code and path is the decoder's. No annotation processor or generated code is needed: a record is all a codec needs.

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

`Haus.parse(text, Limits.DEFAULT.withMaxDepth(64))` sets limits (spec §7): depth 256, 1000 characters per number literal (and so 829 hex digits), exponents up to ±6144, 16 Mi characters per string, key, tag or byte string, and 64 Mi characters per top-level value of a stream (which only the stream reader applies). `withMaxNodes` sets the node limit (64 Mi), which the writers, `Haus.check`, the canonical form and hashing apply to a value built in code: they count the values they write, each as often as it is written, so a value whose arrays share one another, small in memory but exponentially larger written out, fails with `too-many-nodes`. The writers check every limit a value built in code can break (depth, string, key, tag and byte string lengths, number length and exponent, nodes), so that a parser with the same limits reads the text back. `maxDepth` can be at most `Limits.MAX_SUPPORTED_DEPTH`, 256 (the default, as in Rust): the parser, the writers, the checks and the schema codecs recurse once per level, and 256 levels fit in a thread with a 512 KiB stack, which the tests check, also interpreted (`-Xint`, `smallStackTest`). A larger limit is rejected with the code `unsupported-depth`. The JSON readers keep their nesting on the heap (self-describing JSON nests up to 4·256+2 levels). A value built in code may be nested as deeply as memory allows: `equals`, `hashCode` (computed once per container and kept, without recursion), `Haus.canonical`, `hash`, `hashAll` and `compare` take any depth, `toString` writes the containers below 256 levels as `…`, and the writers and `Haus.check` reject a value deeper than their limit with `nesting-too-deep` before they go deeper. Duplicate keys are found in linear time also for keys made to collide: large records use a table with a hash seeded at random per process.

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

`Haus.format(text, FormatOptions.PRETTY)` rewrites text in one of the three layouts of spec §11: `PRETTY` keeps comments and blank lines, `COMPACT` writes one item per line, and `MINIMISED` drops the whitespace between tokens. Numbers, byte strings and `"…"` strings keep their spelling. Indent (default 2) and width (default 80) are the options of the pretty layout: `FormatOptions.PRETTY.withIndent(4)`. `withStream(true)` (default false) says the file is a stream, in every layout: a single item gets a comma after it too, so a log with one entry so far keeps the comma the next one is appended after; a file of several items, or of none, is written the same either way. `Haus.hasComments` tells a tool that rewrites files in place whether compact or minimised would drop comments.

`Haus.write(value, options)` and `Haus.writeAll(values, options)` write values built in code: numbers normalized, byte strings in lowercase hex, strings with the fewest escapes. `writeAll` writes a file: one value alone, more as a stream with a comma after every value, and with `withStream(true)` a comma after a single value too (`write` writes one value and ignores the option; in Kotlin, `values.toHaus(stream = true)` and `text.formatHaus(stream = true)`).

## Canonical form and hashing

```java
Value v = Haus.parse("Order { total: 19.90, id: 0xFF, \"x-y\": 1e+5 }");
Haus.canonical(v);   // Order{id:255,total:19.90,"x-y":1e5}
Haus.hash(v);        // SHA-256 of the canonical form (java.security.MessageDigest), 64 hex digits
```

`Haus.hashAll(values)` hashes a whole file; `Haus.compare` orders values by their canonical forms. They apply only the node limit (spec §12; overloads take `Limits` for it): a value longer than a writer's limits still has a canonical form. The hash is unkeyed: don't publish the hash of a document with private content (spec §9).

## Threads

Values, `Limits`, the options, `Codecs`, `Schema`, `SchemaType` and `HausCodec` are immutable and safe for concurrent use, and parsing, writing, formatting, the canonical form, hashing and JSON keep their state in the call. A `StreamReader` or `JsonLinesReader` belongs to one stream. The Kotlin functions hold no state.

## JSON

```java
Value v = HausJson.importJson("{\"price\": 19.90, \"tags\": [\"a\"], \"note\": null}");   // { price: 19.90, tags: ["a"], note: None }
String json = HausJson.toHausJson(v);   // {"_haus":1,"_value":{"_rec":{"price":{"_num":"19.90"},…}}}
Value back = HausJson.fromHausJson(json);   // equal to v
```

The JSON import (§16.1) reads any JSON; self-describing JSON (§16.2) writes every haus value exactly and reads it back. Numbers keep their exact text, readers accept only I-JSON, and the limits of §7 count the haus value. JSON Lines: `toHausJsonLines`, `fromHausJsonLines`, `importJsonLines`, and `hausJsonLinesReader(in, limits)`, which holds one line at a time. Schema-based JSON (§16.3) is on `SchemaType` (see [Schemas](#schemas)).

## Examples

[`examples`](examples) has the `quickstart` and `order` examples of the other bindings, in Java and Kotlin, on the shared files in [`../examples`](../examples): `./gradlew :examples:quickstart`, `:examples:order`, `:examples:quickstartKotlin`, `:examples:orderKotlin`. They check the files with their schemas, decode them into records and data classes, with codecs for `Money` and `LatLng` on top of the official profiles, and their output is compared with Go's line for line in `ExamplesTest`.

## Speed

Measured against Jackson's `JsonNode` tree in [`bench/speed/jvm`](../bench/speed/jvm) (JMH; see [`bench/README.md`](../bench/README.md#jvm)): on the seven corpora, parsing takes 0.8–1.6× Jackson's time and writing 0.6–1.5×; decoding with a schema 1.4–2.4× Jackson's untyped parse. The writers quote and check a string in one pass, the parser checks UTF-8 only in strings and comments (the whole text again only after an error, so the error is the same), and large records find repeated keys with `String.hashCode` until crafted keys collide, then with a hash seeded per process; `LinearTest` checks that parsing, writing, the canonical form and decoding stay linear in the input, also for keys made to collide.

## Building

```sh
./gradlew build   # compile, the conformance suite, the linearity tests, the Kotlin tests and the examples
```

The tests run the shared conformance suite in [`../test-suite`](../test-suite): the valid and invalid files, the format suite, the stream suite, the JSON suite (all three forms), the schema suite (each schema with and without its attributes), the invalid schemas and the package suite (its `core` cases, each also with its packages given as classpath resources where it gives no folders; the `npm` cases are for implementations of the npm ecosystem), byte for byte, and the test vectors of the official profiles. The differential fuzzers run the JVM binding through [`../fuzz/jvm`](../fuzz/jvm) (`jvm-runner`), built by `fuzz/build.sh`: the parser, formatters, std/time, the profiles, schema decoding, schema files and all JSON modes, against the Lean reference.
