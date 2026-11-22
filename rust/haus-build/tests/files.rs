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

/// The Rust code for the schema at `path`, packages given explicitly, in
/// crates named after them. The build's root is the directory above the
/// schema's, so that the app's `../` imports stay inside it (spec §13.3).
fn rust(config: &Config, path: &Path, packages: &Explicit) -> Result<String, haus_build::Error> {
    let krate = |name: &str| name.trim_start_matches('@').replace(['/', '-', '.'], "_");
    let root = path.parent().and_then(Path::parent);
    config.generate(path, &Options { packages, root, ..Options::default() }, &krate)
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
    let modules = RocConfig::new().root(dir.path()).modules(&app(dir.path()), "Order", "order").unwrap();
    let names: Vec<&str> = modules.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["Order", "OrderUpBillingCommon", "OrderUpSharedMoney", "OrderUpShippingCommon"]);
    let code = |name: &str| modules.iter().find(|(n, _)| n == name).map(|(_, c)| c.as_str()).unwrap();
    let order = code("Order");
    for part in [
        "import OrderUpBillingCommon\nimport OrderUpShippingCommon\nimport OrderUpSharedMoney\n",
        "bill : OrderUpBillingCommon.Address",
        "lines : OrderUpSharedMoney.Page(OrderUpSharedMoney.Money)",
        "OrderUpSharedMoney.decode_page(x1, OrderUpSharedMoney.read_value_money)",
    ] {
        assert!(order.contains(part), "{part}\n{order}");
    }
    let billing = code("OrderUpBillingCommon");
    assert!(billing.contains("import OrderUpSharedMoney\n"), "{billing}");
    assert!(billing.contains("haus type `../billing/common#Address`"), "{billing}");
    assert!(code("OrderUpShippingCommon").contains("haus type `../shipping/common#Address`"));
    // One module has no room for the others.
    let e = RocConfig::new().root(dir.path()).generate(&app(dir.path()), "Order", "order").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportUnavailable, "{e}");
    // By default the root is the schema's directory: ../billing goes above it.
    let e = RocConfig::new().modules(&app(dir.path()), "Order", "order").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportOutsideRoot, "{e}");
}

#[test]
fn haus_gen_writes_the_modules_of_imported_files_next_to_out() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("roc/Order.roc");
    fs::create_dir_all(out.parent().unwrap()).unwrap();
    let haus_gen = |args: &[&str]| Command::new(env!("CARGO_BIN_EXE_haus-gen")).args(args).output().unwrap();
    let schema = app(dir.path());
    let root = dir.path().to_str().unwrap();
    let run = haus_gen(&[
        "roc",
        schema.to_str().unwrap(),
        "--module",
        "Order",
        "--root",
        root,
        "--out",
        out.to_str().unwrap(),
    ]);
    assert!(run.status.success(), "{}", String::from_utf8_lossy(&run.stderr));
    for module in ["Order", "OrderUpBillingCommon", "OrderUpShippingCommon", "OrderUpSharedMoney"] {
        assert!(dir.path().join(format!("roc/{module}.roc")).is_file(), "{module}");
    }
    // Without --out there is nowhere to write them.
    let run = haus_gen(&["roc", schema.to_str().unwrap(), "--module", "Order", "--root", root]);
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

/// `@acme/orders` imports `@acme/ledger`, which imports `@haus-fmt/money`:
/// Money in ledger's types directly, in a field and in a variant's payloads,
/// and in orders' types two levels deep, in arrays. The app imports Order
/// and Customer, and Money.
fn closure(root: &Path) -> [std::path::PathBuf; 4] {
    let (orders, ledger, money) = (root.join("orders"), root.join("ledger"), root.join("money"));
    package(&money, "@haus-fmt/money", "1.0.0", "type Money = { amount: Decimal }\ntype Rate = { percent: Int }");
    package(
        &ledger,
        "@acme/ledger",
        "1.0.0",
        "import @haus-fmt/money@1 (Money, Rate)\ntype Entry = { amount: Money, note: Note }\n\
         type Note = { text: String }\ntype Move = < Credit Money | Debit { amount: Money } | Memo Note >\n\
         type Terms = { rate: Rate }",
    );
    package(
        &orders,
        "@acme/orders",
        "1.0.0",
        "import @acme/ledger@1 (Entry, Move, Terms)\n\
         type Order = { entries: Array Entry, moves: Array Move, terms: Terms, customer: Customer }\n\
         type Customer = { name: String }",
    );
    let a = root.join("a.schema.haus");
    write(
        &a,
        "import @acme/orders@1 (Order, Customer)\nimport @haus-fmt/money@1 (Money)\n\
         type A = { order: Order, customer: Customer, price: Money }",
    );
    [a, orders, ledger, money]
}

