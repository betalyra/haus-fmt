//! Package rules for tools (packages.md §7, "Tools"). A program implements
//! the rules of the packages it uses, or takes them shape-only, and a schema
//! that reaches a rule it has neither is `missing-codec`, an error, when it
//! is compiled ([`crate::Options::require_rules`]). A tool that checks data
//! without a program behind it (`haus check`, an editor) has the official
//! rules built in, and for any other reached rule reports a hint instead, at
//! the import of its package: [`unchecked_rules`].

use crate::resolve::Schema;
use crate::{Error, Warning};
use haus::ErrorCode;
use std::collections::BTreeMap;

/// The note of a tool for an import of the package `name` whose reached
/// `rules` (`Id: ulid`) it doesn't check.
pub fn unchecked_note(name: &str, rules: &str) -> String {
    format!("the rules of {name} ({rules}) are not checked here")
}

/// For tools that can't supply rules: one `missing-codec` hint per import,
/// in the schema file `text` (the root of `schema`, compiled with
/// `require_rules: false`), of a package with a rule the schema reaches and
/// the tool doesn't implement, at the import (its line and column), in the
/// order of the imports.
pub fn unchecked_rules(text: &str, schema: &Schema) -> Vec<Warning> {
    let mut unchecked: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    let reached = schema.reached_rules();
    for (id, rule, _) in reached.iter().filter(|(_, _, implemented)| !implemented) {
        let Some((package, ty)) = id.split_once('#') else { continue };
        let name = package.rsplit_once('@').map_or(package, |(n, _)| n);
        unchecked.entry(name).or_default().push(format!("{ty}: {rule}"));
    }
    let Ok(file) = crate::syntax::parse_with_imported_spreads(text) else { return vec![] };
    file.imports
        .iter()
        .filter_map(|import| {
            let module =
                import.module.rsplit_once('@').filter(|(p, _)| p.contains('/')).map_or(&*import.module, |(p, _)| p);
            let rules = unchecked.get(module)?;
            let note = unchecked_note(module, &rules.join(", "));
            Some(Error::from(crate::syntax::error(text, import.pos, ErrorCode::MissingCodec, note)))
        })
        .collect()
}
