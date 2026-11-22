//! A schema file with its imports: names looked up, generic types applied,
//! and every rule of spec §14 checked. A port of the TypeScript reference
//! (typescript/packages/haus/src/schema-file.ts), on the syntax trees of
//! [`syntax`](crate::syntax).
//!
//! Generic types are applied by instantiating them (`List Int` is a type of
//! its own), which terminates because no type parameter passes, inside a
//! bigger type, along a cycle of references back to itself (§9.10, the
//! expansive-cycle rule); a limit on the number of instances is a second
//! guard.

use crate::files::{self, FileCache, Found};
use crate::locator::{Locator, NoImports, duplicate};
use crate::syntax::{self, Attribute, STD_TIME, Ty, deprecation, unknown_type};
use crate::types::{Builtin, Case, Deprecation, Field, Instance, InstanceId, Payload, Record, Type, Variant};
use crate::{Error, Result, Warning, quote, shown};
use haus::ErrorCode as Code;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

const MAX_INSTANCES: usize = 10_000;
const MAX_FILES: usize = 256;

/// The prelude's types with parameters, and how many.
const GENERIC: [(&str, usize); 6] =
    [("Array", 1), ("Map", 1), ("Maybe", 1), ("Result", 2), ("Secret", 1), ("Stream", 1)];

/// How to load a schema.
#[derive(Clone, Copy)]
pub struct Options<'a> {
    /// Finds the packages imports name (spec §13.3). [`NoImports`] (the
    /// default) finds none.
    pub packages: &'a dyn Locator,
    /// The root file's path: its relative imports resolve from it, and its
    /// own imports of packages are checked as its. None: a schema given as
    /// text, which imports no files.
    pub path: Option<&'a Path>,
    /// The root file's id, for the ids of its types (`shop/order` gives
    /// `shop/order#Order`). Default: from its manifest for a package's
    /// `schema.haus`, else as for any file outside packages ([`Options::project`]).
    pub id: Option<&'a str>,
    /// Ids of files outside packages: `Some(("shop", dir))` gives
    /// `dir/src/common.schema.haus` the id `shop/src/common`. None: the path
    /// from the root file's directory (`common`, `billing/common`).
    pub project: Option<(&'a str, &'a Path)>,
    /// The build's root (spec §13.3, "The root"): a directory that contains
    /// the root file, to widen the root, such as a repository whose schemas
    /// share files across folders, resolved to its real path once; a
    /// relative one is relative to the directory of the root file's real
    /// path. Relative imports never go above it (`import-outside-root`) and
    /// follow no symbolic link (`import-not-found`), and messages show
    /// paths relative to it. None: the directory of the root file's real
    /// path. A root that doesn't contain the root file is
    /// `import-outside-root` (without a place), one that doesn't exist
    /// `import-not-found`.
    pub root: Option<&'a Path>,
    /// Leave the attributes of every file out, as if they weren't written:
    /// decoding is the same (spec §15). For tests of that.
    pub without_attributes: bool,
}

impl Default for Options<'_> {
    fn default() -> Self {
        Options { packages: &NoImports, path: None, id: None, project: None, root: None, without_attributes: false }
    }
}

/// A type definition, in the file a schema was loaded from or imported into it.
#[derive(Debug, Clone)]
pub struct Definition {
    /// Its name in the file (imported types keep their names).
    pub name: String,
    /// Its id (spec §13.3): `@haus-fmt/money@1#Money`, `<file id>#Name`, or just the name.
    pub id: String,
    pub params: Vec<String>,
    /// The `//` comment lines just above it.
    pub doc: String,
    pub deprecated: Option<Deprecation>,
    /// The type: for a generic type, applied to its parameters ([`Type::Param`]).
    pub template: InstanceId,
}

/// A schema package a schema reaches, directly or through other packages.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemaPackage {
    /// `@haus-fmt/money`.
    pub name: String,
    /// The version of its manifest: `1.2.0`.
    pub version: String,
    /// Its directory (a real path).
    pub dir: PathBuf,
}

/// A schema file, its imports resolved and every rule of spec §14 checked.
#[derive(Debug, Clone)]
pub struct Schema {
    instances: Vec<Instance>,
    /// The file's own definitions in source order, then the imported ones.
    definitions: Vec<Definition>,
    /// Each name's first definition in `definitions`.
    by_name: HashMap<String, usize>,
    own: usize,
    warnings: Vec<Warning>,
    packages: Vec<SchemaPackage>,
    files: Vec<SchemaFile>,
}

/// A file a schema loaded: the root, or a file or package it imports,
/// directly or not. Code generators make one module of each.
#[derive(Debug, Clone)]
pub struct SchemaFile {
    /// Its real path; None for a schema given as text.
    pub path: Option<PathBuf>,
    /// Its id (spec §13.3): `@haus-fmt/money@1`, `shop/src/common`; None for
    /// a schema given as text without one.
    pub id: Option<String>,
    /// The package's name, for a package's `schema.haus`; None for a file outside packages.
    pub package: Option<String>,
    /// Its text, as read: each file is read once for a schema (spec §13.3).
    pub text: String,
    /// Its own definitions in source order, then the ones it imports.
    definitions: Vec<Definition>,
    own: usize,
    warnings: Vec<Warning>,
}

impl SchemaFile {
    /// The file's own definitions, in source order.
    pub fn definitions(&self) -> &[Definition] {
        &self.definitions[..self.own]
    }

    /// The types the file imports from packages and files (not std/time), by
    /// the name they have in it.
    pub fn imported(&self) -> &[Definition] {
        &self.definitions[self.own..]
    }

    /// What to point out in the file, in source order (as [`Schema::warnings`]).
    pub fn warnings(&self) -> &[Warning] {
        &self.warnings
    }
}

impl Schema {
    /// A schema whose imports are std modules only.
    pub fn parse(text: &str) -> Result<Schema> {
        Schema::parse_with(text, &Options::default())
    }

    /// A schema, with `options`: the packages it imports found by
    /// `options.packages`, its files next to `options.path`.
    pub fn parse_with(text: &str, options: &Options) -> Result<Schema> {
        Loader::new(options, FileCache::new()).run(text)
    }

    /// The schema file at `path`: its relative imports next to it, the
    /// packages it imports found by `packages`.
    pub fn load(path: impl AsRef<Path>, packages: &dyn Locator) -> Result<Schema> {
        Schema::load_with(path, &Options { packages, ..Options::default() })
    }

    /// [`Schema::load`] with options; `options.path` is `path`.
    pub fn load_with(path: impl AsRef<Path>, options: &Options) -> Result<Schema> {
        let path = path.as_ref();
        let mut files = FileCache::new();
        let (real, text) = files::root(path, &mut files)?;
        // A root option that doesn't contain the file is reported at no place.
        let root = files::build_root(&real, options.root)?;
        Loader::new(&Options { path: Some(path), root: Some(&root), ..*options }, files)
            .run(&text)
            .map_err(|e| if e.path().is_some() { e } else { e.in_file(path) })
    }

    /// Every schema package the schema reaches, by name.
    pub fn packages(&self) -> &[SchemaPackage] {
        &self.packages
    }

    /// Every file the schema loaded: the root first, then the files and
    /// packages it imports, directly or not, each once.
    pub fn files(&self) -> &[SchemaFile] {
        &self.files
    }

    /// The file's own definitions, in source order.
    pub fn definitions(&self) -> &[Definition] {
        &self.definitions[..self.own]
    }

    /// The types the file imports, by the name they have in it.
    pub fn imported(&self) -> &[Definition] {
        &self.definitions[self.own..]
    }

