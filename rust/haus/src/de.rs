//! Decoding values into Rust types: the [`Decode`] trait, its implementations
//! for the prelude types, and the helpers that generated code calls.
//!
//! Decoding is linear in the input (spec §9): records are indexed once, and a
//! variant's case is chosen by its tag, never by trying cases in turn.

use crate::{Codec, DecodeError, ErrorCode as Code, Limits, Secret, Value};
use std::collections::{BTreeMap, HashMap};

type R<T> = Result<T, DecodeError>;

/// Where a value is read with a type, as [`Encoder`](crate::Encoder) is
/// where one is written: the limits of the reader, and how many containers
/// (records, arrays, payloads) the value is inside, counted as the parser
/// counts them. Decoding ([`Decode`]) and reading schema-based JSON
/// ([`FromJson`](crate::FromJson)) take one, and reading a container takes
/// [`Decoder::nested`], so that a value nested deeper than the depth limit
/// (a [`Value`] or [`Json`](crate::Json) built in code may be nested
/// arbitrarily deep) fails there instead of recursing on (spec §9.8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Decoder {
    limits: Limits,
    depth: usize,
    /// The record is read from a tag's object, beside its `"_tag"` (a record
    /// case whose record is a named type, spec §16.3): `"_tag"` is not one of
    /// its fields. Only the next object read takes it.
    in_tag: bool,
    /// The value is a tag's only argument: a record here is `Tag { … }`,
    /// inside the payload's level rather than one more (§7).
    payload: bool,
}

impl Decoder {
    /// At the top, for a reader with `limits`.
    pub fn new(limits: &Limits) -> Decoder {
        Decoder { limits: *limits, depth: 0, in_tag: false, payload: false }
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// How many containers the value is inside.
    pub fn depth(&self) -> usize {
        self.depth
    }

    /// Inside one more container, if the depth limit allows it. Fails too
    /// if the limit is more than [`crate::MAX_SUPPORTED_DEPTH`].
    pub fn nested(self) -> R<Decoder> {
        crate::json::open(&self.limits, self.depth).map(|depth| Decoder {
            depth,
            in_tag: false,
            payload: false,
            ..self
        })
    }

    /// Inside a tag's only argument: like [`Decoder::nested`], but a record
    /// right inside takes no level of its own (`Tag { … }`).
    pub fn payload(self) -> R<Decoder> {
        self.nested().map(|d| Decoder { payload: true, ..d })
    }

    /// Inside a record or map: one more level, unless the record is a tag's
    /// only argument and so shares its level.
    pub fn record_level(self) -> R<Decoder> {
        match self.payload {
            true => Ok(Decoder { payload: false, ..self }),
            false => self.nested(),
        }
    }

    /// Inside the arguments of a tag with `n` of them: [`Decoder::payload`]
    /// for one, [`Decoder::nested`] for more.
    pub fn args(self, n: usize) -> R<Decoder> {
        if n == 1 { self.payload() } else { self.nested() }
    }

    /// For the record of a record case (spec §15) whose record is a named
    /// type, read from the tag's object: its members other than `"_tag"`
    /// are the record's fields.
    pub(crate) fn in_tag(self) -> Decoder {
        Decoder { in_tag: true, ..self }
    }

    /// Whether the object read here is a tag's (see [`Decoder::in_tag`]).
    pub(crate) fn is_in_tag(&self) -> bool {
        self.in_tag
    }
}

/// A Rust type that a haus value decodes to.
///
/// Decoding checks the nesting depth as it goes, for a reader with the
/// limits of a [`Decoder`] (spec §7, §9.8): before each container, so that
/// a [`Value`] built in code nested deeper than the limit fails with
/// `nesting-too-deep` instead of recursing on, also inside an `Any`.
pub trait Decode: Sized {
    /// The value, decoded at `d`'s depth, for a reader with `d`'s limits.
    fn decode_with(v: &Value, d: Decoder) -> R<Self>;

