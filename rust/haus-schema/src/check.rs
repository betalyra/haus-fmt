//! Data checked against a schema at runtime (spec §15): decoding a
//! [`Value`] with a type, and the diagnostics of `haus check` and editors.
//!
//! One walk does both. Decoding stops at the first error and builds the
//! value an encoder writes back (the suite's `output`); checking goes on
//! after errors, reports up to [`MAX_ISSUES`] of them with their place in the
//! text, and adds hints: fields and tags an open type doesn't list ("not in
//! the schema", with a "did you mean"), and deprecated fields and tags that
//! the data uses (spec §14). Messages follow the TypeScript checker
//! (typescript/packages/haus/src/check.ts).
//!
//! Decoding is linear in the input whatever the schema (spec §9.8): a
//! variant's case is one lookup, the nesting depth is limited, and the work
//! is limited to 16 steps per value of the input. A problem inside a
//! `Secret` is reported as one error at the secret, with its type and never
//! its value, a key or a tag of it.

use crate::locate::{Lines, Node, locate};
use crate::resolve::{Schema, tags};
use crate::types::{Builtin, Case, Instance, Payload, Record, Type, Variant};
use haus::{Encode, EncodeError, Encoder, ErrorCode as Code, Limits, Value};
use std::fmt;
use std::ops::Range;

/// At most this many issues are reported for one file.
pub const MAX_ISSUES: usize = 200;
const STEPS_PER_VALUE: usize = 16;
/// Values beyond this are rejected before decoding (the parser's 64 Mi characters can't produce more).
const MAX_VALUES: usize = 64 * 1024 * 1024;

/// How bad an issue is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Severity {
    /// The data doesn't fit the schema.
    Error,
    /// Allowed, but maybe not meant: a field or tag an open type doesn't
    /// list (a typo?), or a deprecated one.
    Hint,
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Severity::Error => "error",
            Severity::Hint => "hint",
        })
    }
}

/// One step into a value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Segment {
    /// A record field or map key: `.price`, `["pt-BR"]`.
    Field(String),
    /// An array item, a payload value, or a value of a stream: `[2]`.
    Index(usize),
}

/// Line and column, 1-based; columns count code points (spec §8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Position {
    pub line: usize,
    pub column: usize,
}

/// A problem with data, or a hint about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Issue {
    pub severity: Severity,
    /// Which mistake it is (spec §17): `missing-field`, or for a hint
    /// `unlisted-field`, `unlisted-tag` or `deprecated`.
    pub code: Code,
    /// The message, without the place.
    pub message: String,
    /// Where in the value: field names and indexes, outermost first.
    pub path: Vec<Segment>,
    /// Byte offsets in the data text, end exclusive, when checked from text.
    pub span: Option<Range<usize>>,
    /// Where `span` starts.
    pub position: Option<Position>,
    /// A fix for this case, better than the catalogue's for the code
    /// (boxed: errors are returned by value, and stay small this way).
    fix: Option<Box<str>>,
}

impl Issue {
    fn new(severity: Severity, code: Code, message: String, path: Vec<Segment>) -> Issue {
        Issue { severity, code, message, path, span: None, position: None, fix: None }
    }

    fn error((code, message): (Code, String)) -> Issue {
        Issue::new(Severity::Error, code, message, vec![])
    }

    /// A concrete fix: the one for this case (`Point takes 2 arguments …`),
    /// or the catalogue's for the code (spec §17).
    pub fn hint(&self) -> &str {
        self.fix.as_deref().unwrap_or(self.code.hint())
    }

    /// The documentation of the code: `https://haus-fmt.org/docs/errors#<code>`.
    pub fn docs(&self) -> String {
        self.code.docs()
    }

    /// The JSON form of spec §17: `{ code, message, line?, column?, path, hint, docs }`.
    pub fn to_json(&self) -> String {
        haus::ErrorJson {
            code: self.code,
            message: &self.message,
            position: self.position.map(|p| (p.line, p.column)),
            path: Some(&self.path_string()),
            expected: None,
            found: None,
            hint: self.hint(),
        }
        .write()
    }

    /// The path as `$.items[2].price` (spec §15): a key that isn't an
    /// identifier as a canonical haus string (spec §12), `$.m["pt-BR"]`.
    pub fn path_string(&self) -> String {
        let mut out = String::from("$");
        for s in &self.path {
            match s {
                Segment::Index(i) => out.push_str(&format!("[{i}]")),
                Segment::Field(k) if is_word(k) => out.push_str(&format!(".{k}")),
                Segment::Field(k) => out.push_str(&format!("[{}]", haus::canonical(&Value::String(k.clone())))),
            }
        }
        out
    }
}

/// `expected Int, found the string "7" at $.items[2].id`.
impl fmt::Display for Issue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at {}", self.message, self.path_string())
    }
}

impl std::error::Error for Issue {}

impl Schema {
    /// Decode `value` with the type `name` (a definition without parameters)
    /// as spec §15 says. The result is the value an encoder writes back:
    /// numbers in their written form (`0xFF` as `255`, `-0` as an integer
    /// `0`, floats in their one spelling), fields an open record ignores
    /// left out, and everything else as it was. Fails with the first error.
    /// For a `Stream` definition, `value` is one value of the stream.
    pub fn decode(&self, name: &str, value: &Value) -> Result<Value, Issue> {
        self.decode_with(name, value, &Limits::default())
    }

    /// [`Schema::decode`] for a reader with `limits` (depth, and the limits
    /// that raw values of an `Any` or an unknown tag are checked against).
    pub fn decode_with(&self, name: &str, value: &Value, limits: &Limits) -> Result<Value, Issue> {
        let item = self.root(name).map_err(Issue::error)?;
        self.decode_type(&item.body, value, limits)
    }