    /// The definition called `name` in the file, its own or imported.
    pub fn definition(&self, name: &str) -> Option<&Definition> {
        self.by_name.get(name).map(|&i| &self.definitions[i])
    }

    pub fn instance(&self, id: InstanceId) -> &Instance {
        &self.instances[id.0]
    }

    /// What to point out in the file (not in the files it imports), in source
    /// order: attributes this version doesn't define, uses of deprecated
    /// types, record cases with no schema-based JSON form (`no-json-form`).
    pub fn warnings(&self) -> &[Warning] {
        &self.warnings
    }

    /// The type a reference stands for, following named types: a record, a variant, …
    pub fn resolve<'a>(&'a self, mut ty: &'a Type) -> &'a Type {
        // Schemas are checked: every chain of names ends (§9.9).
        while let Type::Ref(id) = ty {
            ty = &self.instance(*id).body;
        }
        ty
    }

    /// A short description of a type, as in a schema: `Array Line`,
    /// `Maybe Int`, `one of A, B` (for messages). Arguments nested deeper than
    /// a few levels are left out (`P (P (P … …) …) …`): they can be shared, so
    /// written in full they could double at every level.
    pub fn describe(&self, ty: &Type) -> String {
        self.describe_at(ty, 0)
    }

    fn describe_at(&self, ty: &Type, depth: usize) -> String {
        match ty {
            Type::Builtin(b) => b.name().into(),
            Type::Time(name) => (*name).into(),
            Type::Array(item) => format!("Array {}", self.atom(item, depth)),
            Type::Map(value) => format!("Map {}", self.atom(value, depth)),
            Type::Maybe(item) => format!("Maybe {}", self.atom(item, depth)),
            Type::Secret(item) => format!("Secret {}", self.atom(item, depth)),
            Type::Record(_) => "a record".into(),
            Type::Variant(v) => tags(v),
            Type::Ref(id) => {
                let inst = self.instance(*id);
                match inst.args.is_empty() {
                    true => inst.name.clone(),
                    false => {
                        let args: Vec<String> = match depth < 2 {
                            true => inst.args.iter().map(|a| self.atom(a, depth + 1)).collect(),
                            false => inst.args.iter().map(|_| "…".to_string()).collect(),
                        };
                        format!("{} {}", inst.name, args.join(" "))
                    }
                }
            }
            Type::Param(name) => name.clone(),
        }
    }

    fn atom(&self, ty: &Type, depth: usize) -> String {
        let d = self.describe_at(ty, depth);
        match d.contains(' ') && !d.starts_with('<') {
            true => format!("({d})"),
            false => d,
        }
    }
}

/// The tags of a variant, for messages: `one of A, B`, or `any tag` for `< >`.
pub(crate) fn tags(v: &Variant) -> String {
    let names: Vec<&str> = v.cases.iter().map(|c| c.tag.as_str()).collect();
    match names.len() {
        0 => "any tag".into(),
        n if n > 6 => format!("one of {}, …", names[..6].join(", ")),
        _ => format!("one of {}", names.join(", ")),
    }
}

// ── loading ──────────────────────────────────────────────────

/// One schema file: the root, or one it imports (directly or not).
struct Unit {
    text: String,
    file: syntax::File,
    /// Its real path, if it is a file.
    path: Option<PathBuf>,
    /// The package's name, for a package's `schema.haus`.
    package: Option<String>,
    id: Option<String>,
    /// Where it was first imported: the importing file, the import's offset there, the module as written.
    origin: Option<(usize, usize, String)>,
    /// Its own definitions, by name: what other files can import.
    own: HashMap<String, usize>,
    /// Every named type in scope, its own and imported ones: (file, definition).
    scope: HashMap<String, (usize, usize)>,
    /// Types imported from std/time.
    std: HashMap<String, &'static str>,
}

/// What is wrong, at an offset of a file.
struct Fail {
    unit: usize,
    pos: usize,
    code: Code,
    reason: String,
}

fn fail<T>(unit: usize, pos: usize, code: Code, reason: impl Into<String>) -> Result<T, Fail> {
    Err(Fail { unit, pos, code, reason: reason.into() })
}

/// A package a schema reaches: one per name.
struct Reached {
    /// Its `schema.haus`.
    path: PathBuf,
    found: Found,
    text: String,
}

struct Loader<'a> {
    options: &'a Options<'a>,
    units: Vec<Unit>,
    /// Files by real path, loaded once each.
    by_path: HashMap<PathBuf, usize>,
    /// Packages by name.
    packages: BTreeMap<String, Reached>,
    /// Ids of files outside packages: a prefix, and the directory their paths start from.
    base: Option<(String, PathBuf)>,
    /// The files being loaded, for import cycles.
    loading: Vec<usize>,
    /// Every file read, each once.
    files: FileCache,
    /// The `schema.haus` of copies of packages (identical to the one
    /// loaded), whose imports were resolved too.
    copies: HashSet<PathBuf>,
    instances: Vec<Instance>,
    /// Per instance: the definition it applies.
    def_of: Vec<(usize, usize)>,
    /// Per instance: whether its body is being evaluated, or is done.
    state: Vec<State>,
    by_instance_key: HashMap<String, InstanceId>,
    /// The key of each record's and variant's shape, and of each record and
    /// variant object (kept, so its address stays its own): see [`Loader::key`].
    shapes: HashMap<String, String>,
    records: HashMap<*const Record, (Arc<Record>, String)>,
    variants: HashMap<*const Variant, (Arc<Variant>, String)>,
    queue: VecDeque<InstanceId>,
    /// Every reference to a named type, to check none names a Stream: (instance, file, offset).
    refs: Vec<(InstanceId, usize, usize)>,
}