#[test]
fn a_codec_applies_inside_other_crates_types() {
    let dir = tempfile::tempdir().unwrap();
    let [a, orders, ledger, money] = closure(dir.path());
    let explicit = Explicit::new().package(&orders).unwrap().package(&ledger).unwrap().package(&money).unwrap();
    let code = rust(&Config::new().codec("@haus-fmt/money@1#Money", "crate::Cents"), &a, &explicit).unwrap();
    let cents = "<crate::Cents as ::haus::Codec>::Target";
    for part in [
        // The packages' types that contain Money are copied, each package's in a module.
        "pub order: self::acme_orders::Order,",
        "pub customer: ::acme_orders::Customer,",
        &format!("pub price: {cents},"),
        "pub mod acme_orders {",
        "pub entries: ::std::vec::Vec<super::acme_ledger::Entry>,",
        "pub moves: ::std::vec::Vec<super::acme_ledger::Move>,",
        // Their other types are the crates'.
        "pub terms: ::acme_ledger::Terms,",
        "pub customer: ::acme_orders::Customer,",
        "pub mod acme_ledger {",
        &format!("pub amount: {cents},"),
        "pub note: ::acme_ledger::Note,",
        &format!("Credit({cents}),"),
        &format!("Debit {{ amount: {cents} }},"),
        "Memo(::acme_ledger::Note),",
        // With the ids of the packages' types.
        "pub const ID: &'static str = \"@acme/orders@1#Order\";",
        "pub const ID: &'static str = \"@acme/ledger@1#Move\";",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }
    for kept in ["pub struct Customer", "pub struct Note", "pub struct Terms", "pub struct Rate", "pub struct Money"] {
        assert!(!code.contains(kept), "{kept}\n{code}");
    }
    assert_eq!(code.matches("pub mod ").count(), 2, "{code}");
    // Without the codec, nothing is copied.
    let plain = rust(&Config::new(), &a, &explicit).unwrap();
    assert!(plain.contains("pub order: ::acme_orders::Order,") && !plain.contains("pub mod "), "{plain}");
    // A codec only for a type inside packages' types: Rate is in ledger's Terms.
    let code = rust(&Config::new().codec("@haus-fmt/money@1#Rate", "crate::Percent"), &a, &explicit).unwrap();
    assert!(code.contains("pub terms: super::acme_ledger::Terms,"), "{code}");
    assert!(code.contains("pub rate: <crate::Percent as ::haus::Codec>::Target,"), "{code}");
    assert!(code.contains("pub entries: ::std::vec::Vec<::acme_ledger::Entry>,"), "{code}");
    // A type the schema doesn't have at all.
    let e = rust(&Config::new().codec("@haus-fmt/money@1#Coin", "crate::Cents"), &a, &explicit).unwrap_err();
    assert_eq!(e.code(), ErrorCode::UnknownType, "{e}");
    assert!(e.to_string().contains("the schema has no such type"), "{e}");
}

#[test]
fn a_crate_names_its_dependencies_dependencies_through_them() {
    let dir = tempfile::tempdir().unwrap();
    let [a, orders, ledger, money] = closure(dir.path());
    // The crate depends on orders and money; ledger is orders' dependency (its haus_graph).
    let cargo = Packages::none()
        .with(&orders, "haus_orders")
        .unwrap()
        .with(&money, "haus_money")
        .unwrap()
        .through(&ledger, "haus_orders::__haus_deps::haus_ledger")
        .unwrap();
    let codec = Codec { id: "@haus-fmt/money@1#Money".into(), path: "crate::Cents".into() };
    let text = fs::read_to_string(&a).unwrap();
    let code = haus_build::generate(&text, "app", std::slice::from_ref(&codec), &cargo).unwrap();
    for part in [
        "pub customer: ::haus_orders::Customer,",
        "pub terms: ::haus_orders::__haus_deps::haus_ledger::Terms,",
        "pub note: ::haus_orders::__haus_deps::haus_ledger::Note,",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }
    // Only packages' files import it: the crate's own files import its dependencies.
    let e = haus_build::generate("import @acme/ledger@1 (Note)\ntype B = Note", "app", &[], &cargo).unwrap_err();
    assert_eq!(e.code(), ErrorCode::UndeclaredPackage, "{e}");
    assert!(e.to_string().contains("@acme/ledger is a dependency of haus_orders, not of this crate"), "{e}");
}

