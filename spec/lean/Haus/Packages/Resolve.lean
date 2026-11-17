import Haus.Packages.Fs
import Haus.Packages.SchemaFile
import Haus.Json.Text

/-!
# The reference resolver for schema packages (spec §13.3, §9.2)

`resolve tree config root`: loads the schema file `root` of `tree` with all
it imports, and returns the packages it reaches (`name@version`, sorted) or
the first error, with its code (spec §17) and a message.

It runs in `M`, which reads the tree only through `readFile` (recording each
path it reads in `St.reads`), `Tree.child?` (`lstat`), `Tree.realPath` and
`Tree.list`, so that what it reads can be stated about the same model.

**How packages are found** (`Mode`). The packages given explicitly, by their
directory (`packages`) or as a folder whose subdirectories with a
`package.haus` are packages (`folders`); and, with `npm`, `node_modules` by
the npm rules. Explicit packages are read first, once: a given directory
without a valid manifest is an error at the start; a folder's subdirectory
whose manifest can't be read is skipped, and named when an import isn't
found (security review Q5). An import `@org/name` from a file:

1. A package given by its directory with that name is used, and nothing else
   is looked at.
2. Otherwise the folders' packages with that name, and, with `npm`, the one
   the npm walk finds, all count. The walk runs only if the importer declares
   the name (checked before anything is looked for, F5); a name that is
   neither declared nor in a folder is `undeclared-package`.
3. Every candidate is loaded, its own imports resolved (F4); candidates that
   aren't one package are `duplicate-package`.

**One package per name.** Copies are compared after their imports are
resolved: a copy's *class* is its name, its `package.haus` and `schema.haus`
bytes, and the classes its imports reach, in order. Copies of one class are
one package; two classes with one name are `duplicate-package`. Since import
cycles are errors, a class is final when it is made, and two copies are one
package exactly when §13.3 says so ("byte for byte the same, and whose
imports reach the same packages").

**Each file is read at most once** (`St.files`, `St.copies`, `St.manifests`,
`St.npm`), so the diamond of 2^24 paths reads 49 files.

Recursion: `load` takes fuel, the number of entries of the tree plus one.
Each call on the stack is loading a different file of the tree (a file
being loaded again is an import cycle), so the fuel never runs out.
-/

namespace Haus.Packages

/-- How packages are found: the packages and folders given explicitly, and whether `node_modules` is read. -/
structure Mode where
  npm : Bool
  /-- Package directories, given one by one. -/
  packages : List Path := []
  /-- Folders whose subdirectories with a `package.haus` are packages. -/
  folders : List Path := []
  deriving Repr, Inhabited

/-- The limits of §13.3, in bytes and counts. -/
structure Limits where
  manifest : Nat := 64 * 1024
  schemaFile : Nat := 1024 * 1024
  packageJson : Nat := 1024 * 1024
  folderEntries : Nat := 4096
  files : Nat := 256
  deriving Repr, Inhabited

structure Config where
  mode : Mode
  limits : Limits := {}
  /--
  Directories everyone may write to, such as `/tmp`, which the npm walk
  SHOULD skip (§13.3). The tree has no owners or permissions, so this is a
  parameter; the suite can't express it and gives none.
  -/
  worldWritable : Path → Bool := fun _ => false
  /-- Whether the SHOULD check of "Package versions" (§13.3) is made. -/
  checkVersions : Bool := true

/-- A valid manifest (`package.haus`). -/
structure Manifest where
  name : String
  version : String
  bytes : List UInt8
  deriving Repr, Inhabited

/-- What a `package.json` says. -/
structure NpmInfo where
  /-- It has a `name` or a dependency field: it is a project's (§13.3 skips the others). -/
  project : Bool
  /-- The keys of `dependencies`, `peerDependencies` and `optionalDependencies` (objects only). -/
  deps : List String
  /-- The keys of `devDependencies`. -/
  dev : List String
  /-- Its `version`, if it is a string. -/
  version : Option String
  deriving Repr, Inhabited

/-- A package given explicitly. -/
structure Given where
  /-- The real path of its directory. -/
  dir : Path
  /-- The path it was given as (or found under, in a folder), for messages. -/
  shown : String
  name : String
  /-- Given by its directory (used instead of any other), or found in a folder. -/
  byDir : Bool
  deriving Repr, Inhabited

/-- A package as one or more identical copies (§13.3). -/
structure Class where
  name : String
  version : String
  manifest : List UInt8
  schema : List UInt8
  /-- The classes its package imports reach, in order. -/
  imports : List Nat
  /-- The types its schema defines. -/
  types : List String
  /-- The directory of the copy it was made from. -/
  dir : Path
  deriving Repr, Inhabited

/-- Loading a file or a package's copy: in progress, or done (with the copy's class). -/
inductive Loading where
  | loading
  | done (cls : Nat)
  deriving Repr, DecidableEq, Inhabited

