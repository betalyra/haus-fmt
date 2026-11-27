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

The schema gives the shape; the package's rule, `iso` for `Currency` (and so
for `Money`), says which values are valid. The crate carries the rule
(`haus_money::rules::Iso`), and the generated code checks it wherever a
`Currency` is decoded or encoded, before any codec: `Money(19.90, Bitcoin)`
is rejected (`codec-rejected`) with or without codecs. Its codecs are
optional and give you Rust types for the values the rule accepts:

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