#[test]
fn a_codec_applies_inside_other_packages_roc_modules() {
    let dir = tempfile::tempdir().unwrap();
    let [a, orders, ledger, money] = closure(dir.path());
    let modules = RocConfig::new()
        .json()
        .package(&orders, "orders")
        .package(&ledger, "ledger")
        .package(&money, "money")
        .codec("@haus-fmt/money@1#Money", "Cents")
        .modules(&a, "A", "a")
        .unwrap();
    let names: Vec<&str> = modules.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["A", "AAcmeOrders", "AAcmeLedger"]);
    let code = |name: &str| modules.iter().find(|(n, _)| n == name).map(|(_, c)| c.as_str()).unwrap();
    for (module, parts) in [
        (
            "A",
            &[
                "import AAcmeOrders\nimport orders.AcmeOrders\nimport money.HausFmtMoney\nimport Cents\n",
                "A_ : { order : AAcmeOrders.Order, customer : AcmeOrders.Customer, price : Cents.Target }",
            ][..],
        ),
        (
            "AAcmeOrders",
            &[
                "## Generated by haus-gen from @acme/orders@1. Don't edit.",
                "import orders.AcmeOrders\nimport AAcmeLedger\nimport ledger.AcmeLedger\n",
                "Order : { entries : List(AAcmeLedger.Entry), moves : List(AAcmeLedger.Move), terms : AcmeLedger.Terms, customer : AcmeOrders.Customer }",
                "AAcmeLedger.read_value_entry",
                "AcmeLedger.read_json_terms",
            ][..],
        ),
        (
            "AAcmeLedger",
            &[
                "import money.HausFmtMoney\nimport ledger.AcmeLedger\nimport Cents\n",
                "Entry : { amount : Cents.Target, note : AcmeLedger.Note }",
                "Move := [Credit(Cents.Target), Debit({ amount : Cents.Target }), Memo(AcmeLedger.Note), Unknown(Str, List(Value))]",
                "Decode.codec(x1, HausFmtMoney.read_value_money, Cents.decode)",
            ][..],
        ),
    ] {
        for part in parts {
            assert!(code(module).contains(part), "{part}\n{}", code(module));
        }
    }
    assert!(!code("AAcmeLedger").contains("Terms :") && !code("AAcmeOrders").contains("Customer :"));
}

#[test]
fn a_codec_for_a_type_of_an_imported_file() {
    let dir = tempfile::tempdir().unwrap();
    let main = app(dir.path());
    let code = rust(&Config::new().codec("../shared/money#Money", "crate::Cents"), &main, &Explicit::new()).unwrap();
    assert!(code.contains("pub owes: ::std::option::Option<<crate::Cents as ::haus::Codec>::Target>"), "{code}");
    let modules = RocConfig::new()
        .root(dir.path())
        .codec("../shared/money#Money", "Cents")
        .modules(&main, "Order", "order")
        .unwrap();
    for (name, code) in &modules {
        let uses = code.contains("Cents.decode");
        assert_eq!(code.contains("import Cents\n"), uses, "{name}: {code}");
    }
    assert!(modules.iter().any(|(_, code)| code.contains("import Cents\n")));
}

/// Spreads of imported types (spec §14): `main/order` spreads billing's
/// Address (whose `owes` is a Money that order doesn't import), shipping's
/// Parcel (whose `to` is shipping's Address, not the billing Address order
/// imports) and shipping's Status, a variant.
fn spreads(root: &Path) -> std::path::PathBuf {
    let main = app(root);
    write(
        &main,
        "import ../billing/common (Address)\nimport ../shipping/common (Parcel, Status)\n\
         type Invoice = { ...Address, number: Int }\ntype Shipment = closed { id: Int, ...Parcel }\n\
         type Tracking = < ...Status | Lost >",
    );
    write(
        &root.join("app/shipping/common.schema.haus"),
        "type Address = { line: String }\ntype Parcel = { to: Address }\ntype Status = < Packed | Sent { to: Address } >",
    );
    main
}

