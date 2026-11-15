//! Encoding Rust values as haus: the [`Encode`] trait and the compact writer
//! (spec §11: one value per line, normal spacing), which checks what it writes.

use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::{Codec, EncodeError, Limits, Secret, Segment, Value};
use std::borrow::Cow;
use std::collections::{BTreeMap, HashSet};
use std::fmt::Write as _;

/// A Rust type that encodes to a haus value.
///
/// Encoding checks the value as it goes, for a writer with the limits of an
/// [`Encoder`] (spec §7, §9.8): the nesting depth before each container, so
/// that a value nested deeper than the limit fails with the writer's error
/// instead of recursing on, and every number, string and raw [`Value`] in it.
/// An error inside a [`Secret`] is reported at the secret (spec §15).
pub trait Encode {
    /// The haus value, checked for a writer with `e`'s limits, at `e`'s depth.
    fn encode_with(&self, e: Encoder) -> R;

    /// The haus value, checked for a writer with the default limits.
    fn encode(&self) -> R {
        self.encode_with(Encoder::default())
    }
}

type R = Result<Value, EncodeError>;

/// Where a value is encoded: the limits of the reader it is for, and how
/// many containers (records, arrays, payloads) it is inside, counted as the
/// writer counts them. Encoding a container takes [`Encoder::nested`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Encoder {
    limits: Limits,
    depth: usize,
}

impl Encoder {
    /// At the top, for a reader with `limits`.
    pub fn new(limits: &Limits) -> Encoder {
        Encoder { limits: *limits, depth: 0 }
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// How many containers the value is inside.
    pub fn depth(&self) -> usize {
        self.depth
    }

    /// Inside one more container, if the depth limit allows it.
    pub fn nested(self) -> Result<Encoder, EncodeError> {
        match self.depth >= self.limits.max_depth {
            true => Err(EncodeError::new(format!("nesting deeper than {} levels", self.limits.max_depth))),
            false => Ok(Encoder { depth: self.depth + 1, ..self }),
        }
    }

    /// A number literal, if the writer takes it.
    pub fn number(self, text: &str) -> R {
        Ok(Value::Number(normalized(text, &self.limits).map_err(EncodeError::new)?.into_owned()))
    }

    /// A string, if it is within the string limit.
    pub fn string(self, s: &str) -> R {
        check_length(s, &self.limits)?;
        Ok(Value::String(s.to_owned()))
    }

    /// A byte string, if it is within the string limit.
    pub fn bytes(self, b: &[u8]) -> R {
        check_bytes(b, &self.limits)?;
        Ok(Value::Bytes(b.to_vec()))
    }

    /// A [`Value`] built in code, if the writer takes it here.
    pub fn value(self, v: &Value) -> R {
        self.check(v)?;
        Ok(v.clone())
    }

    /// Whether the writer takes `v` here: it writes it, and drops the text.
    fn check(self, v: &Value) -> Result<(), EncodeError> {
        Writer { out: &mut String::new(), limits: &self.limits }.value(v, self.depth)
    }
}

/// A variant value. Doesn't check `tag`.
pub fn variant(tag: &str, args: Vec<Value>) -> Value {
    Value::Variant { tag: tag.to_owned(), args }
}

/// A case with `N` positional values: `Empty`, `Wrap(3)`, `Point(1, 2)`.
/// The values are encoded inside the payload, which is a level of its own.
pub fn tagged<const N: usize>(tag: &str, e: Encoder, values: impl FnOnce(Encoder) -> [R; N]) -> R {
    if N == 0 {
        return Ok(variant(tag, vec![]));
    }
    let args = values(e.nested()?)
        .into_iter()
        .enumerate()
        .map(|(i, v)| v.map_err(|e| e.within(Segment::Index(i)).within(Segment::Tag(tag.to_owned()))))
        .collect::<Result<_, _>>()?;
    Ok(variant(tag, args))
}

/// A case with a record payload: `Circle { r: 1.5 }`. The record is the
/// payload's only level.
pub fn tagged_record<'k, const N: usize>(
    tag: &str,
    e: Encoder,
    fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N],
) -> R {
    let payload = record(e, fields).map_err(|e| e.within(Segment::Tag(tag.to_owned())))?;
    Ok(variant(tag, vec![payload]))
}

/// A record from fields in order, leaving out missing optional ones.
pub fn record<'k, const N: usize>(e: Encoder, fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N]) -> R {
    fields(e.nested()?)
        .into_iter()
        .filter_map(|(k, v)| Some(v?.map(|v| (k.to_owned(), v)).map_err(|e| e.within(Segment::Field(k.to_owned())))))
        .collect::<Result<_, _>>()
        .map(Value::Record)
}

