# haus-fmt-geo

The haus schema package `@haus-fmt/geo` for Rust: points and boxes on the earth, WGS 84, `LatLng(52.52, 13.405)`.

```toml
[dependencies]
haus-fmt = "0.2"                # imported as haus
haus-fmt-geo = "1"

[build-dependencies]
haus-fmt-build = "0.2"
```

> ⚠️ haus is a draft. Everything may still change.

Import its types in your schema like any other package's:

```haus
import @haus-fmt/geo (LatLng)
```

The schema gives the shape; the profile says which values are valid. Register
its codecs in `build.rs`, and values that break the rule are rejected when
decoding. Without them the build warns (`missing-codec`).

```rust
haus_build::Config::new()
    .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")
    .codec("@haus-fmt/geo@1#BBox", "haus_geo::Wgs84BBox")
    .compile("app.schema.haus")?;
```

| Codec | For | Rust type |
|---|---|---|
| `haus_geo::Wgs84` | `LatLng` | `Point` (`lat()`, `lng()`) |
| `haus_geo::Wgs84BBox` | `BBox` | `Bounds` (`sw()`, `ne()`, `crosses_antimeridian()`) |

More: [haus for Rust](https://github.com/betalyra/haus-fmt/tree/main/rust).