    /// The value, decoded for a reader with the default limits.
    fn decode(v: &Value) -> R<Self> {
        Self::decode_with(v, Decoder::default())
    }
}

/// Whether `v` nests within the depth limit at `d` (a raw value kept as it
/// is: an `Any`, or the payload of an unknown tag), counted as the writer
/// counts it. Stops at the limit, so it recurses at most that deep.
pub fn within_depth(v: &Value, d: Decoder) -> R<()> {
    match v {
        Value::Array(items) => {
            let inner = d.nested()?;
            items.iter().enumerate().try_for_each(|(i, x)| within_depth(x, inner).map_err(|e| e.index(i)))
        }
        Value::Record(fields) => {
            let inner = d.record_level()?;
            fields.iter().try_for_each(|(k, x)| within_depth(x, inner).map_err(|e| e.field(k)))
        }
        Value::Variant { tag, args } => args_within_depth(tag, args, d),
        _ => Ok(()),
    }
}

/// Whether the arguments of `tag` nest within the depth limit at `d`, the
/// variant's place: a record payload's fields are steps from the tag.
fn args_within_depth(tag: &str, args: &[Value], d: Decoder) -> R<()> {
    if args.is_empty() {
        return Ok(());
    }
    let inner = d.args(args.len())?;
    match args {
        [Value::Record(fields)] => {
            let inner = inner.record_level()?;
            fields.iter().try_for_each(|(k, x)| within_depth(x, inner).map_err(|e| e.field(k).tag(tag)))
        }
        _ => args.iter().enumerate().try_for_each(|(i, x)| within_depth(x, inner).map_err(|e| e.index(i).tag(tag))),
    }
}

/// What a value is, for messages: `a string`, `the tag Open`.
pub fn describe(v: &Value) -> String {
    match v {
        Value::Number(n) => format!("the number {n}"),
        Value::String(_) => "a string".into(),
        Value::Bytes(_) => "a byte string".into(),
        Value::Array(_) => "an array".into(),
        Value::Record(_) => "a record".into(),
        Value::Variant { tag, args } if args.is_empty() => format!("the tag {tag}"),
        Value::Variant { tag, .. } => format!("{tag}(…)"),
    }
}

/// `expected <what>, found <v>`: a value of another kind (`type-mismatch`).
pub fn mismatch(what: &str, v: &Value) -> DecodeError {
    mismatch_as(Code::TypeMismatch, what, v)
}

/// `expected <what>, found <v>`, with `code`.
fn mismatch_as(code: Code, what: &str, v: &Value) -> DecodeError {
    let found = describe(v);
    DecodeError::new(code, format!("expected {what}, found {found}")).with_expected_found(what, found)
}

/// `v` isn't one of the cases of a closed variant with `tags` (`Bool`,
/// `Maybe`, `Result`): an unknown tag, a known tag with the wrong payload, or
/// not a variant at all (spec §17).
fn not_case(what: &str, v: &Value, tags: &[&str]) -> DecodeError {
    match v {
        Value::Variant { tag, .. } if tags.contains(&tag.as_str()) => {
            // The prelude's cases: `True`, `False` and `None` take nothing, the others one value.
            let n = usize::from(!matches!(tag.as_str(), "True" | "False" | "None"));
            mismatch_as(Code::WrongPayload, what, v).with_hint(positional_hint(tag, n, &[]))
        }
        Value::Variant { .. } => mismatch_as(Code::UnknownTag, what, v),
        _ => mismatch_as(Code::TypeMismatch, what, v),
    }
}

// ── records ──────────────────────────────────────────────────

/// A record, indexed by key once.
pub struct Record<'a> {
    fields: &'a [(String, Value)],
    index: HashMap<&'a str, &'a Value>,
    /// The payload of this tag, for error paths.
    tag: Option<&'a str>,
    /// Where the fields are: inside the record.
    d: Decoder,
}

