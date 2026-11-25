//! The build-script side of schema packages, with the variables Cargo sets
//! (spec §13.3): a package crate's checks in `haus_build::package()` (its
//! version is its manifest's, its `links` is its library name), and a
//! dependent crate's (the version a package crate gives, the `@major`); the
//! packages a package crate passes on (`haus_graph`), for the codec closure
//! (spec §13.4).
//!
//! The variables are the process's, so this file has one test.
#![cfg(unix)]

use haus::ErrorCode;
use std::fs;
use std::path::Path;

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn set(key: &str, value: impl AsRef<std::ffi::OsStr>) {
    // SAFETY: the only test of this binary; nothing else reads the environment meanwhile.
    unsafe { std::env::set_var(key, value) }
}

fn unset(key: &str) {
    // SAFETY: as for `set`.
    unsafe { std::env::remove_var(key) }
}

#[test]
fn package_crates_and_their_dependents() {
    let dir = tempfile::tempdir().unwrap();
    let (ids, app, out) = (dir.path().join("ids"), dir.path().join("app"), dir.path().join("out"));
    write(&ids.join("package.haus"), "{ name: \"@acme/ids\", version: \"1.0.0\" }");
    write(&ids.join("schema.haus"), "type Id = Int");
    write(
        &ids.join("Cargo.toml"),
        "[package]\nname = \"acme-ids\"\nversion = \"1.0.0\"\nlinks = \"haus_ids\"\n\n[lib] # the library\nname = \"haus_ids\"\n",
    );
    fs::create_dir_all(&out).unwrap();
    set("OUT_DIR", &out);

    // The package crate's build script.
    set("CARGO_MANIFEST_DIR", &ids);
    set("CARGO_PKG_NAME", "acme-ids");
    set("CARGO_PKG_VERSION", "1.0.1");
    set("CARGO_MANIFEST_LINKS", "haus_ids");
    let e = haus_build::package().unwrap_err();
    assert_eq!(e.code().unwrap(), ErrorCode::PackageVersion, "{e}");
    assert!(e.to_string().contains("says version 1.0.0, its Cargo.toml 1.0.1"), "{e}");

    set("CARGO_PKG_VERSION", "1.0.0");
    set("CARGO_MANIFEST_LINKS", "acme_ids");
    let e = haus_build::package().unwrap_err();
    assert!(e.to_string().contains("acme-ids has links = \"acme_ids\", but its library is haus_ids"), "{e}");
    unset("CARGO_MANIFEST_LINKS");
    let e = haus_build::package().unwrap_err();
    assert!(e.to_string().contains("acme-ids has no links: add links = \"haus_ids\""), "{e}");

    set("CARGO_MANIFEST_LINKS", "haus_ids");
    haus_build::package().unwrap();
    assert!(fs::read_to_string(out.join("schema.rs")).unwrap().contains("@acme/ids@1#Id"));

    // A crate that depends on it: Cargo passes the package's metadata.
    unset("CARGO_MANIFEST_LINKS");
    write(&app.join("src/app.schema.haus"), "import @acme/ids@1 (Id)\ntype A = { id: Id }");
    set("CARGO_MANIFEST_DIR", &app);
    set("CARGO_PKG_NAME", "app");
    set("DEP_HAUS_IDS_HAUS_PACKAGE", &ids);
    set("DEP_HAUS_IDS_HAUS_CRATE", "haus_ids");
    set("DEP_HAUS_IDS_HAUS_VERSION", "1.1.0");
    let e = haus_build::Config::new().compile("src/app.schema.haus").unwrap_err();
    assert_eq!(e.code().unwrap(), ErrorCode::PackageVersion, "{e}");

    set("DEP_HAUS_IDS_HAUS_VERSION", "1.0.0");
    haus_build::Config::new().compile("src/app.schema.haus").unwrap();
    let code = fs::read_to_string(out.join("app.rs")).unwrap();
    assert!(code.contains("pub id: ::haus_ids::Id"), "{code}");
    assert!(code.contains("\"app/src/app#A\""), "{code}");

    write(&app.join("src/app.schema.haus"), "import @acme/ids@2 (Id)\ntype A = { id: Id }");
    let e = haus_build::Config::new().compile("src/app.schema.haus").unwrap_err();
    assert_eq!(e.code().unwrap(), ErrorCode::ImportVersion, "{e}");

    // A package crate that depends on ids: it re-exports its dependencies'
    // crates and passes on the packages its schema reaches (haus_graph).
    let (orders, orders_out) = (dir.path().join("orders"), dir.path().join("orders_out"));
    write(&orders.join("package.haus"), "{ name: \"@acme/orders\", version: \"2.0.0\" }");
    write(&orders.join("schema.haus"), "import @acme/ids@1 (Id, Tag)\ntype Order = { id: Id, tag: Tag }");
    write(
        &orders.join("Cargo.toml"),
        "[package]\nname = \"acme-orders\"\nversion = \"2.0.0\"\nlinks = \"haus_orders\"\n\n[lib]\nname = \"haus_orders\"\n",
    );
    write(&ids.join("schema.haus"), "type Id = Int\ntype Tag = { name: String }");
    fs::create_dir_all(&orders_out).unwrap();
    set("OUT_DIR", &orders_out);
    set("CARGO_MANIFEST_DIR", &orders);
    set("CARGO_PKG_NAME", "acme-orders");
    set("CARGO_PKG_VERSION", "2.0.0");
    set("CARGO_MANIFEST_LINKS", "haus_orders");
    haus_build::package().unwrap();
    let code = fs::read_to_string(orders_out.join("schema.rs")).unwrap();
    assert!(code.contains("pub mod __haus_deps {\n    pub use ::haus_ids;\n}"), "{code}");
    let graph = fs::read_to_string(orders_out.join("haus_graph.haus")).unwrap();
    let ids_dir = ids.canonicalize().unwrap();
    let entry = format!(
        "[{{ dir: {:?}, krate: \"haus_ids\", name: \"@acme/ids\", version: \"1.0.0\" }}]",
        ids_dir.display().to_string()
    );
    assert_eq!(graph, entry);

    // A crate that depends on orders only: ids is visible to orders' schema,
    // its crate named through orders, and a codec applies inside Order.
    unset("CARGO_MANIFEST_LINKS");
    ["PACKAGE", "CRATE", "VERSION"].iter().for_each(|k| unset(&format!("DEP_HAUS_IDS_HAUS_{k}")));
    set("DEP_HAUS_ORDERS_HAUS_PACKAGE", &orders);
    set("DEP_HAUS_ORDERS_HAUS_CRATE", "haus_orders");
    set("DEP_HAUS_ORDERS_HAUS_VERSION", "2.0.0");
    set("DEP_HAUS_ORDERS_HAUS_GRAPH", orders_out.join("haus_graph.haus"));
    set("OUT_DIR", &out);
    set("CARGO_MANIFEST_DIR", &app);
    set("CARGO_PKG_NAME", "app");
    write(&app.join("src/app.schema.haus"), "import @acme/orders@2 (Order)\ntype A = { order: Order }");
    haus_build::Config::new().codec("@acme/ids@1#Id", "crate::Code").compile("src/app.schema.haus").unwrap();
    let code = fs::read_to_string(out.join("app.rs")).unwrap();
    for part in [
        "pub order: self::acme_orders::Order,",
        "pub id: <crate::Code as ::haus::Codec>::Target,",
        "pub tag: ::haus_orders::__haus_deps::haus_ids::Tag,",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }
    // Its own files import only its dependencies.
    write(&app.join("src/app.schema.haus"), "import @acme/ids@1 (Id)\ntype A = { id: Id }");
    let e = haus_build::Config::new().compile("src/app.schema.haus").unwrap_err();
    assert_eq!(e.code().unwrap(), ErrorCode::UndeclaredPackage, "{e}");
    assert!(e.to_string().contains("@acme/ids is a dependency of haus_orders, not of this crate"), "{e}");
}