structure Env where
  tree : Tree
  config : Config
  given : List Given := []
  /-- Folder entries whose `package.haus` could not be read, as shown. -/
  broken : List String := []

/--
The classes made so far, with distinct names: one package per name. The
invariant is part of the type, so that every state of a run has it (R2,
`Haus.Packages.Props`): `classify` can only add a class whose name is new.
-/
structure Classes where
  list : List Class
  distinct : (list.map (·.name)).Nodup

def Classes.empty : Classes := ⟨[], List.nodup_nil⟩

instance : Inhabited Classes := ⟨.empty⟩

theorem nodup_append_one {l : List String} {x : String} (h : l.Nodup) (hx : x ∉ l) : (l ++ [x]).Nodup := by
  rw [List.nodup_append]
  refine ⟨h, List.nodup_cons.mpr ⟨by simp, List.nodup_nil⟩, ?_⟩
  intro a ha b hb
  simp only [List.mem_singleton] at hb
  subst hb
  intro e; subst e; exact hx ha

/-- `cs` with the class `c`, whose name no class of `cs` has. -/
def Classes.push (cs : Classes) (c : Class) (h : ∀ d ∈ cs.list, d.name ≠ c.name) : Classes :=
  ⟨cs.list ++ [c], by
    rw [List.map_append]
    exact nodup_append_one cs.distinct (by
      intro hm
      obtain ⟨d, hd, e⟩ := List.mem_map.mp hm
      exact h d hd e)⟩

structure St where
  /-- Every file read, by real path, in order. -/
  reads : Array Path := #[]
  /-- Schema files outside packages: being loaded (`none`) or their types. -/
  files : List (Path × Option (List String)) := []
  /-- Package copies, by their directory's real path. -/
  copies : List (Path × Loading) := []
  manifests : List (Path × Manifest) := []
  /-- `package.json` files read, by real path, and what they say (`none`: not valid JSON). -/
  npm : List (Path × Option NpmInfo) := []
  classes : Classes := .empty
  /-- Schema files loaded, the root included. -/
  count : Nat := 0
  deriving Inhabited

abbrev M := ReaderT Env (ExceptT Err (StateM St))

def fail {α} (code : Code) (message : String) : M α := throw ⟨code, message⟩

/-! ## Reading files -/

/-- Reads the regular file at the real path `p`, and records it. The one way the resolver reads a file. -/
def readFile (p : Path) : M (List UInt8) := do
  match (← read).tree.at? p with
  | some (.file bs) =>
    modify fun s => { s with reads := s.reads.push p }
    pure bs
  | _ => fail .outOfFuel s!"internal: {showPath p} is not a regular file"

/-- The size of the regular file at the real path `p` (`fstat`). Not a read. -/
def fileSize (p : Path) : M Nat := do
  match (← read).tree.at? p with
  | some (.file bs) => pure bs.length
  | _ => pure 0

def utf8 (bs : List UInt8) : Option Text := (String.fromUTF8? ⟨bs.toArray⟩).map (·.toList)

