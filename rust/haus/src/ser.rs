//! Encoding Rust values as haus: the [`Encode`] trait and the compact writer
//! (spec §11: one value per line, normal spacing), which checks what it writes.

use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::keys::first_repeated;
use crate::scan::{Special, is_ident, next_special, plain_decimal};
use crate::{Codec, EncodeError, ErrorCode as Code, Limits, Secret, Segment, Value};
use std::borrow::Cow;
use std::cell::Cell;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};

/// A Rust type that encodes to a haus value.
///
/// Encoding checks the value as it goes, for a writer with the limits of an
/// [`Encoder`] (spec §7, §9.8): the nesting depth before each container, so
/// that a value nested deeper than the limit fails with the writer's error
/// instead of recursing on, and every number, string and raw [`Value`] in it.
/// It also counts the values it makes against a budget (16 Mi by default,
/// see [`Encoder::with_max_steps`]), so that a value whose parts are shared
/// (an `Rc` reached many times, a DAG) fails with `step-budget` instead of
/// expanding without bound. An error inside a [`Secret`] is reported at the
/// secret (spec §15).
pub trait Encode {
    /// The haus value, checked for a writer with `e`'s limits, at `e`'s depth.
    fn encode_with(&self, e: Encoder) -> R;

    /// The haus value, checked for a writer with the default limits.
    fn encode(&self) -> R {
        self.encode_with(Encoder::default())
    }

    /// The [`Value`] itself, if this is one: the writers write it as it is,
    /// checking it as they go, instead of encoding a copy of it first.
    #[doc(hidden)]
    fn as_value(&self) -> Option<&Value> {
        None
    }
}

type R = Result<Value, EncodeError>;

/// Where a value is encoded: the limits of the reader it is for, and how
/// many containers (records, arrays, payloads) it is inside, counted as the
/// writer counts them. Encoding a container takes [`Encoder::nested`].
///
/// Every value made counts one step against the budget of the encoding the
/// encoder belongs to, which [`Encoder::new`] starts (spec §9.8): the
/// encoders made from it by [`Encoder::nested`] share it. The count is kept
/// per thread, for the encoding that counted last: start another encoding
/// in the middle of one (a hand-written [`Encode`] that calls
/// [`Encode::encode`] instead of passing its encoder on) and the outer one
/// counts again from 0 when it continues.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Encoder {
    limits: Limits,
    depth: usize,
    /// The value is a tag's only payload: a record here is written
    /// `Tag { … }`, inside the payload's level rather than one more (§7).
    payload: bool,
    budget: Budget,
}

impl Default for Encoder {
    /// At the top, for a reader with the default limits.
    fn default() -> Encoder {
        Encoder::new(&Limits::default())
    }
}

/// The most values one encoding makes by default (spec §9.8: TypeScript's
/// 16 Mi steps when encoding): see [`Encoder::with_max_steps`].
pub const DEFAULT_MAX_STEPS: u64 = 16 * 1024 * 1024;

/// The budget of one encoding: its id, and the most steps it may take.
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

    /// Take `n` more steps: `step-budget` beyond the most.
    fn take(self, n: u64) -> Result<(), EncodeError> {
        let steps = STEPS.with(|cell| {
            let (id, steps) = cell.get();
            let steps = if id == self.id { steps } else { 0 }.saturating_add(n);
            cell.set((self.id, steps));
            steps
        });
        match steps > self.max {
            true => Err(EncodeError::new(
                Code::StepBudget,
                format!(
                    "encode budget of {} steps exceeded (a value whose parts are shared expands when written)",
                    self.max
                ),
            )),
            false => Ok(()),
        }
    }
}

impl Encoder {
    /// At the top, for a reader with `limits`, starting an encoding with a
    /// budget of [`DEFAULT_MAX_STEPS`].
    pub fn new(limits: &Limits) -> Encoder {
        Encoder { limits: *limits, depth: 0, payload: false, budget: Budget::new(DEFAULT_MAX_STEPS) }
    }

    /// The same encoding, with a budget of `max` steps, one per value made:
    /// beyond it, encoding fails with `step-budget`.
    pub fn with_max_steps(self, max: u64) -> Encoder {
        Encoder { budget: Budget { max, ..self.budget }, ..self }
    }

    /// The most steps this encoding may take.
    pub fn max_steps(&self) -> u64 {
        self.budget.max
    }