    /// Decode `value` with any type of this schema (such as the body of an
    /// instance of a generic type).
    pub fn decode_type(&self, ty: &Type, value: &Value, limits: &Limits) -> Result<Value, Issue> {
        let mut w = Walker::new(self, *limits, Mode::Decode, None);
        w.budget(std::slice::from_ref(value)).map_err(Issue::error)?;
        match w.value(value, ty, None) {
            Some(out) if w.issues.is_empty() => Ok(out),
            _ => Err(w
                .issues
                .into_iter()
                .next()
                .unwrap_or_else(|| Issue::error((Code::TypeMismatch, "not a valid value".into())))),
        }
    }

    /// Decode the values of a stream (spec §15): each one, on its own, with
    /// the type a `Stream` definition `name` holds (or with `name` itself, if
    /// it isn't one). An error names the value's index: `$[3].total`.
    pub fn decode_stream(&self, name: &str, values: &[Value]) -> Result<Vec<Value>, Issue> {
        let item = self.root(name).map_err(Issue::error)?;
        values
            .iter()
            .enumerate()
            .map(|(i, v)| {
                self.decode_type(&item.body, v, &Limits::default()).map_err(|mut e| {
                    e.path.insert(0, Segment::Index(i));
                    e
                })
            })
            .collect()
    }

    /// Every problem with `values` (a file's top-level values) as the type
    /// `name`: a `Stream` checks each value, any other type expects exactly
    /// one. Errors and hints, without positions.
    pub fn check(&self, name: &str, values: &[Value]) -> Vec<Issue> {
        self.check_located(name, values, None, &Limits::default())
    }

    /// Every problem with the data file `text` as the type `name`, with
    /// positions: a syntax error, or what [`Schema::check`] finds.
    pub fn check_text(&self, name: &str, text: &str) -> Vec<Issue> {
        self.check_text_with(name, text, &Limits::default())
    }

    /// [`Schema::check_text`], parsing with `limits`.
    pub fn check_text_with(&self, name: &str, text: &str, limits: &Limits) -> Vec<Issue> {
        let values = match haus::parse_with(text, limits) {
            Ok(values) => values,
            Err(e) => {
                let end = text[e.offset..].chars().next().map_or(e.offset, |c| e.offset + c.len_utf8());
                return vec![Issue {
                    span: Some(e.offset..end.max(e.offset)),
                    position: Some(Position { line: e.line, column: e.column }),
                    ..Issue::new(Severity::Error, e.code, e.reason, vec![])
                }];
            }
        };
        let nodes = locate(text).filter(|n| n.len() == values.len());
        let lines = Lines::new(text);
        let mut issues = self.check_located(name, &values, nodes.as_deref(), limits);
        for i in &mut issues {
            // No span: the start of the file (an empty file, say).
            let span = i.span.clone().unwrap_or(0..text.chars().next().map_or(0, char::len_utf8));
            let (line, column) = lines.position(span.start);
            i.position = Some(Position { line, column });
            i.span = Some(span);
        }
        issues
    }

    fn check_located(&self, name: &str, values: &[Value], nodes: Option<&[Node]>, limits: &Limits) -> Vec<Issue> {
        let root = match self.root(name) {
            Ok(root) => root,
            Err(e) => return vec![Issue::error(e)],
        };
        let mut w = Walker::new(self, *limits, Mode::Check, nodes);
        if let Err(e) = w.budget(values) {
            return vec![Issue::error(e)];
        }
        let node = |i: usize| nodes.and_then(|n| n.get(i));
        if root.stream {
            for (i, v) in values.iter().enumerate() {
                w.path.push(Step::Index(i));
                w.value(v, &root.body, node(i));
                w.path.pop();
            }
        } else if values.len() != 1 {
            let span = node(1).map(|n| n.start..n.end);
            let message = format!("expected one value ({name} is not a Stream), found {}", values.len());
            w.report(Severity::Error, Code::NotOneValue, message, span);
        } else {
            w.value(&values[0], &root.body, node(0));
        }
        w.issues
    }

    /// The instance a whole file is checked with: a definition without parameters.
    fn root(&self, name: &str) -> Result<&Instance, (Code, String)> {
        let def = self.definition(name).ok_or_else(|| (Code::UnknownType, format!("the schema has no type {name}")))?;
        if !def.params.is_empty() {
            return Err((Code::WrongArity, format!("{name} needs arguments, so it can't describe a whole file")));
        }
        Ok(self.instance(def.template))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// Stop at the first error; build the decoded value.
    Decode,
    /// Report every problem and the hints.
    Check,
}

type Loc<'n> = Option<&'n Node>;

struct Walker<'s, 'v> {
    schema: &'s Schema,
    limits: Limits,
    mode: Mode,
    issues: Vec<Issue>,
    /// Where the walk is, borrowing the keys of the value: an issue copies it.
    path: Vec<Step<'v>>,
    depth: usize,
    steps: usize,
    max_steps: usize,
    /// The work budget or the depth limit is exceeded: nothing more is checked.
    fatal: bool,
    located: bool,
    /// For the records being walked, innermost last: which of the type's
    /// fields the value has, by their place in the type.
    present: Vec<bool>,
    /// For the records being walked, innermost last: the place in the type
    /// of each of the value's fields, `NOT_LISTED` for none.
    places: Vec<usize>,
}

/// In [`Walker::places`]: a field the record type doesn't list.
const NOT_LISTED: usize = usize::MAX;

/// Nothing: what the walk gives for a value when it only checks.
const NOTHING: Value = Value::Array(Vec::new());

impl<'s, 'v> Walker<'s, 'v> {
    fn new(schema: &'s Schema, limits: Limits, mode: Mode, nodes: Option<&[Node]>) -> Walker<'s, 'v> {
        Walker {
            schema,
            limits,
            mode,
            issues: vec![],
            path: vec![],
            depth: 0,
            steps: 0,
            max_steps: 0,
            fatal: false,
            located: nodes.is_some(),
            present: vec![],
            places: vec![],
        }
    }

