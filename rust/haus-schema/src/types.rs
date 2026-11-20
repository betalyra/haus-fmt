//! Resolved types: what a schema means once its names are looked up, its
//! imports loaded and its generic types applied (spec §14, §15). They carry
//! no attributes, only what tools need of them: whether a field, tag or type
//! is deprecated. Decoding never looks at that.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::sync::Arc;

/// The hash of the indexes of a schema's own names (fields, tags): fast and
/// fixed. Only the schema puts names in them; data only looks names up,
/// which takes no longer for names made to collide than comparing them with
/// each of the schema's names would (spec §9.8).
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct NameHasher(u64);

impl NameHasher {
    fn mix(&mut self, word: u64) {
        self.0 = (self.0.rotate_left(5) ^ word).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
}

impl Hasher for NameHasher {
    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut word = [0; 8];
            word[..chunk.len()].copy_from_slice(chunk);
            self.mix(u64::from_le_bytes(word));
        }
    }
    fn write_u8(&mut self, n: u8) {
        self.mix(u64::from(n));
    }
    fn finish(&self) -> u64 {
        self.0 ^ self.0 >> 32
    }
}

/// An index of names, by [`NameHasher`].
type Names = HashMap<String, usize, BuildHasherDefault<NameHasher>>;

/// A built-in type of the prelude without parameters (spec §13).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Builtin {
    String,
    Bytes,
    Bool,
    Decimal,
    Int,
    Int8,
    Int16,
    Int32,
    Int64,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Float32,
    Float64,
    Any,
}

impl Builtin {
    pub const ALL: [Builtin; 16] = [
        Builtin::String,
        Builtin::Bytes,
        Builtin::Bool,
        Builtin::Decimal,
        Builtin::Int,
        Builtin::Int8,
        Builtin::Int16,
        Builtin::Int32,
        Builtin::Int64,
        Builtin::UInt8,
        Builtin::UInt16,
        Builtin::UInt32,
        Builtin::UInt64,
        Builtin::Float32,
        Builtin::Float64,
        Builtin::Any,
    ];

    /// Its name in schemas: `UInt8`.
    pub fn name(self) -> &'static str {
        match self {
            Builtin::String => "String",
            Builtin::Bytes => "Bytes",
            Builtin::Bool => "Bool",
            Builtin::Decimal => "Decimal",
            Builtin::Int => "Int",
            Builtin::Int8 => "Int8",
            Builtin::Int16 => "Int16",
            Builtin::Int32 => "Int32",
            Builtin::Int64 => "Int64",
            Builtin::UInt8 => "UInt8",
            Builtin::UInt16 => "UInt16",
            Builtin::UInt32 => "UInt32",
            Builtin::UInt64 => "UInt64",
            Builtin::Float32 => "Float32",
            Builtin::Float64 => "Float64",
            Builtin::Any => "Any",
        }
    }

    /// The built-in type called `name`.
    pub fn from_name(name: &str) -> Option<Builtin> {
        Builtin::ALL.into_iter().find(|b| b.name() == name)
    }
}

/// A named type applied to its arguments, in [`Schema::instance`](crate::Schema::instance).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct InstanceId(pub(crate) usize);

/// A type.
#[derive(Debug, Clone)]
pub enum Type {
    Builtin(Builtin),
    /// A type of std/time: `Date`, `Instant`, …
    Time(&'static str),
    Array(Box<Type>),
    Map(Box<Type>),
    Maybe(Box<Type>),
    /// `Secret a`: the same data as `a`, never shown (spec §15).
    Secret(Box<Type>),
    /// Shared: an argument used twice is not copied (`P a a` inside `P a a` …
    /// would otherwise double at every level).
    Record(Arc<Record>),
    /// Also `Result e a`, as `closed < Err e | Ok a >`. Shared, as records are.
    Variant(Arc<Variant>),
    /// A named type: `Comment`, `List Int`. Recursive types refer to themselves this way.
    Ref(InstanceId),
    /// A type parameter, only in the template of a generic type.
    Param(String),
}

/// `{ … }` or `closed { … }`.
#[derive(Debug, Clone)]
pub struct Record {
    /// Other fields are an error; an open record ignores them.
    pub closed: bool,
    pub fields: Vec<Field>,
    /// Each key's field.
    index: Names,
    /// For each field, the place of the field its key finds (itself, but
    /// for a record built in code with a key twice).
    found: Vec<usize>,
    /// The places of the fields that aren't optional.
    required: Vec<usize>,
}

impl Record {
    pub fn new(closed: bool, fields: Vec<Field>) -> Record {
        let index: Names = fields.iter().enumerate().map(|(i, f)| (f.key.clone(), i)).collect();
        let found = fields.iter().map(|f| index[&f.key]).collect();
        let required = (0..fields.len()).filter(|&i| !fields[i].optional).collect();
        Record { closed, fields, index, found, required }
    }