    /// One more value made: `step-budget` beyond the budget. Encoders of
    /// values that are no container and use none of the [`Encoder`]'s
    /// methods (a `ToJson` for a number, say) take theirs here.
    pub fn step(&self) -> Result<(), EncodeError> {
        self.budget.take(1)
    }

    /// `n` more values made.
    pub(crate) fn steps(&self, n: u64) -> Result<(), EncodeError> {
        self.budget.take(n)
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

    /// A number literal, if the writer takes it.
    pub fn number(self, text: &str) -> R {
        self.step()?;
        Ok(Value::Number(normalized(text, &self.limits)?.into_owned()))
    }

    /// A tag without a payload: `None`, `Circle`, if it is a tag name within
    /// the string limit.
    pub fn tag(self, tag: &str) -> R {
        self.step()?;
        check_tag(tag, &self.limits)?;
        Ok(variant(tag, vec![]))
    }

    /// A string, if it is within the string limit.
    pub fn string(self, s: &str) -> R {
        self.step()?;
        check_length(s, &self.limits)?;
        Ok(Value::String(s.to_owned()))
    }

    /// A byte string, if it is within the string limit.
    pub fn bytes(self, b: &[u8]) -> R {
        self.step()?;
        check_bytes(b, &self.limits)?;
        Ok(Value::Bytes(b.to_vec()))
    }

    /// A [`Value`] built in code, if the writer takes it here: a step for
    /// each value in it.
    pub fn value(self, v: &Value) -> R {
        self.check(v)?;
        Ok(v.clone())
    }

    /// Whether the writer takes `v` here, as [`Encoder::value`] checks it,
    /// without copying it: a step for each value in it.
    pub fn check(self, v: &Value) -> Result<(), EncodeError> {
        supported(&self.limits)?;
        // A record that is a tag's only payload shares the payload's level.
        let depth = match (self.payload, v) {
            (true, Value::Record(_)) => self.depth - 1,
            _ => self.depth,
        };
        let mut writer = Writer { out: &mut Discard, limits: &self.limits, spaced: true, values: 0 };
        writer.value(v, depth)?;
        self.budget.take(writer.values)
    }
}

/// The depth inside one more container, after `depth`, if `limits` allow it.
pub(crate) fn open(limits: &Limits, depth: usize) -> Result<usize, EncodeError> {
    supported(limits)?;
    match depth >= limits.max_depth {
        true => Err(EncodeError::new(Code::NestingTooDeep, format!("nesting deeper than {} levels", limits.max_depth))),
        false => Ok(depth + 1),
    }
}

/// Whether this binding supports `limits` (spec §7): an error naming
/// [`crate::MAX_SUPPORTED_DEPTH`] if the depth limit is above it.
pub(crate) fn supported(limits: &Limits) -> Result<(), EncodeError> {
    limits.unsupported().map_or(Ok(()), |reason| Err(EncodeError::new(Code::UnsupportedDepth, reason)))
}

/// A variant value. Doesn't check `tag`.
pub fn variant(tag: &str, args: Vec<Value>) -> Value {
    Value::Variant { tag: tag.to_owned(), args }
}

/// A case with `N` positional values: `Empty`, `Wrap(3)`, `Point(1, 2)`.
/// The values are encoded inside the payload, which is a level of its own.
pub fn tagged<const N: usize>(tag: &str, e: Encoder, values: impl FnOnce(Encoder) -> [R; N]) -> R {
    if N == 0 {
        return e.tag(tag);
    }
    check_tag(tag, &e.limits)?;
    let inner = if N == 1 { e.payload()? } else { e.nested()? };
    let args = values(inner)
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
    check_tag(tag, &e.limits)?;
    let payload = record(e, fields).map_err(|e| e.within(Segment::Tag(tag.to_owned())))?;
    Ok(variant(tag, vec![payload]))
}

/// A record from fields in order, leaving out missing optional ones.
pub fn record<'k, const N: usize>(e: Encoder, fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N]) -> R {
    let inner = e.record_level()?;
    fields(inner)
        .into_iter()
        .filter_map(|(k, v)| {
            let field = v?.and_then(|v| check_key(k, &inner.limits).map(|()| (k.to_owned(), v)));
            Some(field.map_err(|e| e.within(Segment::Field(k.to_owned()))))
        })
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
    let inner = e.record_level()?;
    m.iter()
        .map(|(k, v)| {
            let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
            check_key(k, &inner.limits).map_err(within)?;
            Ok((k.clone(), f(v, inner).map_err(within)?))
        })
        .collect::<Result<_, _>>()
        .map(Value::Record)
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

/// `Secret a`: the value in full (the receiver needs it). An error inside it
/// is reported here, saying only that it isn't a valid `what`: never the
/// value, nor where in it, since a key of a `Map` or an `Any` in the path
/// could reveal it (spec §15).
pub fn secret<T>(s: &Secret<T>, e: Encoder, what: &str, f: impl FnOnce(&T, Encoder) -> R) -> R {
    f(s.expose(), e)
        .map_err(|_| EncodeError::new(Code::InvalidSecret, format!("not a valid {what} (the value is hidden)")))
}

/// A type with a codec: back to its base type, then encoded.
pub fn codec<C: Codec>(x: &C::Target, e: Encoder) -> R {
    C::encode(x).encode_with(e)
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
/// `Any`: the value as it is, checked as the writer checks it.
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
/// names, unique keys, and the nesting depth and lengths of `limits`.
/// Integers are written in decimal: one longer than
/// `limits.max_number_length` is an error (`number-too-long`).
pub fn write_with(v: &Value, limits: &Limits) -> Result<String, EncodeError> {
    write_line(v, limits, true)
}

/// One value on one line in the minimised layout (spec §11): the compact
/// layout without the whitespace between tokens, `Person{name:"Ada",tags:[1,2]}`.
/// Checked as [`write_with`] checks it.
pub fn write_minimised_with(v: &Value, limits: &Limits) -> Result<String, EncodeError> {
    write_line(v, limits, false)
}

fn write_line(v: &Value, limits: &Limits, spaced: bool) -> Result<String, EncodeError> {
    supported(limits)?;
    let mut out = String::new();
    Writer { out: &mut out, limits, spaced, values: 0 }.value(v, 0)?;
    Ok(out)
}

/// What [`crate::to_string_with`] and [`crate::to_string_minimised_with`]
/// do for a [`Value`] (`Encoder::new(limits).value(v)`, then
/// [`write_with`]), in one pass and without copying the value: the same
/// text, and the same errors in the same order (the writer's first, then the
/// step budget).
pub(crate) fn write_value(v: &Value, limits: &Limits, spaced: bool) -> Result<String, EncodeError> {
    supported(limits)?;
    let mut out = String::new();
    let mut writer = Writer { out: &mut out, limits, spaced, values: 0 };
    writer.value(v, 0)?;
    Budget::new(DEFAULT_MAX_STEPS).take(writer.values)?;
    Ok(out)
}

/// Where a [`Writer`] writes: a `String`, or nowhere when it only checks.
trait Sink {
    fn push(&mut self, c: char);
    fn push_str(&mut self, s: &str);
    /// `"…"`, as [`quote`] writes it.
    fn quote(&mut self, s: &str);
    /// Bytes as hex digits.
    fn hex(&mut self, b: &[u8]);
}

impl Sink for String {
    fn push(&mut self, c: char) {
        String::push(self, c);
    }
    fn push_str(&mut self, s: &str) {
        String::push_str(self, s);
    }
    fn quote(&mut self, s: &str) {
        quote(s, self);
    }
    fn hex(&mut self, b: &[u8]) {
        const DIGITS: &[u8; 16] = b"0123456789abcdef";
        self.reserve(2 * b.len());
        for &x in b {
            String::push(self, char::from(DIGITS[usize::from(x >> 4)]));
            String::push(self, char::from(DIGITS[usize::from(x & 0xF)]));
        }
    }
}

/// Writes nothing: for checking.
struct Discard;

impl Sink for Discard {
    fn push(&mut self, _: char) {}
    fn push_str(&mut self, _: &str) {}
    fn quote(&mut self, _: &str) {}
    fn hex(&mut self, _: &[u8]) {}
}

struct Writer<'a, O: Sink> {
    out: &'a mut O,
    limits: &'a Limits,
    /// Compact has spaces between tokens; minimised has none.
    spaced: bool,
    /// Values written so far.
    values: u64,
}

type W = Result<(), EncodeError>;

impl<O: Sink> Writer<'_, O> {
    /// `v`, inside `depth` containers. The steps that don't recurse are
    /// functions of their own, so that this frame stays small (see
    /// [`crate::MAX_SUPPORTED_DEPTH`]).
    fn value(&mut self, v: &Value, depth: usize) -> W {
        self.values += 1;
        match v {
            Value::Array(items) => self.list('[', items, depth, ']'),
            Value::Record(fields) => self.record(fields, depth),
            Value::Variant { tag, args } => {
                self.tag(tag)?;
                match args.as_slice() {
                    [] => Ok(()),
                    [Value::Record(fields)] => {
                        if self.spaced {
                            self.out.push(' ');
                        }
                        self.record(fields, depth).map_err(|e| e.within(Segment::Tag(tag.clone())))
                    }
                    _ => self.list('(', args, depth, ')').map_err(|e| e.within(Segment::Tag(tag.clone()))),
                }
            }
            scalar => self.scalar(scalar),
        }
    }