/// `@acme/base` has a record and a variant whose fields are `@haus-fmt/money`'s
/// Money, and spreads Money itself; the app spreads the first two and
/// imports nothing from money itself.
fn spread_package(root: &Path) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let (base, money) = (root.join("base"), root.join("money"));
    package(&money, "@haus-fmt/money", "1.0.0", "type Money = { amount: Decimal }");
    package(
        &base,
        "@acme/base",
        "1.0.0",
        "import @haus-fmt/money@1 (Money)\ntype Base = { id: Int, total: Money }\n\
         type Events = < Created | Paid { amount: Money } >\ntype Priced = { ...Money, label: String }",
    );
    let a = root.join("a.schema.haus");
    write(
        &a,
        "import @acme/base@1 (Base, Events)\ntype Order = { ...Base, note: String }\n\
         type Event = closed < ...Events | Shipped >",
    );
    (a, base, money)
}

#[test]
fn spreads_of_imported_types_in_rust() {
    let dir = tempfile::tempdir().unwrap();
    let code = rust(&Config::new(), &spreads(dir.path()), &Explicit::new()).unwrap();
    for part in [
        // The types of copied fields are those of the file they come from.
        "pub struct Invoice {\n    pub street: ::std::string::String,\n    pub owes: ::std::option::Option<self::up_shared_money::Money>,\n    pub number: ::haus::Int,\n}",
        "pub struct Shipment {\n    pub id: ::haus::Int,\n    pub to: self::up_shipping_common::Address,\n}",
        "r.closed(&[\"id\", \"to\"])?;",
        "pub enum Tracking {\n    Packed,\n    Sent { to: self::up_shipping_common::Address },\n    Lost,\n",
        // JSON too.
        "<self::up_shared_money::Money as ::haus::FromJson>::from_json_with",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }

    let (a, base, money) = spread_package(dir.path());
    let packages = Explicit::new().package(&base).unwrap().package(&money).unwrap();
    let code = rust(&Config::new(), &a, &packages).unwrap();
    for part in [
        "pub struct Order {\n    pub id: ::haus::Int,\n    pub total: ::haus_fmt_money::Money,\n    pub note: ::std::string::String,\n}",
        "pub enum Event {\n    Created,\n    Paid { amount: ::haus_fmt_money::Money },\n    Shipped,\n}",
        "<::haus_fmt_money::Money as ::haus::FromJson>::from_json_with",
        // Hints name types as the schema writes them.
        "record_payload(tag, args, __d, \"{ amount: Money }\")",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }

    // A package's own code, which spreads another package's type, and a crate that uses it.
    let cargo = Packages::none().with(&base, "haus_base").unwrap().with(&money, "haus_money").unwrap();
    let schema = fs::read_to_string(base.join("schema.haus")).unwrap();
    let own = haus_build::generate(&schema, "@acme/base@1", &[], &cargo).unwrap();
    let priced = "pub struct Priced {\n    pub amount: ::haus::Decimal,\n    pub label: ::std::string::String,\n}";
    assert!(own.contains(priced), "{own}");
    let user =
        haus_build::generate("import @acme/base@1 (Priced)\ntype A = { p: Priced }", "app", &[], &cargo).unwrap();
    assert!(user.contains("pub p: ::haus_base::Priced,"), "{user}");
}