impl<'a> Record<'a> {
    /// `v` as a record, at `d`; `what` names the expected type in errors.
    pub fn new(v: &'a Value, d: Decoder, what: &str) -> R<Record<'a>> {
        match v {
            Value::Record(fields) => {
                let index = fields.iter().map(|(k, v)| (k.as_str(), v)).collect();
                Ok(Record { fields, index, tag: None, d: d.record_level()? })
            }
            _ => Err(mismatch(&format!("a record ({what})"), v)),
        }
    }

    fn at(&self, e: DecodeError) -> DecodeError {
        match self.tag {
            Some(tag) => e.tag(tag),
            None => e,
        }
    }

    /// A closed record has only the fields listed.
    pub fn closed(&self, known: &[&str]) -> R<()> {
        match self.fields.iter().find(|(k, _)| !known.contains(&k.as_str())) {
            Some((k, _)) => {
                let e = DecodeError::new(Code::UnknownField, format!("unknown field {k:?} in a closed record"));
                Err(self.at(e.field(k)))
            }
            None => Ok(()),
        }
    }

    pub fn required<T>(&self, key: &str, f: impl FnOnce(&Value, Decoder) -> R<T>) -> R<T> {
        match self.index.get(key) {
            Some(v) => f(v, self.d).map_err(|e| self.at(e.field(key))),
            None => {
                let e = DecodeError::new(Code::MissingField, format!("missing field {key}"));
                Err(self.at(e.with_expected(format!("the field '{key}'"))))
            }
        }
    }

    /// `key?: T`: the field may be missing.
    pub fn optional<T>(&self, key: &str, f: impl FnOnce(&Value, Decoder) -> R<T>) -> R<Option<T>> {
        self.index.get(key).map(|v| f(v, self.d).map_err(|e| self.at(e.field(key)))).transpose()
    }
}

// ── variants ─────────────────────────────────────────────────

/// `v` as a variant: its tag and payload.
pub fn variant<'a>(v: &'a Value, what: &str) -> R<(&'a str, &'a [Value])> {
    match v {
        Value::Variant { tag, args } => Ok((tag, args)),
        _ => Err(mismatch(&format!("a variant ({what})"), v)),
    }
}

/// The payload of `tag`: exactly `N` values.
pub fn args<'a, const N: usize>(tag: &str, args: &'a [Value]) -> R<&'a [Value; N]> {
    typed_args::<N>(tag, args, &[])
}

/// The payload of `tag`: exactly `N` values, of the schema types `types`
/// (`["Float64", "Float64"]`), which the hint names; `[]` if not known.
pub fn typed_args<'a, const N: usize>(tag: &str, args: &'a [Value], types: &[&str]) -> R<&'a [Value; N]> {
    args.try_into().map_err(|_| {
        let (reason, expected) = match N {
            0 => (format!("{tag} takes no payload"), "no payload".to_owned()),
            1 => (format!("{tag} takes one value, found {}", args.len()), "one value".to_owned()),
            n => (format!("{tag} takes {n} values, found {}", args.len()), format!("{n} values")),
        };
        DecodeError::new(Code::WrongPayload, reason)
            .with_expected_found(expected, format!("{} argument(s)", args.len()))
            .with_hint(positional_hint(tag, N, types))
    })
}

/// What a tag with `n` positional values takes, as a hint:
/// ``Point takes 2 arguments (Float64, Float64): write `Point(…, …)`.``
/// `types` are the schema types, or `[]` if not known.
pub fn positional_hint(tag: &str, n: usize, types: &[&str]) -> String {
    if n == 0 {
        return format!("{tag} takes no payload: write `{tag}`.");
    }
    let s = if n == 1 { "" } else { "s" };
    let types = match types.len() == n {
        true => format!(" ({})", types.join(", ")),
        false => String::new(),
    };
    format!("{tag} takes {n} argument{s}{types}: write `{tag}({})`.", vec!["…"; n].join(", "))
}

/// What a tag with a record payload takes, as a hint:
/// ``Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.``
/// `record` is the record type as the schema writes it, or `""` if not known.
pub fn record_hint(tag: &str, record: &str) -> String {
    let record = match record.is_empty() {
        true => String::new(),
        false => format!(" {record}"),
    };
    format!("{tag} takes one argument, a record{record}: write `{tag} {{ … }}`.")
}

