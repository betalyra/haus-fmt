//! `missing-codec` (spec §13.4, "A profile without its codec"): a type that
//! an official profile has a rule for, reached without a codec for its id.

use haus::ErrorCode;
use haus_schema::{Explicit, Options, Schema, profiles};
use std::path::{Path, PathBuf};

fn repo(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(path)
}

fn schema(text: &str) -> Schema {
    let packages = Explicit::new().package(repo("extensions/money")).unwrap().package(repo("extensions/geo")).unwrap();
    Schema::parse_with(text, &Options { packages: &packages, ..Options::default() }).unwrap_or_else(|e| panic!("{e}"))
}

/// The ids the warnings name, in order, each checked for its code and place.
fn missing(schema: &Schema, codecs: &[&str]) -> Vec<String> {
    schema
        .missing_codecs(codecs.iter().copied())
        .iter()
        .map(|w| {
            assert_eq!(w.code(), Some(ErrorCode::MissingCodec));
            assert_eq!((w.position(), w.path()), (None, None));
            w.reason().split(' ').next().unwrap().to_owned()
        })
        .collect()
}

const MONEY: &str = "@haus-fmt/money@1#Money";
const CURRENCY: &str = "@haus-fmt/money@1#Currency";
const LATLNG: &str = "@haus-fmt/geo@1#LatLng";
const BBOX: &str = "@haus-fmt/geo@1#BBox";

const ORDER: &str = "import @haus-fmt/money (Money)\nimport @haus-fmt/geo (LatLng, BBox)\n\
                     type Order = { total: Money, at?: Maybe LatLng, area: Array BBox }";

#[test]
fn each_listed_type_once() {
    let s = schema(ORDER);
    // Money reaches Currency; Money itself has no rule of its own. BBox reaches LatLng too: once.
    assert_eq!(missing(&s, &[]), [BBOX, LATLNG, CURRENCY]);
    assert_eq!(
        s.missing_codecs([])[2].reason(),
        "@haus-fmt/money@1#Currency has profiles (iso), but no codec is set for it: \
         its values are checked for their shape only"
    );
}

#[test]
fn not_with_its_codec_nor_inside_a_type_with_one() {
    let s = schema(ORDER);
    assert_eq!(missing(&s, &[CURRENCY, LATLNG, BBOX]), Vec::<String>::new());
    // A codec for Money covers its Currency.
    assert_eq!(missing(&s, &[MONEY, LATLNG, BBOX]), Vec::<String>::new());
    // A codec for BBox covers the LatLngs inside it, not the one of `at`.
    assert_eq!(missing(&s, &[MONEY, BBOX]), [LATLNG]);
}

#[test]
fn only_types_the_files_definitions_reach() {
    // BBox is imported, but no definition uses it.
    let s = schema("import @haus-fmt/geo (LatLng, BBox)\ntype Root = { at: LatLng }");
    assert_eq!(missing(&s, &[]), [LATLNG]);
    // From one type.
    let s = schema(ORDER);
    let order = s.instance(s.definition("Order").unwrap().template);
    let ids: Vec<String> = s
        .missing_codecs_from([&order.body], [MONEY])
        .iter()
        .map(|w| w.reason().split(' ').next().unwrap().to_owned())
        .collect();
    assert_eq!(ids, [BBOX, LATLNG]);
    // Through generic types, variants, arrays, maps and secrets.
    let s = schema(
        "import @haus-fmt/money (Currency)\n\
         type Page a = { items: Array a }\n\
         type Root = < A (Page (Map (Secret Currency))) | B >",
    );
    assert_eq!(missing(&s, &[]), [CURRENCY]);
    let s = Schema::parse("import std/time (Date)\ntype Root = { d: Date }").unwrap();
    assert_eq!(missing(&s, &[]), Vec::<String>::new());
}

#[test]
fn the_table() {
    assert_eq!(profiles::profiles(CURRENCY), Some("iso"));
    assert_eq!(profiles::profiles(BBOX), Some("wgs84"));
    for id in [MONEY, "@haus-fmt/money@2#Currency", "@acme/money@1#Currency", "std/time#Date", "Currency"] {
        assert_eq!(profiles::profiles(id), None, "{id}");
    }
    assert_eq!(profiles::package_profiles("@haus-fmt/geo").as_deref(), Some("wgs84"));
    assert_eq!(profiles::package_profiles("@haus-fmt/money").as_deref(), Some("iso"));
    assert_eq!(profiles::package_profiles("@acme/money"), None);
}

#[test]
fn a_note_per_import_for_tools_without_codecs() {
    let text = "import std/time (Date)\nimport @haus-fmt/money (Money)\nimport @haus-fmt/geo@1 (LatLng)\n\
                import @acme/ids (Id)\ntype R = Int";
    let notes = profiles::unchecked_profiles(text);
    let shown: Vec<(Option<(usize, usize)>, &str)> = notes.iter().map(|n| (n.position(), n.reason())).collect();
    assert_eq!(
        shown,
        [
            (
                Some((2, 1)),
                "the rules of @haus-fmt/money (profiles: iso) are not checked here; your application checks them by adding a codec"
            ),
            (
                Some((3, 1)),
                "the rules of @haus-fmt/geo (profiles: wgs84) are not checked here; your application checks them by adding a codec"
            ),
        ]
    );
    assert!(notes.iter().all(|n| n.code() == Some(ErrorCode::MissingCodec)));
    assert_eq!(profiles::unchecked_profiles("import @haus-fmt/money ("), vec![]);
}
