//! JSON import (spec §16.1): any JSON read as a haus value, without a schema.
//! It only reads, and nothing in the data is special: `{"_tag": "Circle"}`
//! and `{"_haus": 1, "_value": 2}` are records.

use super::{Json, decode_supported, open};
use crate::ser::check_key;
use crate::{DecodeError, Limits, List, Number, Record, Tag, Text, Value};

type R = Result<Value, DecodeError>;

/// Any JSON as a haus value (spec §16.1): an object as a record, an array as
/// an array, a string as a string, a number as a number with its literal
/// normalized (`1E+05` is `1e5`), `true` / `false` as `True` / `False`, and
/// `null` as `None`. The result nests at most `limits.max_depth`, and its
/// strings and keys are within the string limit. Fails if `limits.max_depth` is more
/// than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn import(json: &Json, limits: &Limits) -> R {
    import_at(json, limits, 0)
}

/// [`import`] for a value inside `depth` containers.
pub(crate) fn import_at(json: &Json, limits: &Limits, depth: usize) -> R {
    decode_supported(limits)?;
    Import { limits }.value(json, depth)
}

/// Reads JSON without a schema. The steps that don't recurse are functions
/// of their own, so that the recursive frames stay small (see
/// [`crate::MAX_SUPPORTED_DEPTH`]).
struct Import<'a> {
    limits: &'a Limits,
}

impl Import<'_> {
    fn value(&self, json: &Json, depth: usize) -> R {
        match json {
            Json::Array(items) => self.items(items, depth),
            Json::Object(members) => self.members(members, depth),
            scalar => scalar_value(scalar, self.limits),
        }
    }

    fn items(&self, items: &[Json], depth: usize) -> R {
        let depth = open(self.limits, depth)?;
        let values = items.iter().enumerate().map(|(i, x)| self.value(x, depth).map_err(|e| e.index(i)));
        values.collect::<Result<_, _>>().map(|items| Value::Array(List::from_checked(items)))
    }

    fn members(&self, members: &[(String, Json)], depth: usize) -> R {
        let depth = open(self.limits, depth)?;
        let fields = members.iter().map(|(k, v)| {
            key(k, self.limits)?;
            Ok((k.clone(), self.value(v, depth).map_err(|e| e.field(k))?))
        });
        let fields = fields.collect::<Result<Vec<_>, DecodeError>>()?;
        // The reader takes no member twice; a Json built in code may have one twice.
        // The depth and the keys were checked above.
        Ok(Value::Record(Record::from_fields_with(fields, &crate::value::any())?))
    }
}

fn scalar_value(json: &Json, limits: &Limits) -> R {
    Ok(match json {
        Json::Bool(true) => tag("True"),
        Json::Bool(false) => tag("False"),
        Json::Number(n) => Value::Number(Number::from_normalized(normalize_number(n))),
        Json::String(s) => {
            crate::ser::check_length(s, limits).map_err(crate::EncodeError::into_decode)?;
            Value::String(Text::from_checked(s.clone()))
        }
        _ => tag("None"),
    })
}

fn tag(name: &str) -> Value {
    Tag::from_valid(name.to_owned()).into()
}

/// A member name as a record key: within the string limit (spec §7).
pub(crate) fn key(k: &str, limits: &Limits) -> Result<(), DecodeError> {
    check_key(k, limits).map_err(|e| e.into_decode().field(k))
}

/// A JSON number as a normalized haus literal: `1E+05` is `1e5`, `1e-0` is `1e0`.
pub(crate) fn normalize_number(n: &str) -> String {
    crate::parser::normalize_exponent(n.replace('E', "e"))
}
