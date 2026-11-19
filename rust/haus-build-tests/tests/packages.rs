//! An application that uses schema packages (shop.schema.haus, packages/):
//! a codec applies wherever its type occurs, inside the packages' types too
//! (spec §13.4). The packages' types that contain Money, directly or not,
//! are copied into the application's code (the codec closure); its other
//! types are still the package crates' own.
//!
//! orders imports ledger, which imports money. This crate depends on orders
//! and money only: ledger's types are named through orders' re-exports.

/// Without codecs: every type is its package crate's.
mod shop {
    haus::include_schema!("shop");
}

/// With a codec for `@haus-test/money@1#Money`.
mod shop_typed {
    haus::include_schema!("shop_typed");
}

use haus::{Codec, from_str, to_string};
use haus_test_orders::__haus_deps::haus_test_ledger;

/// Money as integer cents.
pub struct Cents;

impl Codec for Cents {
    const ID: &'static str = haus_test_money::Money::ID;
    type Base = haus_test_money::Money;
    type Target = (i128, String);

    fn decode(money: Self::Base) -> Result<(i128, String), String> {
        let cents = money.amount.scaled(2).ok_or("more than 2 decimal places")?;
        Ok((cents, money.currency))
    }

    fn encode((cents, currency): &(i128, String)) -> Self::Base {
        haus_test_money::Money { amount: haus::Decimal::from_scaled(*cents, 2), currency: currency.clone() }
    }
}

const SHOP: &str = r#"{ orders: [{ id: 1, entries: [{ amount: { amount: 9.90, currency: "EUR" }, note: { text: "tea" } }], moves: [Credit { amount: 1.50, currency: "EUR" }, Debit { amount: { amount: 0.25, currency: "EUR" } }, Fee { percent: 3 }, Memo { text: "late" }], terms: { rate: { percent: 2 }, note: { text: "net 30" } }, customer: { name: "Ada" } }], customer: { name: "Ada", note: { text: "vip" } }, price: { amount: 12.00, currency: "EUR" }, rate: { percent: 19 } }"#;

/// `x` has the type `T` (a compile-time check of type identity).
fn is<T>(_: &T) {}

#[test]
fn without_codecs_the_types_are_the_package_crates() {
    let shop: shop::Shop = from_str(SHOP).unwrap();
    is::<Vec<haus_test_orders::Order>>(&shop.orders);
    is::<haus_test_money::Money>(&shop.price);
    let order = &shop.orders[0];
    is::<haus_test_ledger::Entry>(&order.entries[0]);
    assert_eq!(order.entries[0].amount.amount.as_str(), "9.90");
    assert_eq!(to_string(&shop).unwrap(), SHOP);
}

#[test]
fn a_codec_applies_inside_the_packages_types() {
    let shop: shop_typed::Shop = from_str(SHOP).unwrap();
    assert_eq!(shop.price, (1200, "EUR".to_owned()));
    let order: &shop_typed::haus_test_orders::Order = &shop.orders[0];
    // In a field of a package's type (ledger's Entry), two levels deep (orders → ledger → money).
    let entry: &shop_typed::haus_test_ledger::Entry = &order.entries[0];
    assert_eq!(entry.amount, (990, "EUR".to_owned()));
    // In a variant's payloads.
    use shop_typed::haus_test_ledger::Move;
    assert!(matches!(&order.moves[0], Move::Credit(m) if *m == (150, "EUR".to_owned())));
    assert!(matches!(&order.moves[1], Move::Debit { amount } if *amount == (25, "EUR".to_owned())));
    assert!(matches!(&order.moves[2], Move::Fee(rate) if rate.percent == haus::Int::from(3i64)));
    // Both copies have the ids of the packages' types.
    assert_eq!(shop_typed::haus_test_orders::Order::ID, haus_test_orders::Order::ID);
    assert_eq!(shop_typed::haus_test_ledger::Move::ID, "@haus-test/ledger@1#Move");

    // Through haus and JSON, the same values.
    assert_eq!(to_string(&shop).unwrap(), SHOP);
    let json = haus::json::to_string(&shop).unwrap();
    assert_eq!(haus::json::from_str::<shop_typed::Shop>(&json).unwrap(), shop);
    let plain: shop::Shop = from_str(SHOP).unwrap();
    assert_eq!(json, haus::json::to_string(&plain).unwrap());

    // The codec rejects what it can't hold, wherever the Money is.
    let e = from_str::<shop_typed::Shop>(&SHOP.replace("0.25", "0.255")).unwrap_err();
    let haus::Error::Decode(e) = e else { panic!("{e}") };
    assert_eq!(e.place(), "$.orders[0].moves[1].amount");
    assert!(e.to_string().contains("more than 2 decimal places"), "{e}");
}

#[test]
fn types_without_the_codecs_type_are_the_package_crates() {
    let shop: shop_typed::Shop = from_str(SHOP).unwrap();
    let order = &shop.orders[0];
    is::<haus_test_orders::Customer>(&shop.customer);
    is::<haus_test_orders::Customer>(&order.customer);
    is::<haus_test_money::Rate>(&shop.rate);
    is::<haus_test_ledger::Terms>(&order.terms);
    is::<haus_test_ledger::Note>(&order.entries[0].note);
    use shop_typed::haus_test_ledger::Move;
    assert!(matches!(&order.moves[3], Move::Memo(note) if { is::<haus_test_ledger::Note>(note); note.text == "late" }));
    // Only the types that contain Money are copied.
    let code = include_str!(concat!(env!("OUT_DIR"), "/shop_typed.rs"));
    for copied in ["pub struct Order ", "pub struct Entry ", "pub enum Move "] {
        assert_eq!(code.matches(copied).count(), 1, "{copied}");
    }
    for kept in
        ["pub struct Customer ", "pub struct Terms ", "pub struct Note ", "pub struct Rate ", "pub struct Money "]
    {
        assert!(!code.contains(kept), "{kept}");
    }
    assert!(!include_str!(concat!(env!("OUT_DIR"), "/shop.rs")).contains("pub mod "));
}