    /// Sets the work budget: 16 steps per value of the input, and 1024.
    /// Fails for a value built in code that is deeper than the limit or has
    /// more than 64 Mi values.
    ///
    /// Counted by going through the containers only. Which error a value
    /// with both problems gets depends on the order values are counted in,
    /// so beyond 64 Mi values they are counted again, one by one, in the
    /// order that decides it ([`Walker::count_all`]).
    fn budget(&mut self, values: &[Value]) -> Result<(), (Code, String)> {
        let max = self.limits.max_depth;
        let mut count = values.len();
        let mut deep = false;
        let mut stack: Vec<(&Value, usize)> = values.iter().filter(|v| is_container(v)).map(|v| (v, 0)).collect();
        while let Some((v, depth)) = stack.pop() {
            deep |= depth >= max;
            let mut inside = |x, depth| {
                count += 1;
                if is_container(x) {
                    stack.push((x, depth));
                }
            };
            match v {
                Value::Array(items) => items.iter().for_each(|x| inside(x, depth + 1)),
                Value::Record(fields) => fields.iter().for_each(|(_, x)| inside(x, depth + 1)),
                // `Tag { … }` is one level, as in the parser; `Tag(a, b)` nests its arguments.
                Value::Variant { args, .. } => match args.as_slice() {
                    [r @ Value::Record(_)] => inside(r, depth),
                    args => args.iter().for_each(|x| inside(x, depth + 1)),
                },
                _ => {}
            }
            if count > MAX_VALUES {
                return self.count_all(values);
            }
        }
        if deep {
            return Err((Code::NestingTooDeep, format!("value nested deeper than {max} levels")));
        }
        self.max_steps = STEPS_PER_VALUE.saturating_mul(count).saturating_add(1024);
        Ok(())
    }

    /// [`Walker::budget`] for more than 64 Mi values: every value counted
    /// on its own, in order, failing at the first problem.
    #[cold]
    fn count_all(&mut self, values: &[Value]) -> Result<(), (Code, String)> {
        let max = self.limits.max_depth;
        let mut count = 0usize;
        let mut stack: Vec<(&Value, usize)> = values.iter().map(|v| (v, 0)).collect();
        while let Some((v, depth)) = stack.pop() {
            count += 1;
            if count > MAX_VALUES {
                return Err((Code::TooManyNodes, format!("value has more than {MAX_VALUES} nodes")));
            }
            let container = matches!(v, Value::Array(_) | Value::Record(_))
                || matches!(v, Value::Variant { args, .. } if !args.is_empty());
            if container && depth >= max {
                return Err((Code::NestingTooDeep, format!("value nested deeper than {max} levels")));
            }
            match v {
                Value::Array(items) => stack.extend(items.iter().map(|x| (x, depth + 1))),
                Value::Record(fields) => stack.extend(fields.iter().map(|(_, x)| (x, depth + 1))),
                // `Tag { … }` is one level, as in the parser; `Tag(a, b)` nests its arguments.
                Value::Variant { args, .. } => match args.as_slice() {
                    [r @ Value::Record(_)] => stack.push((r, depth)),
                    args => stack.extend(args.iter().map(|x| (x, depth + 1))),
                },
                _ => {}
            }
        }
        self.max_steps = STEPS_PER_VALUE.saturating_mul(count).saturating_add(1024);
        Ok(())
    }

    fn decoding(&self) -> bool {
        self.mode == Mode::Decode
    }

    /// Whether to stop: after a fatal error, the first error when decoding,
    /// or [`MAX_ISSUES`] issues.
    fn stopped(&self) -> bool {
        self.fatal || self.issues.len() >= MAX_ISSUES || (self.decoding() && !self.issues.is_empty())
    }

    fn report(&mut self, severity: Severity, code: Code, message: String, span: Option<Range<usize>>) {
        self.report_fix(severity, code, message, None, span);
    }

    fn report_fix(
        &mut self,
        severity: Severity,
        code: Code,
        message: String,
        fix: Option<String>,
        span: Option<Range<usize>>,
    ) {
        if severity == Severity::Hint && self.decoding() {
            return;
        }
        if self.issues.len() < MAX_ISSUES {
            let span = span.filter(|_| self.located).map(|s| s.start..s.end.max(s.start + 1));
            self.issues.push(Issue {
                span,
                fix: fix.map(String::into_boxed_str),
                ..Issue::new(severity, code, message, self.path.iter().map(Step::segment).collect())
            });
        }
    }

    fn error<T>(&mut self, code: Code, message: String, loc: Loc) -> Option<T> {
        self.report(Severity::Error, code, message, span(loc));
        None
    }

    /// A `wrong-payload` error, with a hint that says what `tag` takes.
    fn wrong_payload<T>(&mut self, message: String, fix: String, loc: Loc) -> Option<T> {
        self.report_fix(Severity::Error, Code::WrongPayload, message, Some(fix), span(loc));
        None
    }