    /// The field `key`.
    pub fn field(&self, key: &str) -> Option<&Field> {
        self.position(key).map(|i| &self.fields[i])
    }

    /// The place of the field `key`.
    pub(crate) fn position(&self, key: &str) -> Option<usize> {
        self.index.get(key).copied()
    }

    /// The place of the field that the key of the field at `i` finds.
    pub(crate) fn found(&self, i: usize) -> usize {
        self.found[i]
    }

    /// The places of the fields that aren't optional, in order.
    pub(crate) fn required(&self) -> &[usize] {
        &self.required
    }
}

#[derive(Debug, Clone)]
pub struct Field {
    pub key: String,
    /// `key?: T`: it may be missing.
    pub optional: bool,
    pub ty: Type,
    pub deprecated: Option<Deprecation>,
}

/// `< … >` or `closed < … >`.
#[derive(Debug, Clone)]
pub struct Variant {
    /// Other tags are unknown values; in a closed variant they are errors.
    pub open: bool,
    pub cases: Vec<Case>,
    /// Each tag's case: dispatch is one lookup (spec §9.8).
    index: Names,
}

impl Variant {
    pub fn new(open: bool, cases: Vec<Case>) -> Variant {
        let index = cases.iter().enumerate().map(|(i, c)| (c.tag.clone(), i)).collect();
        Variant { open, cases, index }
    }

    /// The case of `tag`.
    pub fn case(&self, tag: &str) -> Option<&Case> {
        self.index.get(tag).map(|&i| &self.cases[i])
    }
}

#[derive(Debug, Clone)]
pub struct Case {
    pub tag: String,
    pub payload: Payload,
    pub deprecated: Option<Deprecation>,
}

/// What a tag takes.
#[derive(Debug, Clone)]
pub enum Payload {
    /// `Tag`.
    None,
    /// `Tag { … }`: one record.
    Record(Record),
    /// `Tag R`, whose one argument is a named type that is a record (`Wrap
    /// Box` with `type Box = { … }`, through aliases, or an applied name
    /// that gives one, `Found (Page Int)`): a record case like `Tag { … }`
    /// (spec §15). The type resolves to a [`Type::Record`]. A type parameter
    /// is never one, even where its argument is a record.
    Named(Type),
    /// `Tag A B`: exactly these values.
    Positional(Vec<Type>),
}

/// `@deprecated` or `@deprecated("why")` (spec §14).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deprecation {
    /// Why, and what to use instead.
    pub message: Option<String>,
}

impl Deprecation {
    /// What tools say about a use of `name`: `mail is deprecated: use email`.
    pub fn note(&self, name: &str) -> String {
        match self.message.as_deref().filter(|m| !m.is_empty()) {
            Some(why) => format!("{name} is deprecated: {why}"),
            None => format!("{name} is deprecated"),
        }
    }
}

/// A named type applied to arguments: its body with the parameters replaced.
#[derive(Debug, Clone)]
pub struct Instance {
    pub name: String,
    /// The type's id, the same in every language (spec §13.3): `@haus-fmt/money@1#Money`.
    pub id: String,
    pub args: Vec<Type>,
    pub body: Type,
    /// `type Events = Stream Event`: a file of `body`s.
    pub stream: bool,
}