impl<'a> Loader<'a> {
    fn new(options: &'a Options<'a>, files: FileCache) -> Loader<'a> {
        Loader {
            options,
            units: vec![],
            by_path: HashMap::new(),
            packages: BTreeMap::new(),
            base: None,
            loading: vec![],
            files,
            copies: HashSet::new(),
            instances: vec![],
            def_of: vec![],
            state: vec![],
            by_instance_key: HashMap::new(),
            shapes: HashMap::new(),
            records: HashMap::new(),
            variants: HashMap::new(),
            queue: VecDeque::new(),
            refs: vec![],
        }
    }

    /// An error in a file, as an error of the root file: errors inside an
    /// imported file are reported at the import, with their place in that file.
    fn lift(&self, mut f: Fail) -> Error {
        loop {
            let unit = &self.units[f.unit];
            let e = syntax::error(&unit.text, f.pos, f.code, f.reason);
            match &unit.origin {
                None => return Error::from(e),
                Some((parent, pos, module)) => {
                    f = Fail {
                        unit: *parent,
                        pos: *pos,
                        code: e.code,
                        reason: format!("{module} ({}:{}): {}", e.line, e.column, e.reason),
                    };
                }
            }
        }
    }

    fn run(mut self, text: &str) -> Result<Schema> {
        let path = self.options.path.map(|p| p.canonicalize().unwrap_or_else(|_| p.to_owned()));
        if let Some(path) = &path {
            self.files.set_root(files::build_root(path, self.options.root)?);
        }
        let package = match &path {
            Some(path) => files::package_of(path, &mut self.files)?,
            None => None,
        };
        let real = |dir: &Path| dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        self.base = match self.options.project {
            Some((name, dir)) => Some((format!("{name}/"), real(dir))),
            None => path.as_deref().and_then(Path::parent).map(|dir| (String::new(), dir.to_owned())),
        };
        let id = match (self.options.id, &package, &path) {
            (Some(id), Some(_), _) => Some(id.to_owned()),
            (Some(id), None, _) => Some(files::file_id(id.to_owned())),
            (None, Some(found), _) => Some(found.manifest.id()),
            (None, None, Some(path)) => Some(self.app_id(path)),
            (None, None, None) => None,
        };
        let name = package.as_ref().map(|found| found.manifest.name.clone());
        if let (Some(found), Some(path)) = (package, &path) {
            let reached = Reached { path: path.clone(), found, text: text.to_owned() };
            self.packages.insert(reached.found.manifest.name.clone(), reached);
        }
        let root = self.load(text.to_owned(), path, name, id, None)?;
        self.evaluate_all().map_err(|f| self.lift(f))?;
        let files: Vec<SchemaFile> = (0..self.units.len()).map(|u| self.file(u)).collect();
        let warnings = files[root].warnings.clone();
        let (definitions, own) = (files[root].definitions.clone(), files[root].own);
        let packages = self
            .packages
            .into_values()
            .map(|r| SchemaPackage { name: r.found.manifest.name, version: r.found.manifest.version, dir: r.found.dir })
            .collect();
        let mut by_name = HashMap::with_capacity(definitions.len());
        for (i, d) in definitions.iter().enumerate() {
            by_name.entry(d.name.clone()).or_insert(i);
        }
        Ok(Schema { instances: self.instances, own, definitions, by_name, warnings, packages, files })
    }

    /// A loaded file: its own definitions in source order, then the imported ones by name.
    fn file(&self, u: usize) -> SchemaFile {
        let unit = &self.units[u];
        let mut own: Vec<(usize, &str)> = unit.own.iter().map(|(n, &d)| (d, n.as_str())).collect();
        own.sort();
        let mut imported: Vec<(&str, (usize, usize))> =
            unit.scope.iter().filter(|(_, (v, _))| *v != u).map(|(n, &at)| (n.as_str(), at)).collect();
        imported.sort();
        let definitions = own
            .iter()
            .map(|&(d, name)| self.definition(name, (u, d)))
            .chain(imported.iter().map(|&(name, at)| self.definition(name, at)))
            .collect();
        let mut warnings: Vec<syntax::Error> =
            unit.file.warnings.iter().cloned().chain(self.no_json_forms(u)).collect();
        warnings.sort_by_key(|w| (w.line, w.column));
        SchemaFile {
            path: unit.path.clone(),
            id: unit.id.clone(),
            package: unit.package.clone(),
            text: unit.text.clone(),
            definitions,
            own: own.len(),
            warnings: warnings.into_iter().map(Error::from).collect(),
        }
    }

    /// The record cases of file `u` with a field named `_tag` or `_args`,
    /// which have no schema-based JSON form (spec §16.3): the schema is
    /// valid, converters fail on values of such a case, and checkers warn
    /// about it, at the case. Spreads in the file copy cases, which are
    /// reported where they are written.
    fn no_json_forms(&self, u: usize) -> Vec<syntax::Error> {
        let unit = &self.units[u];
        let mut found = vec![];
        for (d, def) in unit.file.types.iter().enumerate() {
            let template = &self.instances[self.by_instance_key[&template_key(u, d, &def.params)].0];
            let ty = match &def.ty {
                Ty::Name { name, args, .. } if name == "Stream" && template.stream => &args[0],
                ty => ty,
            };
            self.reserved_cases(ty, &template.body, &mut found);
        }
        found.sort();
        found.dedup();
        found.into_iter().map(|(pos, reason)| syntax::error(&unit.text, pos, Code::NoJsonForm, reason)).collect()
    }

    /// The cases written in `ty` (whose decided type is `t`) that are record
    /// cases with a reserved field: where each is written, and why.
    fn reserved_cases(&self, ty: &Ty, t: &Type, found: &mut Vec<(usize, String)>) {
        match (ty, t) {
            (Ty::Name { args, .. }, Type::Array(x) | Type::Map(x) | Type::Maybe(x) | Type::Secret(x)) => {
                args.iter().for_each(|a| self.reserved_cases(a, x, found))
            }
            // `Result e a`: `closed < Err e | Ok a >`.
            (Ty::Name { name, args, .. }, Type::Variant(v)) if name == "Result" => {
                for (a, tag) in args.iter().zip(["Err", "Ok"]) {
                    if let Some(Case { payload: Payload::Positional(xs), .. }) = v.case(tag) {
                        xs.iter().for_each(|x| self.reserved_cases(a, x, found));
                    }
                }
            }
            (Ty::Record { fields, .. }, Type::Record(r)) => self.reserved_in_fields(fields, r, found),
            (Ty::Variant { cases, .. }, Type::Variant(v)) => {
                for c in cases {
                    let Some(case) = v.case(&c.tag) else { continue };
                    let record = match &case.payload {
                        Payload::Record(r) => Some(r),
                        Payload::Named(x) => match self.resolve(x) {
                            Type::Record(r) => Some(&**r),
                            _ => None,
                        },
                        _ => None,
                    };
                    if let Some(field) =
                        record.and_then(|r| r.fields.iter().find(|f| f.key == "_tag" || f.key == "_args"))
                    {
                        let reason =
                            format!("{} has a field named {}, so it has no schema-based JSON form", c.tag, field.key);
                        found.push((c.pos, reason));
                    }
                    match (&case.payload, c.payload.as_slice()) {
                        (Payload::Record(r), [Ty::Record { fields, .. }]) => self.reserved_in_fields(fields, r, found),
                        (Payload::Named(x), [p]) => self.reserved_cases(p, x, found),
                        (Payload::Positional(xs), ps) => {
                            ps.iter().zip(xs).for_each(|(p, x)| self.reserved_cases(p, x, found))
                        }
                        _ => {}
                    }
                }
            }
            // Named types are checked where they are defined; parameters and scalars have no cases.
            _ => {}
        }
    }

    fn reserved_in_fields(&self, fields: &[syntax::Field], r: &Record, found: &mut Vec<(usize, String)>) {
        for f in fields {
            if let Some(field) = r.field(&f.key) {
                self.reserved_cases(&f.ty, &field.ty, found);
            }
        }
    }

    /// The id of a file outside packages (spec §13.3): different for different files.
    fn app_id(&self, path: &Path) -> String {
        match &self.base {
            Some((prefix, dir)) => files::file_id(format!("{prefix}{}", files::relative_id(dir, path))),
            None => files::file_id(path.display().to_string()),
        }
    }

    fn definition(&self, name: &str, (u, d): (usize, usize)) -> Definition {
        let def = &self.units[u].file.types[d];
        let template = self.by_instance_key[&template_key(u, d, &def.params)];
        Definition {
            name: name.to_owned(),
            id: self.def_id(u, d),
            params: def.params.clone(),
            doc: def.doc.clone(),
            deprecated: deprecated(&def.attrs),
            template,
        }
    }

    fn def_id(&self, u: usize, d: usize) -> String {
        let name = &self.units[u].file.types[d].name;
        match &self.units[u].id {
            Some(id) => format!("{id}#{name}"),
            None => name.clone(),
        }
    }

    /// Parse a file, load its imports and build its scope.
    fn load(
        &mut self,
        text: String,
        path: Option<PathBuf>,
        package: Option<String>,
        id: Option<String>,
        origin: Option<(usize, usize, String)>,
    ) -> Result<usize> {
        let file = match syntax::parse_with_imported_spreads(&text) {
            Ok(file) => file,
            Err(e) => {
                return Err(match origin {
                    None => Error::from(e),
                    Some((parent, pos, module)) => self.lift(Fail {
                        unit: parent,
                        pos,
                        code: e.code,
                        reason: format!("{module} ({}:{}): {}", e.line, e.column, e.reason),
                    }),
                });
            }
        };
        let file = if self.options.without_attributes { syntax::without_attributes(file) } else { file };
        let unit = self.units.len();
        if let Some(path) = &path {
            self.by_path.insert(path.clone(), unit);
        }
        self.units.push(Unit {
            text,
            file,
            path,
            package,
            id,
            origin,
            own: HashMap::new(),
            scope: HashMap::new(),
            std: HashMap::new(),
        });
        self.loading.push(unit);
        let loaded = self.imports(unit);
        self.loading.pop();
        loaded?;
        self.own_types(unit).map_err(|f| self.lift(f))?;
        Ok(unit)
    }

    fn imports(&mut self, unit: usize) -> Result<()> {
        let imports = self.units[unit].file.imports.clone();
        for imp in &imports {
            let at = |code: Code, reason: String| Fail { unit, pos: imp.pos, code, reason };
            if let Some(module) = imp.module.strip_prefix("std/") {
                let names = imp.names.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>().join(", ");
                if module == "money" {
                    let reason = format!(
                        "std/money is no longer a standard module; it is the package @haus-fmt/money: import @haus-fmt/money ({names})"
                    );
                    return Err(self.lift(at(Code::UnknownModule, reason)));
                }
                if module != "time" {
                    let reason = format!("unknown standard module {} (there is std/time)", quote(&imp.module));
                    return Err(self.lift(at(Code::UnknownModule, reason)));
                }
                for (n, pos) in &imp.names {
                    let Some(&t) = STD_TIME.iter().find(|t| *t == n) else {
                        let reason = format!("std/time has no type {n} (it has {})", STD_TIME.join(", "));
                        return Err(self.lift(Fail { unit, pos: *pos, code: Code::UnknownImport, reason }));
                    };
                    self.bring(unit, n, *pos, None, Some(t))?;
                }
                continue;
            }
            let is_module = (imp.module.starts_with('@') && imp.module.contains('/'))
                || imp.module.starts_with("./")
                || imp.module.starts_with("../");
            if !is_module {
                let reason = format!(
                    "unknown module {}: import std/…, a package @org/name or a file ./name",
                    quote(&imp.module)
                );
                return Err(self.lift(at(Code::UnknownModule, reason)));
            }
            let dep = self.import(unit, imp)?;
            for (n, pos) in &imp.names {
                let Some(&d) = self.units[dep].own.get(n) else {
                    let mut has: Vec<&str> = self.units[dep].file.types.iter().map(|t| t.name.as_str()).collect();
                    has.dedup();
                    let list = if has.is_empty() { String::new() } else { format!(" (it has {})", has.join(", ")) };
                    let reason = format!("{} has no type {n}{list}", quote(&imp.module));
                    return Err(self.lift(Fail { unit, pos: *pos, code: Code::UnknownImport, reason }));
                };
                self.bring(unit, n, *pos, Some((dep, d)), None)?;
            }
        }
        Ok(())
    }

    /// Puts an imported name in scope, once.
    fn bring(
        &mut self,
        unit: usize,
        name: &str,
        pos: usize,
        def: Option<(usize, usize)>,
        std: Option<&'static str>,
    ) -> Result<()> {
        if self.units[unit].scope.contains_key(name) || self.units[unit].std.contains_key(name) {
            let reason = format!("{name} is imported twice");
            return Err(self.lift(Fail { unit, pos, code: Code::DuplicateImport, reason }));
        }
        let u = &mut self.units[unit];
        if let Some(def) = def {
            u.scope.insert(name.to_owned(), def);
        }
        if let Some(t) = std {
            u.std.insert(name.to_owned(), t);
        }
        Ok(())
    }

    /// The file an import names, loaded.
    fn import(&mut self, unit: usize, imp: &syntax::Import) -> Result<usize> {
        let from = self.units[unit].path.clone();
        self.import_from(unit, imp.pos, &imp.module, &imp.module, from)
    }

    /// The file `module` names for the file at `from`, loaded; errors are
    /// reported at offset `pos` of `unit`, for the import `label`.
    fn import_from(
        &mut self,
        unit: usize,
        pos: usize,
        module: &str,
        label: &str,
        from: Option<PathBuf>,
    ) -> Result<usize> {
        let at = |code: Code, reason: String| Fail { unit, pos, code, reason };
        // `@org/name@2`: the package, and the major version wanted.
        let (name, wanted) = match module.rsplit_once('@') {
            Some((name, major))
                if module.starts_with('@')
                    && name.len() > 1
                    && !major.is_empty()
                    && major.bytes().all(|b| b.is_ascii_digit()) =>
            {
                (name, Some(major))
            }
            _ => (module, None),
        };
        let found = match name.starts_with('@') {
            true => files::package(self.options.packages, name, from.as_deref(), &mut self.files),
            false => files::file(name, from.as_deref(), self.units[unit].package.as_deref(), &mut self.files),
        };
        let found = found.map_err(|e| self.lift(at(e.code(), format!("can't import {label}: {}", e.reason()))))?;
        if let (Some(wanted), Some(package)) = (wanted, &found.package) {
            let version = quote(&package.manifest.version);
            if package.manifest.major() != wanted {
                let reason = format!("{label} wants major version {wanted}, but version {version} was found");
                return Err(self.lift(at(Code::ImportVersion, reason)));
            }
        }
        // One package per name (spec §13.3): copies with the same files, whose
        // imports reach the same packages, are one.
        let mut copy = None;
        let path = match &found.package {
            Some(new) => match self.packages.get(&new.manifest.name) {
                Some(old) if old.path == found.path => old.path.clone(),
                Some(old) if old.found.manifest_text == new.manifest_text && old.text == found.text => {
                    copy = Some(found.path.clone());
                    old.path.clone()
                }
                Some(Reached { found: old, .. }) => {
                    let (old_dir, new_dir) = (self.files.shown(&old.dir), self.files.shown(&new.dir));
                    let e = duplicate((&old.manifest, &old_dir), (&new.manifest, &new_dir));
                    return Err(self.lift(at(e.code(), format!("can't import {label}: {}", e.reason()))));
                }
                None => found.path.clone(),
            },
            None => found.path.clone(),
        };
        if self.loading.iter().any(|&u| self.units[u].path.as_ref() == Some(&path)) {
            let reason = format!("import cycle: {label} imports this file again");
            return Err(self.lift(at(Code::ImportCycle, reason)));
        }
        if let Some(&cached) = self.by_path.get(&path) {
            if let Some(copy) = copy {
                self.copy_imports(unit, pos, label, cached, copy)?;
            }
            return Ok(cached);
        }
        if self.units.len() + self.copies.len() >= MAX_FILES {
            let reason = format!("more than {MAX_FILES} schema files are imported");
            return Err(self.lift(at(Code::TooManyFiles, reason)));
        }
        let origin = Some((unit, pos, label.to_owned()));
        match found.package {
            Some(package) => {
                let (name, id) = (package.manifest.name.clone(), package.manifest.id());
                let reached = Reached { path: path.clone(), found: package, text: found.text.clone() };
                self.packages.insert(name.clone(), reached);
                self.load(found.text, Some(path), Some(name), Some(id), origin)
            }
            None => {
                let id = self.app_id(&path);
                self.load(found.text, Some(path), None, Some(id), origin)
            }
        }
    }

    /// The imports of a copy of a package (its `schema.haus` at `copy`),
    /// identical to the package loaded as `original`: resolved from the
    /// copy's place, with its own checks, they must reach the same packages
    /// (spec §13.3). Errors are reported at the import `label` of `unit`.
    fn copy_imports(&mut self, unit: usize, pos: usize, label: &str, original: usize, copy: PathBuf) -> Result<()> {
        if !self.copies.insert(copy.clone()) {
            return Ok(());
        }
        if self.units.len() + self.copies.len() > MAX_FILES {
            let reason = format!("more than {MAX_FILES} schema files are imported");
            return Err(self.lift(Fail { unit, pos, code: Code::TooManyFiles, reason }));
        }
        let dir = copy.parent().map(shown).unwrap_or_default();
        let imports: Vec<String> = self.units[original]
            .file
            .imports
            .iter()
            .filter(|imp| imp.module.starts_with('@'))
            .map(|imp| imp.module.clone())
            .collect();
        for module in imports {
            let label = format!("{label} (its copy in {dir} imports {module})");
            self.import_from(unit, pos, &module, &label, Some(copy.clone()))?;
        }
        Ok(())
    }

    /// The file's own definitions: in scope, unless a name is also imported;
    /// generic ones can't grow without bound (§9.10).
    fn own_types(&mut self, unit: usize) -> Result<(), Fail> {
        let defs: Vec<(String, usize)> = self.units[unit].file.types.iter().map(|d| (d.name.clone(), d.pos)).collect();
        for (d, (name, pos)) in defs.iter().enumerate() {
            let u = &mut self.units[unit];
            if u.scope.contains_key(name) || u.std.contains_key(name) {
                return fail(unit, *pos, Code::DuplicateType, format!("type {name} is already imported"));
            }
            u.own.insert(name.clone(), d);
        }
        for (d, (name, _)) in defs.iter().enumerate() {
            self.units[unit].scope.insert(name.clone(), (unit, d));
        }
        self.growth(unit)
    }

    /// §9.10, the expansive-cycle rule: no type parameter passes, inside a
    /// bigger type, along a cycle of references back to itself (see
    /// [`Growth`]). The first expanding edge on a cycle is reported, at its
    /// reference: definitions in order, references in body order (outermost
    /// first), then by argument. Checked on the definitions as written, before
    /// anything is instantiated. Cycles are within one file: imports have no
    /// cycles.
    fn growth(&self, unit: usize) -> Result<(), Fail> {
        let u = &self.units[unit];
        let graph = Growth::new(&u.file.types, &u.own);
        let component = components(&graph.edges);
        for pass in &graph.passes {
            let to = graph.first[pass.to] + pass.index;
            if pass.from.is_none_or(|from| component[from] != component[to]) {
                continue;
            }
            // The first parameter in the argument that the cycle comes back to.
            let mut back = None;
            walk(pass.arg, &mut |t| {
                if let Ty::Param { name, .. } = t
                    && back.is_none()
                {
                    back = graph.param(pass.def, name).filter(|&a| component[a] == component[to]);
                }
            });
            if let Some(a) = back {
                return fail(unit, pass.pos, Code::GrowingRecursion, graph.growing(a, to, &component));
            }
        }
        Ok(())
    }

    // ── evaluation ───────────────────────────────────────────

    /// Every definition of every file (templates for generic ones), so all errors surface.
    fn evaluate_all(&mut self) -> Result<(), Fail> {
        for u in 0..self.units.len() {
            for d in 0..self.units[u].file.types.len() {
                let params = self.units[u].file.types[d].params.clone();
                let pos = self.units[u].file.types[d].pos;
                let args = params.into_iter().map(Type::Param).collect();
                self.instance(u, d, args, u, pos)?;
                while let Some(id) = self.queue.pop_front() {
                    self.evaluate_instance(id)?;
                }
            }
        }
        for &(inst, unit, pos) in &self.refs {
            let i = &self.instances[inst.0];
            if i.stream {
                return fail(
                    unit,
                    pos,
                    Code::MisplacedStream,
                    format!("{} is a Stream; a stream can only be the whole file, not part of a type", i.name),
                );
            }
        }
        // §9.9: every cycle passes through a record, array or variant (`Secret` is no step).
        for start in 0..self.instances.len() {
            let mut seen = HashSet::new();
            let mut t = &self.instances[start].body;
            loop {
                match t {
                    Type::Ref(id) => {
                        if !seen.insert(*id) {
                            let (u, d) = self.def_of[start];
                            let name = &self.instances[start].name;
                            return fail(
                                u,
                                self.units[u].file.types[d].pos,
                                Code::UnguardedRecursion,
                                format!("type {name} refers to itself without a record, array or variant in between"),
                            );
                        }
                        t = &self.instances[id.0].body;
                    }
                    Type::Secret(inner) => t = inner,
                    _ => break,
                }
            }
        }
        Ok(())
    }

    /// Whether `ty`, written in file `u`, is a record (spec §15), decided
    /// where it is written: names are followed through their definitions,
    /// with their arguments as written, and a type parameter of the
    /// definition it is written in is not a record, whatever its argument
    /// is. So `X (Id a)` in `type T a = Holder (< X (Id a) >)` is never a
    /// record case, and `X (Id R)` always is.
    fn is_record(&self, u: usize, ty: &Ty) -> bool {
        /// The arguments of the definitions followed: each with the file and
        /// the arguments it is written with.
        #[derive(Clone, Default)]
        struct Env<'s>(Rc<Vec<(&'s str, usize, &'s Ty, Env<'s>)>>);
        let (mut u, mut ty, mut env) = (u, ty, Env::default());
        // Checked: every chain of names ends (§9.9); the bound is for safety.
        for _ in 0..MAX_INSTANCES {
            match ty {
                Ty::Record { .. } => return true,
                Ty::Variant { .. } => return false,
                Ty::Param { name, .. } => match env.0.iter().find(|(p, ..)| p == name) {
                    Some((_, au, aty, aenv)) => (u, ty, env) = (*au, *aty, aenv.clone()),
                    None => return false,
                },
                // The prelude's types and std/time's are not records.
                Ty::Name { name, .. } if GENERIC.iter().any(|(g, _)| g == name) => return false,
                Ty::Name { name, args, .. } => match self.units[u].scope.get(name) {
                    Some(&(du, dd)) => {
                        let def = &self.units[du].file.types[dd];
                        let bound = def.params.iter().zip(args).map(|(p, a)| (p.as_str(), u, a, env.clone()));
                        (u, ty, env) = (du, &def.ty, Env(Rc::new(bound.collect())));
                    }
                    None => return false,
                },
            }
        }
        false
    }

    /// The type a reference stands for, following named types (as [`Schema::resolve`]).
    fn resolve<'t>(&'t self, mut ty: &'t Type) -> &'t Type {
        // Checked: every chain of names ends (§9.9).
        while let Type::Ref(id) = ty {
            ty = &self.instances[id.0].body;
        }
        ty
    }

    /// The instance of definition `d` of file `u` with `args`, created if new.
    /// `at` and `pos`: where it is used, for errors.
    fn instance(&mut self, u: usize, d: usize, args: Vec<Type>, at: usize, pos: usize) -> Result<InstanceId, Fail> {
        let key = match args.is_empty() {
            true => format!("{u}:{d}"),
            false => {
                let keys: Vec<String> = args.iter().map(|a| self.key(a)).collect();
                format!("{u}:{d}({})", keys.join(","))
            }
        };
        if let Some(&id) = self.by_instance_key.get(&key) {
            return Ok(id);
        }
        if self.instances.len() >= MAX_INSTANCES {
            return fail(
                at,
                pos,
                Code::GrowingRecursion,
                format!("more than {MAX_INSTANCES} type instances: a generic type grows without bound"),
            );
        }
        let id = InstanceId(self.instances.len());
        let name = self.units[u].file.types[d].name.clone();
        self.instances.push(Instance {
            name,
            id: self.def_id(u, d),
            args,
            body: Type::Builtin(Builtin::Any),
            stream: false,
        });
        self.def_of.push((u, d));
        self.state.push(State::New);
        self.by_instance_key.insert(key, id);
        self.queue.push_back(id);
        Ok(id)
    }

    /// A key that tells types apart, for instances. It never holds the whole
    /// of an argument, which can grow exponentially with legitimate nesting
    /// (`P a a` inside `P a a` …): an instance is keyed by its number, a
    /// record or variant by the number of its shape, so a key is as long as
    /// one type expression. Each record and variant object is keyed once.
    fn key(&mut self, t: &Type) -> String {
        match t {
            Type::Builtin(b) => b.name().into(),
            Type::Time(name) => (*name).into(),
            Type::Param(name) => format!("'{name}"),
            Type::Array(item) => format!("Array({})", self.key(item)),
            Type::Map(value) => format!("Map({})", self.key(value)),
            Type::Maybe(item) => format!("Maybe({})", self.key(item)),
            Type::Secret(item) => format!("Secret({})", self.key(item)),
            Type::Ref(id) => format!("#{}", id.0),
            Type::Record(r) => {
                if let Some((_, key)) = self.records.get(&Arc::as_ptr(r)) {
                    return key.clone();
                }
                let shape = self.record_shape(r);
                let key = self.shape_key(shape);
                self.records.insert(Arc::as_ptr(r), (r.clone(), key.clone()));
                key
            }
            Type::Variant(v) => {
                if let Some((_, key)) = self.variants.get(&Arc::as_ptr(v)) {
                    return key.clone();
                }
                let cases: Vec<String> = v
                    .cases
                    .iter()
                    .map(|c| match &c.payload {
                        Payload::None => c.tag.clone(),
                        Payload::Record(r) => format!("{}{}", c.tag, self.record_shape(r)),
                        // Not the key of one positional argument: `X R` and `X a` with R for a differ.
                        Payload::Named(t) => format!("{}{{{}}}", c.tag, self.key(t)),
                        Payload::Positional(items) => {
                            format!("{}({})", c.tag, items.iter().map(|t| self.key(t)).collect::<Vec<_>>().join(","))
                        }
                    })
                    .collect();
                let key = self.shape_key(format!("<{}{}>", cases.join("|"), if v.open { "|_" } else { "" }));
                self.variants.insert(Arc::as_ptr(v), (v.clone(), key.clone()));
                key
            }
        }
    }

    /// The number of a shape, as a key.
    fn shape_key(&mut self, shape: String) -> String {
        let next = format!("~{}", self.shapes.len());
        self.shapes.entry(shape).or_insert(next).clone()
    }

    fn record_shape(&mut self, r: &Record) -> String {
        let fields: Vec<String> = r
            .fields
            .iter()
            .map(|f| format!("{:?}{}:{}", f.key, if f.optional { "?" } else { "" }, self.key(&f.ty)))
            .collect();
        format!("{{{}{}}}", if r.closed { "|" } else { "" }, fields.join(","))
    }

    /// The body of an instance, evaluated now if it isn't yet (a spread needs it).
    fn evaluate_instance(&mut self, id: InstanceId) -> Result<(), Fail> {
        let (u, d) = self.def_of[id.0];
        match self.state[id.0] {
            State::Done => return Ok(()),
            State::Busy => {
                let def = &self.units[u].file.types[d];
                return fail(
                    u,
                    def.pos,
                    Code::SpreadCycle,
                    format!("type {} spreads itself (directly or through another type)", def.name),
                );
            }
            State::New => self.state[id.0] = State::Busy,
        }
        let def = &self.units[u].file.types[d];
        let ty = def.ty.clone();
        let env: Vec<(String, Type)> = def.params.iter().cloned().zip(self.instances[id.0].args.clone()).collect();
        let (body, stream) = match &ty {
            Ty::Name { name, args, pos } if name == "Stream" => match args.as_slice() {
                [item] => (self.eval(u, item, &env)?, true),
                _ => {
                    return fail(
                        u,
                        *pos,
                        Code::WrongArity,
                        format!("Stream takes 1 argument(s), found {}", args.len()),
                    );
                }
            },
            ty => (self.eval(u, ty, &env)?, false),
        };
        let inst = &mut self.instances[id.0];
        inst.body = body;
        inst.stream = stream;
        self.state[id.0] = State::Done;
        Ok(())
    }

    /// The record or variant `...Name` copies (`want`: "record" or "variant"),
    /// for a spread of an imported type, which the syntax tree leaves in place.
    fn spread(&mut self, u: usize, s: &syntax::Spread, want: &str) -> Result<Type, Fail> {
        let Some(&(du, dd)) = self.units[u].scope.get(&s.name) else {
            // A standard or built-in type is known, just not a record or variant.
            let known = self.units[u].std.contains_key(&s.name) || syntax::PRELUDE.iter().any(|(n, _)| *n == s.name);
            return match known {
                true => fail(
                    u,
                    s.pos,
                    Code::InvalidSpread,
                    format!("{} is not a {want}, so it can't be spread here", s.name),
                ),
                false => fail(u, s.pos, Code::UnknownType, unknown_type(&s.name)),
            };
        };
        let params = &self.units[du].file.types[dd].params;
        if !params.is_empty() {
            let name = &s.name;
            return fail(
                u,
                s.pos,
                Code::InvalidSpread,
                format!(
                    "{name} has parameters ({name} {}); only a type without parameters can be spread",
                    params.join(" ")
                ),
            );
        }
        let mut id = self.instance(du, dd, vec![], u, s.pos)?;
        let mut seen = HashSet::new();
        loop {
            self.evaluate_instance(id)?;
            if self.instances[id.0].stream {
                return fail(u, s.pos, Code::InvalidSpread, format!("{} is a Stream and can't be spread", s.name));
            }
            match &self.instances[id.0].body {
                Type::Ref(next) if seen.insert(*next) => id = *next,
                Type::Record(_) if want == "record" => return Ok(self.instances[id.0].body.clone()),
                Type::Variant(_) if want == "variant" => return Ok(self.instances[id.0].body.clone()),
                _ => {
                    let reason = format!("{} is not a {want}, so it can't be spread here", s.name);
                    return fail(u, s.pos, Code::InvalidSpread, reason);
                }
            }
        }
    }

    /// A type expression of file `u`, with the parameters in `env`.
    fn eval(&mut self, u: usize, ty: &Ty, env: &[(String, Type)]) -> Result<Type, Fail> {
        match ty {
            Ty::Param { name, pos } => match env.iter().find(|(p, _)| p == name) {
                Some((_, t)) => Ok(t.clone()),
                None => fail(u, *pos, Code::UnknownParameter, format!("unknown type parameter {name}")),
            },
            Ty::Record { closed, fields, spreads, .. } => {
                Ok(Type::Record(Arc::new(self.record(u, *closed, fields, spreads, env)?)))
            }
            Ty::Variant { closed, cases, spreads, .. } => {
                let cases = cases
                    .iter()
                    .map(|c| {
                        let payload = match c.payload.as_slice() {
                            [] => Payload::None,
                            [Ty::Record { closed, fields, spreads, .. }] => {
                                Payload::Record(self.record(u, *closed, fields, spreads, env)?)
                            }
                            // A record case by name, if it is a record where it is written.
                            [one @ Ty::Name { .. }] => match self.is_record(u, one) {
                                true => Payload::Named(self.eval(u, one, env)?),
                                false => Payload::Positional(vec![self.eval(u, one, env)?]),
                            },
                            items => Payload::Positional(
                                items.iter().map(|t| self.eval(u, t, env)).collect::<Result<_, _>>()?,
                            ),
                        };
                        Ok((Case { tag: c.tag.clone(), payload, deprecated: deprecated(&c.attrs) }, c.pos))
                    })
                    .collect::<Result<Vec<_>, Fail>>()?;
                let mut copied = vec![];
                for sp in spreads {
                    if let Type::Variant(v) = self.spread(u, sp, "variant")? {
                        copied.push((sp, v.cases.clone()));
                    }
                }
                let cases = insert(cases, copied);
                let mut tags = HashSet::new();
                if let Some((c, pos)) = cases.iter().find(|(c, _)| !tags.insert(c.tag.as_str())) {
                    return fail(u, *pos, Code::DuplicateTag, format!("duplicate tag {}", c.tag));
                }
                Ok(Type::Variant(Arc::new(Variant::new(!closed, cases.into_iter().map(|(c, _)| c).collect()))))
            }
            Ty::Name { name, args, pos } => self.named(u, name, args, *pos, env),
        }
    }

    fn record(
        &mut self,
        u: usize,
        closed: bool,
        fields: &[syntax::Field],
        spreads: &[syntax::Spread],
        env: &[(String, Type)],
    ) -> Result<Record, Fail> {
        let fields: Vec<(Field, usize)> = fields
            .iter()
            .map(|f| {
                let ty = self.eval(u, &f.ty, env)?;
                let field = Field { key: f.key.clone(), optional: f.optional, ty, deprecated: deprecated(&f.attrs) };
                Ok((field, f.pos))
            })
            .collect::<Result<_, Fail>>()?;
        let mut copied = vec![];
        for sp in spreads {
            if let Type::Record(r) = self.spread(u, sp, "record")? {
                copied.push((sp, r.fields.clone()));
            }
        }
        let fields = insert(fields, copied);
        let mut keys = HashSet::new();
        if let Some((f, pos)) = fields.iter().find(|(f, _)| !keys.insert(f.key.as_str())) {
            return fail(u, *pos, Code::DuplicateField, format!("duplicate field {}", f.key));
        }
        Ok(Record::new(closed, fields.into_iter().map(|(f, _)| f).collect()))
    }

    fn named(&mut self, u: usize, name: &str, args: &[Ty], pos: usize, env: &[(String, Type)]) -> Result<Type, Fail> {
        let arity = |n: usize| -> Result<(), Fail> {
            match args.len() == n {
                true => Ok(()),
                false => fail(u, pos, Code::WrongArity, format!("{name} takes {n} argument(s), found {}", args.len())),
            }
        };
        if let Some(&(_, n)) = GENERIC.iter().find(|(g, _)| *g == name) {
            // Arity first, then where it is: `{ e: Stream }` is wrong-arity.
            arity(n)?;
            if name == "Stream" {
                return fail(u, pos, Code::MisplacedStream, "Stream is only allowed as the whole type of a definition");
            }
            let mut evaluated = args.iter().map(|a| self.eval(u, a, env)).collect::<Result<Vec<_>, _>>()?.into_iter();
            let mut next = || Box::new(evaluated.next().unwrap_or(Type::Builtin(Builtin::Any)));
            return Ok(match name {
                "Array" => Type::Array(next()),
                "Map" => Type::Map(next()),
                "Maybe" => Type::Maybe(next()),
                "Secret" => Type::Secret(next()),
                _ => {
                    let (err, ok) = (next(), next());
                    let case = |tag: &str, t: Box<Type>| Case {
                        tag: tag.into(),
                        payload: Payload::Positional(vec![*t]),
                        deprecated: None,
                    };
                    Type::Variant(Arc::new(Variant::new(false, vec![case("Err", err), case("Ok", ok)])))
                }
            });
        }
        if let Some(&(du, dd)) = self.units[u].scope.get(name) {
            arity(self.units[du].file.types[dd].params.len())?;
            let args = args.iter().map(|a| self.eval(u, a, env)).collect::<Result<Vec<_>, _>>()?;
            let id = self.instance(du, dd, args, u, pos)?;
            self.refs.push((id, u, pos));
            return Ok(Type::Ref(id));
        }
        if let Some(&t) = self.units[u].std.get(name) {
            arity(0)?;
            return Ok(Type::Time(t));
        }
        if let Some(b) = Builtin::from_name(name) {
            arity(0)?;
            return Ok(Type::Builtin(b));
        }
        fail(u, pos, Code::UnknownType, unknown_type(name))
    }
}

