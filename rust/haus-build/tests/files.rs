//! Schemas with imports, in both generators: an application's schema split
//! into files, the `@major` of package imports, and codecs for types used
//! inside packages' types (spec §13.3, §13.4). haus-fmt-schema loads and
//! checks the imports; the generators make a module of each file.
#![cfg(unix)]

use haus::ErrorCode;
use haus_build::roc::RocConfig;
use haus_build::{Codec, Config, Explicit, Options, Packages};
use std::fs;
use std::path::Path;
use std::process::Command;

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn package(dir: &Path, name: &str, version: &str, schema: &str) {
    write(&dir.join("package.haus"), &format!("{{ name: {name:?}, version: {version:?} }}"));
    write(&dir.join("schema.haus"), schema);
}

/// An application's schema in `app/main`, with files in `app/billing`,
/// `app/shipping` (both `common.schema.haus`) and `app/shared`.
fn app(root: &Path) -> std::path::PathBuf {
    let main = root.join("app/main/order.schema.haus");
    write(
        &main,
        "import ../billing/common (Address)\nimport ../shipping/common (Parcel)\nimport ../shared/money (Money, Page)\n\
         type Order = { bill: Address, ship: Parcel, total: Money, lines: Page Money }",
    );
    write(
        &root.join("app/billing/common.schema.haus"),
        "import ../shared/money (Money)\ntype Address = { street: String, owes?: Money }",
    );
    write(
        &root.join("app/shipping/common.schema.haus"),
        "type Address = { line: String }\ntype Parcel = { to: Address }",
    );
    write(
        &root.join("app/shared/money.schema.haus"),
        "type Money = { amount: Decimal }\ntype Page a = { items: Array a }",
    );
    main
}

/// The Rust code for the schema at `path`, packages given explicitly, in crates named after them.
fn rust(config: &Config, path: &Path, packages: &Explicit) -> Result<String, haus_build::Error> {
    let krate = |name: &str| name.trim_start_matches('@').replace(['/', '-', '.'], "_");
    config.generate(path, &Options { packages, ..Options::default() }, &krate)
}

#[test]
fn an_application_split_into_files_in_rust() {
    let dir = tempfile::tempdir().unwrap();
    let code = rust(&Config::new(), &app(dir.path()), &Explicit::new()).unwrap();
    for part in [
        "pub mod up_billing_common {",
        "pub mod up_shipping_common {",
        "pub mod up_shared_money {",
        "pub bill: self::up_billing_common::Address,",
        "pub ship: self::up_shipping_common::Parcel,",
        "pub lines: self::up_shared_money::Page<self::up_shared_money::Money>,",
        "pub owes: ::std::option::Option<super::up_shared_money::Money>,",
        // Ids from the root file's directory: different files, different ids.
        "\"order#Order\"",
        "\"../billing/common#Address\"",
        "\"../shipping/common#Address\"",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }
    assert_eq!(code.matches("pub mod up_shared_money {").count(), 1, "{code}");
}

#[test]
fn an_application_split_into_files_in_roc() {
    let dir = tempfile::tempdir().unwrap();
    let modules = RocConfig::new().modules(&app(dir.path()), "Order", "order").unwrap();
    let names: Vec<&str> = modules.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["Order", "OrderUpBillingCommon", "OrderUpSharedMoney", "OrderUpShippingCommon"]);
    let code = |name: &str| modules.iter().find(|(n, _)| n == name).map(|(_, c)| c.as_str()).unwrap();
    let order = code("Order");
    for part in [
        "import OrderUpBillingCommon\nimport OrderUpShippingCommon\nimport OrderUpSharedMoney\n",
        "bill : OrderUpBillingCommon.Address",
        "lines : OrderUpSharedMoney.Page(OrderUpSharedMoney.Money)",
        "OrderUpSharedMoney.decode_page(x1, OrderUpSharedMoney.decode_money)",
    ] {
        assert!(order.contains(part), "{part}\n{order}");
    }
    let billing = code("OrderUpBillingCommon");
    assert!(billing.contains("import OrderUpSharedMoney\n"), "{billing}");
    assert!(billing.contains("haus type `../billing/common#Address`"), "{billing}");
    assert!(code("OrderUpShippingCommon").contains("haus type `../shipping/common#Address`"));
    // One module has no room for the others.
    let e = RocConfig::new().generate(&app(dir.path()), "Order", "order").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportUnavailable, "{e}");
}

