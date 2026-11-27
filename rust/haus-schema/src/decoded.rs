//! What decoding with a schema gives ([`crate::Schema::decode`]): the value an
//! encoder writes back, with its secrets hidden (spec §15, "Secrets").

use crate::check::{Segment, is_word};
use haus::{Secret, Tag, Value};
use std::collections::HashMap;
use std::fmt;

/// A value decoded with a schema (spec §15): the value an encoder writes
/// back, in which every `Secret` stays hidden.
///
/// `{:?}` and `{}` show each secret as `<redacted>`. The canonical form, the
/// hash, comparing and the writers take a [`haus::Value`], which can't hold a
/// secret: [`Decoded::reveal`] gives one, with every secret in it, and only
/// when asked. Encoding with the schema ([`crate::Schema::encode`]) refuses a
/// secret (`cannot-encode`), unless asked to reveal secrets
/// ([`crate::EncodeOptions::reveal_secrets`], spec §15).
///
/// ```
/// use haus_schema::{Decoded, Schema};
///
/// let schema = Schema::parse("type Login = { user: String, key: Secret String }").unwrap();
/// let value = haus::parse_one(r#"{ user: "ada", key: "sk-123" }"#).unwrap();
/// let login = schema.decode("Login", &value).unwrap();
/// assert_eq!(login.to_string(), r#"{user:"ada",key:<redacted>}"#);
/// assert!(!format!("{login:?}").contains("sk-123"));
/// assert!(login.as_value().is_none(), "it holds a secret");
///
/// // Revealed only when asked: then it is a plain value again.
/// assert_eq!(haus::canonical(&login.reveal()), r#"{key:"sk-123",user:"ada"}"#);
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decoded {
    /// A value without a secret inside.
    Value(Value),
    /// An array with a secret inside.
    Array(Vec<Decoded>),
    /// A record or a map with a secret inside: its fields in order, each key once.
    Record(Vec<(String, Decoded)>),
    /// A variant with a secret inside its payload.
    Variant { tag: Tag, args: Vec<Decoded> },
    /// The value of a `Secret`: `<redacted>` when printed.
    Secret(Secret<Value>),
}

impl Decoded {
    /// The value, if it holds no secret.
    pub fn as_value(&self) -> Option<&Value> {
        match self {
            Decoded::Value(v) => Some(v),
            _ => None,
        }
    }

    /// Whether a secret is inside.
    pub fn has_secret(&self) -> bool {
        !matches!(self, Decoded::Value(_))
    }

    /// The value with every secret in it, in full: what the canonical form,
    /// the hash and the writers take. Call it only where the secrets may be seen.
    pub fn reveal(self) -> Value {
        // Built from the parts of a value decoded, no deeper than it.
        const DECODED: &str = "a decoded value's parts make a value again";
        match self {
            Decoded::Value(v) => v,
            Decoded::Secret(s) => s.into_inner(),
            Decoded::Array(items) => Value::array(items.into_iter().map(Decoded::reveal).collect()).expect(DECODED),
            Decoded::Record(fields) => {
                let read = haus::Limits { max_string_length: usize::MAX, ..haus::Limits::default() };
                let fields: Vec<(String, Value)> = fields.into_iter().map(|(k, x)| (k, x.reveal())).collect();
                haus::Record::from_fields_with(fields, &read).expect(DECODED).into()
            }
            Decoded::Variant { tag, args } => {
                Value::variant(&tag, args.into_iter().map(Decoded::reveal).collect()).expect(DECODED)
            }
        }
    }

    /// The place of the first secret in it (spec §15), if it holds one.
    pub fn secret_path(&self) -> Option<Vec<Segment>> {
        let inside = |step: Segment, x: &Decoded| {
            x.secret_path().map(|mut path| {
                path.insert(0, step);
                path
            })
        };
        match self {
            Decoded::Value(_) => None,
            Decoded::Secret(_) => Some(vec![]),
            Decoded::Array(items) => items.iter().enumerate().find_map(|(i, x)| inside(Segment::Index(i), x)),
            Decoded::Record(fields) => fields.iter().find_map(|(k, x)| inside(Segment::Field(k.clone()), x)),
            // `Tag { … }`: the record's fields are at the variant's place.
            Decoded::Variant { args, .. } => match args.as_slice() {
                [record @ (Decoded::Record(_) | Decoded::Value(Value::Record(_)))] => record.secret_path(),
                _ => args.iter().enumerate().find_map(|(i, x)| inside(Segment::Index(i), x)),
            },
        }
    }
}