    /// What `tag` takes, as a hint: `Point takes 2 arguments (Float64, Float64): write `Point(…, …)`.`
    fn payload_fix(&self, tag: &str, payload: &Payload) -> String {
        match payload {
            Payload::None => format!("{tag} takes no payload: write `{tag}`."),
            Payload::Record(r) => self.record_fix(tag, r),
            Payload::Named(t) => match self.schema.resolve(t) {
                Type::Record(r) => self.record_fix(tag, r),
                _ => self.payload_fix(tag, &Payload::Positional(vec![t.clone()])),
            },
            Payload::Positional(items) => {
                let n = items.len();
                let described: Vec<String> = items.iter().map(|t| self.schema.describe(t)).collect();
                let s = if n == 1 { "" } else { "s" };
                let holes = vec!["…"; n].join(", ");
                format!("{tag} takes {n} argument{s} ({}): write `{tag}({holes})`.", described.join(", "))
            }
        }
    }

    /// What a record case takes, as a hint: `Circle takes one argument, a record { r: Float64 }: …`.
    fn record_fix(&self, tag: &str, r: &Record) -> String {
        let fields: Vec<String> = r
            .fields
            .iter()
            .take(6)
            .map(|f| {
                format!("{}{}: {}", quote_key(&f.key), if f.optional { "?" } else { "" }, self.schema.describe(&f.ty))
            })
            .collect();
        let more = if r.fields.len() > 6 { ", …" } else { "" };
        let record = match fields.is_empty() {
            true => "{}".to_owned(),
            false => format!("{{ {}{more} }}", fields.join(", ")),
        };
        format!("{tag} takes one argument, a record {record}: write `{tag} {{ … }}`.")
    }

    fn fatal<T>(&mut self, code: Code, message: String) -> Option<T> {
        self.report(Severity::Error, code, message, None);
        self.fatal = true;
        None
    }

    /// One schema step; fails when the budget is used up.
    fn step(&mut self) -> Option<()> {
        self.steps += 1;
        match self.steps > self.max_steps {
            true => self.fatal(
                Code::StepBudget,
                format!(
                    "decode budget of {} steps exceeded (a schema doing more work than the input justifies)",
                    self.max_steps
                ),
            ),
            false => Some(()),
        }
    }

    /// `f` on a child value at `segment`, one level deeper.
    fn child<T>(&mut self, segment: Step<'v>, f: impl FnOnce(&mut Self) -> Option<T>) -> Option<T> {
        self.path.push(segment);
        let out = match self.depth >= self.limits.max_depth {
            true => self.fatal(Code::NestingTooDeep, format!("nesting deeper than {} levels", self.limits.max_depth)),
            false => {
                self.depth += 1;
                let out = f(self);
                self.depth -= 1;
                out
            }
        };
        self.path.pop();
        out
    }

    /// What the decoded value keeps of `v`: all of it when decoding.
    fn keep(&self, v: &Value) -> Value {
        match self.decoding() {
            true => v.clone(),
            false => NOTHING,
        }
    }

    /// `v` with type `ty`: the value decoded (when decoding), or None after a problem.
    fn value(&mut self, v: &'v Value, ty: &Type, loc: Loc) -> Option<Value> {
        if self.stopped() {
            return None;
        }
        self.step()?;
        let mut t = ty;
        while let Type::Ref(id) = t {
            t = &self.schema.instance(*id).body;
        }
        match t {
            Type::Builtin(b) => self.builtin(v, *b, ty, loc),
            Type::Time(name) => self.time(v, name, ty, loc),
            Type::Array(item) => match v {
                Value::Array(items) => {
                    let out: Vec<Option<Value>> = items
                        .iter()
                        .enumerate()
                        .map(|(i, x)| self.child(Step::Index(i), |w| w.value(x, item, item_of(loc, i))))
                        .collect();
                    out.into_iter().collect::<Option<Vec<_>>>().map(|xs| self.out(|| Value::Array(xs)))
                }
                _ => self.mismatch(v, ty, loc),
            },
            Type::Map(value) => match v {
                Value::Record(fields) => {
                    let out: Vec<Option<(String, Value)>> = fields
                        .iter()
                        .enumerate()
                        .map(|(i, (k, x))| {
                            let at = field_of(loc, i).map(|(_, n)| n);
                            self.child(Step::Field(k), |w| w.value(x, value, at)).map(|x| (k.clone(), x))
                        })
                        .collect();
                    out.into_iter().collect::<Option<Vec<_>>>().map(|fs| self.out(|| Value::Record(fs)))
                }
                _ => self.mismatch(v, ty, loc),
            },
            Type::Maybe(item) => match v {
                Value::Variant { tag, args } if tag == "None" && args.is_empty() => Some(self.keep(v)),
                Value::Variant { tag, args } if tag == "Some" && args.len() == 1 => {
                    let x = self.child(Step::Index(0), |w| w.value(&args[0], item, item_of(loc, 0)))?;
                    Some(self.out(|| haus::ser::variant("Some", vec![x])))
                }
                _ => {
                    let message =
                        format!("expected None or Some(…) ({}), found {}", self.schema.describe(ty), found(v));
                    let fix = match v {
                        Value::Variant { tag, .. } if tag == "None" => Some(self.payload_fix(tag, &Payload::None)),
                        Value::Variant { tag, .. } if tag == "Some" => {
                            Some(self.payload_fix(tag, &Payload::Positional(vec![(**item).clone()])))
                        }
                        _ => None,
                    };
                    self.report_fix(Severity::Error, not_case(v, &["None", "Some"]), message, fix, span(loc));
                    None
                }
            },
            Type::Secret(item) => self.secret(v, item, loc),
            Type::Record(r) => match v {
                Value::Record(fields) => self.record(fields, r, loc),
                _ => self.mismatch(v, ty, loc),
            },
            Type::Variant(var) => self.variant(v, var, ty, loc),
            Type::Param(_) | Type::Ref(_) => Some(self.keep(v)),
        }
    }

    /// The decoded value made by `f`, when decoding.
    fn out(&self, f: impl FnOnce() -> Value) -> Value {
        match self.decoding() {
            true => f(),
            false => NOTHING,
        }
    }