/// Decode payload value `i` of `tag`, one of `N`, whose variant is at `d`.
pub fn arg<const N: usize, T>(
    tag: &str,
    i: usize,
    v: &Value,
    d: Decoder,
    f: impl FnOnce(&Value, Decoder) -> R<T>,
) -> R<T> {
    f(v, d.args(N)?).map_err(|e| e.index(i).tag(tag))
}

/// The record payload of `Tag { … }`, whose variant is at `d`.
pub fn payload<'a>(tag: &'a str, args: &'a [Value], d: Decoder) -> R<Record<'a>> {
    record_payload(tag, args, d, "")
}

/// The record payload of `Tag { … }`, whose record type the schema writes
/// `record` (`{ r: Float64 }`, for the hint; `""` if not known). Anything
/// but one record, `Circle(1.5)` too, is the wrong payload (spec §15),
/// reported at the variant.
pub fn record_payload<'a>(tag: &'a str, args: &'a [Value], d: Decoder, record: &str) -> R<Record<'a>> {
    match args {
        [v @ Value::Record(_)] => Record::new(v, d.payload()?, tag).map(|r| Record { tag: Some(tag), ..r }),
        _ => Err(not_one_record(tag, args, record)),
    }
}

/// The record of a record case whose record is a named type (spec §15:
/// `Wrap Box` with `type Box = { w: Int }`), decoded with `f`: the same as
/// `Tag { … }`, so anything but one record, `Wrap(1)` too, is the wrong
/// payload, and errors in the record are at the variant's place. `record`
/// names the type for the hint (`""` if not known).
pub fn record_arg<T>(
    tag: &str,
    args: &[Value],
    d: Decoder,
    record: &str,
    f: impl FnOnce(&Value, Decoder) -> R<T>,
) -> R<T> {
    match args {
        [v @ Value::Record(_)] => f(v, d.payload()?).map_err(|e| e.tag(tag)),
        _ => Err(not_one_record(tag, args, record)),
    }
}

/// `wrong-payload`: `tag` takes one argument, a record, and `args` isn't one.
fn not_one_record(tag: &str, args: &[Value], record: &str) -> DecodeError {
    let found = match args {
        [] => "no payload".to_owned(),
        [v] => describe(v),
        _ => format!("{} arguments", args.len()),
    };
    DecodeError::new(Code::WrongPayload, format!("{tag} takes one argument, a record; found {found}"))
        .with_expected_found("one argument, a record", found)
        .with_hint(record_hint(tag, record))
}

/// A tag a closed variant doesn't list.
pub fn unknown_tag(tag: &str, known: &[&str]) -> DecodeError {
    let expected = format!("one of {}", known.join(", "));
    DecodeError::new(Code::UnknownTag, format!("unknown tag {tag}; expected {expected}"))
        .with_expected_found(expected, tag)
}

/// A tag an open variant doesn't list: kept as it was (spec §9: untrusted).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unknown {
    pub tag: String,
    pub args: Vec<Value>,
}

impl Unknown {
    pub fn new(tag: &str, args: &[Value]) -> Unknown {
        Unknown { tag: tag.to_owned(), args: args.to_vec() }
    }
}

/// A tag an open variant at `d` doesn't list, kept as it was if its payload
/// nests within the depth limit (see [`within_depth`]).
pub fn unknown(tag: &str, args: &[Value], d: Decoder) -> R<Unknown> {
    args_within_depth(tag, args, d).map(|()| Unknown::new(tag, args))
}

/// `< >`: a variant with any tag. A bare tag is its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnyTag {
    Bare(String),
    Other(Unknown),
}

impl std::fmt::Display for AnyTag {
    /// The tag: `EUR`; a tag with a payload as `Tag(…)`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AnyTag::Bare(tag) => f.write_str(tag),
            AnyTag::Other(u) => write!(f, "{}(…)", u.tag),
        }
    }
}

impl Decode for AnyTag {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        let (tag, args) = variant(v, "a tag")?;
        Ok(if args.is_empty() { AnyTag::Bare(tag.to_owned()) } else { AnyTag::Other(unknown(tag, args, d)?) })
    }
}

// ── containers ───────────────────────────────────────────────