/// Compact haus text, as the canonical form writes each part, with the
/// fields in order and each secret as `<redacted>`.
impl fmt::Display for Decoded {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let list = |f: &mut fmt::Formatter<'_>, items: &[Decoded]| -> fmt::Result {
            items.iter().enumerate().try_for_each(|(i, x)| write!(f, "{}{x}", if i > 0 { "," } else { "" }))
        };
        match self {
            Decoded::Value(v) => f.write_str(&haus::canonical(v)),
            Decoded::Secret(s) => write!(f, "{s}"),
            Decoded::Array(items) => {
                f.write_str("[")?;
                list(f, items)?;
                f.write_str("]")
            }
            Decoded::Record(fields) => {
                f.write_str("{")?;
                for (i, (k, x)) in fields.iter().enumerate() {
                    let key = match is_word(k) {
                        true => k.clone(),
                        // `["pt-BR"]`, the path's form: the quoted key inside.
                        false => {
                            let path = haus::Segment::Field(k.clone()).to_string();
                            path.trim_start_matches('[').trim_end_matches(']').to_owned()
                        }
                    };
                    write!(f, "{}{key}:{x}", if i > 0 { "," } else { "" })?;
                }
                f.write_str("}")
            }
            Decoded::Variant { tag, args } => match args.as_slice() {
                [record @ (Decoded::Record(_) | Decoded::Value(Value::Record(_)))] => write!(f, "{tag}{record}"),
                _ => {
                    write!(f, "{tag}(")?;
                    list(f, args)?;
                    f.write_str(")")
                }
            },
        }
    }
}

/// `value` with the secrets at `secrets` (paths in it, as decoding found
/// them) hidden.
pub(crate) fn hide(value: Value, secrets: &[Vec<Segment>]) -> Decoded {
    let paths: Vec<&[Segment]> = secrets.iter().map(Vec::as_slice).collect();
    split(value, &paths)
}

/// `value` with the secrets at `secrets` hidden, the paths relative to it.
fn split(mut value: Value, secrets: &[&[Segment]]) -> Decoded {
    if secrets.is_empty() {
        return Decoded::Value(value);
    }
    if secrets.iter().any(|p| p.is_empty()) {
        return Decoded::Secret(Secret::new(value));
    }
    // The secrets inside each part, by the step to it: linear in the paths.
    let mut inside: HashMap<&Segment, Vec<&[Segment]>> = HashMap::new();
    for path in secrets {
        inside.entry(&path[0]).or_default().push(&path[1..]);
    }
    let part = |segment: Segment, x: Value| split(x, inside.get(&segment).map_or(&[], Vec::as_slice));
    // `Tag { … }`: the record is at the variant's level, its fields' paths without an index (spec §15).
    let record_payload = secrets.iter().all(|p| matches!(p[0], Segment::Field(_)));
    match &mut value {
        Value::Array(items) => Decoded::Array(
            std::mem::take(items).into_iter().enumerate().map(|(i, x)| part(Segment::Index(i), x)).collect(),
        ),
        Value::Record(r) => Decoded::Record(
            std::mem::take(r)
                .into_fields()
                .into_iter()
                .map(|(k, x)| {
                    let x = part(Segment::Field(k.clone()), x);
                    (k, x)
                })
                .collect(),
        ),
        Value::Variant { tag, args } if record_payload && matches!(args.as_slice(), [Value::Record(_)]) => {
            let args = std::mem::take(args).into_iter().map(|x| split(x, secrets)).collect();
            Decoded::Variant { tag: tag.clone(), args }
        }
        Value::Variant { tag, args } => Decoded::Variant {
            tag: tag.clone(),
            args: std::mem::take(args).into_iter().enumerate().map(|(i, x)| part(Segment::Index(i), x)).collect(),
        },
        _ => Decoded::Value(value),
    }
}
