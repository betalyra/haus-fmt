//! A schema loaded by haus-fmt-schema, as the generators need it: the files
//! to generate code for (the root, and the application's files it imports,
//! directly or not), each parsed, with where each imported type comes from.
//!
//! A codec applies wherever its type occurs, inside packages' types too
//! (spec §13.4). A package's types are generated in its own crate or Roc
//! module, without the application's codecs, so the types of packages that
//! contain a codec's type, directly or not, and that the application uses
//! are copied into its code: the **codec closure**. Each package with such
//! types is a unit of its own, with only those types; the copies use the
//! package's other types from its crate or module, and each other's copies.
//!
//! haus-fmt-schema has already checked the whole graph (spec §13.3): the
//! packages and their manifests, versions and `@major`s, containment, one
//! package per name, cycles, and every rule of §14. The generators only
//! read the files it loaded.
//!
//! A spread of an imported type (`{ ...Base, x: Int }`, `Base` from a file
//! or a package) copies its fields or cases into the unit, as a spread of a
//! type of the file does. Their types are named in the file they come from,
//! so in the copy each named type is the key of an import of its own: the
//! type's id (`../shared/money#Money`), which no name in a file can be.

use crate::codegen::unknown_type;
use crate::schema::{self, Case, Field, Spread, Ty, TypeDef};
use crate::{Error, Result};
use haus::ErrorCode as Code;
use haus_schema::{Definition, InstanceId, Schema, SchemaFile, Type};
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
    /// Where each type it imports comes from, by the name it has in the
    /// file, and the types the fields and cases copied by spreads of
    /// imported types name, by their ids (see [`type_name`]). In a copy of
    /// a package's types, the package's other types it uses too.
    pub imports: HashMap<String, Origin>,
    /// The keys of `imports` that the file's own imports don't list, sorted:
    /// those ids, and in a copy of a package's types every key (the copy
    /// lists no imports of its own).
    pub copied: Vec<String>,
    /// For a copy of a package's types (the codec closure): the package.
    pub package: Option<String>,
}