    fn mismatch<T>(&mut self, v: &Value, ty: &Type, loc: Loc) -> Option<T> {
        self.mismatch_as(Code::TypeMismatch, v, ty, loc)
    }

    fn mismatch_as<T>(&mut self, code: Code, v: &Value, ty: &Type, loc: Loc) -> Option<T> {
        let message = format!("expected {}, found {}", self.schema.describe(ty), found(v));
        self.error(code, message, loc)
    }

    /// Check what's inside, then replace whatever was found there (messages
    /// quote values, keys and tags of the data, and paths may name keys) by
    /// one error at the secret, with its type only.
    fn secret(&mut self, v: &'v Value, item: &Type, loc: Loc) -> Option<Value> {
        let before = self.issues.len();
        let out = self.value(v, item, loc);
        let inside: Vec<Issue> = self.issues.drain(before..).collect();
        if inside.iter().any(|i| i.severity == Severity::Error) {
            let message = format!("expected {} (a Secret: the value is not shown)", self.schema.describe(item));
            return self.error(Code::InvalidSecret, message, loc);
        }
        out
    }

    fn builtin(&mut self, v: &Value, b: Builtin, ty: &Type, loc: Loc) -> Option<Value> {
        let name = b.name();
        match (b, v) {
            (Builtin::Any, _) => self.raw(v, loc),
            (Builtin::String, Value::String(_)) | (Builtin::Bytes, Value::Bytes(_)) => Some(self.keep(v)),
            (Builtin::Bool, Value::Variant { tag, args }) if args.is_empty() && (tag == "True" || tag == "False") => {
                Some(self.keep(v))
            }
            (Builtin::Float32 | Builtin::Float64, Value::Variant { tag, args })
                if args.is_empty() && matches!(tag.as_str(), "NaN" | "Infinity" | "NegInfinity") =>
            {
                Some(self.keep(v))
            }
            (Builtin::Bool, Value::Variant { tag, .. }) if tag == "True" || tag == "False" => {
                let message = format!("expected {}, found {}", self.schema.describe(ty), found(v));
                let fix = self.payload_fix(tag, &Payload::None);
                self.wrong_payload(message, fix, loc)
            }
            (Builtin::Bool, Value::Variant { .. }) => self.mismatch_as(not_case(v, &["True", "False"]), v, ty, loc),
            (Builtin::Float64 | Builtin::Float32, Value::Number(text)) if self.spelled(b, text) => {
                Some(self.out(|| Value::Number(text.clone())))
            }
            (Builtin::Float64, Value::Number(text)) => self.float(text.parse::<f64>(), text, name, v, ty, loc),
            (Builtin::Float32, Value::Number(text)) => self.float(text.parse::<f32>(), text, name, v, ty, loc),
            (Builtin::Decimal, Value::Number(text)) => match Encoder::new(&self.limits).number(text) {
                Ok(n) => Some(self.out(|| n)),
                Err(_) => self.mismatch(v, ty, loc),
            },
            (Builtin::Int, Value::Number(text)) => match whole(text) {
                Some(n) => Some(self.out(|| Value::Number(n.to_owned()))),
                None => self.not_whole(name, text, loc),
            },
            (_, Value::Number(text)) if range(b).is_some() => {
                let Some(n) = whole(text) else {
                    return self.not_whole(name, text, loc);
                };
                let (min, max) = range(b).unwrap_or((0, 0));
                match n.parse::<i128>() {
                    Ok(x) if (min..=max).contains(&x) => Some(self.out(|| Value::Number(n.to_owned()))),
                    _ => {
                        let message = format!("{} is out of range for {name} ({min} to {max})", short(text));
                        self.error(Code::OutOfRange, message, loc)
                    }
                }
            }
            _ => self.mismatch(v, ty, loc),
        }
    }

    fn not_whole<T>(&mut self, name: &str, text: &str, loc: Loc) -> Option<T> {
        self.error(Code::NotAnInteger, format!("expected a whole number ({name}), found {}", short(text)), loc)
    }

    /// Whether `text` is already the one spelling (spec §15) of the float of
    /// type `b` it reads as, within the number limit: then it is decoded as
    /// it is, without reading and writing the float (see [`spelled`]).
    fn spelled(&self, b: Builtin, text: &str) -> bool {
        let digits = if b == Builtin::Float64 { f64::DIGITS } else { f32::DIGITS };
        text.len() <= self.limits.max_number_length && spelled(text, digits as usize)
    }

    /// A float: the nearest value of the type, written in its one spelling (spec §15).
    fn float<F: Encode + FloatLike>(
        &mut self,
        parsed: Result<F, std::num::ParseFloatError>,
        text: &str,
        name: &str,
        v: &Value,
        ty: &Type,
        loc: Loc,
    ) -> Option<Value> {
        match parsed {
            Ok(x) if x.finite() => match self.decoding() {
                true => match x.encode_with(Encoder::new(&self.limits)) {
                    Ok(out) => Some(out),
                    Err(e) => self.encode_error(e, loc),
                },
                false => Some(NOTHING),
            },
            Ok(_) => self.error(Code::OutOfRange, format!("{} is too large for {name}", short(text)), loc),
            Err(_) => self.mismatch(v, ty, loc),
        }
    }

    /// A raw value kept as it is (an `Any`, an unknown tag): one a writer
    /// takes, within the limits (spec §9.8).
    fn raw(&mut self, v: &Value, loc: Loc) -> Option<Value> {
        match Encoder::new(&self.limits).check(v) {
            Ok(()) => Some(self.keep(v)),
            Err(e) => self.encode_error(e, loc),
        }
    }

