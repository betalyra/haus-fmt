//! Encoding Rust values as haus: the [`Encode`] trait, and the compact and
//! minimised writers (spec §11: one value per line), which can't fail.

use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::scan::{Special, is_ident, next_special};
use crate::value::{self, args_depth, is_normalized};
use crate::{
    ByteString, Codec, EncodeError, ErrorCode as Code, Limits, List, Number, Record, Rule, Secret, Segment, Tag, Text,
    Value,
};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

/// A Rust type that encodes to a haus value.
///
/// Encoding builds the value and checks it as the constructors of
/// [`Value`] do, with the limits of an [`Encoder`] (spec §7, §9.8): the
/// nesting depth before each container, so that a value nested deeper than
/// the limit fails with `nesting-too-deep` instead of recursing on, and
/// every number, string, key and tag in it. It also counts the values it
/// makes against the node limit ([`Limits::max_nodes`], 64 Mi by default),
/// so that a value whose parts are shared (an `Rc` reached many times, a
/// DAG) fails with `too-many-nodes` instead of expanding without bound. A
/// [`Secret`] is refused (`cannot-encode`, at the secret) unless the encoder
/// reveals secrets ([`Encoder::reveal_secrets`], spec §15).
pub trait Encode {
    /// The haus value, checked with `e`'s limits, at `e`'s depth.
    fn encode_with(&self, e: Encoder) -> R;

    /// The haus value, checked with the default limits; secrets refused.
    fn encode(&self) -> R {
        self.encode_with(Encoder::default())
    }

    /// The [`Value`] itself, if this is one: the writers write it as it is,
    /// instead of encoding a copy of it first.
    #[doc(hidden)]
    fn as_value(&self) -> Option<&Value> {
        None
    }
}

type R = Result<Value, EncodeError>;

/// Where a value is encoded: the limits of the reader it is for, how many
/// containers (records, arrays, payloads) it is inside, counted as the
/// writer counts them, and whether secrets are written. Encoding a container
/// takes [`Encoder::nested`].
///
/// Every value made counts against the node limit ([`Limits::max_nodes`],
/// spec §7, §9.8) of the encoding the encoder belongs to, which
/// [`Encoder::new`] starts: the encoders made from it by [`Encoder::nested`]
/// share the count. The count is kept per thread, for the encoding that
/// counted last: start another encoding in the middle of one (a hand-written
/// [`Encode`] that calls [`Encode::encode`] instead of passing its encoder
/// on) and the outer one counts again from 0 when it continues.
///
/// ```
/// let key = haus::Secret::new("sk-123".to_owned());
/// assert_eq!(haus::to_string(&key).unwrap_err().code, haus::ErrorCode::CannotEncode);
/// let revealed = haus::Encode::encode_with(&key, haus::Encoder::default().reveal_secrets()).unwrap();
/// assert_eq!(haus::ser::write(&revealed), r#""sk-123""#);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Encoder {
    limits: Limits,
    depth: usize,
    /// The value is a tag's only payload: a record here is written
    /// `Tag { … }`, inside the payload's level rather than one more (§7).
    payload: bool,
    /// Secrets are written in full (spec §15, `revealSecrets`).
    reveal: bool,
    budget: Budget,
}

impl Default for Encoder {
    /// At the top, for a reader with the default limits; secrets refused.
    fn default() -> Encoder {
        Encoder::new(&Limits::default())
    }
}

/// The budget of one encoding: its id, and the most values it may make.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Budget {
    id: u64,
    max: u64,
}

/// Ids of encodings, unique in the process.
static ENCODINGS: AtomicU64 = AtomicU64::new(1);

thread_local! {
    /// The encoding that took a step last on this thread, and its steps.
    static STEPS: Cell<(u64, u64)> = const { Cell::new((0, 0)) };
}

impl Budget {
    fn new(max: u64) -> Budget {
        Budget { id: ENCODINGS.fetch_add(1, Ordering::Relaxed), max }
    }

