---
title: Why you can trust haus
description: What is proven about haus, how every binding is checked against the proof, and why you can read haus files from anyone.
---

A data format is a contract between whoever writes a file and whoever reads it. This page says how haus keeps that contract: what is proven, what is tested, and what a parser does with a file written to cause trouble. It also says what isn't proven, so you know where the line is.

## Proven

haus has a reference implementation in [Lean](https://lean-lang.org), a programming language that is also a proof assistant. The grammar is written there as a precise definition, and the reference parser is an ordinary program next to it. Lean checks every proof by machine. A proof with a gap doesn't build, and CI builds every proof on every change.

### What is proven about parsing

- **The parser accepts exactly the valid files.** Everything it accepts is a haus file with exactly the values it returned, and every haus file is accepted.
- **Each file reads only one way.** A text has at most one meaning: there are no two readings that give different values.
- **Every valid file is clean.** It holds no raw bidi control character anywhere, and no control character but tab, line feed, and a carriage return directly before a line feed. Every record, at any depth, has unique keys. Every string is valid Unicode, and every value is within the limits. Since the parser accepts only valid files, all of this holds for whatever it returns.
- **Parsing takes linear time.** Lean says nothing about time by itself, so there is a second version of the reference parser that counts its steps: reading a character is one step, visiting a list element is one step, and so is each arithmetic operation. It keeps a record's keys in a trie, and is proven to return exactly what the reference parser returns. On any input of *n* characters, valid or not, crafted or not, it takes at most 256 · *n* + 68 steps.

### What is proven about writing and streams

- **Written values read back.** The canonical form, and the compact, minimised and pretty layouts, all parse back to the values they were written from.
- **One canonical form per value.** Two values have the same canonical form exactly when they are equal, so a hash means the same thing everywhere.
- **Block strings survive editors.** In the pretty layout, no line of a block string ends in a space or a tab, so an editor that trims trailing blanks leaves it unchanged.
- **Chunks don't matter.** A model of the bindings' stream readers returns the same values and the same error however the input is split into chunks. A value it has returned is never taken back.

### What is proven about schemas

- **Decoding follows the spec.** The reference decoder computes the rules of the specification, written as definitions in Lean. Decoding what was encoded gives the same value again, and a float's spelling reads back as the same float.
- **Schemas can't blow up.** A schema that passes the checks has finitely many instances of its generic types. The check rejects exactly the schemas that would have infinitely many, such as one whose instances double at every step.
- **A checked schema never fails on its own.** Decoding any value with it never fails because of the schema itself: no unknown type, no recursion that consumes no input.
- **Decoding takes linear time.** At most a constant times the size of the input, the constant depending only on the schema. This proof *assumes* that rounding a float literal and checking a `std/time` value take time linear in their literal; it doesn't count their steps.
- **Secrets stay out of errors.** An error inside a `Secret` is the same whatever the value is: nothing of the value can leak into it.
- **JSON round-trips.** Both JSON mappings read back what they write, and an older reader reads a newer writer's JSON within a minor version.

The proofs use only Lean's standard axioms.

### What is not proven

- **The bindings you use.** TypeScript, Rust, Python, Go, Zig and Roc are separate programs. They are tested against the reference, as described [below](#the-same-everywhere), but testing is not proof.
- **Running time in the bindings.** The linear bound is about the reference parser in its cost model. The bindings' own speed is not proven; they have tests with hostile inputs that would make a quadratic implementation slow. Converting a long hex literal to decimal is quadratic in its digits, which the number limit keeps small.
- **Some parts below the model.** The model reads Unicode code points, so UTF-8 decoding isn't covered, and neither are error positions. The hash proofs are about the text that is hashed, not SHA-256 itself.
- **Imports in schema files.** Finding packages is modelled and proven on its own, but the Lean schema-file reader doesn't bring in the definitions of imported packages.

**More:** every theorem with its name, in [What is proven](https://github.com/betalyra/haus-fmt/blob/main/spec/lean/README.md#what-is-proven); the [Lean sources](https://github.com/betalyra/haus-fmt/tree/main/spec/lean); what is done and still open, in the [plan](https://github.com/betalyra/haus-fmt/blob/main/spec/lean/PLAN.md).

## The same everywhere

A proof about the reference parser only helps you if the library you use behaves the same way. haus has [bindings](/docs/languages) for TypeScript (with an adapter for Effect), Rust, Python, Go, Swift, Java and Kotlin, Zig (with a C ABI) and Roc. Two things keep them in line with the reference and with each other. The Zig binding is written from the specification and the suite alone, without reading the other bindings' code, so it also checks that the specification says enough.

### One conformance suite

[`test-suite/`](https://github.com/betalyra/haus-fmt/tree/main/test-suite) holds files that every binding must handle the same way:

- valid files with their expected values, canonical forms and hashes;
- invalid files with the exact [error code](/docs/errors) each must be rejected with;
- formatter cases with the expected output in each layout;
- schema cases: decode this input with this type, and expect this output, or this error code at this place;
- JSON, stream and package cases.

Every binding runs the suite in CI. So does the Lean reference, which checks the suite itself against the proven parser.

### Differential fuzzing

A suite only covers the cases someone thought of. The [fuzzer](https://github.com/betalyra/haus-fmt/tree/main/fuzz) makes up new ones. It writes random haus text with varied spacing, comments, CRLF line endings, number spellings and block strings, and values at and just past the limits. Then it damages half of it: bytes deleted, quotes and control characters and bidi characters inserted, invalid UTF-8, input cut short.

Every input goes through the Lean reference and every binding, and they must agree: accepted with the same values, or rejected. Where two report an error at the same place, the error code must be the same too. Stream readers get the same input cut into chunks of different sizes, and must return what parsing the whole input returns.

The same idea covers the rest of haus: canonical forms, `std/time` checks, the official profiles, decoding with a schema, both JSON mappings, schema-file checks and the formatters. The value writers are compared byte for byte with Lean's layout writers, which are proven to read back. (Python has no layout writers yet; its canonical form is compared.)

When the implementations disagree, the fuzzer cuts the input down to the smallest one that still disagrees. It runs in CI on every pull request with a new random seed, and much longer every night.

Some of the bugs it found, all fixed:

- Rust's stream reader crashed on input ending in `/`.
- The stream readers accepted a byte order mark after a comma.
- Go's `strconv.ParseFloat` rounds number literals of more than 800 significant digits wrongly. Go now rounds those exactly.
- Roc's `std/time` check accepted durations with more than about 309 digits, too large for a float. It now uses exact integers.
- Go's formatter moved comments: a comment after a multi-line comment ended up behind the entry, and a blank line before a payload's closing `}` was lost.
- TypeScript and Effect overflowed the stack on a schema whose record reaches its own record case by name.
- Rust had no nesting limit for types in schema files.
- Bindings reported different error codes for the same mistake, such as `"""` used as a field key.

**More:** how the fuzzer works and the full list of findings, in [`fuzz/README.md`](https://github.com/betalyra/haus-fmt/blob/main/fuzz/README.md); the [conformance suite](https://github.com/betalyra/haus-fmt/tree/main/test-suite).

## Safe to accept

haus is meant to be read from sources you don't control: a request body, a file a user uploaded, a message from another service. A parser that follows the spec gives such input no way to make it slow, run out of memory or show something other than what the file holds.

### Limits

Every parser enforces these while it reads, not afterwards:

| Limit | Default |
|---|---|
| Nesting depth (records, arrays, payloads) | 256 |
| Characters in one number literal | 1000 |
| Hex digits in one hex literal | 829 |
| Absolute exponent | 6144 |
| Characters in one string, record key or tag, or between the quotes of a byte string | 16 Mi (16,777,216) |
| Characters in one top-level value of a stream (stream readers only) | 64 Mi (67,108,864) |

All of them can be configured. With the defaults, every parser accepts every input within them, so a file one binding accepts, the others accept too. A binding that can't go as deep as you ask (because it uses the call stack) rejects the setting with an error that names its maximum, rather than crash on deep input.

### Linear time

Parsing takes time linear in the input, for any input within the limits, including input crafted against a particular implementation. Duplicate keys are found with a sorted structure or a hash table seeded at random, never by comparing each key with every other.

Decoding with a schema is linear too, whatever the schema. A variant's case is found by looking up its tag, never by trying cases in turn. Each decode has a work budget proportional to the input. Schemas can't define types that grow without bound.

### What a file can't contain

- **No hidden text.** Raw bidi control characters are rejected everywhere, in strings and comments too ([`bidi-control`](/docs/errors#bidi-control)), so a file can't display differently from what it contains. The same goes for raw control characters other than tab and line breaks, which could rewrite a terminal ([`control-character`](/docs/errors#control-character)). Inside a string, write them as escapes: `"\u{202E}"`.
- **No duplicate keys.** `{ admin: False, admin: True }` is an error ([`duplicate-key`](/docs/errors#duplicate-key)), not "the last one wins".
- **No invalid UTF-8**, and no lone surrogates.
- **No code and no references.** There are no includes, anchors or remote schemas. Parsing never opens a file or touches the network. A tag like `Shipped { … }` is data: bindings never turn it into a class or a function call. A key such as `__proto__` never reaches an object's prototype.

And a parser never repairs input. It stops at the first error, because two parsers that repair differently disagree about what a file says.

### Secrets

A schema can mark a value `Secret`:

```haus-schema
type Config = { host: String, apiKey: Secret String }
```

The binding decodes `apiKey` into a type that prints as something like `<redacted>` in logs, debug output and JSON, and gives the value out only when you ask for it explicitly. An error inside a secret names its place and type, never the value. `Secret` protects against accidental leaks in your program. It is not encryption: the file holds the value in full. The tour [Config and secrets](/docs/tours/secrets) shows it in use.

### Error codes

Every error has a code, such as `nesting-too-deep` or `duplicate-key`. For an input with one mistake, every binding reports the same code; the conformance suite checks it. Messages differ between bindings and may change. Codes are stable. See [Error codes](/docs/errors).

### Taking haus from untrusted sources

1. **Keep the default limits**, or lower them. Raise them only for input you trust.
2. **Decode with a schema** that lists the types you expect. Use `closed` where an unknown field or case should be an error. In an open variant, an unknown case keeps its raw data: treat it as untrusted, like the rest of the input.
3. **Read network streams in strict mode**, so a cut-off last value is an error and not a shorter number ([`stream-truncated`](/docs/errors#stream-truncated)).
4. **Mark passwords and keys `Secret`**, so they stay out of your logs and error messages.
5. **Act on error codes**, not on messages.
6. **Sign the exact bytes, or the canonical form.** Then equal values verify whatever their layout.
7. **Don't publish the hash of a document with private content.** The hash is unkeyed: anyone who can guess the content can confirm the guess. Use a keyed hash (HMAC), or keep the hash as private as the data.

**More:** the rules in full, in the specification: [§4 Strings and Unicode](/docs/spec#4-strings-and-unicode), [§7 Limits](/docs/spec#7-limits), [§9 Security considerations](/docs/spec#9-security-considerations), and [Secrets in §15](/docs/spec#15-decoding-with-a-schema).