#[test]
fn haus_gen_writes_the_modules_of_imported_files_next_to_out() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("roc/Order.roc");
    fs::create_dir_all(out.parent().unwrap()).unwrap();
    let haus_gen = |args: &[&str]| Command::new(env!("CARGO_BIN_EXE_haus-gen")).args(args).output().unwrap();
    let schema = app(dir.path());
    let run = haus_gen(&["roc", schema.to_str().unwrap(), "--module", "Order", "--out", out.to_str().unwrap()]);
    assert!(run.status.success(), "{}", String::from_utf8_lossy(&run.stderr));
    for module in ["Order", "OrderUpBillingCommon", "OrderUpShippingCommon", "OrderUpSharedMoney"] {
        assert!(dir.path().join(format!("roc/{module}.roc")).is_file(), "{module}");
    }
    // Without --out there is nowhere to write them.
    let run = haus_gen(&["roc", schema.to_str().unwrap(), "--module", "Order"]);
    assert!(!run.status.success());
    assert!(String::from_utf8_lossy(&run.stderr).contains("give --out"));
}

#[test]
fn import_cycles_between_files() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a.schema.haus");
    write(&a, "import ./b (B)\ntype A = { b?: B }");
    write(&dir.path().join("b.schema.haus"), "import ./a (A)\ntype B = { a?: A }");
    let e = rust(&Config::new(), &a, &Explicit::new()).unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportCycle, "{e}");
    let e = RocConfig::new().modules(&a, "A", "a").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportCycle, "{e}");
}

#[test]
fn a_file_outside_packages_cant_reach_into_one() {
    let dir = tempfile::tempdir().unwrap();
    package(&dir.path().join("ids"), "@acme/ids", "1.0.0", "type Id = Int");
    write(&dir.path().join("ids/x.schema.haus"), "type Id = Int");
    let a = dir.path().join("a.schema.haus");
    write(&a, "import ./ids/x (Id)\ntype A = Id");
    let e = rust(&Config::new(), &a, &Explicit::new()).unwrap_err();
    assert_eq!(e.code(), ErrorCode::PackagePath, "{e}");
    let e = RocConfig::new().modules(&a, "A", "a").unwrap_err();
    assert_eq!(e.code(), ErrorCode::PackagePath, "{e}");
}

#[test]
fn the_major_version_of_an_import_is_checked() {
    let dir = tempfile::tempdir().unwrap();
    package(&dir.path().join("x"), "@acme/x", "1.0.0", "type X = Int");
    let a = dir.path().join("a.schema.haus");
    write(&a, "import @acme/x@7 (X)\ntype A = X");
    let e = RocConfig::new().package(dir.path().join("x"), "x").modules(&a, "A", "a").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportVersion, "{e}");
    assert!(e.to_string().contains("@acme/x@7 wants major version 7, but version 1.0.0 was found"), "{e}");
    let packages = Explicit::new().package(dir.path().join("x")).unwrap();
    let e = rust(&Config::new(), &a, &packages).unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportVersion, "{e}");
    let text = "import @acme/x@7 (X)\ntype A = X";
    let cargo = Packages::none().with(&dir.path().join("x"), "acme_x").unwrap();
    assert_eq!(haus_build::generate(text, "a", &[], &cargo).unwrap_err().code(), ErrorCode::ImportVersion);
    write(&a, "import @acme/x@1 (X)\ntype A = X");
    RocConfig::new().package(dir.path().join("x"), "x").modules(&a, "A", "a").unwrap();
}

#[test]
fn roc_messages_are_about_the_packages_given() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a.schema.haus");
    write(&a, "import @acme/x (X)\ntype A = X");
    let e = RocConfig::new().modules(&a, "A", "a").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportNotFound, "{e}");
    let message = e.to_string();
    assert!(message.contains("not among the packages given"), "{message}");
    assert!(!message.contains("crate") && !message.contains("build script"), "{message}");
    let e = haus_build::roc::generate("import @acme/x (X)\ntype A = X", "A", "a", &[], &Packages::none()).unwrap_err();
    assert!(!e.to_string().contains("crate"), "{e}");
}

#[test]
fn roc_finds_packages_in_folders() {
    let dir = tempfile::tempdir().unwrap();
    package(&dir.path().join("vendor/whatever"), "@acme/ids", "2.0.0", "type Id = Int");
    let a = dir.path().join("a.schema.haus");
    write(&a, "import @acme/ids@2 (Id)\ntype A = { id: Id }");
    let modules = RocConfig::new().folder(dir.path().join("vendor")).modules(&a, "A", "a").unwrap();
    assert!(modules[0].1.contains("import ids.AcmeIds\n"), "{}", modules[0].1);
}