    /// Make `n` more values: `too-many-nodes` beyond the most.
    fn take(self, n: u64) -> Result<(), EncodeError> {
        let steps = STEPS.with(|cell| {
            let (id, steps) = cell.get();
            let steps = if id == self.id { steps } else { 0 }.saturating_add(n);
            cell.set((self.id, steps));
            steps
        });
        match steps > self.max {
            true => Err(too_many_nodes(self.max)),
            false => Ok(()),
        }
    }
}

/// The error for a value that writes more than `max` values (spec §7).
#[cold]
pub(crate) fn too_many_nodes(max: u64) -> EncodeError {
    EncodeError::new(
        Code::TooManyNodes,
        format!("more than {max} values written for one value (a value whose parts are shared expands when written)"),
    )
}

/// The node limit (spec §7), as a count.
pub(crate) fn max_nodes(limits: &Limits) -> u64 {
    u64::try_from(limits.max_nodes).unwrap_or(u64::MAX)
}

impl Encoder {
    /// At the top, for a reader with `limits`, starting an encoding that may
    /// make at most `limits.max_nodes` values. Secrets are refused.
    pub fn new(limits: &Limits) -> Encoder {
        Encoder { limits: *limits, depth: 0, payload: false, reveal: false, budget: Budget::new(max_nodes(limits)) }
    }

    /// The same encoder, writing every secret in full (spec §15,
    /// `revealSecrets`): the value it builds is then ordinary data, and its
    /// canonical form and hash include the secrets. Off by default, so that
    /// a secret leaves the program only by the program's choice; a program
    /// that saves a document with a secret again (a configuration file) sets it.
    pub fn reveal_secrets(self) -> Encoder {
        Encoder { reveal: true, ..self }
    }

    /// Whether secrets are written ([`Encoder::reveal_secrets`]).
    pub fn reveals_secrets(&self) -> bool {
        self.reveal
    }

    /// The same encoder at the top, starting an encoding of its own: for
    /// each top-level value, which the node limit counts on its own (spec §7).
    pub(crate) fn restarted(self) -> Encoder {
        Encoder { depth: 0, payload: false, budget: Budget::new(max_nodes(&self.limits)), ..self }
    }

