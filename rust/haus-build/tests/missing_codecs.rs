//! `missing-codec` (spec §13.4) in the generators: an application's schema
//! reaches a type that an official profile has a rule for, and no codec is
//! set for its id.

use haus::ErrorCode;
use haus_build::roc::RocConfig;
use haus_build::{Config, Explicit, Options};
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
fn rust_codecs() {
    let packages = Explicit::new().package(repo("extensions/money")).unwrap();
    let options = Options { packages: &packages, ..Options::default() };
    let schema = Schema::parse_with("import @haus-fmt/money (Money)\ntype Order = { total: Money }", &options).unwrap();
    let missing = |config: Config| ids(&config.missing_codecs(&schema));
    assert_eq!(missing(Config::new()), ["@haus-fmt/money@1#Currency"]);
    assert_eq!(missing(Config::new().codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")), [""; 0]);
    // A codec for Money covers its Currency.
    assert_eq!(missing(Config::new().codec("@haus-fmt/money@1#Money", "haus_money::Iso")), [""; 0]);
}

#[test]
fn roc_codecs() {
    let config = RocConfig::new().package(repo("extensions/geo"), "geo").package(repo("extensions/money"), "money");
    let schema = repo("examples/order.schema.haus");
    let order = |config: &RocConfig| ids(&config.modules_and_warnings(&schema, "Order", "order").unwrap().1);
    assert_eq!(order(&config), ["@haus-fmt/geo@1#LatLng", "@haus-fmt/money@1#Currency"]);
    let config = config.codec("@haus-fmt/geo@1#LatLng", "geo.Wgs84").codec("@haus-fmt/money@1#Money", "money.Iso");
    assert_eq!(order(&config), [""; 0]);
}
