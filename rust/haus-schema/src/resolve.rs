//! A schema file with its imports: names looked up, generic types applied,
//! and every rule of spec §14 checked. A port of the TypeScript reference
//! (typescript/packages/haus/src/schema-file.ts), on the syntax trees of
//! [`syntax`](crate::syntax).
//!
//! Generic types are applied by instantiating them (`List Int` is a type of
//! its own), which terminates because a generic type may refer to itself only
//! with its own parameters (§9.10); a limit on the number of instances is a
//! second guard.

use crate::files::{NoImports, Resolver, identify};
use crate::syntax::{self, Attribute, STD_TIME, Ty, deprecation, unknown_type};
use crate::types::{Builtin, Case, Deprecation, Field, Instance, InstanceId, Payload, Record, Type, Variant};
use crate::{Error, Result, Warning, read};
use haus::ErrorCode as Code;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;

const MAX_INSTANCES: usize = 10_000;
const MAX_FILES: usize = 256;

/// The prelude's types with parameters, and how many.
const GENERIC: [(&str, usize); 6] =
    [("Array", 1), ("Map", 1), ("Maybe", 1), ("Result", 2), ("Secret", 1), ("Stream", 1)];

/// How to load a schema.
#[derive(Clone, Copy)]
pub struct Options<'a> {
    /// Finds imported packages and files. [`NoImports`] (the default) allows std modules only.
    pub resolver: &'a dyn Resolver,
    /// The root file's key for the resolver (its path), so its relative imports resolve from it.
    pub key: Option<&'a str>,
    /// The root file's identity, for the ids of its types (see [`Module::id`](crate::Module::id)).
    pub id: Option<&'a str>,
    /// Leave the attributes of every file out, as if they weren't written:
    /// decoding is the same (spec §15). For tests of that.
    pub without_attributes: bool,
}