#[test]
fn the_version_of_a_package_json_is_the_manifests() {
    let dir = tempfile::tempdir().unwrap();
    package(&dir.path().join("x"), "@acme/x", "1.0.0", "type X = Int");
    write(&dir.path().join("x/package.json"), r#"{ "name": "@acme/x", "version": "1.2.0" }"#);
    let a = dir.path().join("a.schema.haus");
    write(&a, "import @acme/x (X)\ntype A = X");
    let e = RocConfig::new().package(dir.path().join("x"), "x").modules(&a, "A", "a").unwrap_err();
    assert_eq!(e.code(), ErrorCode::PackageVersion, "{e}");
    assert!(e.to_string().contains("1.0.0") && e.to_string().contains("1.2.0"), "{e}");
}

/// `@acme/orders` uses `@haus-fmt/money`'s Money; the app imports Order.
fn orders(root: &Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let (orders, money) = (root.join("orders"), root.join("money"));
    package(&money, "@haus-fmt/money", "1.0.0", "type Money = { amount: Decimal }");
    package(&orders, "@acme/orders", "1.0.0", "import @haus-fmt/money@1 (Money)\ntype Order = { total: Money }");
    (orders, money)
}

#[test]
fn a_codec_cant_reach_into_another_crates_type() {
    let dir = tempfile::tempdir().unwrap();
    let (orders, money) = orders(dir.path());
    let cargo = Packages::none().with(&orders, "haus_orders").unwrap().with(&money, "haus_money").unwrap();
    let codec = Codec { id: "@haus-fmt/money@1#Money".into(), path: "crate::Cents".into() };
    let generate = |text: &str| haus_build::generate(text, "app", std::slice::from_ref(&codec), &cargo);
    let e = generate("import @acme/orders@1 (Order)\ntype A = { order: Order }").unwrap_err();
    assert_eq!(e.code(), ErrorCode::CodecUnreachable, "{e}");
    assert_eq!(
        e.to_string(),
        "@haus-fmt/money@1#Money is used inside @acme/orders@1#Order, which haus_orders generates; \
         codecs can't reach into other crates' types yet"
    );
    // Imported directly too: still not applied inside Order.
    let e = generate(
        "import @acme/orders@1 (Order)\nimport @haus-fmt/money@1 (Money)\ntype A = { order: Order, m: Money }",
    )
    .unwrap_err();
    assert_eq!(e.code(), ErrorCode::CodecUnreachable, "{e}");
    // Where the app's own code has the type, the codec applies.
    generate("import @haus-fmt/money@1 (Money)\ntype A = { m: Money }").unwrap();
    // A type the schema doesn't have at all.
    let e = haus_build::generate(
        "type A = Int",
        "app",
        &[Codec { id: "@haus-fmt/money@1#Money".into(), path: "crate::Cents".into() }],
        &cargo,
    )
    .unwrap_err();
    assert!(e.to_string().contains("the schema has no such type"), "{e}");
}

#[test]
fn a_codec_cant_reach_into_another_packages_roc_module() {
    let dir = tempfile::tempdir().unwrap();
    let (orders, money) = orders(dir.path());
    let a = dir.path().join("a.schema.haus");
    write(&a, "import @acme/orders@1 (Order)\ntype A = { order: Order }");
    let e = RocConfig::new()
        .package(&orders, "orders")
        .package(&money, "money")
        .codec("@haus-fmt/money@1#Money", "Cents")
        .modules(&a, "A", "a")
        .unwrap_err();
    assert_eq!(e.code(), ErrorCode::CodecUnreachable, "{e}");
    assert!(
        e.to_string().ends_with(
            "@haus-fmt/money@1#Money is used inside @acme/orders@1#Order, which the Roc module orders.AcmeOrders \
             generates; codecs can't reach into other packages' modules yet"
        ),
        "{e}"
    );
}

#[test]
fn a_codec_for_a_type_of_an_imported_file() {
    let dir = tempfile::tempdir().unwrap();
    let main = app(dir.path());
    let code = rust(&Config::new().codec("../shared/money#Money", "crate::Cents"), &main, &Explicit::new()).unwrap();
    assert!(code.contains("pub owes: ::std::option::Option<<crate::Cents as ::haus::Codec>::Target>"), "{code}");
    let modules = RocConfig::new().codec("../shared/money#Money", "Cents").modules(&main, "Order", "order").unwrap();
    for (name, code) in &modules {
        let uses = code.contains("Cents.decode");
        assert_eq!(code.contains("import Cents\n"), uses, "{name}: {code}");
    }
    assert!(modules.iter().any(|(_, code)| code.contains("import Cents\n")));
}
