//! Building `--json` output with haus's own JSON writer.

use haus::json::Json;

pub fn s(text: &str) -> Json {
    Json::String(text.to_owned())
}

pub fn n(number: usize) -> Json {
    Json::Number(number.into())
}

pub fn b(value: bool) -> Json {
    Json::Bool(value)
}

/// An object's members, in the order they are added.
#[derive(Default)]
pub struct Members(haus::json::JsonObject);

impl Members {
    /// Adds a member; each name is added once.
    pub fn add(&mut self, name: &str, value: Json) {
        self.0.insert(name, value).unwrap_or_else(|e| panic!("writing JSON output: {e}"));
    }

    /// Adds the member if there is a value: members that don't apply are left out.
    pub fn opt(&mut self, name: &str, value: Option<Json>) {
        if let Some(value) = value {
            self.add(name, value);
        }
    }
}

impl From<Members> for Json {
    fn from(m: Members) -> Json {
        Json::Object(m.0)
    }
}

/// The JSON text, on one line. The output is built from strings and small
/// numbers, well within the writer's limits.
pub fn write(json: &Json) -> String {
    let limits = haus::Limits { max_string_length: usize::MAX, ..haus::Limits::default() };
    haus::json::write_with(json, &limits).unwrap_or_else(|e| panic!("writing JSON output: {e}"))
}