/// `Array a`, at `d`.
pub fn array<T>(v: &Value, d: Decoder, f: impl Fn(&Value, Decoder) -> R<T>) -> R<Vec<T>> {
    match v {
        Value::Array(items) => {
            let inner = d.nested()?;
            items.iter().enumerate().map(|(i, x)| f(x, inner).map_err(|e| e.index(i))).collect()
        }
        _ => Err(mismatch("an array", v)),
    }
}

/// `Map v`: a record used as a dictionary, at `d`.
pub fn map<T>(v: &Value, d: Decoder, f: impl Fn(&Value, Decoder) -> R<T>) -> R<BTreeMap<String, T>> {
    match v {
        Value::Record(fields) => {
            let inner = d.record_level()?;
            fields.iter().map(|(k, x)| Ok((k.clone(), f(x, inner).map_err(|e| e.field(k))?))).collect()
        }
        _ => Err(mismatch("a record (Map)", v)),
    }
}

/// `Maybe a`: `None` or `Some(a)`, at `d`.
pub fn maybe<T>(v: &Value, d: Decoder, f: impl FnOnce(&Value, Decoder) -> R<T>) -> R<Option<T>> {
    match variant(v, "Maybe")? {
        ("None", []) => Ok(None),
        ("Some", [x]) => f(x, d.payload()?).map(Some).map_err(|e| e.index(0).tag("Some")),
        _ => Err(not_case("None or Some(…)", v, &["None", "Some"])),
    }
}

/// `Result e a`: `Err(e)` or `Ok(a)`, at `d`.
pub fn result<A, E>(
    v: &Value,
    d: Decoder,
    ok: impl FnOnce(&Value, Decoder) -> R<A>,
    err: impl FnOnce(&Value, Decoder) -> R<E>,
) -> R<Result<A, E>> {
    match variant(v, "Result")? {
        ("Ok", [x]) => ok(x, d.payload()?).map(Ok).map_err(|e| e.index(0).tag("Ok")),
        ("Err", [x]) => err(x, d.payload()?).map(Err).map_err(|e| e.index(0).tag("Err")),
        _ => Err(not_case("Ok(…) or Err(…)", v, &["Ok", "Err"])),
    }
}

/// `Secret a`: decoded as `a` decodes, but an error says only that the value
/// isn't a valid `what` (`Secret String`), never what was found or where in
/// it (spec §15). The path to the secret itself is added on the way out.
pub fn secret<T>(v: &Value, d: Decoder, what: &str, f: impl FnOnce(&Value, Decoder) -> R<T>) -> R<Secret<T>> {
    f(v, d).map(Secret::new).map_err(|_| hidden(what))
}

/// The error for a `Secret` (`what`) whose value doesn't decode: nothing of the value (spec §15).
pub(crate) fn hidden(what: &str) -> DecodeError {
    DecodeError::new(Code::InvalidSecret, format!("not a valid {what} (the value is hidden)"))
}

/// A type decoded by a codec: its base type first, then the codec (spec §13.4).
pub fn codec<C: Codec>(v: &Value, d: Decoder) -> R<C::Target> {
    C::decode(C::Base::decode_with(v, d)?).map_err(|reason| DecodeError::new(Code::TypeMismatch, reason))
}

impl<T: Decode> Decode for Vec<T> {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        array(v, d, T::decode_with)
    }
}
impl<T: Decode> Decode for BTreeMap<String, T> {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        map(v, d, T::decode_with)
    }
}
impl<T: Decode> Decode for Option<T> {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        maybe(v, d, T::decode_with)
    }
}
impl<A: Decode, E: Decode> Decode for Result<A, E> {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        result(v, d, A::decode_with, E::decode_with)
    }
}
impl<T: Decode> Decode for Box<T> {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        T::decode_with(v, d).map(Box::new)
    }
}

// ── scalars ──────────────────────────────────────────────────

/// `Any`: the value as it is, if it nests within the depth limit here.
impl Decode for Value {
    fn decode_with(v: &Value, d: Decoder) -> R<Self> {
        within_depth(v, d).map(|()| v.clone())
    }
}