/--
One of a package's own files, `name` in its directory `dir` (a real path):
opened without following a link, which must be a regular file (else
`package-path`) of at most `limit` bytes (else `tooLarge`), checked before
it is read. `none` if there is none.
-/
def openPackageFile (dir : Path) (name : String) (limit : Nat) (tooLarge : Code) (owner : String) : M (Option (List UInt8)) := do
  match (← read).tree.child? dir name with
  | none => pure none
  | some (.file _) =>
    let p := dir ++ [name]
    let size ← fileSize p
    if size > limit then fail tooLarge s!"the {name} of {owner} has {size} bytes, more than {limit}; it is not read"
    readFile p
  | some (.link _) => fail .packagePath s!"the {name} of {owner} is a symbolic link; it is not read"
  | some _ => fail .packagePath s!"the {name} of {owner} is not a regular file; it is not read"

/-- A manifest's text checked (§13.3): one record, a valid `name` and `version`. -/
def parseManifest (bytes : List UInt8) (owner : String) : Except Err Manifest :=
  let bad (why : String) : Except Err Manifest := .error ⟨.packageManifest, s!"the package.haus of {owner} {why}"⟩
  match utf8 bytes with
  | none => bad "is not valid UTF-8"
  | some t =>
    match Parser.parse {} t with
    | .error e => bad s!"is not valid haus ({e.code})"
    | .ok [.record fs] =>
      match fs.lookup "name", fs.lookup "version" with
      | some (.str n), some (.str v) =>
        if !isPackageName n then bad s!"has the name {quote n}, not @org/name in lowercase"
        else if !isSemver v then bad s!"has the version {quote v}, not a semantic version"
        else .ok ⟨n, v, bytes⟩
      | some (.str _), _ => bad "has no version that is a string"
      | _, _ => bad "has no name that is a string"
    | .ok [_] => bad "is not a record"
    | .ok vs => bad s!"has {vs.length} values, not one record"

/-- The manifest of the package in `dir` (a real path), read once. `none` if it has no `package.haus`. -/
def manifestOf (dir : Path) (shown : String) : M (Option Manifest) := do
  if let some m := (← get).manifests.lookup dir then return some m
  match ← openPackageFile dir "package.haus" (← read).config.limits.manifest .packageManifest shown with
  | none => pure none
  | some bytes =>
    let m ← match parseManifest bytes shown with
      | .ok m => pure m
      | .error e => throw e
    modify fun s => { s with manifests := (dir, m) :: s.manifests }
    pure (some m)

def keys (j : Option JSON) : List String :=
  match j with
  | some (.obj ms) => ms.map (·.1)
  | _ => []

/-- What a `package.json`'s text says; `none` if it isn't valid JSON (§13.3: it declares nothing). -/
def parseNpm (bytes : List UInt8) : Option NpmInfo :=
  match utf8 bytes with
  | none => none
  | some t =>
    match JSON.parse {} t with
    | .ok (.obj ms) =>
      let fields := ["dependencies", "peerDependencies", "optionalDependencies", "devDependencies"]
      some {
        project := ms.any fun (k, _) => k == "name" || k ∈ fields
        deps := keys (ms.lookup "dependencies") ++ keys (ms.lookup "peerDependencies") ++ keys (ms.lookup "optionalDependencies")
        dev := keys (ms.lookup "devDependencies")
        version := match ms.lookup "version" with | some (.str v) => some v | _ => none }
    | .ok _ => some { project := false, deps := [], dev := [], version := none }
    | .error _ => none

/-- A package's own `package.json` (in `dir`, a real path), read once, under the rule of its other files. -/
def packageJsonOf (dir : Path) (owner : String) : M (Option NpmInfo) := do
  let p := dir ++ ["package.json"]
  if let some r := (← get).npm.lookup p then return r
  match ← openPackageFile dir "package.json" (← read).config.limits.packageJson .fileTooLarge owner with
  | none => pure none
  | some bytes =>
    let r := parseNpm bytes
    modify fun s => { s with npm := (p, r) :: s.npm }
    pure r

