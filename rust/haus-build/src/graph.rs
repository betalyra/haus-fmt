//! A schema loaded by haus-fmt-schema, as the generators need it: the files
//! to generate code for (the root, and the application's files it imports,
//! directly or not), each parsed, with where each imported type comes from.
//!
//! haus-fmt-schema has already checked the whole graph (spec §13.3): the
//! packages and their manifests, versions and `@major`s, containment, one
//! package per name, cycles, and every rule of §14. The generators only
//! read the files it loaded.

use crate::schema;
use crate::{Error, Result};
use haus::ErrorCode as Code;
use haus_schema::{InstanceId, Schema, Type};
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

/// A file to generate code for: the root, or an application's file it imports.
pub(crate) struct Unit {
    /// Its real path (None for a schema given as text).
    pub path: Option<PathBuf>,
    pub text: String,
    pub file: schema::File,
    /// `shop/src/order`, `@haus-fmt/money@1`.
    pub id: String,
    /// Its path from the root file's directory, without the extension, `..`
    /// as `up`: `["billing", "common"]`. Empty for the root.
    pub segments: Vec<String>,
    /// Where each type it imports comes from, by the name it has in the file.
    pub imports: HashMap<String, Origin>,
}

/// Where an imported type comes from.
#[derive(Debug, Clone)]
pub(crate) enum Origin {
    /// std/time.
    Time,
    /// A schema package (`@haus-fmt/money`), whose code is generated elsewhere.
    Package { package: String, id: String, params: usize, template: InstanceId },
    /// Another file of the application: the index of its [`Unit`].
    File { unit: usize, id: String, params: usize, template: InstanceId },
}

impl Origin {
    pub fn id(&self, name: &str) -> String {
        match self {
            Origin::Time => format!("std/time#{name}"),
            Origin::Package { id, .. } | Origin::File { id, .. } => id.clone(),
        }
    }
}

/// What an imported type is, as far as record cases go (spec §15): a case
/// `Tag T` is one if `T` is a record, through names and applied generic types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Shape {
    /// A record: the first of its fields named `_tag` or `_args`, if any
    /// (such a case has no schema-based JSON form, §16.3).
    Record(Option<String>),
    /// One of its parameters, the `i`-th: `type Id a = a`.
    Param(usize),
    Other,
}

impl Origin {
    /// What the imported type is.
    pub fn shape(&self, schema: &Schema) -> Shape {
        match self {
            Origin::Time => Shape::Other,
            Origin::Package { template, .. } | Origin::File { template, .. } => shape(schema, *template),
        }
    }
}

/// What the type with this template (its body, its parameters left as they are) is.
pub(crate) fn shape(schema: &Schema, template: InstanceId) -> Shape {
    let template = schema.instance(template);
    match schema.resolve(&template.body) {
        Type::Record(r) => {
            Shape::Record(r.fields.iter().map(|f| f.key.clone()).find(|k| matches!(k.as_str(), "_tag" | "_args")))
        }
        Type::Param(p) => {
            template.args.iter().position(|a| matches!(a, Type::Param(q) if q == p)).map_or(Shape::Other, Shape::Param)
        }
        _ => Shape::Other,
    }
}

/// Whether `ty`, the one argument of a case, is a record type: then the
/// case is a record case (spec §15), as `Tag { … }` is. Names are followed
/// through the file's definitions `defs` (aliases, applied generic types,
/// `Found (Page Int)`) and imported types (`imported`). A type parameter
/// never is one, even where its argument is a record. If it is, the first of
/// the record's fields named `_tag` or `_args`, if any.
pub(crate) fn record_case(
    ty: &schema::Ty,
    defs: &HashMap<&str, &schema::TypeDef>,
    imported: &dyn Fn(&str) -> Option<Shape>,
) -> Option<Option<String>> {
    use schema::Ty;
    let mut ty = ty.clone();
    // Schemas are checked: every chain of names ends (§9.9); the bound is for safety.
    for _ in 0..1000 {
        match ty {
            Ty::Record { fields, .. } => {
                return Some(fields.iter().map(|f| f.key.clone()).find(|k| matches!(k.as_str(), "_tag" | "_args")));
            }
            Ty::Name { name, args, .. } => match (defs.get(name.as_str()), imported(&name)) {
                (Some(def), _) => ty = substitute(&def.ty, &def.params, &args),
                (None, Some(Shape::Record(reserved))) => return Some(reserved),
                (None, Some(Shape::Param(i))) => ty = args.get(i)?.clone(),
                // The prelude's types and std/time's are not records.
                _ => return None,
            },
            Ty::Param { .. } | Ty::Variant { .. } => return None,
        }
    }
    None
}