    fn scalar(&mut self, v: &Value) -> W {
        match v {
            Value::Number(n) => self.out.push_str(&normalized(n, self.limits)?),
            Value::String(s) => {
                check_length(s, self.limits)?;
                self.out.quote(s);
            }
            Value::Bytes(b) => {
                check_bytes(b, self.limits)?;
                self.out.push_str("x\"");
                self.out.hex(b);
                self.out.push('"');
            }
            _ => {}
        }
        Ok(())
    }

    /// A tag name within the string limit.
    fn tag(&mut self, tag: &str) -> W {
        check_tag(tag, self.limits)?;
        self.out.push_str(tag);
        Ok(())
    }

    /// `open item, item, … close`: an array or a payload, inside `depth` containers.
    fn list(&mut self, open: char, items: &[Value], depth: usize, close: char) -> W {
        let depth = self::open(self.limits, depth)?;
        self.out.push(open);
        for (i, x) in items.iter().enumerate() {
            if i > 0 {
                self.out.push_str(self.gap(", ", ","));
            }
            self.value(x, depth).map_err(|e| e.within(Segment::Index(i)))?;
        }
        self.out.push(close);
        Ok(())
    }

    fn record(&mut self, fields: &[(String, Value)], depth: usize) -> W {
        let depth = self::open(self.limits, depth)?;
        if fields.is_empty() {
            self.out.push_str("{}");
            return Ok(());
        }
        unique_keys(fields)?;
        self.out.push_str(self.gap("{ ", "{"));
        for (i, (k, v)) in fields.iter().enumerate() {
            self.key(i, k)?;
            self.value(v, depth).map_err(|e| e.within(Segment::Field(k.clone())))?;
        }
        self.out.push_str(self.gap(" }", "}"));
        Ok(())
    }