/--
The `package.json` that speaks for a file outside a package (§13.3): the
nearest above its real path `p`, skipping one that has neither a `name` nor
a dependency field. It is opened like any file (following links): the spec
puts no rule on it. Not valid JSON, or not a regular file: it declares nothing.
Returns where it is, and what it declares (with `devDependencies`; `none`: nothing, as it can't be read).
-/
def projectOf (p : Path) : M (Option (Path × Option (List String))) := do
  let env ← read
  for d in ancestors p.dropLast do
    if (env.tree.child? d "package.json").isNone then continue
    match env.tree.realPath (d ++ ["package.json"]) with
    | .ok real =>
      if !(env.tree.at? real matches some (.file _)) then return some (d, none)
      let info ← match (← get).npm.lookup real with
        | some r => pure r
        | none => do
          let size ← fileSize real
          if size > env.config.limits.packageJson then
            fail .fileTooLarge s!"{showPath (d ++ ["package.json"])} has {size} bytes, more than {env.config.limits.packageJson}; it is not read"
          let r := parseNpm (← readFile real)
          modify fun s => { s with npm := (real, r) :: s.npm }
          pure r
      match info with
      | none => return some (d, none)
      | some i => if i.project then return some (d, some (i.deps ++ i.dev)) else continue
    | .error _ => return some (d, none)
  return none

/-! ## Finding packages -/

/-- Who imports: a schema file outside packages (its real path), or a package's `schema.haus`. -/
inductive Importer where
  | app (p : Path)
  | pkg (dir : Path) (name : String) (npm : Option NpmInfo)

def Importer.show : Importer → String
  | .app p => showPath p
  | .pkg dir name _ => s!"{name} ({showPath dir})"

/-- The packages an importer declares (§13.3), and what to say when a name isn't one of them. -/
def declared : Importer → M (List String × String)
  | .pkg _ _ (some i) => pure (i.deps, "its package.json doesn't declare it")
  | .pkg _ _ none => pure ([], "it has no package.json, so it declares nothing")
  | .app p => do
    match ← projectOf p with
    | some (d, some names) => pure (names, s!"{showPath (d ++ ["package.json"])} doesn't declare it")
    | some (d, none) => pure ([], s!"{showPath (d ++ ["package.json"])} can't be read as JSON, so it declares nothing")
    | none => pure ([], "there is no package.json above it, so it declares nothing")

/-- Where the npm walk doesn't look (§13.3): `node_modules`, a scope directory in one, a directory everyone may write to. -/
def skipped (worldWritable : Path → Bool) (d : Path) : Bool :=
  d.getLast? == some "node_modules"
    || (d.dropLast.getLast? == some "node_modules" && (d.getLast?.any (·.startsWith "@")))
    || worldWritable d

/--
The npm walk (§13.3) for the package `name` (`@org/n`) from the directory
`start` (a real path): the first `D/node_modules/@org/n` that exists, for
`D` from `start` up, nearest first, skipping the directories of `skipped`.
Its real path; an error if it has no `package.haus`; `none` if there is none.
-/
def npmLookup (start : Path) (name : String) : M (Option Path) := do
  let env ← read
  let parts := splitPath name
  for d in ancestors start do
    if skipped env.config.worldWritable d then continue
    let p := d ++ "node_modules" :: parts
    match env.tree.realPath p with
    | .ok real =>
      if (env.tree.child? real "package.haus").isSome then return some real
      fail .importNotFound s!"{name}: {showPath p} has no package.haus (not a schema package); the search stops there"
    | .error _ => continue
  return none

/-- Is the real path `p` in a package's directory: a directory above it with a `package.haus`? -/
def inPackage (t : Tree) (p : Path) : Option Path :=
  (ancestors p.dropLast).find? fun d => (t.child? d "package.haus").isSome

/-- What loading gives: the types defined, and for a package, its class. -/
structure Loaded where
  types : List String
  cls : Option Nat := none

inductive Target where
  /-- A schema file outside packages, by its real path. -/
  | file (p : Path)
  /-- A package's copy, by its directory's real path. -/
  | copy (dir : Path)

def checkNames (imp : Import) (types : List String) (what : String) : M Unit := do
  if let some n := imp.names.find? (· ∉ types) then
    fail .unknownImport s!"{what} has no type {n}"

/-- The candidates for `@org/n` from `importer` (§13.3, "Resolution" and "npm"): real directories, with how they are shown. -/
def candidates (importer : Importer) (name : String) : M (List (Path × String)) := do
  let env ← read
  let byDir := env.given.filter fun g => g.byDir && g.name == name
  if !byDir.isEmpty then return byDir.map fun g => (g.dir, g.shown)
  let inFolders := (env.given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown)
  let fromNpm ← if !env.config.mode.npm then pure [] else do
    let (decl, where_) ← declared importer
    if name ∈ decl then
      let start := match importer with | .app p => p.dropLast | .pkg dir _ _ => dir
      pure ((← npmLookup start name).toList.map fun d => (d, showPath d))
    else if inFolders.isEmpty then
      fail .undeclaredPackage s!"{importer.show} imports {name}, but {where_}"
    else pure []
  let all := inFolders ++ fromNpm.filter fun (d, _) => !inFolders.any (·.1 == d)
  if all.isEmpty then
    let broken := if env.broken.isEmpty then "" else
      s!"; these entries of the folders given have no valid package.haus: {", ".intercalate env.broken}"
    fail .importNotFound s!"{importer.show} imports {name}, which isn't found{broken}"
  return all

/--
One import of `importer`. `loadFn` loads a target (it is `load` with less
fuel). Returns the class of an imported package.
-/
def resolveImport (loadFn : Target → M Loaded) (importer : Importer) (imp : Import) : M (Option Nat) := do
  let env ← read
  match imp.module with
  | .std _ => pure none  -- checked by `scan`
  | .file path =>
    match importer with
    | .pkg _ name _ => fail .packagePath s!"the schema of {name} imports the file {path}; a package imports only packages, by name"
    | .app p =>
      let comps := splitPath path
      let comps := comps.dropLast ++ [comps.getLastD "" ++ ".schema.haus"]
      match resolve env.tree maxLinks p.dropLast comps with
      | .error _ => fail .importNotFound s!"{showPath p} imports {path}, which isn't found"
      | .ok real =>
        if let some d := inPackage env.tree real then
          fail .packagePath s!"{showPath p} imports {path}, a file in the package directory {showPath d}; import the package by its name"
        if !(real.getLast?.any (·.endsWith ".schema.haus")) then
          fail .importNotFound s!"{showPath p} imports {path}, which is not a schema file (its real path doesn't end in .schema.haus); it is not read"
        if !(env.tree.at? real matches some (.file _)) then
          fail .importNotFound s!"{showPath p} imports {path}, which is not a regular file; it is not read"
        let r ← loadFn (.file real)
        checkNames imp r.types path
        pure none
  | .pkg name major =>
    let cands ← candidates importer name
    let mut cls : Option Nat := none
    for (dir, shown) in cands do
      let some m ← manifestOf dir shown
        | fail .importNotFound s!"{importer.show} imports {name}: {shown} has no package.haus"
      if m.name != name then
        fail .importNotFound s!"{importer.show} imports {name}: the package in {shown} is {m.name}"
      if let some n := major then
        if majorOf m.version != n then
          fail .importVersion s!"{importer.show} imports {name}@{n}, and {shown} has version {m.version}"
      let r ← loadFn (.copy dir)
      if cls.isNone then cls := r.cls
      checkNames imp r.types name
    pure cls

/-! ## Loading -/

def countFile (what : String) : M Unit := do
  let s ← get
  let limit := (← read).config.limits.files
  if s.count + 1 > limit then
    fail .tooManyFiles s!"{what} would be schema file {s.count + 1}, more than {limit}"
  set { s with count := s.count + 1 }

def decodeScan (bytes : List UInt8) (what : String) : M Scanned := do
  match utf8 bytes with
  | none => fail .invalidUtf8 s!"{what} is not valid UTF-8"
  | some t =>
    match scan t with
    | .ok s => pure s
    | .error e => fail e.code s!"in {what}: {e.message}"

theorem not_named {l : List Class} {c : Class} (h : l.find? (·.name == c.name) = none) :
    ∀ d ∈ l, d.name ≠ c.name := by
  intro d hd e
  have := List.find?_eq_none.mp h d hd
  simp [e] at this

/-- Copies of one package (§13.3): the same name, the same bytes in `package.haus` and `schema.haus`, and imports that reach the same packages. -/
def Class.same (c d : Class) : Bool :=
  d.name == c.name && d.manifest == c.manifest && d.schema == c.schema && d.imports == c.imports

/--
The class of a loaded copy, described by `c` (§13.3): an existing class with
the same name, files and imports, or a new one, whose name no class may
have yet. Returns its index and the classes.
-/
def addClass (c : Class) (cs : Classes) : Except Err (Nat × Classes) :=
  match cs.list.findIdx? (Class.same c) with
  | some i => .ok (i, cs)
  | none =>
    match h : cs.list.find? (·.name == c.name) with
    | some d =>
      let differ := if d.version == c.version then ", with other files" else ""
      .error ⟨.duplicatePackage, s!"two packages named {c.name}: {d.version} in {showPath d.dir} and {c.version} in {showPath c.dir}{differ}"⟩
    | none => .ok (cs.list.length, cs.push c (not_named h))

/-- `addClass` on the run's classes. -/
def classify (c : Class) : M Nat := do
  let st ← get
  match addClass c st.classes with
  | .ok (i, cs) => set { st with classes := cs }; pure i
  | .error e => throw e

def load : Nat → Target → M Loaded
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, .file p => do
    match (← get).files.lookup p with
    | some (some ts) => return { types := ts }
    | some none => fail .importCycle s!"{showPath p} imports itself, directly or not"
    | none => pure ()
    modify fun s => { s with files := (p, none) :: s.files }
    let env ← read
    let size ← fileSize p
    if size > env.config.limits.schemaFile then
      fail .fileTooLarge s!"{showPath p} has {size} bytes, more than {env.config.limits.schemaFile}; it is not read"
    countFile (showPath p)
    let s ← decodeScan (← readFile p) (showPath p)
    for imp in s.imports do
      let _ ← resolveImport (load n) (.app p) imp
    modify fun st => { st with files := (p, some s.types) :: st.files }
    return { types := s.types }
  | n + 1, .copy dir => do
    match (← get).copies.lookup dir with
    | some (.done c) => return { types := (← get).classes.list[c]!.types, cls := some c }
    | some .loading => fail .importCycle s!"the package in {showPath dir} imports itself, directly or not"
    | none => pure ()
    modify fun s => { s with copies := (dir, .loading) :: s.copies }
    let env ← read
    let some m ← manifestOf dir (showPath dir)
      | fail .importNotFound s!"{showPath dir} has no package.haus"
    let owner := s!"{m.name} ({showPath dir})"
    -- Its package.json: what it declares, and the version its package manager gives it.
    let npm ← if env.config.mode.npm then packageJsonOf dir owner else pure none
    if env.config.checkVersions then
      if let some v := npm.bind (·.version) then
        if v != m.version then
          let shown := if isSemver v then quote v else "a version that isn't a semantic version"
          fail .packageVersion s!"the package.haus of {owner} says version {quote m.version}, its package.json {shown}"
    let some bytes ← openPackageFile dir "schema.haus" env.config.limits.schemaFile .fileTooLarge owner
      | fail .importNotFound s!"{owner} has no schema.haus"
    countFile s!"the schema.haus of {owner}"
    let s ← decodeScan bytes s!"the schema.haus of {owner}"
    -- A package imports packages, never files: checked before anything is looked for.
    if let some i := s.imports.find? (·.module matches .file _) then
      fail .packagePath s!"the schema of {m.name} imports the file {i.module.show}; a package imports only packages, by name"
    let mut targets : List Nat := []
    for imp in s.imports do
      if let some c ← resolveImport (load n) (.pkg dir m.name npm) imp then targets := targets ++ [c]
    let c ← classify { name := m.name, version := m.version, manifest := m.bytes, schema := bytes,
                       imports := targets, types := s.types, dir }
    modify fun st => { st with copies := (dir, .done c) :: st.copies }
    return { types := s.types, cls := some c }

/-! ## The explicit packages, and the whole -/

/-- Reads the manifests of the packages given explicitly (§13.3), at the start. -/
def givenPackages : M (List Given × List String) := do
  let env ← read
  let mut given : List Given := []
  let mut broken : List String := []
  for d in env.config.mode.packages do
    let real ← match env.tree.realPath d with
      | .ok r => if env.tree.isDir r then pure r else fail .importNotFound s!"the package directory {showPath d} given is not a directory"
      | .error _ => fail .importNotFound s!"the package directory {showPath d} given doesn't exist"
    let some m ← manifestOf real (showPath d)
      | fail .importNotFound s!"the package directory {showPath d} given has no package.haus"
    given := given ++ [{ dir := real, shown := showPath d, name := m.name, byDir := true }]
  for f in env.config.mode.folders do
    let real ← match env.tree.realPath f with
      | .ok r => if env.tree.isDir r then pure r else fail .importNotFound s!"the folder of packages {showPath f} given is not a directory"
      | .error _ => fail .importNotFound s!"the folder of packages {showPath f} given doesn't exist"
    let names := env.tree.list real
    if names.length > env.config.limits.folderEntries then
      fail .tooManyFiles s!"the folder of packages {showPath f} has {names.length} entries, more than {env.config.limits.folderEntries}"
    for n in names.mergeSort (· ≤ ·) do
      let shown := showPath (f ++ [n])
      let .ok sub := env.tree.realPath (real ++ [n]) | continue
      if !env.tree.isDir sub || (env.tree.child? sub "package.haus").isNone then continue
      try
        if let some m ← manifestOf sub shown then
          given := given ++ [{ dir := sub, shown, name := m.name, byDir := false }]
      catch _ => broken := broken ++ [shown]
  return (given, broken)

/-- The packages reached, as `name@version`, sorted. -/
def packagesOf (cs : List Class) : List String :=
  (cs.map fun c => c.name ++ "@" ++ c.version).mergeSort (· ≤ ·)

/-- The result of `resolveIn`, with the files read and the packages (classes) reached. -/
structure Outcome where
  result : Except Err (List String)
  reads : Array Path
  /-- The packages made, also when an error ended the run. -/
  classes : Classes

/-- The outcome of a run: on success, the packages made. -/
def Outcome.of (p : Except Err Unit × St) : Outcome :=
  ⟨p.1.map fun _ => packagesOf p.2.classes.list, p.2.reads, p.2.classes⟩

/--
Loads the schema file `root` of `tree` and everything it imports. On success,
every package reached, as `name@version`, sorted.
-/
def resolveIn (tree : Tree) (config : Config) (root : Path) : Outcome :=
  let run : M Unit := do
    let (given, broken) ← givenPackages
    withReader (fun e => { e with given, broken }) do
      let real ← match tree.realPath root with
        | .ok r => pure r
        | .error _ => fail .importNotFound s!"the schema file {showPath root} doesn't exist"
      if !(tree.at? real matches some (.file _)) then
        fail .importNotFound s!"the schema file {showPath root} is not a regular file"
      let _ ← load (tree.entries.length + 1) (.file real)
  Outcome.of (((run.run { tree, config }).run).run {})

end Haus.Packages