/// `ty` with the parameters `params` replaced by `args`.
fn substitute(ty: &schema::Ty, params: &[String], args: &[schema::Ty]) -> schema::Ty {
    use schema::Ty;
    match ty {
        Ty::Param { name, .. } => match params.iter().position(|p| p == name).and_then(|i| args.get(i)) {
            Some(arg) => arg.clone(),
            None => ty.clone(),
        },
        Ty::Name { name, args: inner, pos } => Ty::Name {
            name: name.clone(),
            args: inner.iter().map(|a| substitute(a, params, args)).collect(),
            pos: *pos,
        },
        // Only whether it is a record matters, not what its fields hold.
        Ty::Record { .. } | Ty::Variant { .. } => ty.clone(),
    }
}

/// The files of `schema` to generate code for, the root first, each with
/// the text haus-fmt-schema read (each file is read once, spec §13.3).
pub(crate) fn units(schema: &Schema, without_attributes: bool) -> Result<Vec<Unit>> {
    let files = schema.files();
    let root_dir = files[0].path.as_deref().and_then(Path::parent);
    // The root, and every file outside packages.
    let indices: Vec<usize> = (0..files.len()).filter(|&i| i == 0 || files[i].package.is_none()).collect();
    let unit_of: HashMap<usize, usize> = indices.iter().enumerate().map(|(u, &i)| (i, u)).collect();
    let file_by_id: HashMap<&str, usize> =
        files.iter().enumerate().filter_map(|(i, f)| Some((f.id.as_deref()?, i))).rev().collect();
    indices
        .iter()
        .map(|&i| {
            let f = &files[i];
            let text = f.text.clone();
            let in_file = |e: Error| match &f.path {
                Some(path) => e.in_file(path),
                None => e,
            };
            let file = schema::parse(&text).map_err(|e| in_file(Error::from(e)))?;
            let file = if without_attributes { schema::without_attributes(file) } else { file };
            let mut imports = HashMap::new();
            for imp in &file.imports {
                for (name, _) in &imp.names {
                    let origin = match imp.module.as_str() {
                        "std/time" => Origin::Time,
                        _ => {
                            let def = f.imported().iter().find(|d| d.name == *name).ok_or_else(|| {
                                Error::new(Code::UnknownImport, format!("{} has no type {name}", imp.module))
                            })?;
                            let from = def.id.rsplit_once('#').map_or("", |(file, _)| file);
                            let at = *file_by_id.get(from).ok_or_else(|| {
                                Error::new(Code::ImportNotFound, format!("no file has the id {from}"))
                            })?;
                            let (id, params) = (def.id.clone(), def.params.len());
                            match &files[at].package {
                                Some(package) if at != 0 => {
                                    Origin::Package { package: package.clone(), id, params, template: def.template }
                                }
                                _ => Origin::File { unit: unit_of[&at], id, params, template: def.template },
                            }
                        }
                    };
                    imports.insert(name.clone(), origin);
                }
            }
            let segments = match (i, root_dir, &f.path) {
                (0, _, _) | (_, None, _) | (_, _, None) => vec![],
                (_, Some(dir), Some(path)) => segments(dir, path),
            };
            let id = f.id.clone().unwrap_or_default();
            Ok(Unit { path: f.path.clone(), text, file, id, segments, imports })
        })
        .collect()
}

/// The path of `path` from the directory `dir`, without the extension, with
/// `..` as `up`: `["billing", "common"]`, `["up", "shared", "money"]`.
fn segments(dir: &Path, path: &Path) -> Vec<String> {
    let (dir, path): (Vec<Component>, Vec<Component>) = (dir.components().collect(), path.components().collect());
    let common = dir.iter().zip(&path).take_while(|(a, b)| a == b).count();
    let up = (common..dir.len()).map(|_| "up".to_owned());
    let down = path[common..].iter().map(|c| c.as_os_str().to_string_lossy().into_owned());
    let mut all: Vec<String> = up.chain(down).collect();
    if let Some(last) = all.last_mut() {
        *last = last.strip_suffix(".schema.haus").unwrap_or(last).to_owned();
    }
    all
}

