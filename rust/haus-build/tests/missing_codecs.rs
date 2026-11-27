//! `missing-codec` (packages.md §7) in the generators: an application's
//! schema reaches a type whose package gives it a rule (its manifest's
//! `rules`), and the build has no implementation of it, nor takes the
//! package shape-only. A codec is no implementation of a rule (§6). And a
//! codec for a type that can't have one is a mistake of the configuration.

use haus::ErrorCode;
use haus_build::roc::RocConfig;
use haus_build::{Codec, Explicit, Options, PackageRule, Packages};
use haus_schema::Schema;
use std::path::{Path, PathBuf};

fn repo(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(path)
}

fn ids(warnings: &[haus_build::Warning]) -> Vec<String> {
    warnings
        .iter()
        .map(|w| {
            assert_eq!(w.code(), Some(ErrorCode::MissingCodec), "{w}");
            w.reason().split(' ').next().unwrap().to_owned()
        })
        .collect()
}

#[test]
fn a_rule_without_an_implementation_is_an_error() {
    let packages = Explicit::new().package(repo("extensions/money")).unwrap();
    let text = "import @haus-fmt/money (Money)\ntype Order = { total: Money }";
    // The money crate's documents are still profiles/iso.md, which the build leaves to `haus package check`.
    let options = Options { packages: &packages, rule_documents: false, ..Options::default() };
    let e = Schema::parse_with(text, &options).unwrap_err();
    assert_eq!(e.code(), Some(ErrorCode::MissingCodec));
    assert!(e.reason().starts_with("@haus-fmt/money@1#Currency has the rule iso"), "{e}");
    // Implemented, or the package taken shape-only.
    let rule = PackageRule { id: "@haus-fmt/money@1#Currency".into(), name: "iso".into(), check: |_| Ok(()) };
    assert!(Schema::parse_with(text, &Options { rules: &[rule], ..options }).is_ok());
    assert!(Schema::parse_with(text, &Options { shape_only: &["@haus-fmt/money"], ..options }).is_ok());
}

#[test]
fn a_codec_for_a_type_that_cant_have_one_is_rejected() {
    let codec = |id: &str| Codec { id: id.into(), path: "crate::C".into() };
    let generate = |text: &str, id: &str| haus_build::generate(text, "app", &[codec(id)], &Packages::none());
    let e = generate("type Entry = { at: Int }\ntype Log = Stream Entry", "app#Log").unwrap_err();
    assert_eq!((e.code(), e.reason().contains("Log is a Stream: set the codec for Entry")), (None, true), "{e}");
    let e = generate("type Pair a = { a: a }\ntype R = Pair Int", "app#Pair").unwrap_err();
    assert_eq!((e.code(), e.reason().contains("Pair a has parameters")), (None, true), "{e}");
    let e = generate("type R = Maybe Int", "prelude#Maybe").unwrap_err();
    assert_eq!((e.code(), e.reason().contains("Maybe has 1 parameter")), (None, true), "{e}");
    // A type without parameters can have one.
    assert!(generate("type Entry = { at: Int }\ntype Log = Stream Entry", "app#Entry").is_ok());
}

#[test]
fn roc_codecs() {
    let config = RocConfig::new().package(repo("extensions/geo"), "geo").package(repo("extensions/money"), "money");
    let schema = repo("examples/order.schema.haus");
    let order = |config: &RocConfig| ids(&config.modules_and_warnings(&schema, "Order", "order").unwrap().1);
    assert_eq!(order(&config), ["@haus-fmt/geo@1#LatLng", "@haus-fmt/money@1#Currency"]);
    // Roc applies a package's rule with the codecs its Roc package ships.
    let config =
        config.codec("@haus-fmt/geo@1#LatLng", "geo.Wgs84").codec("@haus-fmt/money@1#Currency", "money.IsoCurrency");
    assert_eq!(order(&config), [""; 0]);
}