    /// A value a writer doesn't take: the writer's error, a decoding error
    /// here (what a writer can't encode is of the wrong type for a reader).
    fn encode_error<T>(&mut self, e: EncodeError, loc: Loc) -> Option<T> {
        let code = if e.code == Code::CannotEncode { Code::TypeMismatch } else { e.code };
        self.error(code, e.to_string(), loc)
    }

    fn time(&mut self, v: &Value, name: &str, ty: &Type, loc: Loc) -> Option<Value> {
        let Value::Variant { tag, args } = v else { return self.mismatch(v, ty, loc) };
        if tag != name {
            return self.mismatch(v, ty, loc);
        }
        let [Value::String(s)] = args.as_slice() else {
            return self.error(Code::TypeMismatch, format!("write {name}(\"…\") with one string"), loc);
        };
        // The std/time profile (spec/std/time.md): built-in rules, like the ranges of Int8.
        match haus::time::check(name, s) {
            Ok(()) => Some(self.keep(v)),
            Err(reason) => {
                // Bounded messages (§9.8): a long string is shown shortened.
                let reason = match s.chars().count() > 40 {
                    true => reason.replacen(&format!("{s:?}"), &json_quote(&shorten(s, 40)), 1),
                    false => reason,
                };
                self.child(Step::Index(0), |w| w.error::<Value>(Code::InvalidTime, reason, item_of(loc, 0)));
                None
            }
        }
    }

    fn record(&mut self, fields: &'v [(String, Value)], r: &Record, loc: Loc) -> Option<Value> {
        // Where each field is in the type, and which of the type's fields
        // are there, above the outer records'.
        let (at, places) = (self.present.len(), self.places.len());
        self.present.resize(at + r.fields.len(), false);
        for (k, _) in fields {
            let place = r.position(k);
            if let Some(i) = place {
                self.present[at + i] = true;
            }
            self.places.push(place.unwrap_or(NOT_LISTED));
        }
        let out = self.record_fields(fields, r, (at, places), loc);
        self.present.truncate(at);
        self.places.truncate(places);
        out
    }

    /// [`Walker::record`], with which of `r`'s fields are there at `at` in
    /// `present`, and the places of the value's fields at `places` in `places`.
    fn record_fields(
        &mut self,
        fields: &'v [(String, Value)],
        r: &Record,
        (at, places): (usize, usize),
        loc: Loc,
    ) -> Option<Value> {
        let present = |w: &Self, i: usize| w.present[at + r.found(i)];
        let missing: Vec<String> =
            r.required().iter().filter(|&&i| !present(self, i)).map(|&i| quote_key(&r.fields[i].key)).collect();
        let mut ok = true;
        if !missing.is_empty() {
            let s = if missing.len() > 1 { "s" } else { "" };
            let start = loc.map(|n| n.start..n.start + 1);
            self.report(Severity::Error, Code::MissingField, format!("missing field{s} {}", missing.join(", ")), start);
            ok = false;
        }
        let mut out = Vec::with_capacity(fields.len());
        for (i, (key, x)) in fields.iter().enumerate() {
            if self.stopped() {
                return None;
            }
            let at = field_of(loc, i);
            let key_span = at.map(|((s, e), _)| *s..*e).or_else(|| span(loc));
            match r.fields.get(self.places[places + i]) {
                Some(f) => {
                    if let Some(d) = &f.deprecated {
                        // At the field's value, as `unlisted-field` is (spec §14).
                        self.path.push(Step::Field(key));
                        self.report(Severity::Hint, Code::Deprecated, d.note(&quote_key(key)), key_span);
                        self.path.pop();
                    }
                    match self.child(Step::Field(key), |w| w.value(x, &f.ty, at.map(|(_, n)| n))) {
                        Some(x) => out.push((key.clone(), x)),
                        None => ok = false,
                    }
                }
                None if self.decoding() && !r.closed => {}
                None => {
                    let unused =
                        (r.fields.iter().enumerate()).filter(|&(i, _)| !present(self, i)).map(|(_, f)| f.key.as_str());
                    let hint = suggest(key, unused);
                    self.path.push(Step::Field(key));
                    if r.closed {
                        self.report(
                            Severity::Error,
                            Code::UnknownField,
                            format!("{} is not a field of this closed record.{hint}", quote_key(key)),
                            key_span,
                        );
                        ok = false;
                    } else {
                        let message = format!("{} is not in the schema; a reader ignores it.{hint}", quote_key(key));
                        self.report(Severity::Hint, Code::UnlistedField, message, key_span);
                    }
                    self.path.pop();
                }
            }
        }
        ok.then(|| self.out(|| Value::Record(out)))
    }

    fn variant(&mut self, v: &'v Value, var: &Variant, ty: &Type, loc: Loc) -> Option<Value> {
        let Value::Variant { tag, args } = v else { return self.mismatch(v, ty, loc) };
        let tag_span = loc.map(|n| n.start..n.tag_end);
        let Some(case) = var.case(tag) else {
            if var.open && self.decoding() {
                return self.raw(v, loc);
            }
            let hint = suggest(tag, var.cases.iter().map(|c| c.tag.as_str()));
            if var.open {
                // `< >` lists no tags: any tag is meant, so there is nothing to hint.
                if !var.cases.is_empty() {
                    let message = format!("{tag} is not in the schema; a reader keeps it as an unknown value.{hint}");
                    self.report(Severity::Hint, Code::UnlistedTag, message, tag_span);
                }
                return self.raw(v, loc);
            }
            let message = format!("{tag} is not allowed here: expected {}.{hint}", tags(var));
            self.report(Severity::Error, Code::UnknownTag, message, tag_span);
            return None;
        };
        if let Some(d) = &case.deprecated {
            self.report(Severity::Hint, Code::Deprecated, d.note(tag), tag_span);
        }
        self.payload(tag, args, case, loc)
    }

