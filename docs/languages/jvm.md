---
title: Java and Kotlin
description: Parse haus on the JVM and Android, and decode it with a schema into records, sealed interfaces and Kotlin data classes.
---

Parse haus into `Value`s, or decode it with a schema straight into your Java records, sealed interfaces and enums, or Kotlin data classes. No annotation processor and no generated code. Java 17 or later, Android too; the Java library has no dependencies.

## Install

| Module | Package | For |
|---|---|---|
| `haus` | `org.hausfmt` | Java, and every JVM language |
| `haus-kotlin` | `org.hausfmt.kotlin` | Kotlin extensions over it |

Not on Maven Central yet: build both from [`jvm/`](https://github.com/betalyra/haus-fmt/tree/main/jvm) in the repository with `./gradlew build` (group `org.haus-fmt`).

## Read and write

```java
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.Value;

Value order = Haus.parse("{ id: 7, total: 44.40, status: Shipped { tracking: \"DE-4711\" } }");
Value.Record r = (Value.Record) order;
if (r.get("status") instanceof Value.Variant status && status.tag().equals("Shipped")) {
    System.out.println(status.payload().get("tracking"));   // "DE-4711"
}
((Value.Number) r.get("total")).toBigDecimal();             // 44.40: exact, never a double
Haus.write(order, FormatOptions.COMPACT);                    // one line of haus
```

In Kotlin:

```kotlin
import org.hausfmt.kotlin.*

val order = """{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }""".parseHaus()
println(order["id"]?.bigInteger)   // 7
println(order.toHaus())            // { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }
```

`Haus.parseAll` reads a file of several values (a stream).

## With a schema

A `HausCodec` maps a schema type onto your types, checked against each other once, when it is built:

```java
record Line(String sku, int qty) {}
sealed interface Status permits Pending, Shipped {}
record Pending() implements Status {}
record Shipped(String tracking) implements Status {}
record Order(long id, List<Line> lines, Status status) {}

Schema schema = Schema.load(Path.of("order.schema.haus"));
HausCodec<Order> orders = schema.codec("Order", Order.class);

Order o = orders.decode(text);                          // parse, check with the schema, build the records
String back = orders.encode(o, FormatOptions.COMPACT);  // and back to haus
```

```kotlin
data class Line(val sku: String, val qty: Int)
sealed interface Status
data object Pending : Status
data class Shipped(val tracking: String) : Status
data class Order(val id: Long, val lines: List<Line>, val status: Status)

val orders = schema.codec<Order>("Order")   // needs javaParameters.set(true) in the Kotlin compiler options
```

A variant is a sealed interface with a record per tag, or an enum for tags without payload; `Maybe` is an `Optional` (or a nullable). A value that doesn't fit throws a `HausException` with its code and place:

```java
try {
    orders.decode("{ id: 7, lines: [{ sku: \"TEA-01\", qty: \"lots\" }], status: Pending }");
} catch (HausException e) {
    e.code();         // TYPE_MISMATCH, "type-mismatch"
    e.getMessage();   // names the place, $.lines[0].qty
}
```

All the mappings: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Packages and codecs.** Packages are found only where you say: `PackageLocator.explicit()` with `packageDir`, `folder`, or `resources(classLoader, prefix)` for packages in a jar. The official profiles are codecs:

```java
Schema schema = Schema.load(Path.of("order.schema.haus"),
    SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().folder(Path.of("schemas"))));
SchemaType root = schema.type("Root");

Codecs codecs = Codecs.of(MoneyCodecs.ISO, GeoCodecs.WGS84);   // org.hausfmt.ext.money, org.hausfmt.ext.geo
root.decode(Haus.parse(text), DecodeOptions.DEFAULT.withCodecs(codecs));   // Money(1, Eur): codec-rejected
root.missingCodecs(codecs);   // missing-codec warnings for profiled types left without a codec
```

`Codec.of(id, Host.class, decode, encode)` writes your own. [What haus checks](/docs/checks), [`missing-codec`](/docs/errors#missing-codec)

- **Time.** std/time values are a `String`, their exact text. `LocalDate`, `Instant`, `OffsetDateTime`, `ZoneId` and the other `java.time` types work too, keeping the meaning but not the spelling.
- **Decimals.** `Decimal` is a `BigDecimal`, or a `Value.Number` to keep `-0` and exponents as written.
- **Streams.** `new StreamReader(in, StreamOptions.DEFAULT.withStrict(true))` reads one value at a time; it is an `Iterator<Value>` with `stream()`. In Kotlin, `input.hausValues()` is a `Sequence`. [Logs and streams](/docs/tours/streams)
- **JSON.** `orders.toJson(o)` writes schema-based JSON; `HausJson.importJson` reads any JSON as haus. [Coming from JSON](/docs/from-json)
- **Secrets.** `Secret a` is a `Secret<A>`; errors inside never show the value. [Config and secrets](/docs/tours/secrets)
- **Threads.** Values, schemas and codecs are immutable and safe to share.
- **Errors.** `HausException` is unchecked, with `code()`, `hint()` and `toJson()` for tools. [Error codes](/docs/errors)

## More

- [README of the JVM modules](https://github.com/betalyra/haus-fmt/tree/main/jvm): schemas, limits, streams and JSON in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/jvm/examples), in Java and Kotlin: `./gradlew :examples:quickstart`, `:examples:order`, `:examples:quickstartKotlin`, `:examples:orderKotlin`.
- [A tour of haus](/docs/tour).