/// Names for the units after the root, made by `name` from their segments,
/// different from each other and from `taken`: a second `billing_common`
/// is `billing_common<sep>2`.
pub(crate) fn module_names(
    units: &[Unit],
    taken: &[&str],
    sep: &str,
    name: impl Fn(&[String]) -> String,
) -> Vec<String> {
    let mut used: HashSet<String> = taken.iter().map(|t| t.to_string()).collect();
    units
        .iter()
        .map(|u| {
            let base = name(&u.segments);
            let mut candidate = base.clone();
            let mut n = 1;
            while !used.insert(candidate.clone()) {
                n += 1;
                candidate = format!("{base}{sep}{n}");
            }
            candidate
        })
        .collect()
}

/// Checks the codecs' ids (spec §13.4): each names a type of the schema,
/// and none a type used inside a type whose code is generated elsewhere (a
/// package's), where the codec couldn't apply. `owner(package)` says what
/// generates a package's code: `haus_orders`, for the message.
pub(crate) fn check_codecs<'a>(
    schema: &Schema,
    units: &[Unit],
    ids: impl IntoIterator<Item = &'a str>,
    owner: impl Fn(&str) -> String,
    elsewhere: &str,
) -> Result<()> {
    let ids: Vec<&str> = ids.into_iter().collect();
    if ids.is_empty() {
        return Ok(());
    }
    for unit in units {
        let mut packages: Vec<(&String, &Origin)> =
            unit.imports.iter().filter(|(_, o)| matches!(o, Origin::Package { .. })).collect();
        packages.sort_by_key(|(n, _)| n.as_str());
        for (_, origin) in packages {
            let Origin::Package { package, id, template, .. } = origin else { continue };
            let mut inside = HashSet::new();
            walk(schema, &schema.instance(*template).body, &mut HashSet::new(), &mut inside);
            if let Some(codec) = ids.iter().find(|c| inside.contains(**c)) {
                return Err(Error::new(
                    Code::CodecUnreachable,
                    format!(
                        "{codec} is used inside {id}, which {} generates; codecs can't reach into {elsewhere} yet",
                        owner(package)
                    ),
                ));
            }
        }
    }
    // Every type the generated code has: the units' own, and what they import.
    let mut known: Vec<String> = units
        .iter()
        .flat_map(|u| {
            let own = u.file.types.iter().map(|d| format!("{}#{}", u.id, d.name));
            own.chain(u.imports.iter().map(|(n, o)| o.id(n))).collect::<Vec<_>>()
        })
        .collect();
    known.sort();
    known.dedup();
    match ids.iter().find(|c| !known.iter().any(|k| k == *c)) {
        Some(codec) => Err(Error::new(
            Code::UnknownType,
            format!("a codec for {codec}, but the schema has no such type (it has {})", known.join(", ")),
        )),
        None => Ok(()),
    }
}

/// The ids of the named types `ty` uses, directly or not, and of std/time types.
fn walk(schema: &Schema, ty: &Type, seen: &mut HashSet<InstanceId>, out: &mut HashSet<String>) {
    match ty {
        Type::Builtin(_) | Type::Param(_) => {}
        Type::Time(name) => {
            out.insert(format!("std/time#{name}"));
        }
        Type::Array(t) | Type::Map(t) | Type::Maybe(t) | Type::Secret(t) => walk(schema, t, seen, out),
        Type::Record(r) => r.fields.iter().for_each(|f| walk(schema, &f.ty, seen, out)),
        Type::Variant(v) => v.cases.iter().for_each(|c| match &c.payload {
            haus_schema::Payload::None => {}
            haus_schema::Payload::Record(r) => r.fields.iter().for_each(|f| walk(schema, &f.ty, seen, out)),
            haus_schema::Payload::Named(t) => walk(schema, t, seen, out),
            haus_schema::Payload::Positional(items) => items.iter().for_each(|t| walk(schema, t, seen, out)),
        }),
        Type::Ref(id) => {
            if seen.insert(*id) {
                let instance = schema.instance(*id);
                out.insert(instance.id.clone());
                instance.args.iter().for_each(|a| walk(schema, a, seen, out));
                walk(schema, &instance.body, seen, out);
            }
        }
    }
}
