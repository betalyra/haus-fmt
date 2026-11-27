//! Codecs for the types of the rule `iso` (profiles/iso.md, spec §13.4):
//! Rust types for what the rule accepts. The rule itself is checked before
//! them, by the generated code ([`crate::rules::Iso`]).

use std::fmt;
use std::str::FromStr;

use haus::{AnyTag, Codec, Decimal, Tag};

use crate::{Currency, Money};

/// A currency the iso rule accepts: three letters `A`–`Z`, the shape of
/// an ISO 4217 code (whether the code is assigned is not checked).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CurrencyCode([u8; 3]);

impl CurrencyCode {
    /// The code `EUR`; an error unless it is three letters `A`–`Z`.
    pub fn new(code: &str) -> Result<CurrencyCode, String> {
        match code.as_bytes() {
            &[a, b, c] if [a, b, c].iter().all(u8::is_ascii_uppercase) => Ok(CurrencyCode([a, b, c])),
            _ => Err(format!("\"{}\" is not a currency of the iso rule: three letters A–Z", haus::for_message(code))),
        }
    }

    /// A `Currency` as the schema decoded it: a tag without payload, three letters `A`–`Z`.
    pub fn from_tag(currency: &Currency) -> Result<CurrencyCode, String> {
        match currency {
            AnyTag::Bare(code) => CurrencyCode::new(code),
            AnyTag::Other(_) => Err(format!(
                "{} is not a currency of the iso rule: a tag of three letters A–Z, without payload",
                haus::for_message(&currency.to_string())
            )),
        }
    }

    /// The code: `EUR`.
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).expect("A–Z is ASCII")
    }
}

impl fmt::Display for CurrencyCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for CurrencyCode {
    type Err = String;
    fn from_str(code: &str) -> Result<CurrencyCode, String> {
        CurrencyCode::new(code)
    }
}

impl From<CurrencyCode> for Currency {
    fn from(code: CurrencyCode) -> Currency {
        AnyTag::Bare(Tag::new(code.as_str()).expect("three letters A–Z are a tag name"))
    }
}

/// A `Money` the iso rule accepts. It keeps the value: the amount is the
/// exact `Decimal`, its scale included (`19.90` stays `19.90`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IsoMoney {
    pub amount: Decimal,
    pub currency: CurrencyCode,
}

/// The iso rule's codec for `@haus-fmt/money@1#Money`: `Money(19.90, EUR)`
/// ↔ [`IsoMoney`]. It rejects a currency that isn't three letters `A`–`Z`,
/// and any amount is accepted.
pub struct Iso;

impl Codec for Iso {
    const ID: &'static str = Money::ID;
    type Base = Money;
    type Target = IsoMoney;

    fn decode(Money(amount, currency): Money) -> Result<IsoMoney, String> {
        Ok(IsoMoney { amount, currency: CurrencyCode::from_tag(&currency)? })
    }

    fn encode(money: &IsoMoney) -> Money {
        Money(money.amount.clone(), money.currency.into())
    }
}

/// The iso rule's codec for `@haus-fmt/money@1#Currency`: `EUR` ↔ [`CurrencyCode`].
pub struct IsoCurrency;

impl Codec for IsoCurrency {
    const ID: &'static str = CURRENCY_ID;
    type Base = Currency;
    type Target = CurrencyCode;

    fn decode(currency: Currency) -> Result<CurrencyCode, String> {
        CurrencyCode::from_tag(&currency)
    }

    fn encode(code: &CurrencyCode) -> Currency {
        (*code).into()
    }
}

/// The id of `Currency` (an alias of `AnyTag` in Rust, so it has no `ID` of its own).
pub const CURRENCY_ID: &str = "@haus-fmt/money@1#Currency";

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(text: &str) -> Result<IsoMoney, String> {
        let money: Money = haus::from_str(text).map_err(|e| e.to_string())?;
        Iso::decode(money)
    }

    #[test]
    fn codes_are_three_capital_letters() {
        for ok in ["EUR", "USD", "BTC", "AAA", "ZZZ", "XXX"] {
            assert_eq!(CurrencyCode::new(ok).unwrap().as_str(), ok);
        }
        // Not A–Z: lower case, digits, the letters around A and Z, non-ASCII capitals.
        for bad in ["", "EU", "EURO", "Eur", "eur", "E1R", "@AA", "[AA", "ÄUR", "EUR ", "E_R"] {
            assert!(CurrencyCode::new(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_currency_with_a_payload_is_rejected() {
        let currency: Currency = haus::from_str("CHF(1)").unwrap();
        let e = IsoCurrency::decode(currency).unwrap_err();
        assert!(e.contains("without payload"), "{e}");
        assert!(decode("Money(1, EUR(1))").is_err());
    }

    #[test]
    fn the_amount_is_kept_as_written() {
        for amount in
            ["19.90", "0.00005", "-3", "0", "-0", "0.000", "1e3", "-1.50e-2", "123456789012345678901234567890.1"]
        {
            let money = decode(&format!("Money({amount}, EUR)")).unwrap();
            assert_eq!(money.amount.as_str(), amount);
            assert_eq!(haus::to_string(&Iso::encode(&money)).unwrap(), format!("Money({amount}, EUR)"));
        }
    }

    #[test]
    fn decode_encode_decode_is_decode() {
        let money = decode("Money(19.90, USD)").unwrap();
        assert_eq!(money, IsoMoney { amount: Decimal::parse("19.90").unwrap(), currency: "USD".parse().unwrap() });
        assert_eq!(Iso::decode(Iso::encode(&money)), Ok(money));
    }

    /// Messages quote the rejected code as the binding's messages do (spec §9).
    #[test]
    fn messages_quote_the_code_escaped_and_short() {
        let e = CurrencyCode::new(&"A".repeat(100)).unwrap_err();
        assert_eq!(e, format!("\"{}…\" is not a currency of the iso rule: three letters A–Z", "A".repeat(39)));
        let e = CurrencyCode::new("E\u{202E}R").unwrap_err();
        assert!(e.starts_with(r#""E\u{202E}R""#), "{e}");
    }
}