    /// One more value made: `too-many-nodes` beyond the node limit. Encoders of
    /// values that are no container and use none of the [`Encoder`]'s
    /// methods (a `ToJson` for a number, say) take theirs here.
    pub fn step(&self) -> Result<(), EncodeError> {
        supported(&self.limits)?;
        self.budget.take(1)
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
    pub fn nested(self) -> Result<Encoder, EncodeError> {
        let depth = open(&self.limits, self.depth)?;
        self.step()?;
        Ok(Encoder { depth, payload: false, ..self })
    }

    /// Inside a tag's only payload: like [`Encoder::nested`], but a record
    /// right inside takes no level of its own (`Tag { … }`).
    pub(crate) fn payload(self) -> Result<Encoder, EncodeError> {
        self.nested().map(|e| Encoder { payload: true, ..e })
    }

    /// Inside a record or map: one more level, unless the record is a tag's
    /// only payload and so shares its level.
    pub(crate) fn record_level(self) -> Result<Encoder, EncodeError> {
        match self.payload {
            true => self.step().map(|()| Encoder { payload: false, ..self }),
            false => self.nested(),
        }
    }

    /// A number literal, normalized (`1E+05` is `1e5`), if it is one
    /// (`invalid-number`) within the number limits.
    pub fn number(self, literal: &str) -> R {
        self.step()?;
        Ok(Value::Number(number(literal, &self.limits)?))
    }

    /// A number, if it is within the number limits.
    pub(crate) fn number_value(self, n: Number) -> R {
        self.step()?;
        check_number(&n, &self.limits)?;
        Ok(Value::Number(n))
    }

    /// A tag without a payload: `None`, `Circle`, if it is a tag name within
    /// the string limit.
    pub fn tag(self, tag: &str) -> R {
        self.step()?;
        Ok(tag_name(tag, &self.limits)?.into())
    }

    /// A string, if it is within the string limit.
    pub fn string(self, s: &str) -> R {
        self.step()?;
        Ok(Value::String(Text::with_limits(s, &self.limits)?))
    }

    /// A byte string, if it is within the string limit.
    pub fn bytes(self, b: &[u8]) -> R {
        self.step()?;
        Ok(Value::Bytes(ByteString::with_limits(b, &self.limits)?))
    }

    /// A [`Value`] that exists (an `Any`), if it nests within the depth
    /// limit here: a step for each value in it. Its parts keep the limits
    /// they were built with (spec §7).
    pub fn value(self, v: &Value) -> R {
        self.check(v)?;
        Ok(v.clone())
    }

    /// Whether `v` nests within the depth limit here, as [`Encoder::value`]
    /// checks it, without copying it: a step for each value in it.
    pub fn check(self, v: &Value) -> Result<(), EncodeError> {
        // A record that is a tag's only payload shares the payload's level.
        let at = match (self.payload, v) {
            (true, Value::Record(_)) => self.depth - 1,
            _ => self.depth,
        };
        self.fits(at, v.depth())?;
        self.budget.take(v.size())
    }

    /// Whether a value `depth` levels deep fits inside `at` containers.
    fn fits(self, at: usize, depth: usize) -> Result<(), EncodeError> {
        supported(&self.limits)?;
        match at + depth > self.limits.max_depth {
            true => Err(nesting_too_deep(&self.limits)),
            false => Ok(()),
        }
    }

    /// Whether the unknown variant `u` (its tag and arguments) fits here: a
    /// step for each value in it.
    pub(crate) fn check_unknown(self, u: &Unknown) -> Result<(), EncodeError> {
        check_tag_length(&u.tag, &self.limits)?;
        self.fits(self.depth, args_depth(&u.args))?;
        self.budget.take(1 + u.args.iter().map(Value::size).sum::<u64>())
    }
}

/// The depth inside one more container, after `depth`, if `limits` allow it.
pub(crate) fn open(limits: &Limits, depth: usize) -> Result<usize, EncodeError> {
    supported(limits)?;
    match depth >= limits.max_depth {
        true => Err(nesting_too_deep(limits)),
        false => Ok(depth + 1),
    }
}

fn nesting_too_deep(limits: &Limits) -> EncodeError {
    EncodeError::new(Code::NestingTooDeep, format!("nesting deeper than {} levels", limits.max_depth))
}

/// Whether this binding supports `limits` (spec §7): an error naming
/// [`crate::MAX_SUPPORTED_DEPTH`] if the depth limit is above it.
pub(crate) fn supported(limits: &Limits) -> Result<(), EncodeError> {
    limits.unsupported().map_or(Ok(()), |reason| Err(EncodeError::new(Code::UnsupportedDepth, reason)))
}

/// A case with `N` positional values: `Empty`, `Wrap(3)`, `Point(1, 2)`.
/// The values are encoded inside the payload, which is a level of its own.
pub fn tagged<const N: usize>(tag: &str, e: Encoder, values: impl FnOnce(Encoder) -> [R; N]) -> R {
    if N == 0 {
        return e.tag(tag);
    }
    let tag = tag_name(tag, &e.limits)?;
    let inner = if N == 1 { e.payload()? } else { e.nested()? };
    let args = values(inner)
        .into_iter()
        .enumerate()
        .map(|(i, v)| v.map_err(|e| e.within(Segment::Index(i)).within(Segment::Tag(tag.to_string()))))
        .collect::<Result<_, _>>()?;
    Ok(Value::Variant { tag, args: List::from_checked(args) })
}

/// A case with a record payload: `Circle { r: 1.5 }`. The record is the
/// payload's only level.
pub fn tagged_record<'k, const N: usize>(
    tag: &str,
    e: Encoder,
    fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N],
) -> R {
    let tag = tag_name(tag, &e.limits)?;
    let payload = record(e, fields).map_err(|e| e.within(Segment::Tag(tag.to_string())))?;
    Ok(Value::Variant { tag, args: List::from_checked(vec![payload]) })
}