    /// A record case's payload that isn't one record: the wrong payload (spec §15).
    fn not_one_record(&mut self, tag: &str, args: &[Value], case: &Case, loc: Loc) -> Option<Value> {
        let fix = self.payload_fix(tag, &case.payload);
        let got = match args {
            [] => "no payload".to_owned(),
            [x] => found(x),
            _ => format!("{} arguments", args.len()),
        };
        self.wrong_payload(format!("{tag} takes one argument, a record; found {got}"), fix, loc)
    }

    fn payload(&mut self, tag: &str, args: &'v [Value], case: &Case, loc: Loc) -> Option<Value> {
        match &case.payload {
            Payload::None if args.is_empty() => Some(self.out(|| haus::ser::variant(tag, vec![]))),
            Payload::None => {
                let fix = self.payload_fix(tag, &case.payload);
                self.wrong_payload(format!("{tag} takes no payload"), fix, loc)
            }
            Payload::Record(r) => match args {
                // `Tag { … }`: the record is at the variant's level and place.
                [Value::Record(fields)] => {
                    let x = self.record(fields, r, item_of(loc, 0))?;
                    Some(self.out(|| haus::ser::variant(tag, vec![x])))
                }
                // Anything else, `Circle(1.5)` too, is the wrong payload (spec §15).
                _ => self.not_one_record(tag, args, case, loc),
            },
            // A record case too: `Wrap Box` takes `Wrap { … }`, and errors are at the same places.
            Payload::Named(t) => match args {
                [x @ Value::Record(_)] => {
                    let x = self.value(x, t, item_of(loc, 0))?;
                    Some(self.out(|| haus::ser::variant(tag, vec![x])))
                }
                _ => self.not_one_record(tag, args, case, loc),
            },
            Payload::Positional(items) if items.len() != args.len() => {
                let n = items.len();
                let described: Vec<String> = items.iter().map(|t| self.schema.describe(t)).collect();
                let s = if n == 1 { "" } else { "s" };
                let message = format!("{tag} takes {n} argument{s} ({}), found {}", described.join(", "), args.len());
                let fix = self.payload_fix(tag, &case.payload);
                self.wrong_payload(message, fix, loc)
            }
            Payload::Positional(items) => {
                let out: Vec<Option<Value>> = args
                    .iter()
                    .zip(items)
                    .enumerate()
                    .map(|(i, (x, t))| self.child(Step::Index(i), |w| w.value(x, t, item_of(loc, i))))
                    .collect();
                out.into_iter().collect::<Option<Vec<_>>>().map(|xs| self.out(|| haus::ser::variant(tag, xs)))
            }
        }
    }
}

/// Whether a value has values inside it: an array, a record, or a variant
/// with a payload.
fn is_container(v: &Value) -> bool {
    match v {
        Value::Array(_) | Value::Record(_) => true,
        Value::Variant { args, .. } => !args.is_empty(),
        _ => false,
    }
}

/// One step into a value, borrowing its key: a [`Segment`] once an issue has it.
#[derive(Debug, Clone, Copy)]
enum Step<'v> {
    Field(&'v str),
    Index(usize),
}

impl Step<'_> {
    fn segment(&self) -> Segment {
        match *self {
            Step::Field(k) => Segment::Field(k.to_owned()),
            Step::Index(i) => Segment::Index(i),
        }
    }
}

trait FloatLike {
    fn finite(&self) -> bool;
}
impl FloatLike for f64 {
    fn finite(&self) -> bool {
        self.is_finite()
    }
}
impl FloatLike for f32 {
    fn finite(&self) -> bool {
        self.is_finite()
    }
}

/// `v` isn't one of the cases of a closed variant with `tags` (`Bool`,
/// `Maybe`): an unknown tag, a known tag with the wrong payload, or not a
/// variant at all (spec §17).
fn not_case(v: &Value, tags: &[&str]) -> Code {
    match v {
        Value::Variant { tag, .. } if tags.contains(&tag.as_str()) => Code::WrongPayload,
        Value::Variant { .. } => Code::UnknownTag,
        _ => Code::TypeMismatch,
    }
}

fn span(loc: Loc) -> Option<Range<usize>> {
    loc.map(|n| n.start..n.end)
}

fn item_of<'n>(loc: Loc<'n>, i: usize) -> Loc<'n> {
    loc.and_then(|n| n.item(i))
}

fn field_of<'n>(loc: Loc<'n>, i: usize) -> Option<&'n ((usize, usize), Node)> {
    loc.and_then(|n| n.field(i))
}

/// The range of an integer type.
fn range(b: Builtin) -> Option<(i128, i128)> {
    Some(match b {
        Builtin::Int8 => (i8::MIN.into(), i8::MAX.into()),
        Builtin::Int16 => (i16::MIN.into(), i16::MAX.into()),
        Builtin::Int32 => (i32::MIN.into(), i32::MAX.into()),
        Builtin::Int64 => (i64::MIN.into(), i64::MAX.into()),
        Builtin::UInt8 => (0, u8::MAX.into()),
        Builtin::UInt16 => (0, u16::MAX.into()),
        Builtin::UInt32 => (0, u32::MAX.into()),
        Builtin::UInt64 => (0, u64::MAX.into()),
        _ => return None,
    })
}

/// The digits of a whole number literal (`-12`, `0`), or None (`1.5`, `1e3`).
/// `-0` is 0 (spec §15).
fn whole(text: &str) -> Option<&str> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let is_whole = !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit());
    is_whole.then_some(if digits.bytes().all(|c| c == b'0') { "0" } else { text })
}