/// Own entries (with their offsets) and the entries of spreads of imported
/// types, each where its spread is written (with the spread's offset).
fn insert<T>(own: Vec<(T, usize)>, copied: Vec<(&syntax::Spread, Vec<T>)>) -> Vec<(T, usize)> {
    let mut out = vec![];
    let mut copied = copied.into_iter().peekable();
    let n = own.len();
    for (i, entry) in own.into_iter().map(Some).chain([None]).enumerate() {
        while let Some((sp, xs)) = copied.next_if(|(sp, _)| sp.at == i || i == n) {
            out.extend(xs.into_iter().map(|x| (x, sp.pos)));
        }
        out.extend(entry);
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    New,
    Busy,
    Done,
}

fn template_key(u: usize, d: usize, params: &[String]) -> String {
    match params.is_empty() {
        true => format!("{u}:{d}"),
        false => format!("{u}:{d}({})", params.iter().map(|p| format!("'{p}")).collect::<Vec<_>>().join(",")),
    }
}

fn deprecated(attrs: &[Attribute]) -> Option<Deprecation> {
    deprecation(attrs).map(|why| Deprecation { message: why.map(str::to_owned) })
}

/// Every type expression in `t`, outermost first.
fn walk(t: &Ty, f: &mut impl FnMut(&Ty)) {
    f(t);
    match t {
        Ty::Name { args, .. } => args.iter().for_each(|a| walk(a, f)),
        Ty::Param { .. } => {}
        Ty::Record { fields, .. } => fields.iter().for_each(|x| walk(&x.ty, f)),
        Ty::Variant { cases, .. } => cases.iter().flat_map(|c| &c.payload).for_each(|p| walk(p, f)),
    }
}

/// The parameter graph of §9.10 for one file. It has a node per type
/// parameter of every definition, and for each reference `B t₁ … tₙ` in the
/// body of a definition `A` to a definition `B` of the file (not one of the
/// prelude's), an edge from each parameter `a` of `A` occurring in `tᵢ` to the
/// i-th parameter of `B`: *expanding* unless `tᵢ` is `a` itself. A schema in
/// which an expanding edge lies on a cycle could have instances that grow
/// without bound (`type T a = < X (T (Pair a a)) >`).
///
/// Built in linear time: rather than an edge per occurrence of a parameter
/// (`a` nested in n references would count n times), an argument with
/// several parameters gets a node of its own that they flow into, so that
/// the node of `tᵢ` reaches exactly the parameters occurring in it, and the
/// edge from it stands for the edges of all of them. Paths between
/// parameters, and so cycles, are those of the parameter graph.
struct Growth<'a> {
    types: &'a [syntax::TypeDef],
    own: &'a HashMap<String, usize>,
    /// Node `first[d] + p` is parameter `p` of definition `d`.
    first: Vec<usize>,
    /// Per parameter node: its definition.
    owner: Vec<usize>,
    /// The parameter nodes, then the nodes of arguments with several parameters.
    edges: Vec<Vec<usize>>,
    /// The arguments other than a bare parameter, each passed to a
    /// definition of the file, in the order they are checked.
    passes: Vec<Pass<'a>>,
}