    /// The `i`th key of a record, with `: ` after it (`:` minimised).
    fn key(&mut self, i: usize, k: &str) -> W {
        if i > 0 {
            self.out.push_str(self.gap(", ", ","));
        }
        check_key(k, self.limits).map_err(|e| e.within(Segment::Field(k.to_owned())))?;
        match is_bare_key(k) {
            true => self.out.push_str(k),
            false => self.out.quote(k),
        }
        self.out.push_str(self.gap(": ", ":"));
        Ok(())
    }

    /// `spaced` as written in compact, or `minimised`, the same without its spaces.
    fn gap(&self, spaced: &'static str, minimised: &'static str) -> &'static str {
        if self.spaced { spaced } else { minimised }
    }
}

/// How many values `v` holds, itself included. Recurses as deep as `v` is
/// nested: for values checked against the depth limit.
pub(crate) fn size(v: &Value) -> u64 {
    match v {
        Value::Array(items) | Value::Variant { args: items, .. } => 1 + items.iter().map(size).sum::<u64>(),
        Value::Record(fields) => 1 + fields.iter().map(|(_, x)| size(x)).sum::<u64>(),
        _ => 1,
    }
}

/// Keys are unique (spec §1): a record built in code might repeat one.
pub(crate) fn unique_keys(fields: &[(String, Value)]) -> W {
    match first_repeated(fields) {
        Some(i) => Err(EncodeError::new(Code::DuplicateKey, "the key is used twice in this record")
            .within(Segment::Field(fields[i].0.clone()))),
        None => Ok(()),
    }
}

/// Whether a record key is within the string limit (spec §7).
pub(crate) fn check_key(k: &str, limits: &Limits) -> W {
    check_text(k, Code::KeyTooLong, limits)
}

/// Whether a tag is a tag name, within the string limit (spec §4, §7).
pub(crate) fn check_tag(tag: &str, limits: &Limits) -> W {
    if !is_tag(tag) {
        return Err(EncodeError::new(Code::InvalidTag, "not a tag name: A to Z, then letters, digits and _"));
    }
    check_text(tag, Code::TagTooLong, limits)
}