/// Whether the number literal `text` is the one spelling (spec §15) of the
/// float it reads as, for a float type whose values keep `digits`
/// significant decimal digits (15 for Float64, 6 for Float32): a decimal
/// without exponent, `-?(0|[1-9][0-9]*)(.[0-9]*[1-9])?`, with at most
/// `digits` significant digits and at most five zeros after `0.`. No other
/// decimal of as few digits reads as the same float (two decimals of
/// `digits` digits never do), so these are its shortest digits, and
/// JavaScript's layout writes them as they are here.
fn spelled(text: &str, digits: usize) -> bool {
    let unsigned = text.strip_prefix('-').unwrap_or(text);
    let (int, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    let int_ok = int == "0" || (int.starts_with(|c: char| ('1'..='9').contains(&c)) && is_digits(int));
    let fraction_ok =
        (fraction.is_empty() && !unsigned.ends_with('.')) || (is_digits(fraction) && !fraction.ends_with('0'));
    let significant = match int {
        "0" => {
            let zeros = fraction.len() - fraction.trim_start_matches('0').len();
            if zeros > 5 {
                return false;
            }
            fraction.len() - zeros
        }
        _ => int.len() + fraction.len(),
    };
    int_ok && fraction_ok && significant <= digits
}

fn is_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit())
}

/// At most `n` characters of `text`, then `…`.
fn shorten(text: &str, n: usize) -> String {
    match text.char_indices().nth(n) {
        Some((i, _)) => format!("{}…", &text[..i]),
        None => text.to_owned(),
    }
}

fn short(text: &str) -> String {
    shorten(text, 30)
}

/// A short description of a value, for messages.
fn found(v: &Value) -> String {
    match v {
        Value::String(s) if s.chars().count() > 20 => "a string".into(),
        Value::String(s) => format!("the string {}", json_quote(s)),
        Value::Number(n) => format!("the number {}", shorten(n, 20)),
        Value::Bytes(_) => "bytes".into(),
        Value::Array(_) => "an array".into(),
        Value::Record(_) => "a record".into(),
        Value::Variant { tag, .. } => format!("the tag {}", shorten(tag, 30)),
    }
}

/// A key as written: bare if it can be, else quoted.
fn quote_key(k: &str) -> String {
    let bare = k.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_');
    if bare { k.to_owned() } else { json_quote(k) }
}

/// A key that a path writes after a dot: `.price`.
fn is_word(k: &str) -> bool {
    k.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}

/// `s` as a JSON string, as JavaScript's `JSON.stringify` writes it.
fn json_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Edit distance, for "did you mean"; 3 or more for strings far apart in length.
fn distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if a.len().abs_diff(b.len()) > 2 || a.len() > 64 || b.len() > 64 {
        return 3;
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i];
        for j in 1..=b.len() {
            cur.push((prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(a[i - 1] != b[j - 1])));
        }
        prev = cur;
    }
    prev[b.len()]
}

/// ` Did you mean quantity?`, for the closest candidate within two edits; or nothing.
fn suggest<'a>(word: &str, candidates: impl Iterator<Item = &'a str>) -> String {
    let word = word.to_lowercase();
    let mut best: Option<(&str, usize)> = None;
    for c in candidates {
        let d = distance(&word, &c.to_lowercase());
        if d < best.map_or(3, |(_, b)| b) {
            best = Some((c, d));
        }
    }
    best.map_or(String::new(), |(c, _)| format!(" Did you mean {c}?"))
}

#[cfg(test)]
mod tests {
    use super::spelled;
    use haus::{Encode, EncodeError, Value};

    /// Decimals of up to 17 digits before the point and 19 after, from a
    /// fixed sequence (xorshift), with many zeros and nines.
    fn literals() -> impl Iterator<Item = String> {
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        let mut next = move |n: u64| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state % n
        };
        let digits = |next: &mut dyn FnMut(u64) -> u64, n: u64| -> String {
            (0..n)
                .map(|_| match next(4) {
                    0 => '0',
                    1 => '9',
                    _ => char::from(b'0' + next(10) as u8),
                })
                .collect()
        };
        std::iter::repeat_with(move || {
            let n = next(18);
            let int = digits(&mut next, n);
            let int = match int.trim_start_matches('0') {
                "" => "0",
                d => d,
            }
            .to_owned();
            let n = next(20);
            let fraction = digits(&mut next, n);
            let sign = if next(3) == 0 { "-" } else { "" };
            match fraction.is_empty() {
                true => format!("{sign}{int}"),
                false => format!("{sign}{int}.{fraction}"),
            }
        })
    }

    /// The literals `spelled` takes are what reading and writing the float gives.
    #[test]
    fn spelled_floats_are_written_as_they_are() {
        let written = |v: Result<Value, EncodeError>| v.ok().map(|v| haus::canonical(&v));
        let (mut f64s, mut f32s) = (0, 0);
        for text in literals().take(400_000) {
            if spelled(&text, 15) {
                assert_eq!(written(text.parse::<f64>().unwrap().encode()), Some(text.clone()), "Float64 {text}");
                f64s += 1;
            }
            if spelled(&text, 6) {
                assert_eq!(written(text.parse::<f32>().unwrap().encode()), Some(text.clone()), "Float32 {text}");
                f32s += 1;
            }
        }
        assert!(f64s > 20_000 && f32s > 5_000, "{f64s} {f32s}");
        for text in ["0", "-0", "0.5", "-61.68", "0.000001", "123456789012345", "999999"] {
            assert!(spelled(text, 15), "{text}");
        }
        for text in ["1.0", "0.0000001", "1234567890123456", "01", "1e5", "0.", ".5", "-", ""] {
            assert!(!spelled(text, 15), "{text}");
        }
    }
}