/// The name of the type that `key`, a key of [`Unit::imports`], stands
/// for: `Money` for `Money`, and for `../shared/money#Money`, the id of a
/// type named by a field a spread copied.
pub(crate) fn type_name(key: &str) -> &str {
    key.rsplit_once('#').map_or(key, |(_, name)| name)
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
            Origin::Time => format!("std/time#{}", type_name(name)),
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
/// the text haus-fmt-schema read (each file is read once, spec §13.3), then
/// the packages with types to copy for the codecs with the ids `codecs`
/// (the codec closure).
pub(crate) fn units(schema: &Schema, without_attributes: bool, codecs: &[&str]) -> Result<Vec<Unit>> {
    let files = schema.files();
    let root_dir = files[0].path.as_deref().and_then(Path::parent);
    // The root, and every file outside packages.
    let app: Vec<usize> = (0..files.len()).filter(|&i| i == 0 || files[i].package.is_none()).collect();
    let copies = closure(schema, &app, codecs);
    let copied_from = |i: usize| files[i].definitions().iter().any(|d| copies.contains(&d.id));
    let packages = (1..files.len()).filter(|&i| files[i].package.is_some() && copied_from(i));
    let indices: Vec<usize> = app.iter().copied().chain(packages).collect();
    // Every file, packages' too (spreads copy from them), with the spreads of imported types left in place.
    let parsed = files
        .iter()
        .map(|f| schema::parse_with_imported_spreads(&f.text).map_err(|e| in_file(f, Error::from(e))))
        .collect::<Result<Vec<_>>>()?;
    // Positions in copied entries: past the end of every file, a range for each (see `Files::ty`).
    let bases = files
        .iter()
        .scan(files.iter().map(|f| f.text.len() + 1).sum::<usize>(), |next, f| {
            let base = *next;
            *next += f.text.len() + 1;
            Some(base)
        })
        .collect();
    let all = Files {
        files,
        parsed: &parsed,
        bases,
        unit_of: indices.iter().enumerate().map(|(u, &i)| (i, u)).collect(),
        file_by_id: files.iter().enumerate().filter_map(|(i, f)| Some((f.id.as_deref()?, i))).rev().collect(),
        copies: &copies,
    };
    indices
        .iter()
        .map(|&i| {
            let f = &files[i];
            // A copy of a package's types: only those to copy.
            let package = f.package.clone().filter(|_| i != 0);
            let id = f.id.clone().unwrap_or_default();
            let copy = |d: &&TypeDef| package.is_none() || copies.contains(&format!("{id}#{}", d.name));
            let mut copied = HashMap::new();
            let types = parsed[i]
                .types
                .iter()
                .filter(copy)
                .map(|d| Ok(TypeDef { ty: all.ty(i, &d.ty, false, &mut copied)?, ..d.clone() }))
                .collect::<Result<Vec<_>>>()
                .map_err(|e| in_file(f, e))?;
            // The names the file's imports list; in a copy, the names its types use.
            let names: Vec<String> = match package {
                None => parsed[i].imports.iter().flat_map(|imp| &imp.names).map(|(n, _)| n.clone()).collect(),
                Some(_) => used_names(&types),
            };
            let mut imports = HashMap::new();
            for name in names {
                match all.origin(i, &name).map_err(|e| in_file(f, e))? {
                    Some(origin) => imports.insert(name, origin),
                    // The prelude's types, which a copy's types use too.
                    None if package.is_some() => continue,
                    None => return Err(in_file(f, Error::new(Code::UnknownType, unknown_type(&name)))),
                };
            }
            let file = match package {
                None => schema::File { types, ..parsed[i].clone() },
                Some(_) => schema::File { types, imports: vec![], ..parsed[i].clone() },
            };
            let file = if without_attributes { schema::without_attributes(file) } else { file };
            let mut keys: Vec<String> = copied.keys().cloned().collect();
            imports.extend(copied);
            if package.is_some() {
                keys = imports.keys().cloned().collect();
            }
            keys.sort();
            let segments = match (&package, root_dir, &f.path) {
                // `@acme/orders` → ["acme", "orders"].
                (Some(name), _, _) => name.trim_start_matches('@').split('/').map(str::to_owned).collect(),
                _ if i == 0 => vec![],
                (_, Some(dir), Some(path)) => segments(dir, path),
                _ => vec![],
            };
            let (path, text) = (f.path.clone(), f.text.clone());
            Ok(Unit { path, text, file, id, segments, imports, copied: keys, package })
        })
        .collect()
}

/// The names of named types that `types` use, other than their own, sorted.
fn used_names(types: &[TypeDef]) -> Vec<String> {
    fn names(ty: &Ty, out: &mut HashSet<String>) {
        match ty {
            Ty::Name { name, args, .. } => {
                out.insert(name.clone());
                args.iter().for_each(|a| names(a, out));
            }
            Ty::Param { .. } => {}
            Ty::Record { fields, .. } => fields.iter().for_each(|f| names(&f.ty, out)),
            Ty::Variant { cases, .. } => cases.iter().flat_map(|c| &c.payload).for_each(|t| names(t, out)),
        }
    }
    let mut out = HashSet::new();
    types.iter().for_each(|d| names(&d.ty, &mut out));
    let own: HashSet<&str> = types.iter().map(|d| d.name.as_str()).collect();
    // Ids (`@acme/ids@1#Id`) are the keys of types that spreads copied in: those are known already.
    let mut out: Vec<String> = out.into_iter().filter(|n| !own.contains(n.as_str()) && !n.contains('#')).collect();
    out.sort();
    out
}

/// The ids of the packages' types to copy into the application's code, so
/// that the codecs with the ids `codecs` apply inside them (spec §13.4):
/// the types the application's files `app` use, directly or not, that
/// contain a codec's type, directly or not, and have no codec of their own
/// (that codec decodes the package's type, as with `Money` and `Currency`).
/// Packages' other types are their crates' or modules'.
fn closure(schema: &Schema, app: &[usize], codecs: &[&str]) -> HashSet<String> {
    if codecs.is_empty() {
        return HashSet::new();
    }
    let files = schema.files();
    let (mut seen, mut used) = (HashSet::new(), HashSet::new());
    for d in app.iter().flat_map(|&i| files[i].definitions()) {
        walk(schema, &schema.instance(d.template).body, &mut seen, &mut used);
    }
    let contains_codec = |d: &Definition| {
        let mut inside = HashSet::new();
        walk(schema, &schema.instance(d.template).body, &mut HashSet::new(), &mut inside);
        codecs.iter().any(|c| inside.contains(*c))
    };
    files
        .iter()
        .enumerate()
        .filter(|(i, f)| *i != 0 && f.package.is_some())
        .flat_map(|(_, f)| f.definitions())
        // A type with a codec of its own isn't copied: its codec decodes the package's type.
        .filter(|d| used.contains(&d.id) && !codecs.contains(&d.id.as_str()) && contains_codec(d))
        .map(|d| d.id.clone())
        .collect()
}

fn in_file(f: &SchemaFile, e: Error) -> Error {
    match &f.path {
        Some(path) if e.path().is_none() => e.in_file(path),
        _ => e,
    }
}

/// Every file of a schema, parsed: what the names in each stand for, and
/// the spreads of imported types copied in.
struct Files<'a> {
    files: &'a [SchemaFile],
    parsed: &'a [schema::File],
    /// For each file, what is added to the positions of the entries copied from it.
    bases: Vec<usize>,
    /// The unit of each file that is one.
    unit_of: HashMap<usize, usize>,
    file_by_id: HashMap<&'a str, usize>,
    /// The ids of the packages' types copied into the application's code.
    copies: &'a HashSet<String>,
}

