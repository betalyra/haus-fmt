//! An application's schema split into files (app/main/order.schema.haus):
//! each imported file is a module of the generated code, named after its
//! path from the schema's directory, and has ids from its path in the crate.

mod app {
    haus::include_schema!("app");
}

/// The same schema, with a codec for `Money`, which imported files use too.
mod app_typed {
    haus::include_schema!("app_typed");
}

use app::{Invoice, Line, Order, Shipment, Tracking};
use haus::{Codec, from_str, to_string};

const ORDER: &str = r#"{ bill: { street: "Main St", owes: { amount: 1.50, currency: "EUR" } }, ship: { to: { line: "Dock 4" }, weight: 3 }, total: { amount: 9.90, currency: "EUR" }, lines: { items: [{ item: "tea", price: { amount: 9.90, currency: "EUR" } }] } }"#;

#[test]
fn imported_files_are_modules() {
    let order: Order = from_str(ORDER).unwrap();
    let billing: &app::up_billing_common::Address = &order.bill;
    let shipping: &app::up_shipping_common::Address = &order.ship.to;
    assert_eq!(billing.street, "Main St");
    assert_eq!(shipping.line, "Dock 4");
    let lines: &app::up_shared_money::Page<Line> = &order.lines;
    assert_eq!(lines.items[0].price.amount.as_str(), "9.90");
    assert_eq!(to_string(&order).unwrap(), ORDER);
}

#[test]
fn files_with_the_same_name_have_different_ids() {
    assert_eq!(Order::ID, "haus-build-tests/app/main/order#Order");
    assert_eq!(app::up_billing_common::Address::ID, "haus-build-tests/app/billing/common#Address");
    assert_eq!(app::up_shipping_common::Address::ID, "haus-build-tests/app/shipping/common#Address");
    assert_eq!(app::up_shared_money::Money::ID, "haus-build-tests/app/shared/money#Money");
    // shipping's Address is closed, billing's isn't: they are different types.
    assert!(from_str::<app::up_shipping_common::Address>(r#"{ line: "x", extra: 1 }"#).is_err());
    assert!(from_str::<app::up_billing_common::Address>(r#"{ street: "x", extra: 1 }"#).is_ok());
}

/// Money as integer cents.
pub struct Cents;

impl Codec for Cents {
    const ID: &'static str = app_typed::up_shared_money::Money::ID;
    type Base = app_typed::up_shared_money::Money;
    type Target = (i128, String);

    fn decode(money: Self::Base) -> Result<(i128, String), String> {
        let cents = money.amount.scaled(2).ok_or("more than 2 decimal places")?;
        Ok((cents, money.currency))
    }

    fn encode((cents, currency): &(i128, String)) -> Self::Base {
        app_typed::up_shared_money::Money { amount: haus::Decimal::from_scaled(*cents, 2), currency: currency.clone() }
    }
}

#[test]
fn a_codec_applies_in_every_file() {
    let order: app_typed::Order = from_str(ORDER).unwrap();
    assert_eq!(order.total, (990, "EUR".to_owned()));
    assert_eq!(order.bill.owes, Some((150, "EUR".to_owned())));
    assert_eq!(order.lines.items[0].price, (990, "EUR".to_owned()));
    assert_eq!(to_string(&order).unwrap(), ORDER);
    let e = from_str::<app_typed::Order>(&ORDER.replace("1.50", "1.505")).unwrap_err();
    assert!(e.to_string().contains("more than 2 decimal places"), "{e}");
}

#[test]
fn spreads_of_imported_types_copy_their_fields_and_tags() {
    // billing's Address, with its Money (from the file billing imports it from).
    const INVOICE: &str = r#"{ street: "Main St", owes: { amount: 1.50, currency: "EUR" }, number: 7 }"#;
    let invoice: Invoice = from_str(INVOICE).unwrap();
    let owes: &Option<app::up_shared_money::Money> = &invoice.owes;
    assert_eq!(owes.as_ref().map(|m| m.amount.as_str()), Some("1.50"));
    assert_eq!(to_string(&invoice).unwrap(), INVOICE);
    let json = haus::json::to_string(&invoice).unwrap();
    assert_eq!(json, r#"{"street":"Main St","owes":{"amount":"1.50","currency":"EUR"},"number":"7"}"#);
    assert_eq!(haus::json::from_str::<Invoice>(&json).unwrap(), invoice);

    // shipping's Parcel, whose Address is shipping's, in a closed record.
    const SHIPMENT: &str = r#"{ id: 1, to: { line: "Dock 4" }, weight: 3 }"#;
    let shipment: Shipment = from_str(SHIPMENT).unwrap();
    let to: &app::up_shipping_common::Address = &shipment.to;
    assert_eq!(to.line, "Dock 4");
    assert_eq!(to_string(&shipment).unwrap(), SHIPMENT);
    assert!(from_str::<Shipment>(&SHIPMENT.replace("weight", "extra: 0, weight")).is_err());
    assert!(from_str::<Shipment>(r#"{ id: 1, to: { line: "x", floor: 2 }, weight: 3 }"#).is_err());

    // shipping's Status, a variant, and a tag of its own.
    let sent: Tracking = from_str(r#"Sent { to: { line: "Dock 4" } }"#).unwrap();
    assert!(matches!(&sent, Tracking::Sent { to } if to.line == "Dock 4"));
    assert!(matches!(from_str::<Tracking>("Lost").unwrap(), Tracking::Lost));
    let json = haus::json::to_string(&sent).unwrap();
    assert_eq!(json, r#"{"_tag":"Sent","to":{"line":"Dock 4"}}"#);
    assert_eq!(haus::json::from_str::<Tracking>(&json).unwrap(), sent);

    // A codec for Money applies to the copied field too.
    let typed: app_typed::Invoice = from_str(INVOICE).unwrap();
    assert_eq!(typed.owes, Some((150, "EUR".to_owned())));
}