pub fn array<T>(items: &[T], e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.nested()?;
    items
        .iter()
        .enumerate()
        .map(|(i, x)| f(x, inner).map_err(|e| e.within(Segment::Index(i))))
        .collect::<Result<_, _>>()
        .map(Value::Array)
}

pub fn map<T>(m: &BTreeMap<String, T>, e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.nested()?;
    m.iter()
        .map(|(k, v)| {
            let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
            check_length(k, &inner.limits).map_err(within)?;
            Ok((k.clone(), f(v, inner).map_err(within)?))
        })
        .collect::<Result<_, _>>()
        .map(Value::Record)
}

pub fn maybe<T>(m: &Option<T>, e: Encoder, f: impl FnOnce(&T, Encoder) -> R) -> R {
    match m {
        None => Ok(variant("None", vec![])),
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

/// `Secret a`: the value in full (the receiver needs it). An error inside it
/// is reported here, saying only that it isn't a valid `what`: never the
/// value, nor where in it, since a key of a `Map` or an `Any` in the path
/// could reveal it (spec §15).
pub fn secret<T>(s: &Secret<T>, e: Encoder, what: &str, f: impl FnOnce(&T, Encoder) -> R) -> R {
    f(s.expose(), e).map_err(|_| EncodeError::new(format!("not a valid {what} (the value is hidden)")))
}

/// A type with a codec: back to its base type, then encoded.
pub fn codec<C: Codec>(x: &C::Target, e: Encoder) -> R {
    C::encode(x).encode_with(e)
}

impl<T: Encode + ?Sized> Encode for &T {
    fn encode_with(&self, e: Encoder) -> R {
        (**self).encode_with(e)
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
/// `Any`: the value as it is, checked as the writer checks it.
impl Encode for Value {
    fn encode_with(&self, e: Encoder) -> R {
        e.value(self)
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
    fn encode_with(&self, _: Encoder) -> R {
        Ok(variant(if *self { "True" } else { "False" }, vec![]))
    }
}
macro_rules! integers {
    ($($t:ty),*) => {$(
        impl Encode for $t {
            fn encode_with(&self, e: Encoder) -> R {
                e.number(&self.to_string())
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
                    Ok(variant("NaN", vec![]))
                } else if self.is_infinite() {
                    Ok(variant(if *self > 0.0 { "Infinity" } else { "NegInfinity" }, vec![]))
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
        e.number(self.as_str())
    }
}
impl Encode for Decimal {
    fn encode_with(&self, e: Encoder) -> R {
        e.number(self.as_str())
    }
}
/// An unknown variant: its tag and payload, checked as the writer checks them.
impl Encode for Unknown {
    fn encode_with(&self, e: Encoder) -> R {
        let v = variant(&self.tag, self.args.clone());
        e.check(&v)?;
        Ok(v)
    }
}
impl Encode for AnyTag {
    fn encode_with(&self, e: Encoder) -> R {
        match self {
            AnyTag::Bare(tag) => e.value(&variant(tag, vec![])),
            AnyTag::Other(u) => u.encode_with(e),
        }
    }
}

// ── the compact writer ───────────────────────────────────────

/// One value on one line (spec §11, compact), with the default limits.
pub fn write(v: &Value) -> Result<String, EncodeError> {
    write_with(v, &Limits::default())
}

/// One value on one line, for a reader with `limits`. The value is checked as
/// it is written (spec §9.8), since one built in code may hold anything: number
/// literals (normalized as the parser reads them: `1E5` is written `1e5`), tag
/// names, unique keys, and the nesting depth and lengths of `limits`. An
/// integer longer than `limits.max_number_length` is written in hex, so
/// that the same reader takes it.
pub fn write_with(v: &Value, limits: &Limits) -> Result<String, EncodeError> {
    let mut out = String::new();
    Writer { out: &mut out, limits }.value(v, 0)?;
    Ok(out)
}

struct Writer<'a> {
    out: &'a mut String,
    limits: &'a Limits,
}

type W = Result<(), EncodeError>;

impl Writer<'_> {
    /// `v`, inside `depth` containers.
    fn value(&mut self, v: &Value, depth: usize) -> W {
        match v {
            Value::Number(n) => {
                let text = number(n, self.limits).map_err(EncodeError::new)?;
                self.out.push_str(&text);
            }
            Value::String(s) => {
                check_length(s, self.limits)?;
                quote(s, self.out);
            }
            Value::Bytes(b) => {
                check_bytes(b, self.limits)?;
                self.out.push_str("x\"");
                for x in b {
                    let _ = write!(self.out, "{x:02x}");
                }
                self.out.push('"');
            }
            Value::Array(items) => {
                self.open(depth)?;
                self.out.push('[');
                self.items(items, depth + 1, Segment::Index)?;
                self.out.push(']');
            }
            Value::Record(fields) => self.record(fields, depth)?,
            Value::Variant { tag, args } => {
                if !is_tag(tag) {
                    return Err(EncodeError::new("not a tag name: A to Z, then letters, digits and _"));
                }
                self.out.push_str(tag);
                let within = |e: EncodeError| e.within(Segment::Tag(tag.clone()));
                match args.as_slice() {
                    [] => {}
                    [Value::Record(fields)] => {
                        self.out.push(' ');
                        self.record(fields, depth).map_err(within)?;
                    }
                    _ => {
                        self.open(depth)?;
                        self.out.push('(');
                        self.items(args, depth + 1, Segment::Index).map_err(within)?;
                        self.out.push(')');
                    }
                }
            }
        }
        Ok(())
    }

    /// Opening a container inside `depth` others.
    fn open(&self, depth: usize) -> W {
        if depth >= self.limits.max_depth {
            return Err(EncodeError::new(format!("nesting deeper than {} levels", self.limits.max_depth)));
        }
        Ok(())
    }

    /// Items separated by `, `, at `depth`.
    fn items(&mut self, items: &[Value], depth: usize, at: fn(usize) -> Segment) -> W {
        for (i, x) in items.iter().enumerate() {
            if i > 0 {
                self.out.push_str(", ");
            }
            self.value(x, depth).map_err(|e| e.within(at(i)))?;
        }
        Ok(())
    }

    fn record(&mut self, fields: &[(String, Value)], depth: usize) -> W {
        self.open(depth)?;
        if fields.is_empty() {
            self.out.push_str("{}");
            return Ok(());
        }
        // Keys are unique (spec §1): a record built in code might repeat one.
        if fields.len() > 1 {
            let mut seen = HashSet::with_capacity(fields.len());
            if let Some((k, _)) = fields.iter().find(|(k, _)| !seen.insert(k.as_str())) {
                return Err(EncodeError::new("the key is used twice in this record").within(Segment::Field(k.clone())));
            }
        }
        self.out.push_str("{ ");
        for (i, (k, v)) in fields.iter().enumerate() {
            if i > 0 {
                self.out.push_str(", ");
            }
            let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
            check_length(k, self.limits).map_err(within)?;
            key(k, self.out);
            self.out.push_str(": ");
            self.value(v, depth + 1).map_err(within)?;
        }
        self.out.push_str(" }");
        Ok(())
    }
}

/// Whether a string or key is within the string limit.
fn check_length(s: &str, limits: &Limits) -> W {
    let max = limits.max_string_length;
    if s.len() > max && s.chars().count() > max {
        return Err(EncodeError::new(format!("string longer than {max} characters")));
    }
    Ok(())
}

/// Whether a byte string's hex is within the string limit.
fn check_bytes(b: &[u8], limits: &Limits) -> W {
    if b.len() > limits.max_string_length / 2 {
        return Err(EncodeError::new(format!("byte string longer than {} characters", limits.max_string_length)));
    }
    Ok(())
}

/// A tag name: `[A-Z][A-Za-z0-9_]*`.
pub(crate) fn is_tag(tag: &str) -> bool {
    tag.starts_with(|c: char| c.is_ascii_uppercase()) && tag.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}

/// A key: bare if it is an identifier (`[a-z_][A-Za-z0-9_]*`), quoted otherwise.
pub(crate) fn key(k: &str, out: &mut String) {
    let bare = k.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_');
    if bare { out.push_str(k) } else { quote(k, out) }
}

/// The text a number is written as, for a reader with `limits`, or why it
/// can't be written: its normalized literal (spec §2), in hex if it is an
/// integer longer than the number limit.
fn number<'a>(text: &'a str, limits: &Limits) -> Result<Cow<'a, str>, String> {
    let n = normalized(text, limits)?;
    if n.len() <= limits.max_number_length {
        return Ok(n);
    }
    // `normalized` let it through: an integer whose hex literal fits.
    Ok(number_text(&n, limits.max_number_length).into_owned().into())
}

/// A number's normalized literal (spec §2), always in decimal, if it can be
/// written for a reader with `limits` (an integer longer than the number
/// limit in hex): `1E5` is `1e5`; `abc` is an error.
pub(crate) fn normalized<'a>(text: &'a str, limits: &Limits) -> Result<Cow<'a, str>, String> {
    let too_long = || format!("number literal longer than {} characters", limits.max_number_length);
    let n: Cow<str> = if is_normalized(text) {
        text.into()
    } else if text.len() > limits.max_number_length {
        return Err(too_long());
    } else {
        // The exponent is checked below, on the normalized literal.
        let syntax = Limits { max_exponent: u64::MAX, ..*limits };
        crate::parser::number_literal(text, &syntax).ok_or("not a number literal")?.into()
    };
    if let Some((_, exp)) = n.split_once('e') {
        let digits = exp.trim_start_matches('-');
        if digits.len() > 19 || digits.parse::<u64>().map_or(true, |e| e > limits.max_exponent) {
            return Err(format!("exponent larger than {}", limits.max_exponent));
        }
    }
    if n.len() <= limits.max_number_length {
        return Ok(n);
    }
    let digits = n.strip_prefix('-').unwrap_or(&n);
    if !digits.bytes().all(|c| c.is_ascii_digit()) || hex_length_at_least(&n) > limits.max_number_length {
        return Err(too_long());
    }
    if number_text(&n, limits.max_number_length).len() > limits.max_number_length {
        return Err(too_long());
    }
    Ok(n)
}

/// Whether `text` is a normalized literal (spec §2), as the parser gives it:
/// `-?(0|[1-9][0-9]*)(.[0-9]+)?(e(0|-?[1-9][0-9]*))?`.
pub(crate) fn is_normalized(text: &str) -> bool {
    fn whole(s: &str) -> bool {
        s == "0" || (s.starts_with(|c: char| ('1'..='9').contains(&c)) && s.bytes().all(|c| c.is_ascii_digit()))
    }
    let (mantissa, exp) = text.split_once('e').map_or((text, None), |(m, e)| (m, Some(e)));
    let mantissa = mantissa.strip_prefix('-').unwrap_or(mantissa);
    let (int, frac) = mantissa.split_once('.').map_or((mantissa, None), |(i, f)| (i, Some(f)));
    whole(int)
        && frac.is_none_or(|f| !f.is_empty() && f.bytes().all(|c| c.is_ascii_digit()))
        && exp.is_none_or(|e| whole(e) || e.strip_prefix('-').is_some_and(|d| d != "0" && whole(d)))
}

/// A lower bound of the length of an integer's hex literal, without converting
/// it: d decimal digits have at least ⌊(d − 1) · log₁₆ 10⌋ + 1 hex digits.
fn hex_length_at_least(n: &str) -> usize {
    let sign = usize::from(n.starts_with('-'));
    let digits = n.len() - sign;
    // 0.830482 is just below log₁₆ 10 = 0.8304820237…, so this stays a lower bound.
    let hex = (digits as u128 - 1) * 830_482 / 1_000_000 + 1;
    sign + 2 + usize::try_from(hex).unwrap_or(usize::MAX)
}

/// A number's normalized literal, except an integer longer than `max` (the
/// number limit, spec §7), which is written in hex so that it parses again
/// (§11, §12).
pub(crate) fn number_text(n: &str, max: usize) -> Cow<'_, str> {
    let (sign, digits) = n.strip_prefix('-').map_or(("", n), |d| ("-", d));
    if n.len() > max && digits.bytes().all(|c| c.is_ascii_digit()) {
        format!("{sign}0x{}", decimal_to_hex(digits)).into()
    } else {
        n.into()
    }
}

/// Decimal digits as lowercase hex, without leading zeros.
fn decimal_to_hex(digits: &str) -> String {
    // Little-endian limbs of base 2^32.
    let mut limbs: Vec<u64> = vec![0];
    for d in digits.bytes() {
        let mut carry = u64::from(d - b'0');
        for limb in &mut limbs {
            let v = *limb * 10 + carry;
            *limb = v & 0xffff_ffff;
            carry = v >> 32;
        }
        if carry > 0 {
            limbs.push(carry);
        }
    }
    let first = format!("{:x}", limbs.last().copied().unwrap_or(0));
    limbs.iter().rev().skip(1).fold(first, |mut out, limb| {
        let _ = write!(out, "{limb:08x}");
        out
    })
}

/// A `"…"` string with the minimal escapes.
pub(crate) fn quote(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if matches!(u32::from(c), 0..0x20 | 0x7F..=0x9F)
                || matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}') =>
            {
                let _ = write!(out, "\\u{{{:X}}}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}