impl Default for Options<'_> {
    fn default() -> Self {
        Options { resolver: &NoImports, key: None, id: None, without_attributes: false }
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

/// A schema file, its imports resolved and every rule of spec §14 checked.
#[derive(Debug, Clone)]
pub struct Schema {
    instances: Vec<Instance>,
    /// The file's own definitions in source order, then the imported ones.
    definitions: Vec<Definition>,
    own: usize,
    warnings: Vec<Warning>,
}

impl Schema {
    /// A schema whose imports are std modules only.
    pub fn parse(text: &str) -> Result<Schema> {
        Schema::parse_with(text, &Options::default())
    }

    /// A schema, with imports found by `options.resolver`.
    pub fn parse_with(text: &str, options: &Options) -> Result<Schema> {
        Loader::new(options).run(text)
    }

    /// The schema file at `path`, its relative imports next to it.
    pub fn load(path: impl AsRef<Path>, resolver: &dyn Resolver) -> Result<Schema> {
        Schema::load_with(path, &Options { resolver, ..Options::default() })
    }

    /// [`Schema::load`] with options; `options.key` and `options.id` are the file's own.
    pub fn load_with(path: impl AsRef<Path>, options: &Options) -> Result<Schema> {
        let path = path.as_ref();
        let text = read(path)?;
        let full = path.canonicalize().map_err(|e| Error::at(path, Code::ImportNotFound, e))?;
        let key = full.display().to_string();
        let (id, _) = identify(&full);
        Schema::parse_with(&text, &Options { key: Some(&key), id: Some(&id), ..*options }).map_err(|e| e.in_file(path))
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
        self.definitions.iter().find(|d| d.name == name)
    }

    pub fn instance(&self, id: InstanceId) -> &Instance {
        &self.instances[id.0]
    }

    /// What to point out in the file (not in the files it imports), in source
    /// order: attributes this version doesn't define, uses of deprecated types.
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
    /// `Maybe Int`, `one of A, B` (for messages).
    pub fn describe(&self, ty: &Type) -> String {
        match ty {
            Type::Builtin(b) => b.name().into(),
            Type::Time(name) => (*name).into(),
            Type::Array(item) => format!("Array {}", self.atom(item)),
            Type::Map(value) => format!("Map {}", self.atom(value)),
            Type::Maybe(item) => format!("Maybe {}", self.atom(item)),
            Type::Secret(item) => format!("Secret {}", self.atom(item)),
            Type::Record(_) => "a record".into(),
            Type::Variant(v) => tags(v),
            Type::Ref(id) => {
                let inst = self.instance(*id);
                match inst.args.is_empty() {
                    true => inst.name.clone(),
                    false => {
                        let args: Vec<String> = inst.args.iter().map(|a| self.atom(a)).collect();
                        format!("{} {}", inst.name, args.join(" "))
                    }
                }
            }
            Type::Param(name) => name.clone(),
        }
    }

    fn atom(&self, ty: &Type) -> String {
        let d = self.describe(ty);
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

struct Loader<'a> {
    options: &'a Options<'a>,
    units: Vec<Unit>,
    /// Files by key, loaded once each.
    by_key: HashMap<String, usize>,
    /// The key of the file with each id: two files with one id would give their types the same ids.
    ids: HashMap<String, Option<String>>,
    /// Keys of the files being loaded, for import cycles.
    loading: Vec<String>,
    instances: Vec<Instance>,
    /// Per instance: its key, and the definition it applies.
    keys: Vec<String>,
    def_of: Vec<(usize, usize)>,
    /// Per instance: whether its body is being evaluated, or is done.
    state: Vec<State>,
    by_instance_key: HashMap<String, InstanceId>,
    queue: VecDeque<InstanceId>,
    /// Every reference to a named type, to check none names a Stream: (instance, file, offset).
    refs: Vec<(InstanceId, usize, usize)>,
}

impl<'a> Loader<'a> {
    fn new(options: &'a Options<'a>) -> Loader<'a> {
        Loader {
            options,
            units: vec![],
            by_key: HashMap::new(),
            ids: HashMap::new(),
            loading: vec![],
            instances: vec![],
            keys: vec![],
            def_of: vec![],
            state: vec![],
            by_instance_key: HashMap::new(),
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
        let (key, id) = (self.options.key.map(str::to_owned), self.options.id.map(str::to_owned));
        let root = self.load(text.to_owned(), key, id, None)?;
        self.evaluate_all().map_err(|f| self.lift(f))?;
        let warnings = self.units[root].file.warnings.iter().cloned().map(Error::from).collect();
        let unit = &self.units[root];
        let mut own: Vec<(usize, &str)> = unit.own.iter().map(|(n, &d)| (d, n.as_str())).collect();
        own.sort();
        let mut imported: Vec<(&str, (usize, usize))> =
            unit.scope.iter().filter(|(_, (u, _))| *u != root).map(|(n, &at)| (n.as_str(), at)).collect();
        imported.sort();
        let definitions: Vec<Definition> = own
            .iter()
            .map(|&(d, name)| self.definition(name, (root, d)))
            .chain(imported.iter().map(|&(name, at)| self.definition(name, at)))
            .collect();
        Ok(Schema { instances: self.instances, own: own.len(), definitions, warnings })
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
        key: Option<String>,
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
        self.units.push(Unit {
            text,
            file,
            id: id.clone(),
            origin,
            own: HashMap::new(),
            scope: HashMap::new(),
            std: HashMap::new(),
        });
        if let Some(key) = &key {
            self.by_key.insert(key.clone(), unit);
        }
        if let Some(id) = id {
            self.ids.insert(id, key.clone());
        }
        self.loading.push(key.unwrap_or_default());
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
                    let reason = format!("unknown standard module {} (there is std/time)", imp.module);
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
                let reason =
                    format!("unknown module {}: import std/…, a package @org/name or a file ./name", imp.module);
                return Err(self.lift(at(Code::UnknownModule, reason)));
            }
            let dep = self.import(unit, imp)?;
            for (n, pos) in &imp.names {
                let Some(&d) = self.units[dep].own.get(n) else {
                    let mut has: Vec<&str> = self.units[dep].file.types.iter().map(|t| t.name.as_str()).collect();
                    has.dedup();
                    let list = if has.is_empty() { String::new() } else { format!(" (it has {})", has.join(", ")) };
                    let reason = format!("{} has no type {n}{list}", imp.module);
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
        let at = |code: Code, reason: String| Fail { unit, pos: imp.pos, code, reason };
        // `@org/name@2`: the package, and the major version wanted.
        let (module, wanted) = match imp.module.rsplit_once('@') {
            Some((name, major))
                if imp.module.starts_with('@')
                    && name.len() > 1
                    && !major.is_empty()
                    && major.bytes().all(|b| b.is_ascii_digit()) =>
            {
                (name, Some(major))
            }
            _ => (imp.module.as_str(), None),
        };
        let from = self.loading.last().filter(|k| !k.is_empty()).cloned();
        let found = match self.options.resolver.resolve(module, from.as_deref()) {
            Ok(m) => m,
            Err(e) => {
                return Err(self.lift(at(e.code(), format!("can't import {}: {e}", imp.module))));
            }
        };
        if let (Some(wanted), Some(version)) = (wanted, &found.version) {
            let major = version.trim_start_matches('v').split('.').next().unwrap_or_default();
            if major != wanted {
                let reason = format!("{} wants major version {wanted}, but version {version} was found", imp.module);
                return Err(self.lift(at(Code::ImportVersion, reason)));
            }
        }
        if self.loading.contains(&found.key) {
            let reason = format!("import cycle: {} imports this file again", imp.module);
            return Err(self.lift(at(Code::ImportCycle, reason)));
        }
        if let Some(&cached) = self.by_key.get(&found.key) {
            return Ok(cached);
        }
        if let Some(other) = self.ids.get(&found.id)
            && other.as_deref() != Some(found.key.as_str())
        {
            let reason = format!(
                "{} is {}, but another file already is: two copies or two packages with the same name ({})",
                imp.module, found.id, found.key
            );
            return Err(self.lift(at(Code::DuplicatePackage, reason)));
        }
        if self.units.len() >= MAX_FILES {
            let reason = format!("more than {MAX_FILES} schema files are imported");
            return Err(self.lift(at(Code::TooManyFiles, reason)));
        }
        self.load(found.text, Some(found.key), Some(found.id), Some((unit, imp.pos, imp.module.clone())))
    }

    /// The file's own definitions: in scope, unless a name is also imported;
    /// generic ones refer to themselves with their own parameters only (§9.10).
    fn own_types(&mut self, unit: usize) -> Result<(), Fail> {
        let defs: Vec<(String, usize, Vec<String>)> =
            self.units[unit].file.types.iter().map(|d| (d.name.clone(), d.pos, d.params.clone())).collect();
        for (d, (name, pos, _)) in defs.iter().enumerate() {
            let u = &mut self.units[unit];
            if u.scope.contains_key(name) || u.std.contains_key(name) {
                return fail(unit, *pos, Code::DuplicateType, format!("type {name} is already imported"));
            }
            u.own.insert(name.clone(), d);
        }
        for (d, (name, _, _)) in defs.iter().enumerate() {
            self.units[unit].scope.insert(name.clone(), (unit, d));
        }
        for (d, (name, _, params)) in defs.iter().enumerate() {
            let mut bad = None;
            walk(&self.units[unit].file.types[d].ty, &mut |t| {
                if let Ty::Name { name: n, args, pos } = t
                    && n == name
                    && bad.is_none()
                {
                    let own = args.len() == params.len()
                        && args.iter().zip(params).all(|(a, p)| matches!(a, Ty::Param { name, .. } if name == p));
                    if !own {
                        bad = Some(*pos);
                    }
                }
            });
            if let Some(pos) = bad {
                let whole = std::iter::once(name.as_str()).chain(params.iter().map(String::as_str)).collect::<Vec<_>>();
                return fail(
                    unit,
                    pos,
                    Code::GrowingRecursion,
                    format!(
                        "{name} must refer to itself with its own parameters ({}); other arguments could grow without bound",
                        whole.join(" ")
                    ),
                );
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

    /// The instance of definition `d` of file `u` with `args`, created if new.
    /// `at` and `pos`: where it is used, for errors.
    fn instance(&mut self, u: usize, d: usize, args: Vec<Type>, at: usize, pos: usize) -> Result<InstanceId, Fail> {
        let key = match args.is_empty() {
            true => format!("{u}:{d}"),
            false => format!("{u}:{d}({})", args.iter().map(|a| self.key(a)).collect::<Vec<_>>().join(",")),
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
        self.keys.push(key.clone());
        self.def_of.push((u, d));
        self.state.push(State::New);
        self.by_instance_key.insert(key, id);
        self.queue.push_back(id);
        Ok(id)
    }

    /// A key that tells types apart, for instances.
    fn key(&self, t: &Type) -> String {
        match t {
            Type::Builtin(b) => b.name().into(),
            Type::Time(name) => (*name).into(),
            Type::Param(name) => format!("'{name}"),
            Type::Array(item) => format!("Array({})", self.key(item)),
            Type::Map(value) => format!("Map({})", self.key(value)),
            Type::Maybe(item) => format!("Maybe({})", self.key(item)),
            Type::Secret(item) => format!("Secret({})", self.key(item)),
            Type::Ref(id) => self.keys[id.0].clone(),
            Type::Record(r) => self.record_key(r),
            Type::Variant(v) => {
                let cases: Vec<String> = v
                    .cases
                    .iter()
                    .map(|c| match &c.payload {
                        Payload::None => c.tag.clone(),
                        Payload::Record(r) => format!("{}{}", c.tag, self.record_key(r)),
                        Payload::Positional(items) => {
                            format!("{}({})", c.tag, items.iter().map(|t| self.key(t)).collect::<Vec<_>>().join(","))
                        }
                    })
                    .collect();
                format!("<{}{}>", cases.join("|"), if v.open { "|_" } else { "" })
            }
        }
    }

    fn record_key(&self, r: &Record) -> String {
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
            return fail(u, s.pos, Code::UnknownType, unknown_type(&s.name));
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
                Ok(Type::Record(self.record(u, *closed, fields, spreads, env)?))
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
                        copied.push((sp, v.cases));
                    }
                }
                let cases = insert(cases, copied);
                let mut tags = HashSet::new();
                if let Some((c, pos)) = cases.iter().find(|(c, _)| !tags.insert(c.tag.as_str())) {
                    return fail(u, *pos, Code::DuplicateTag, format!("duplicate tag {}", c.tag));
                }
                Ok(Type::Variant(Variant::new(!closed, cases.into_iter().map(|(c, _)| c).collect())))
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
                copied.push((sp, r.fields));
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
            if name == "Stream" {
                return fail(u, pos, Code::MisplacedStream, "Stream is only allowed as the whole type of a definition");
            }
            arity(n)?;
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
                    Type::Variant(Variant::new(false, vec![case("Err", err), case("Ok", ok)]))
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