impl Files<'_> {
    /// Where the type `name` of file `i` comes from: its own, or imported
    /// (from std/time, another file or a package). None for the prelude's.
    fn origin(&self, i: usize, name: &str) -> Result<Option<Origin>> {
        let imported = self.parsed[i].imports.iter().find(|imp| imp.names.iter().any(|(n, _)| n == name));
        match imported {
            Some(imp) if imp.module == "std/time" => Ok(Some(Origin::Time)),
            _ => Ok(self.source(i, name)?.map(|(at, def)| self.origin_of(at, def))),
        }
    }

    /// The file a type of file `i`, its own or imported from a file or
    /// package, is defined in, and its definition there. None for the
    /// prelude's and std/time's.
    fn source(&self, i: usize, name: &str) -> Result<Option<(usize, &Definition)>> {
        let f = &self.files[i];
        if let Some(def) = f.definitions().iter().find(|d| d.name == name) {
            return Ok(Some((i, def)));
        }
        let Some(imp) = self.parsed[i].imports.iter().find(|imp| imp.names.iter().any(|(n, _)| n == name)) else {
            return Ok(None);
        };
        if imp.module == "std/time" {
            return Ok(None);
        }
        let def = f
            .imported()
            .iter()
            .find(|d| d.name == name)
            .ok_or_else(|| Error::new(Code::UnknownImport, format!("{} has no type {name}", imp.module)))?;
        let from = def.id.rsplit_once('#').map_or("", |(file, _)| file);
        let at = *self
            .file_by_id
            .get(from)
            .ok_or_else(|| Error::new(Code::ImportNotFound, format!("no file has the id {from}")))?;
        Ok(Some((at, def)))
    }

    /// Where `def`, a type of file `at`, comes from for the files that use
    /// it: a package's type from its crate or module, unless it is copied.
    fn origin_of(&self, at: usize, def: &Definition) -> Origin {
        let (id, params, template) = (def.id.clone(), def.params.len(), def.template);
        match &self.files[at].package {
            Some(package) if at != 0 && !self.copies.contains(&id) => {
                Origin::Package { package: package.clone(), id, params, template }
            }
            _ => Origin::File { unit: self.unit_of[&at], id, params, template },
        }
    }

    /// `ty`, written in file `i`, with the spreads of imported types
    /// replaced by the entries they copy. With `copy`, `ty` is itself being
    /// copied out of file `i`: its named types become ids, each added to
    /// `copied` with where it comes from, and its positions are moved past
    /// the end of every file, so that they neither point into the wrong file
    /// nor coincide with a position of another (the generators tell some
    /// types apart by position).
    fn ty(&self, i: usize, ty: &Ty, copy: bool, copied: &mut HashMap<String, Origin>) -> Result<Ty> {
        let pos = |p: usize| if copy { self.bases[i] + p } else { p };
        let attrs = |attrs: &[schema::Attribute]| -> Vec<schema::Attribute> {
            attrs.iter().map(|a| schema::Attribute { pos: pos(a.pos), ..a.clone() }).collect()
        };
        Ok(match ty {
            Ty::Name { name, args, pos: p } => {
                let args = args.iter().map(|a| self.ty(i, a, copy, copied)).collect::<Result<_>>()?;
                let name = match (copy, self.origin(i, name)?) {
                    (true, Some(origin)) => {
                        let key = origin.id(name);
                        copied.insert(key.clone(), origin);
                        key
                    }
                    _ => name.clone(),
                };
                Ty::Name { name, args, pos: pos(*p) }
            }
            Ty::Param { name, pos: p } => Ty::Param { name: name.clone(), pos: pos(*p) },
            Ty::Record { closed, fields, spreads, pos: p } => {
                let own = fields
                    .iter()
                    .map(|f| {
                        let ty = self.ty(i, &f.ty, copy, copied)?;
                        Ok(Field { ty, pos: pos(f.pos), attrs: attrs(&f.attrs), ..f.clone() })
                    })
                    .collect::<Result<Vec<_>>>()?;
                let fields = insert(own, spreads, |s| match self.spread(i, s, copied)? {
                    Ty::Record { fields, .. } => Ok(fields),
                    _ => Err(not_a(s, "record")),
                })?;
                Ty::Record { closed: *closed, fields, spreads: vec![], pos: pos(*p) }
            }
            Ty::Variant { closed, cases, spreads, pos: p } => {
                let own = cases
                    .iter()
                    .map(|c| {
                        let payload = c.payload.iter().map(|t| self.ty(i, t, copy, copied)).collect::<Result<_>>()?;
                        Ok(Case { payload, pos: pos(c.pos), attrs: attrs(&c.attrs), ..c.clone() })
                    })
                    .collect::<Result<Vec<_>>>()?;
                let cases = insert(own, spreads, |s| match self.spread(i, s, copied)? {
                    Ty::Variant { cases, .. } => Ok(cases),
                    _ => Err(not_a(s, "variant")),
                })?;
                Ty::Variant { closed: *closed, cases, spreads: vec![], pos: pos(*p) }
            }
        })
    }

    /// The body of the imported type that the spread `s` in file `i` names
    /// (through aliases, in any file), as copied out of its file.
    fn spread(&self, i: usize, s: &Spread, copied: &mut HashMap<String, Origin>) -> Result<Ty> {
        let (mut at, mut name) = (i, s.name.clone());
        // Schemas are checked: every chain of names ends (§9.9); the bound is for safety.
        for _ in 0..1000 {
            let Some((file, def)) = self.source(at, &name)? else { break };
            let def_name = def.id.rsplit_once('#').map_or(def.name.as_str(), |(_, n)| n);
            match self.parsed[file].types.iter().find(|d| d.name == def_name) {
                // An alias, `type Base = Other`: on to `Other`, in that file.
                Some(TypeDef { params, ty: Ty::Name { name: next, args, .. }, .. })
                    if params.is_empty() && args.is_empty() =>
                {
                    (at, name) = (file, next.clone());
                }
                Some(d) => return self.ty(file, &d.ty, true, copied),
                None => break,
            }
        }
        Err(not_a(s, "record or variant"))
    }
}