/// A record from fields in order, leaving out missing optional ones. Fails
/// for a key given twice (`duplicate-key`).
pub fn record<'k, const N: usize>(e: Encoder, fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N]) -> R {
    let inner = e.record_level()?;
    let fields: Vec<(&str, Value)> = fields(inner)
        .into_iter()
        .filter_map(|(k, v)| {
            let field = v?.and_then(|v| check_key(k, &inner.limits).map(|()| (k, v)));
            Some(field.map_err(|e| e.within(Segment::Field(k.to_owned()))))
        })
        .collect::<Result<_, _>>()?;
    // The depth was checked as the fields were encoded.
    Ok(Record::from_fields_with(fields, &value::any())?.into())
}

pub fn array<T>(items: &[T], e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.nested()?;
    items
        .iter()
        .enumerate()
        .map(|(i, x)| f(x, inner).map_err(|e| e.within(Segment::Index(i))))
        .collect::<Result<_, _>>()
        .map(|items| Value::Array(List::from_checked(items)))
}

pub fn map<T>(m: &BTreeMap<String, T>, e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.record_level()?;
    m.iter()
        .map(|(k, v)| {
            let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
            check_key(k, &inner.limits).map_err(within)?;
            Ok((k.clone(), f(v, inner).map_err(within)?))
        })
        .collect::<Result<_, _>>()
        .map(|fields| Value::Record(Record::from_unique(fields)))
}

pub fn maybe<T>(m: &Option<T>, e: Encoder, f: impl FnOnce(&T, Encoder) -> R) -> R {
    match m {
        None => e.tag("None"),
        Some(x) => tagged("Some", e, |e| [f(x, e)]),
    }
}

pub fn result<A, E>(
    r: &Result<A, E>,
    e: Encoder,
    ok: impl FnOnce(&A, Encoder) -> R,
    err: impl FnOnce(&E, Encoder) -> R,
) -> R {
    match r {
        Ok(x) => tagged("Ok", e, |e| [ok(x, e)]),
        Err(x) => tagged("Err", e, |e| [err(x, e)]),
    }
}

/// `Secret a`: refused unless the encoder reveals secrets
/// ([`Encoder::reveal_secrets`], spec §15): `cannot-encode`, at the secret,
/// in an error that doesn't show it. Revealed, the value in full; an error
/// inside it is reported here, saying only that it isn't a valid `what`
/// (`invalid-secret`): never the value, nor where in it, since a key of a
/// `Map` or an `Any` in the path could reveal it.
pub fn secret<T>(s: &Secret<T>, e: Encoder, what: &str, f: impl FnOnce(&T, Encoder) -> R) -> R {
    match e.reveal {
        true => f(s.expose(), e).map_err(|_| invalid_secret(what)),
        false => Err(refused_secret(what)),
    }
}

/// `cannot-encode` for a secret (a `what`) encoded without revealing secrets.
pub(crate) fn refused_secret(what: &str) -> EncodeError {
    EncodeError::new(
        Code::CannotEncode,
        format!("a {what} is not written unless the encoder reveals secrets (Encoder::reveal_secrets)"),
    )
}

/// `invalid-secret`: a revealed secret (a `what`) whose content can't be written.
pub(crate) fn invalid_secret(what: &str) -> EncodeError {
    EncodeError::new(Code::InvalidSecret, format!("not a valid {what} (the value is hidden)"))
}

/// A type with a codec: back to its base type, then encoded.
pub fn codec<C: Codec>(x: &C::Target, e: Encoder) -> R {
    C::encode(x).encode_with(e)
}

/// A value of a type with the package rule `Ru`, encoded: the rule decides
/// on the value encoded (packages.md §6), and a value it rejects is
/// `cannot-encode`, at the place of the type.
pub fn ruled<Ru: Rule>(value: Value) -> R {
    match Ru::check(&value) {
        Ok(()) => Ok(value),
        Err(reason) => Err(EncodeError::new(Code::CannotEncode, rejected_by::<Ru>(&reason))),
    }
}

/// A type with the package rule `Ru` and the codec `C`: back to its base
/// type, encoded, then checked by the rule.
pub fn codec_ruled<C: Codec, Ru: Rule>(x: &C::Target, e: Encoder) -> R {
    ruled::<Ru>(codec::<C>(x, e)?)
}