impl Decode for String {
    fn decode_with(v: &Value, _: Decoder) -> R<Self> {
        match v {
            Value::String(s) => Ok(s.clone()),
            _ => Err(mismatch("a string", v)),
        }
    }
}

/// `Bytes`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Bytes(pub Vec<u8>);

impl Decode for Bytes {
    fn decode_with(v: &Value, _: Decoder) -> R<Self> {
        match v {
            Value::Bytes(b) => Ok(Bytes(b.clone())),
            _ => Err(mismatch("a byte string", v)),
        }
    }
}

impl Decode for bool {
    fn decode_with(v: &Value, _: Decoder) -> R<Self> {
        match variant(v, "Bool")? {
            ("True", []) => Ok(true),
            ("False", []) => Ok(false),
            _ => Err(not_case("True or False", v, &["True", "False"])),
        }
    }
}

/// The digits of a whole number literal (`-12`, `0`), or None (`1.5`, `1e3`).
/// `-0` is 0 (spec §15).
fn whole(text: &str) -> Option<&str> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let is_whole = !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit());
    is_whole.then_some(if digits == "0" { digits } else { text })
}

/// A number with a fraction or an exponent where an integer type (`name`) is expected.
fn not_whole(name: &str, text: &str) -> DecodeError {
    DecodeError::new(Code::NotAnInteger, format!("expected a whole number ({name}), found {text}"))
        .with_expected_found(name, text)
}

macro_rules! integers {
    ($($t:ty => $name:literal),*) => {$(
        impl Decode for $t {
            fn decode_with(v: &Value, _: Decoder) -> R<Self> {
                let Value::Number(text) = v else { return Err(mismatch(concat!("a number (", $name, ")"), v)) };
                let Some(n) = whole(text) else { return Err(not_whole($name, text)) };
                n.parse().map_err(|_| {
                    let range = format!("{} ({} to {})", $name, <$t>::MIN, <$t>::MAX);
                    DecodeError::new(Code::OutOfRange, format!("{text} is out of range for {range}"))
                        .with_expected_found(range, text.as_str())
                })
            }
        }
    )*};
}
integers!(i8 => "Int8", i16 => "Int16", i32 => "Int32", i64 => "Int64", u8 => "UInt8", u16 => "UInt16", u32 => "UInt32", u64 => "UInt64");

/// `Float32` and `Float64`: a number rounded to the nearest value of the type
/// directly from its exact decimal value (ties to even; Rust's `parse` does
/// that for both), or a tag `NaN`, `Infinity`, `NegInfinity` (spec §15). A
/// finite number too large for the type, one that rounds to an infinity, is
/// an error.
macro_rules! floats {
    ($($t:ty => $name:literal),*) => {$(
        impl Decode for $t {
            fn decode_with(v: &Value, _: Decoder) -> R<Self> {
                match v {
                    Value::Number(text) => match text.parse::<$t>() {
                        Ok(x) if x.is_finite() => Ok(x),
                        Ok(_) => Err(DecodeError::new(Code::OutOfRange, format!("{text} is too large for {}", $name))
                            .with_expected_found($name, text.as_str())),
                        Err(_) => Err(DecodeError::new(Code::TypeMismatch, format!("{text} is not a {}", $name))),
                    },
                    Value::Variant { tag, args } if args.is_empty() && tag == "NaN" => Ok(<$t>::NAN),
                    Value::Variant { tag, args } if args.is_empty() && tag == "Infinity" => Ok(<$t>::INFINITY),
                    Value::Variant { tag, args } if args.is_empty() && tag == "NegInfinity" => Ok(<$t>::NEG_INFINITY),
                    _ => Err(mismatch(concat!("a number (", $name, ")"), v)),
                }
            }
        }
    )*};
}
floats!(f32 => "Float32", f64 => "Float64");

/// `Int`: an integer of any size, as its decimal digits. Writing it gives the
/// same digits back. Convert it with [`Int::to_i64`] / [`Int::to_i128`], or to
/// `num_bigint::BigInt` with the `bigint` feature. For a native integer that
/// must fit, the schema says `Int64` (decoded as `i64`, out of range is an error).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Int(pub(crate) String);

