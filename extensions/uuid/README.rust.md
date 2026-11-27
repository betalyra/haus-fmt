# haus-fmt-uuid

The haus schema package `@haus-fmt/uuid` for Rust: universally unique identifiers, RFC 9562.

```toml
[dependencies]
haus-fmt = "0.2"                # imported as haus
haus-fmt-uuid = "1"

[build-dependencies]
haus-fmt-build = "0.2"
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/uuid (Uuid)
```

The schema gives the shape; the package's rule, `rfc9562` for `Uuid`, says
which values are valid. The crate carries the rule
(`haus_uuid::rules::Rfc9562`), and the generated code checks it wherever a
`Uuid` is decoded or encoded, before any codec: an uppercase UUID is rejected
(`codec-rejected`) with or without the codec. The codec is optional and
gives you a Rust type for the values the rule accepts:

```rust
haus_build::Config::new()
    .codec("@haus-fmt/uuid@1#Uuid", "haus_uuid::Rfc9562")
    .compile("app.schema.haus")?;
```

| Codec | For | Rust type |
|---|---|---|
| `haus_uuid::Rfc9562` | `Uuid` | `UuidText` (`as_str()`): the text, lowercase, any version |

More: [haus for Rust](https://github.com/betalyra/haus-fmt/tree/main/rust).