/// The message for a value the rule `Ru` rejects, for the reason it gives.
pub(crate) fn rejected_by<Ru: Rule>(reason: &str) -> String {
    format!("{reason} (the rule {} of {})", Ru::NAME, Ru::ID)
}

impl<T: Encode + ?Sized> Encode for &T {
    fn encode_with(&self, e: Encoder) -> R {
        (**self).encode_with(e)
    }
    fn as_value(&self) -> Option<&Value> {
        (**self).as_value()
    }
}
impl<T: Encode> Encode for Secret<T> {
    fn encode_with(&self, e: Encoder) -> R {
        secret(self, e, "Secret", T::encode_with)
    }
}
impl<T: Encode> Encode for Box<T> {
    fn encode_with(&self, e: Encoder) -> R {
        (**self).encode_with(e)
    }
    fn as_value(&self) -> Option<&Value> {
        (**self).as_value()
    }
}
impl<T: Encode> Encode for Vec<T> {
    fn encode_with(&self, e: Encoder) -> R {
        array(self, e, T::encode_with)
    }
}
impl<T: Encode> Encode for [T] {
    fn encode_with(&self, e: Encoder) -> R {
        array(self, e, T::encode_with)
    }
}
impl<T: Encode> Encode for BTreeMap<String, T> {
    fn encode_with(&self, e: Encoder) -> R {
        map(self, e, T::encode_with)
    }
}
impl<T: Encode> Encode for Option<T> {
    fn encode_with(&self, e: Encoder) -> R {
        maybe(self, e, T::encode_with)
    }
}
impl<A: Encode, E: Encode> Encode for Result<A, E> {
    fn encode_with(&self, e: Encoder) -> R {
        result(self, e, A::encode_with, E::encode_with)
    }
}
/// `Any`: the value as it is, if it nests within the depth limit here.
impl Encode for Value {
    fn encode_with(&self, e: Encoder) -> R {
        e.value(self)
    }
    fn as_value(&self) -> Option<&Value> {
        Some(self)
    }
}
impl Encode for String {
    fn encode_with(&self, e: Encoder) -> R {
        e.string(self)
    }
}
impl Encode for str {
    fn encode_with(&self, e: Encoder) -> R {
        e.string(self)
    }
}
impl Encode for Bytes {
    fn encode_with(&self, e: Encoder) -> R {
        e.bytes(&self.0)
    }
}
impl Encode for bool {
    fn encode_with(&self, e: Encoder) -> R {
        e.tag(if *self { "True" } else { "False" })
    }
}
macro_rules! integers {
    ($($t:ty),*) => {$(
        impl Encode for $t {
            fn encode_with(&self, e: Encoder) -> R {
                e.number_value(Number::from(*self))
            }
        }
    )*};
}
integers!(i8, i16, i32, i64, u8, u16, u32, u64);
macro_rules! floats {
    ($($t:ty),*) => {$(
        impl Encode for $t {
            fn encode_with(&self, e: Encoder) -> R {
                if self.is_nan() {
                    e.tag("NaN")
                } else if self.is_infinite() {
                    e.tag(if *self > 0.0 { "Infinity" } else { "NegInfinity" })
                } else {
                    e.number(&crate::float::text(*self))
                }
            }
        }
    )*};
}
floats!(f32, f64);
impl Encode for Int {
    fn encode_with(&self, e: Encoder) -> R {
        e.number_value(self.0.clone())
    }
}
impl Encode for Decimal {
    fn encode_with(&self, e: Encoder) -> R {
        e.number_value(self.0.clone())
    }
}
/// An unknown variant: its tag and payload, if they fit here.
impl Encode for Unknown {
    fn encode_with(&self, e: Encoder) -> R {
        e.check_unknown(self)?;
        Ok(Value::Variant { tag: self.tag.clone(), args: List::from_checked(self.args.clone()) })
    }
}
impl Encode for AnyTag {
    fn encode_with(&self, e: Encoder) -> R {
        match self {
            AnyTag::Bare(tag) => e.value(&tag.clone().into()),
            AnyTag::Other(u) => u.encode_with(e),
        }
    }
}