/// Whether a string, key or tag (`code` says which) is within the string limit.
fn check_text(s: &str, code: Code, limits: &Limits) -> W {
    let max = limits.max_string_length;
    if s.len() > max && s.chars().count() > max {
        let what = match code {
            Code::KeyTooLong => "key",
            Code::TagTooLong => "tag",
            _ => "string",
        };
        return Err(EncodeError::new(code, format!("{what} longer than {max} characters")));
    }
    Ok(())
}

/// Whether a string is within the string limit.
pub(crate) fn check_length(s: &str, limits: &Limits) -> W {
    check_text(s, Code::StringTooLong, limits)
}

/// Whether a byte string's hex is within the string limit: two characters
/// per byte, also where JSON spells them in base64 (spec §16).
pub(crate) fn check_bytes(b: &[u8], limits: &Limits) -> W {
    if b.len() > limits.max_string_length / 2 {
        let reason = format!("byte string longer than {} characters", limits.max_string_length);
        return Err(EncodeError::new(Code::StringTooLong, reason));
    }
    Ok(())
}

/// A tag name: `[A-Z][A-Za-z0-9_]*`.
pub(crate) fn is_tag(tag: &str) -> bool {
    tag.as_bytes().first().is_some_and(u8::is_ascii_uppercase) && tag.bytes().all(is_ident)
}

/// A key: bare if it is an identifier (`[a-z_][A-Za-z0-9_]*`), quoted otherwise.
pub(crate) fn key(k: &str, out: &mut String) {
    if is_bare_key(k) { out.push_str(k) } else { quote(k, out) }
}

/// Whether a key is an identifier (`[a-z_][A-Za-z0-9_]*`), written bare.
fn is_bare_key(k: &str) -> bool {
    k.as_bytes().first().is_some_and(|&c| c.is_ascii_lowercase() || c == b'_') && k.bytes().all(is_ident)
}

/// A number's normalized literal (spec §2), always in decimal, if it can be
/// written for a reader with `limits`: `1E5` is `1e5`; `abc` is an error
/// (`invalid-number`), and so is one longer than the number limit
/// (`number-too-long`) or with a larger exponent (`exponent-too-large`).
pub(crate) fn normalized<'a>(text: &'a str, limits: &Limits) -> Result<Cow<'a, str>, EncodeError> {
    let too_long = || {
        let reason = format!("number literal longer than {} characters", limits.max_number_length);
        EncodeError::new(Code::NumberTooLong, reason)
    };
    // The common case: a decimal without exponent, already normalized.
    if plain_decimal(text.as_bytes()) == Some(text.len()) && text.len() <= limits.max_number_length {
        return Ok(text.into());
    }
    let n: Cow<str> = if is_normalized(text) {
        text.into()
    } else if text.len() > limits.max_number_length {
        return Err(too_long());
    } else {
        // The exponent is checked below, on the normalized literal.
        let syntax = Limits { max_exponent: u64::MAX, ..*limits };
        crate::parser::number_literal(text, &syntax)
            .ok_or_else(|| EncodeError::new(Code::InvalidNumber, "not a number literal"))?
            .into()
    };
    // The length first, as a parser meets it (spec §7).
    if n.len() > limits.max_number_length {
        return Err(too_long());
    }
    if let Some((_, exp)) = n.split_once('e') {
        let digits = exp.trim_start_matches('-');
        if digits.len() > 19 || digits.parse::<u64>().map_or(true, |e| e > limits.max_exponent) {
            return Err(EncodeError::new(
                Code::ExponentTooLarge,
                format!("exponent larger than {}", limits.max_exponent),
            ));
        }
    }
    Ok(n)
}

/// A number's normalized literal (spec §2), always in decimal, without
/// limits: for the canonical form (spec §12), which every haus number has.
/// `1E+05` is `1e5`, `0xFF` is `255`; text that isn't a number literal is an
/// error (`invalid-number`), as when writing.
pub(crate) fn literal(text: &str) -> Result<Cow<'_, str>, EncodeError> {
    if plain_decimal(text.as_bytes()) == Some(text.len()) || is_normalized(text) {
        return Ok(text.into());
    }
    let any = Limits { max_number_length: usize::MAX, max_exponent: u64::MAX, ..Limits::default() };
    crate::parser::number_literal(text, &any)
        .map(Cow::Owned)
        .ok_or_else(|| EncodeError::new(Code::InvalidNumber, "not a number literal"))
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