/// An argument other than a bare parameter passed to a definition of the
/// file: the `P a a` of `B (P a a)`.
struct Pass<'a> {
    /// The definition the reference is in, and where.
    def: usize,
    pos: usize,
    /// The definition referred to, and which of its parameters the argument is for.
    to: usize,
    index: usize,
    arg: &'a Ty,
    /// The node of the argument's parameters, if it has any.
    from: Option<usize>,
}

impl<'a> Growth<'a> {
    fn new(types: &'a [syntax::TypeDef], own: &'a HashMap<String, usize>) -> Growth<'a> {
        let first: Vec<usize> = types
            .iter()
            .scan(0, |next, def| {
                let at = *next;
                *next += def.params.len();
                Some(at)
            })
            .collect();
        let owner: Vec<usize> =
            types.iter().enumerate().flat_map(|(d, def)| std::iter::repeat_n(d, def.params.len())).collect();
        let edges = vec![vec![]; owner.len()];
        let mut graph = Growth { types, own, first, owner, edges, passes: vec![] };
        for (d, def) in types.iter().enumerate() {
            graph.flow(d, &def.ty);
        }
        graph
    }

    /// The definition of the file `name` refers to, if it is one (the
    /// prelude's generic types come first).
    fn callee(&self, name: &str) -> Option<usize> {
        match GENERIC.iter().any(|(g, _)| *g == name) {
            true => None,
            false => self.own.get(name).copied(),
        }
    }

    /// The node of parameter `name` of definition `d`, if it has one.
    fn param(&self, d: usize, name: &str) -> Option<usize> {
        self.types[d].params.iter().position(|p| p == name).map(|p| self.first[d] + p)
    }

    /// Adds the edges of the references in `t`, in definition `d`; the node
    /// that the parameters occurring in `t` flow into, if any do.
    fn flow(&mut self, d: usize, t: &'a Ty) -> Option<usize> {
        match t {
            Ty::Param { name, .. } => self.param(d, name),
            Ty::Name { name, args, pos } => {
                let callee = self.callee(name).map(|b| (b, args.len().min(self.types[b].params.len())));
                let nested: Vec<usize> =
                    callee.map_or(vec![], |(_, n)| (0..n).filter(|&i| !matches!(args[i], Ty::Param { .. })).collect());
                // This reference's arguments are checked before those of the references inside them.
                let start = self.passes.len();
                if let Some((to, _)) = callee {
                    self.passes.extend(nested.iter().map(|&index| Pass {
                        def: d,
                        pos: *pos,
                        to,
                        index,
                        arg: &args[index],
                        from: None,
                    }));
                }
                let nodes: Vec<Option<usize>> = args.iter().map(|a| self.flow(d, a)).collect();
                if let Some((to, n)) = callee {
                    for (i, node) in nodes.iter().enumerate().take(n) {
                        if let Some(node) = *node {
                            self.edges[node].push(self.first[to] + i);
                        }
                    }
                    for (k, &i) in nested.iter().enumerate() {
                        self.passes[start + k].from = nodes[i];
                    }
                }
                self.join(nodes.into_iter().flatten().collect())
            }
            Ty::Record { fields, .. } => {
                let nodes: Vec<Option<usize>> = fields.iter().map(|f| self.flow(d, &f.ty)).collect();
                self.join(nodes.into_iter().flatten().collect())
            }
            Ty::Variant { cases, .. } => {
                let nodes: Vec<Option<usize>> =
                    cases.iter().flat_map(|c| &c.payload).map(|p| self.flow(d, p)).collect();
                self.join(nodes.into_iter().flatten().collect())
            }
        }
    }

    /// One node for `nodes`: none for none, the node for one (or the same one
    /// again), otherwise a new node they all flow into.
    fn join(&mut self, nodes: Vec<usize>) -> Option<usize> {
        let &one = nodes.first()?;
        if nodes.iter().all(|&n| n == one) {
            return Some(one);
        }
        let joined = self.edges.len();
        self.edges.push(vec![]);
        for n in nodes {
            self.edges[n].push(joined);
        }
        Some(joined)
    }

    /// The message for parameter node `a` passed, inside a bigger type, to
    /// parameter node `to`, from where it comes back to `a`.
    fn growing(&self, a: usize, to: usize, component: &[usize]) -> String {
        let (def, b) = (self.owner[a], self.owner[to]);
        let (name, param) = (&self.types[def].name, &self.types[def].params[a - self.first[def]]);
        if a == to {
            return format!(
                "{name} passes its parameter {param} to itself inside a bigger type: instances could grow without bound"
            );
        }
        let target = match b == def {
            true => "itself",
            false => self.types[b].name.as_str(),
        };
        let names = [def, b]
            .into_iter()
            .chain(self.way(to, a, component).into_iter().map(|n| self.owner[n]))
            .map(|d| self.types[d].name.as_str())
            .collect::<Vec<_>>()
            .join(" → ");
        format!(
            "{name} passes its parameter {param} to {target} inside a bigger type, and it comes back ({names}): instances could grow without bound"
        )
    }

    /// A shortest way along the parameter graph's edges from parameter node
    /// `from` to `to` in the same component: the nodes after `from` (a
    /// breadth-first search, each node's edges in the order of its references).
    /// Only for a message, so it builds the edges between parameters itself.
    fn way(&self, from: usize, to: usize, component: &[usize]) -> Vec<usize> {
        let mut edges = vec![vec![]; self.owner.len()];
        for (d, def) in self.types.iter().enumerate() {
            walk(&def.ty, &mut |t| {
                let Ty::Name { name, args, .. } = t else { return };
                let Some(b) = self.callee(name) else { return };
                for (i, arg) in args.iter().take(self.types[b].params.len()).enumerate() {
                    walk(arg, &mut |x| {
                        if let Ty::Param { name, .. } = x
                            && let Some(p) = self.param(d, name)
                        {
                            edges[p].push(self.first[b] + i);
                        }
                    });
                }
            });
        }
        let mut before = vec![None; edges.len()];
        let mut queue = VecDeque::from([from]);
        while let Some(n) = queue.pop_front() {
            if n == to {
                break;
            }
            for &m in &edges[n] {
                if m != from && before[m].is_none() && component[m] == component[from] {
                    before[m] = Some(n);
                    queue.push_back(m);
                }
            }
        }
        let mut way = vec![];
        let mut n = to;
        while let Some(prev) = before[n] {
            way.push(n);
            n = prev;
        }
        way.reverse();
        way
    }
}