// ── the compact and minimised writers ────────────────────────

/// One value on one line, in the compact layout (spec §11). It can't fail:
/// a value that exists is within the limits it was built with (spec §7), so
/// a reader with those limits reads the text back, a reader with the default
/// limits for every value built by the constructors. Integers are written
/// in decimal.
///
/// ```
/// let v = haus::parse_one(r#"Person { name: "Ada", tags: [0x10, 2] }"#).unwrap();
/// assert_eq!(haus::ser::write(&v), r#"Person { name: "Ada", tags: [16, 2] }"#);
/// ```
pub fn write(v: &Value) -> String {
    write_line(v, true)
}

/// One value on one line in the minimised layout (spec §11): the compact
/// layout without the whitespace between tokens, `Person{name:"Ada",tags:[1,2]}`.
pub fn write_minimised(v: &Value) -> String {
    write_line(v, false)
}

/// One value on one line: compact if `spaced`, minimised otherwise.
pub(crate) fn write_line(v: &Value, spaced: bool) -> String {
    let mut out = String::new();
    Writer { out: &mut out, spaced }.value(v);
    out
}

struct Writer<'a> {
    out: &'a mut String,
    /// Compact has spaces between tokens; minimised has none.
    spaced: bool,
}

impl Writer<'_> {
    /// `v`. Recurses once per level: a value nests at most
    /// [`crate::MAX_SUPPORTED_DEPTH`] levels. The steps that don't recurse
    /// are functions of their own, so that this frame stays small.
    fn value(&mut self, v: &Value) {
        match v {
            Value::Array(items) => self.list('[', items, ']'),
            Value::Record(r) => self.record(r.as_slice()),
            Value::Variant { tag, args } => {
                self.out.push_str(tag);
                match args.as_slice() {
                    [] => {}
                    [Value::Record(r)] => {
                        if self.spaced {
                            self.out.push(' ');
                        }
                        self.record(r.as_slice())
                    }
                    _ => self.list('(', args, ')'),
                }
            }
            scalar => self.scalar(scalar),
        }
    }

    fn scalar(&mut self, v: &Value) {
        match v {
            Value::Number(n) => self.out.push_str(n.as_str()),
            Value::String(s) => quote(s, self.out),
            Value::Bytes(b) => {
                self.out.push_str("x\"");
                hex(b, self.out);
                self.out.push('"');
            }
            _ => {}
        }
    }

    /// `open item, item, … close`: an array or a payload.
    fn list(&mut self, open: char, items: &[Value], close: char) {
        self.out.push(open);
        for (i, x) in items.iter().enumerate() {
            if i > 0 {
                self.out.push_str(self.gap(", ", ","));
            }
            self.value(x);
        }
        self.out.push(close);
    }

    fn record(&mut self, fields: &[(String, Value)]) {
        if fields.is_empty() {
            self.out.push_str("{}");
            return;
        }
        self.out.push_str(self.gap("{ ", "{"));
        for (i, (k, v)) in fields.iter().enumerate() {
            if i > 0 {
                self.out.push_str(self.gap(", ", ","));
            }
            key(k, self.out);
            self.out.push_str(self.gap(": ", ":"));
            self.value(v);
        }
        self.out.push_str(self.gap(" }", "}"));
    }

    /// `spaced` as written in compact, or `minimised`, the same without its spaces.
    fn gap(&self, spaced: &'static str, minimised: &'static str) -> &'static str {
        if self.spaced { spaced } else { minimised }
    }
}

/// Bytes as two lowercase hex digits each.
fn hex(b: &[u8], out: &mut String) {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    out.reserve(2 * b.len());
    for &x in b {
        out.push(char::from(DIGITS[usize::from(x >> 4)]));
        out.push(char::from(DIGITS[usize::from(x & 0xF)]));
    }
}

// ── checks against an encoder's limits ───────────────────────

type W = Result<(), EncodeError>;

/// Whether a record key is within the string limit (spec §7).
pub(crate) fn check_key(k: &str, limits: &Limits) -> W {
    Ok(value::check_text(k, Code::KeyTooLong, limits)?)
}

