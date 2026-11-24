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

The schema gives the shape; the profile says which values are valid. Register
its codecs in `build.rs`, and values that break the rule are rejected when
decoding. Without them the build warns (`missing-codec`).

```rust
haus_build::Config::new()
    .codec("@haus-fmt/uuid@1#Uuid", "haus_uuid::Rfc9562")
    .compile("app.schema.haus")?;
```

| Codec | For | Rust type |
|---|---|---|
| `haus_uuid::Rfc9562` | `Uuid` | `UuidText` (`as_str()`): the text, lowercase, any version |

More: [haus for Rust](https://github.com/betalyra/haus-fmt/tree/main/rust).
