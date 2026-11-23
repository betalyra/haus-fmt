//! Official profiles without their codecs (spec §13.4, "A profile without
//! its codec"). A package's rule is checked only where a codec applies it:
//! a schema that reaches `Currency` without a codec for it checks currencies
//! for their shape only. That is allowed, never an error, but not silent:
//!
//! - [`Schema::missing_codecs`]: for code generated with a set of codecs,
//!   the warning `missing-codec` once per type id;
//! - [`unchecked_profiles`]: for tools without codecs (`haus check`), a note
//!   at each import of an official package that has profiles.
//!
//! Which types have profiles is the table [`PROFILED_TYPES`], the binding's
//! own: a build reads only a package's `package.haus` and `schema.haus`.

use crate::resolve::Schema;
use crate::types::{InstanceId, Payload, Type};
use crate::{Error, Warning};
use haus::ErrorCode;
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

/// The types official profiles have a rule for, by id, with the profiles
/// (spec §13.4). `iso`'s rule for `Money` is its currency's, so `Currency`
/// stands for it.
pub const PROFILED_TYPES: &[(&str, &str)] =
    &[("@haus-fmt/money@1#Currency", "iso"), ("@haus-fmt/geo@1#LatLng", "wgs84"), ("@haus-fmt/geo@1#BBox", "wgs84")];

/// The profiles that have a rule for the type with this id (`iso` for
/// `@haus-fmt/money@1#Currency`), if any.
pub fn profiles(id: &str) -> Option<&'static str> {
    PROFILED_TYPES.iter().find(|(t, _)| *t == id).map(|(_, p)| *p)
}

/// The profiles of an official package (`iso` for `@haus-fmt/money`), if
/// it has any, joined with `, `.
pub fn package_profiles(name: &str) -> Option<String> {
    let mut found: Vec<&str> = PROFILED_TYPES
        .iter()
        .filter(|(id, _)| id.split_once('#').and_then(|(m, _)| m.rsplit_once('@')).is_some_and(|(p, _)| p == name))
        .map(|(_, p)| *p)
        .collect();
    found.dedup();
    (!found.is_empty()).then(|| found.join(", "))
}

/// The warning `missing-codec` for a type with profiles and no codec, at no place.
pub fn missing_codec(id: &str, profiles: &str) -> Warning {
    let reason = format!(
        "{id} has profiles ({profiles}), but no codec is set for it: its values are checked for their shape only"
    );
    Error::new(ErrorCode::MissingCodec, reason)
}

/// The note of a tool without codecs for an import of the official package
/// `name` with `profiles`.
pub fn unchecked_note(name: &str, profiles: &str) -> String {
    format!(
        "the rules of {name} (profiles: {profiles}) are not checked here; your application checks them by adding a codec"
    )
}

/// For tools that have no codecs (`haus check`, editors): one `missing-codec`
/// note per import of an official package with profiles in the schema file
/// `text`, at the import (its line and column), in the order of the
/// imports. A file that doesn't parse has none.
pub fn unchecked_profiles(text: &str) -> Vec<Warning> {
    let Ok(file) = crate::syntax::parse_with_imported_spreads(text) else { return vec![] };
    file.imports
        .iter()
        .filter_map(|import| {
            let module =
                import.module.rsplit_once('@').filter(|(p, _)| p.contains('/')).map_or(&*import.module, |(p, _)| p);
            let profiles = package_profiles(module)?;
            let e = crate::syntax::error(text, import.pos, ErrorCode::MissingCodec, unchecked_note(module, &profiles));
            Some(Error::from(e))
        })
        .collect()
}

impl Schema {
    /// The `missing-codec` warnings for code generated from this schema
    /// with codecs for the types `codecs` (ids): one per type that an
    /// official profile has a rule for ([`PROFILED_TYPES`]), that the
    /// definitions of the application's files (the root, and the files it
    /// imports, not packages) reach, and that has no codec. A type reached
    /// only inside a type that has a codec doesn't count: that codec decides
    /// which values it holds (a codec for `Money` covers its `Currency`).
    /// At no place, sorted by id.
    pub fn missing_codecs<'a>(&self, codecs: impl IntoIterator<Item = &'a str>) -> Vec<Warning> {
        let roots: Vec<&Type> = self
            .files()
            .iter()
            .enumerate()
            .filter(|(i, f)| *i == 0 || f.package.is_none())
            .flat_map(|(_, f)| f.definitions())
            .map(|d| &self.instance(d.template).body)
            .collect();
        self.missing_codecs_from(roots, codecs)
    }

    /// [`Schema::missing_codecs`] for decoding with the types `roots`.
    pub fn missing_codecs_from<'a, 't>(
        &self,
        roots: impl IntoIterator<Item = &'t Type>,
        codecs: impl IntoIterator<Item = &'a str>,
    ) -> Vec<Warning> {
        let codecs: HashSet<&str> = codecs.into_iter().collect();
        let mut missing: BTreeMap<&str, &str> = BTreeMap::new();
        let mut seen: HashSet<InstanceId> = HashSet::new();
        // Records and variants are shared (an argument used twice): each is walked once.
        let mut shared: HashSet<*const ()> = HashSet::new();
        let mut stack: Vec<&Type> = roots.into_iter().collect();
        while let Some(ty) = stack.pop() {
            match ty {
                Type::Ref(id) if seen.insert(*id) => {
                    let instance = self.instance(*id);
                    let plain = instance.args.is_empty();
                    if plain && codecs.contains(instance.id.as_str()) {
                        continue;
                    }
                    if let Some(p) = profiles(&instance.id).filter(|_| plain) {
                        missing.insert(&instance.id, p);
                    }
                    stack.push(&instance.body);
                }
                Type::Array(t) | Type::Map(t) | Type::Maybe(t) | Type::Secret(t) => stack.push(t),
                Type::Record(r) if shared.insert(Arc::as_ptr(r).cast()) => stack.extend(r.fields.iter().map(|f| &f.ty)),
                Type::Variant(v) if shared.insert(Arc::as_ptr(v).cast()) => {
                    for case in &v.cases {
                        match &case.payload {
                            Payload::None => {}
                            Payload::Record(r) => stack.extend(r.fields.iter().map(|f| &f.ty)),
                            Payload::Named(t) => stack.push(t),
                            Payload::Positional(ts) => stack.extend(ts),
                        }
                    }
                }
                _ => {}
            }
        }
        missing.into_iter().map(|(id, p)| missing_codec(id, p)).collect()
    }
}