#[test]
fn spreads_of_imported_types_in_roc() {
    let dir = tempfile::tempdir().unwrap();
    let modules = RocConfig::new().root(dir.path()).json().modules(&spreads(dir.path()), "Order", "order").unwrap();
    let order = &modules.iter().find(|(n, _)| n == "Order").unwrap().1;
    for part in [
        // Order imports no Money: the copied field brings its module in.
        "import OrderUpBillingCommon\nimport OrderUpShippingCommon\nimport OrderUpSharedMoney\n",
        "Invoice : { street : Str, owes : [Missing, Present(OrderUpSharedMoney.Money)], number : Int }",
        "Shipment : { id : Int, to : OrderUpShippingCommon.Address }",
        "Tracking := [Packed, Sent({ to : OrderUpShippingCommon.Address }), Lost, Unknown(Str, List(Value))]",
        "FromJson.optional_field(fs, \"owes\", OrderUpSharedMoney.read_json_money)",
    ] {
        assert!(order.contains(part), "{part}\n{order}");
    }

    let (a, base, money) = spread_package(dir.path());
    let modules =
        RocConfig::new().json().package(&base, "base").package(&money, "money").modules(&a, "A", "a").unwrap();
    let code = &modules[0].1;
    for part in [
        "import base.AcmeBase\nimport money.HausFmtMoney\n",
        "Order : { id : Int, total : HausFmtMoney.Money, note : Str }",
        "Event := [Created, Paid({ amount : HausFmtMoney.Money }), Shipped]",
        "ToJson.tagged_object(\"Paid\", e, [(\"amount\", ToJson.required(r.amount, HausFmtMoney.to_json_money))])",
    ] {
        assert!(code.contains(part), "{part}\n{code}");
    }
}

#[test]
fn a_spread_of_a_std_time_type_is_invalid() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a.schema.haus");
    for text in
        ["import std/time (Date)\ntype B = { ...Date, x: Int }", "import std/time (Date)\ntype B = < ...Date | X >"]
    {
        write(&a, text);
        let e = rust(&Config::new(), &a, &Explicit::new()).unwrap_err();
        assert_eq!(e.code(), ErrorCode::InvalidSpread, "{e}");
        let e = RocConfig::new().modules(&a, "A", "a").unwrap_err();
        assert_eq!(e.code(), ErrorCode::InvalidSpread, "{e}");
    }
}

/// Whether a `Maybe` of a package's type writes `None` as `null` (spec
/// §16.3) depends on that type's JSON, which the package's schema decides:
/// not only types written `Maybe` there (a `Maybe` that reaches itself, a
/// variant written in place that only looks like one, a `Secret` or a
/// generic type around one).
#[test]
fn a_maybe_of_a_package_type_whose_json_can_be_null_in_roc() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("p");
    package(
        &p,
        "@acme/p",
        "1.0.0",
        "type Opt = Maybe Int32\ntype Plain = Int32\ntype Loop = Maybe Loop\ntype Gen a = Maybe a\n\
         type InPlace = closed < None | Some Int32 >\ntype Hidden = Secret Opt\ntype Named = Opt",
    );
    let a = dir.path().join("a.schema.haus");
    write(
        &a,
        "import @acme/p@1 (Opt, Plain, Loop, Gen, InPlace, Hidden, Named)\n\
         type A = { opt: Maybe Opt, plain: Maybe Plain, loop: Maybe Loop, gen: Maybe (Gen Int32), \
         genPlain: Maybe (Gen Plain), inPlace: Maybe InPlace, hidden: Maybe Hidden, named: Maybe Named, held: Gen Opt }",
    );
    let modules = RocConfig::new().json().package(&p, "p").modules(&a, "A", "a").unwrap();
    let code = &modules[0].1;
    // Whether the field's writer writes `None` as `null`: the flag after its encoder.
    let flag = |field: &str| {
        let after = code.split(&format!("ToJson.maybe(v.{field}, ")).nth(1)?;
        after.split(", ").nth(1).map(str::to_owned)
    };
    for (field, tagged, reader) in [
        ("opt", "True", "AcmeP.read_json_opt"),
        ("plain", "False", "AcmeP.read_json_plain"),
        ("loop", "False", "AcmeP.read_json_loop"),
        ("gen", "True", "|y1| AcmeP.from_json_gen("),
        ("gen_plain", "True", "|y3| AcmeP.from_json_gen("),
        ("in_place", "False", "AcmeP.read_json_in_place"),
        ("hidden", "True", "AcmeP.read_json_hidden"),
        ("named", "True", "AcmeP.read_json_named"),
    ] {
        assert_eq!(flag(field).as_deref(), Some(tagged), "{field}\n{code}");
        // The reader reads the same form.
        assert!(code.contains(&format!(", {tagged}, {reader}")), "{field}\n{code}");
    }
    // A generic type of the package takes whether its argument's JSON can be null.
    assert!(code.contains("AcmeP.to_json_gen(v.held, e"), "{code}");
    assert!(code.contains(", AcmeP.to_json_opt, True)"), "{code}");
}