impl Int {
    pub fn as_str(&self) -> &str {
        &self.0
    }
    /// The value, if it fits.
    pub fn to_i64(&self) -> Option<i64> {
        self.0.parse().ok()
    }
    /// The value, if it fits.
    pub fn to_i128(&self) -> Option<i128> {
        self.0.parse().ok()
    }
}

#[cfg(feature = "bigint")]
impl From<num_bigint::BigInt> for Int {
    fn from(n: num_bigint::BigInt) -> Self {
        Int(n.to_string())
    }
}

#[cfg(feature = "bigint")]
impl From<&Int> for num_bigint::BigInt {
    fn from(n: &Int) -> Self {
        // An Int holds decimal digits with an optional minus sign, which always parse.
        n.0.parse().expect("an Int is a decimal integer")
    }
}

#[cfg(feature = "bigint")]
impl From<Int> for num_bigint::BigInt {
    fn from(n: Int) -> Self {
        (&n).into()
    }
}

impl From<i64> for Int {
    fn from(n: i64) -> Self {
        Int(n.to_string())
    }
}

impl From<i128> for Int {
    fn from(n: i128) -> Self {
        Int(n.to_string())
    }
}

impl Decode for Int {
    fn decode_with(v: &Value, _: Decoder) -> R<Self> {
        match v {
            Value::Number(text) => match whole(text) {
                Some(n) => Ok(Int(n.to_owned())),
                None => Err(not_whole("Int", text)),
            },
            _ => Err(mismatch("a number (Int)", v)),
        }
    }
}

/// `Decimal`: an exact decimal as written, scale kept (`19.90` is not `19.9`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Decimal(pub(crate) String);

impl Decimal {
    /// The literal: `19.90`, `-1e10`.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The value in units of 10^-`scale`, if that is exact and fits:
    /// `44.40` at scale 2 is `4440`; `19.999` at scale 2 is None.
    pub fn scaled(&self, scale: u32) -> Option<i128> {
        let (negative, text) = match self.0.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, self.0.as_str()),
        };
        let (mantissa, exp) = match text.split_once('e') {
            Some((m, e)) => (m, e.parse::<i64>().ok()?),
            None => (text, 0),
        };
        let (int, frac) = mantissa.split_once('.').unwrap_or((mantissa, ""));
        let digits = format!("{int}{frac}");
        // value = digits × 10^shift
        let shift = exp - i64::try_from(frac.len()).ok()? + i64::from(scale);
        let digits = if shift >= 0 {
            digits + &"0".repeat(usize::try_from(shift).ok().filter(|&s| s <= 40)?)
        } else {
            let cut = digits.len().saturating_sub(usize::try_from(-shift).ok()?);
            let (kept, dropped) = digits.split_at(cut);
            if dropped.bytes().any(|d| d != b'0') {
                return None;
            }
            kept.to_owned()
        };
        let n: i128 = if digits.is_empty() { 0 } else { digits.parse().ok()? };
        Some(if negative { -n } else { n })
    }

    /// `n` × 10^-`scale`, written with exactly `scale` decimal places: (4440, 2) is `44.40`.
    pub fn from_scaled(n: i128, scale: u32) -> Decimal {
        let digits = format!("{:0>width$}", n.unsigned_abs(), width = scale as usize + 1);
        let (int, frac) = digits.split_at(digits.len() - scale as usize);
        let sign = if n < 0 { "-" } else { "" };
        Decimal(if frac.is_empty() { format!("{sign}{int}") } else { format!("{sign}{int}.{frac}") })
    }
    /// A decimal from a literal; None if `text` isn't a decimal number.
    pub fn parse(text: &str) -> Option<Decimal> {
        match crate::parse(text).ok()?.as_slice() {
            [Value::Number(n)] => Some(Decimal(n.clone())),
            _ => None,
        }
    }
}

impl Decode for Decimal {
    fn decode_with(v: &Value, _: Decoder) -> R<Self> {
        match v {
            Value::Number(text) => Ok(Decimal(text.clone())),
            _ => Err(mismatch("a number (Decimal)", v)),
        }
    }
}
