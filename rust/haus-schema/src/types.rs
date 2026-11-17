//! Resolved types: what a schema means once its names are looked up, its
//! imports loaded and its generic types applied (spec §14, §15). They carry
//! no attributes, only what tools need of them: whether a field, tag or type
//! is deprecated. Decoding never looks at that.

use std::collections::HashMap;

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
    Record(Record),
    /// Also `Result e a`, as `closed < Err e | Ok a >`.
    Variant(Variant),
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
    index: HashMap<String, usize>,
}

impl Record {
    pub fn new(closed: bool, fields: Vec<Field>) -> Record {
        let index = fields.iter().enumerate().map(|(i, f)| (f.key.clone(), i)).collect();
        Record { closed, fields, index }
    }

    /// The field `key`.
    pub fn field(&self, key: &str) -> Option<&Field> {
        self.index.get(key).map(|&i| &self.fields[i])
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
    index: HashMap<String, usize>,
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