/// haus-fmt-schema has checked every spread; this is for safety.
fn not_a(s: &Spread, want: &str) -> Error {
    Error::new(Code::InvalidSpread, format!("{} is not a {want}, so it can't be spread here", s.name))
}

/// Own entries, with the entries of each spread where it is written: before
/// the own entry `s.at`, or after the last one.
fn insert<T>(own: Vec<T>, spreads: &[Spread], mut copied: impl FnMut(&Spread) -> Result<Vec<T>>) -> Result<Vec<T>> {
    let n = own.len();
    let mut out = Vec::with_capacity(n);
    for (i, entry) in own.into_iter().map(Some).chain([None]).enumerate() {
        for s in spreads.iter().filter(|s| s.at == i || (i == n && s.at > n)) {
            out.extend(copied(s)?);
        }
        out.extend(entry);
    }
    Ok(out)
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

/// Checks the codecs' ids (spec §13.4): each names a type of the schema
/// that the generated code has. Types used inside packages' types are
/// among them: the units include the codec closure ([`units`]).
pub(crate) fn check_codecs<'a>(units: &[Unit], ids: impl IntoIterator<Item = &'a str>) -> Result<()> {
    let ids: Vec<&str> = ids.into_iter().collect();
    if ids.is_empty() {
        return Ok(());
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
