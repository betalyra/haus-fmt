//! A codec for the type of the rule `rfc9562` (profiles/rfc9562.md, spec
//! §13.4): a Rust type for the values the rule accepts. The rule itself is
//! [`crate::rules`], checked before any codec, this one included.

use std::fmt;
use std::str::FromStr;

use haus::Codec;

use crate::Uuid;

/// Why the rule rejects a text. It doesn't quote the text, which can be anything.
const REJECTED: &str = "not a UUID of the rfc9562 rule: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens";

/// A UUID the rfc9562 rule accepts, as its text: 32 digits `0`–`9`,
/// `a`–`f` in groups 8-4-4-4-12, joined by hyphens, lowercase only. Any
/// version and variant, the nil and the max UUID included. The text is the
/// UUID's one spelling, so equal UUIDs have equal texts.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct UuidText(String);

impl UuidText {
    /// The UUID `0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57`; an error unless the text is its RFC 9562 form in lowercase.
    pub fn new(text: &str) -> Result<UuidText, String> {
        if is_text(text) { Ok(UuidText(text.to_owned())) } else { Err(REJECTED.to_owned()) }
    }

    /// The text: `0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57`.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Whether `text` is 36 bytes: hyphens at 8, 13, 18 and 23, and `0`–`9`, `a`–`f` everywhere else.
fn is_text(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            _ => matches!(b, b'0'..=b'9' | b'a'..=b'f'),
        })
}

impl fmt::Display for UuidText {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for UuidText {
    type Err = String;
    fn from_str(text: &str) -> Result<UuidText, String> {
        UuidText::new(text)
    }
}

impl TryFrom<Uuid> for UuidText {
    type Error = String;
    fn try_from(Uuid(text): Uuid) -> Result<UuidText, String> {
        if is_text(&text) { Ok(UuidText(text)) } else { Err(REJECTED.to_owned()) }
    }
}

impl From<UuidText> for Uuid {
    fn from(text: UuidText) -> Uuid {
        Uuid(text.0)
    }
}

/// The rfc9562 rule's codec for `@haus-fmt/uuid@1#Uuid`: `Uuid("0190c7a8-…")` ↔ [`UuidText`].
pub struct Rfc9562;

impl Codec for Rfc9562 {
    const ID: &'static str = Uuid::ID;
    type Base = Uuid;
    type Target = UuidText;

    fn decode(uuid: Uuid) -> Result<UuidText, String> {
        uuid.try_into()
    }

    fn encode(text: &UuidText) -> Uuid {
        text.clone().into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57";

    fn decode(text: &str) -> Result<UuidText, String> {
        Rfc9562::decode(haus::from_str(text).map_err(|e| e.to_string())?)
    }

    #[test]
    fn the_lowercase_text_form_any_version() {
        for ok in [ID, "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"] {
            assert_eq!(UuidText::new(ok).unwrap().as_str(), ok);
        }
        for version in "0123456789abcdef".chars() {
            assert!(UuidText::new(&format!("0190c7a8-5b6e-{version}d3f-{version}a41-6c2e8f1b0d57")).is_ok());
        }
    }

    #[test]
    fn every_other_spelling_is_rejected() {
        let upper = ID.to_uppercase();
        let braces = format!("{{{ID}}}");
        let urn = format!("urn:uuid:{ID}");
        let bare = ID.replace('-', "");
        let longer = format!("{ID}0");
        let line = format!("{ID}\n");
        // 36 characters but 37 bytes: a digit that isn't ASCII.
        let arabic = format!("{}٧", &ID[..35]);
        for bad in [
            upper.as_str(),
            &braces,
            &urn,
            &bare,
            &ID[1..],
            &longer,
            &line,
            &arabic,
            "",
            "0190c7a-85b6e-7d3f-9a41-6c2e8f1b0d57",
            "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0g57",
            "0190c7a805b6e-7d3f-9a41-6c2e8f1b0d57",
        ] {
            assert!(UuidText::new(bad).is_err(), "{bad:?}");
            // The rule refuses it both ways, before any codec.
            let refused = haus::to_string(&Uuid(bad.to_owned())).unwrap_err();
            assert_eq!(refused.code, haus::ErrorCode::CannotEncode, "{bad:?}");
            let value = haus::Value::variant("Uuid", vec![haus::Value::string(bad).unwrap()]).unwrap();
            assert!(decode(&haus::ser::write(&value)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn decode_encode_decode_is_decode() {
        let text = format!("Uuid(\"{ID}\")");
        let id = decode(&text).unwrap();
        assert_eq!(haus::to_string(&Rfc9562::encode(&id)).unwrap(), text);
        assert_eq!(Rfc9562::decode(Rfc9562::encode(&id)), Ok(id));
        // Checked on the decoded string: an escaped hyphen is a hyphen.
        assert_eq!(decode(r#"Uuid("0190c7a8\u{2d}5b6e-7d3f-9a41-6c2e8f1b0d57")"#).unwrap().as_str(), ID);
    }

    /// The message never quotes the rejected text (it could be anything).
    #[test]
    fn the_message_says_what_a_uuid_is() {
        assert_eq!(UuidText::new("E\u{202E}R").unwrap_err(), REJECTED);
    }
}
