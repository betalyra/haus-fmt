# haus-fmt-money

The haus schema package `@haus-fmt/money` for Rust: exact amounts with a currency, `Money(19.90, EUR)`.

```toml
[dependencies]
haus-fmt = "0.2"                # imported as haus
haus-fmt-money = "1"

[build-dependencies]
haus-fmt-build = "0.2"
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/money (Money)
```

The schema gives the shape; the profile says which values are valid. Register
its codecs in `build.rs`, and values that break the rule are rejected when
decoding. Without them the build warns (`missing-codec`).

```rust
haus_build::Config::new()
    .codec("@haus-fmt/money@1#Money", "haus_money::Iso")
    .codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")
    .compile("app.schema.haus")?;
```

| Codec | For | Rust type |
|---|---|---|
| `haus_money::Iso` | `Money` | `IsoMoney { amount: Decimal, currency: CurrencyCode }`: the exact amount, scale kept |
| `haus_money::IsoCurrency` | `Currency` | `CurrencyCode`: three letters A–Z |

More: [haus for Rust](https://github.com/betalyra/haus-fmt/tree/main/rust).