/// The strongly connected components of a graph, the edges of node `n` in
/// `edges[n]`: each node's component (Tarjan's algorithm, with a stack of its
/// own rather than recursion).
fn components(edges: &[Vec<usize>]) -> Vec<usize> {
    const NONE: usize = usize::MAX;
    let n = edges.len();
    let (mut index, mut low, mut component) = (vec![NONE; n], vec![0; n], vec![NONE; n]);
    let (mut stack, mut work, mut next, mut count) = (vec![], vec![], 0, 0);
    for start in 0..n {
        if index[start] != NONE {
            continue;
        }
        index[start] = next;
        low[start] = next;
        next += 1;
        stack.push(start);
        work.push((start, 0));
        while let Some(&mut (v, ref mut i)) = work.last_mut() {
            if let Some(&w) = edges[v].get(*i) {
                *i += 1;
                if index[w] == NONE {
                    index[w] = next;
                    low[w] = next;
                    next += 1;
                    stack.push(w);
                    work.push((w, 0));
                } else if component[w] == NONE {
                    low[v] = low[v].min(index[w]);
                }
                continue;
            }
            work.pop();
            if let Some(&(parent, _)) = work.last() {
                low[parent] = low[parent].min(low[v]);
            }
            if low[v] == index[v] {
                while let Some(w) = stack.pop() {
                    component[w] = count;
                    if w == v {
                        break;
                    }
                }
                count += 1;
            }
        }
    }
    component
}