/// The tag `name`, if it is a tag name (spec §4) within the string limit (§7).
pub(crate) fn tag_name(name: &str, limits: &Limits) -> Result<Tag, EncodeError> {
    Ok(Tag::with_limits(name, limits)?)
}

/// Whether `tag` is a tag name (spec §4) within the string limit (§7): for
/// the JSON forms, which write it as a string.
pub(crate) fn check_tag(tag: &str, limits: &Limits) -> W {
    tag_name(tag, limits).map(drop)
}

/// Whether a tag is within the string limit (§7).
pub(crate) fn check_tag_length(tag: &Tag, limits: &Limits) -> W {
    Ok(value::check_text(tag, Code::TagTooLong, limits)?)
}

/// Whether a string is within the string limit.
pub(crate) fn check_length(s: &str, limits: &Limits) -> W {
    Ok(value::check_text(s, Code::StringTooLong, limits)?)
}

/// Whether a byte string's hex is within the string limit: two characters
/// per byte, also where JSON spells them in base64 (spec §16).
pub(crate) fn check_bytes(b: &[u8], limits: &Limits) -> W {
    Ok(value::check_bytes(b, limits)?)
}

/// A key: bare if it is an identifier (`[a-z_][A-Za-z0-9_]*`), quoted otherwise.
pub(crate) fn key(k: &str, out: &mut String) {
    if is_bare_key(k) { out.push_str(k) } else { quote(k, out) }
}

/// Whether a key is an identifier (`[a-z_][A-Za-z0-9_]*`), written bare.
fn is_bare_key(k: &str) -> bool {
    k.as_bytes().first().is_some_and(|&c| c.is_ascii_lowercase() || c == b'_') && k.bytes().all(is_ident)
}

/// The number of a literal (`1E5` is `1e5`), if it is one (`invalid-number`)
/// within the number limits of `limits` (see [`check_number`]). Text longer
/// than the number limit that isn't normalized fails before it is converted,
/// as the parser rejects it (a long hex literal takes long to convert).
pub(crate) fn number(literal: &str, limits: &Limits) -> Result<Number, EncodeError> {
    if literal.len() > limits.max_number_length && !is_normalized(literal) {
        let reason = format!("number literal longer than {} characters", limits.max_number_length);
        return Err(EncodeError::new(Code::NumberTooLong, reason));
    }
    Ok(Number::with_limits(literal, limits)?)
}

/// Whether a number is within the number limits (spec §7): one longer than
/// the number limit is an error (`number-too-long`), and so is one with a
/// larger exponent (`exponent-too-large`). The length first, as a parser
/// meets it.
pub(crate) fn check_number(n: &str, limits: &Limits) -> W {
    Ok(value::check_number(n, limits)?)
}

/// A `"…"` string with the minimal escapes: `\"`, `\\`, `\n`, `\r`, `\t`,
/// and `\u{…}` (uppercase hex) for the other control characters, the bidi
/// controls and the line and paragraph separators U+2028 and U+2029 (spec
/// §11, §12). The same in every layout and in the canonical form.
pub(crate) fn quote(s: &str, out: &mut String) {
    out.reserve(s.len() + 2);
    out.push('"');
    // Runs of characters written as they are, copied whole.
    let mut run = 0;
    while let Some((at, special)) = next_special(s, run) {
        out.push_str(&s[run..at]);
        match (special, s.as_bytes()[at]) {
            (Special::Quote, _) => out.push_str("\\\""),
            (Special::Backslash, _) => out.push_str("\\\\"),
            (Special::Control, b'\n') => out.push_str("\\n"),
            (Special::Control, b'\r') => out.push_str("\\r"),
            (Special::Control, b'\t') => out.push_str("\\t"),
            // The other controls, the bidirectional ones and the separators.
            (Special::Control | Special::C1 | Special::Bidi | Special::LineSeparator, _) => {
                let c = s[at..].chars().next().unwrap_or_default();
                let _ = write!(out, "\\u{{{:X}}}", u32::from(c));
            }
        }
        run = at + special.width();
    }
    out.push_str(&s[run..]);
    out.push('"');
}
