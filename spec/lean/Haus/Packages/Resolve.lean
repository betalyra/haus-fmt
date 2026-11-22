import Haus.Packages.Fs
import Haus.Packages.SchemaFile
import Haus.Json.Text

/-!
# The reference resolver for schema packages (spec §13.3, §9.2)

`resolve tree config root`: loads the schema file `root` of `tree` with all
it imports, and returns the packages it reaches (`name@version`, sorted) or
the first error, with its code (spec §17) and a message.

It runs in `M`, which sees the tree only through `openFile` (recording each
path it opens in `St.reads`) and `look`, which tells only kinds, names,
links and real paths (`Tree.childKind?` for `lstat`, `Tree.realPath`,
`Tree.list`), never a file's bytes: so what it reads can be stated about
the same model, and the bytes of a file it doesn't open can't matter (R7,
`Haus.Packages.Reads`).

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

The model is one resolver for every ecosystem (§13.3): the core rules, and
the npm lookup as an option (`Mode.npm`). The npm walk takes the first
`node_modules/@org/name` that is there as `lstat` sees it; one that is there
but can't be followed (a dangling link, a cycle of links) stops it
(`Tree.stops`). The tree has no permissions, so `EACCES` is not modelled.

**Relative imports** (`fileTarget`, `resolveImport`): a path goes up with
`..` only at its start (grammar `path`, checked by `Haus.Packages.isRelPath`
when the file is scanned), from the directory of the importing file's real
path, then down its names, one at a time (`walkNames`): each listed in its
directory with that spelling, and none a symbolic link, which is never
followed. Only the entry file and the `root` option are resolved to real
paths, once, at the start (`main`, `baseOf`). The checks of a relative
import come in the order of §13.3: its syntax (when the file is scanned);
`..` names that go above the build's root (`Env.base`: the directory of the
entry file's real path, or the `root` option), before anything is looked at
(`import-outside-root`); the walk (`import-not-found`); the target in a
package's directory, looked for from its directory up to the root, failing
closed on a directory that can't be listed (`inPackage`); and opening the
file. Every file read is a regular file, opened in a real directory without
following a link: the project's `package.json` too (§13.3, "Files read"),
which declares nothing when it isn't one.

**One package per name.** Copies are compared after their imports are
resolved: a copy's *class* is its name, its `package.haus` and `schema.haus`
bytes, and the classes its imports reach, in order. Copies of one class are
one package; two classes with one name are `duplicate-package`. Since import
cycles are errors, a class is final when it is made, and two copies are one
package exactly when §13.3 says so ("byte for byte the same, and whose
imports reach the same packages").

**Each file is read at most once** (`St.files`, `St.copies`, `St.manifests`,
`St.npm`), so the diamond of 2^24 paths reads 49 files. `openFile` also
keeps the paths it opened, and doesn't open one twice: the caches are kept
by kind, and one file can be of two kinds (a root that is a `package.json`).

Recursion: `load` takes fuel, `Limits.files` plus one. Each call on the
stack has counted its schema file (`countFile`) before it loads the file's
imports, so `too-many-files` ends a run before the fuel runs out.
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
  /--
  The build's `root` option (§13.3, "The root"): a directory that contains
  the entry file. Without it, the root is the directory of the entry file's
  real path.
  -/
  root : Option Path := none

/--
The order in which a schema file's imports are walked, as a function of its
list of imports, each walked once (a permutation). The spec fixes none
(§13.3); the resolver walks them in the order of the file (`Walk.file`), and
R3 (`Haus.Packages.Walk`) proves that every order gives the same success or
failure, and on success the same packages.
-/
structure Walk where
  order : List Import → List Import
  perm : ∀ l, (order l).Perm l

/-- In the order of the file. -/
def Walk.file : Walk := ⟨id, fun l => List.Perm.refl l⟩

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
  /-- The real path of the build's root (§13.3): relative imports stay inside it. -/
  base : Path := []

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

/-- What `load` loads. -/
inductive Target where
  /-- A schema file outside packages, by its real path. -/
  | file (p : Path)
  /-- A package's copy, by its directory's real path. -/
  | copy (dir : Path)
  deriving DecidableEq

/-- `l` with `T` at its end, unless `T` is in it already. -/
def addNew (l : List Target) (T : Target) : List Target := if T ∈ l then l else l ++ [T]

structure St where
  /-- Every file opened (and read, unless too large), by real path, in order. -/
  reads : List Path := []
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
  /-- Searches for a package (`candidates`), for the bound of R4. -/
  lookups : Nat := 0
  /-- Schema files scanned, their imports all together, and the most in one of them. -/
  scanned : Nat := 0
  imports : Nat := 0
  widest : Nat := 0
  /-- The targets loaded, in the order they were done, each once: only for the proofs of R3. -/
  finished : List Target := []
  deriving Inhabited

abbrev M := ReaderT Env (ExceptT Err (StateM St))

def fail {α} (code : Code) (message : String) : M α := throw ⟨code, message⟩

/-! ## Reading files -/

/--
Something of the tree that is not a file's bytes: kinds, names, links, real
paths. Everything the resolver learns of the tree, except through `openFile`.
-/
def look {β} (g : Tree → β) : M β := do return g (← read).tree

/-- Something of the run's settings: the configuration, the explicit packages. -/
def ask {β} (f : Env → β) : M β := do return f (← read)

def cfg : M Config := ask (·.config)

/--
Opens the regular file at the real path `p`, records it, checks its size on
the opened file (else `tooLarge size`), and reads it. The one way the
resolver reads a file. A file opened before is not opened again: a binding
keeps what it read, and the model's tree doesn't change.
-/
def openFile (p : Path) (limit : Nat) (tooLarge : Nat → Err) : M (List UInt8) := do
  match (← read).tree.at? p with
  | some (.file bs) =>
    if p ∉ (← get).reads then modify fun s => { s with reads := s.reads ++ [p] }
    if bs.length > limit then throw (tooLarge bs.length)
    pure bs
  | _ => fail .outOfFuel s!"internal: {showPath p} is not a regular file"

def utf8 (bs : List UInt8) : Option Text := (String.fromUTF8? ⟨bs.toArray⟩).map (·.toList)

/--
One of a package's own files, `name` in its directory `dir` (a real path):
opened without following a link, which must be a regular file (else
`package-path`) of at most `limit` bytes (else `tooLarge`), checked before
it is read. `none` if there is none.
-/
def openPackageFile (dir : Path) (name : String) (limit : Nat) (tooLarge : Code) (owner : String) : M (Option (List UInt8)) := do
  match ← look (·.childKind? dir name) with
  | none => pure none
  | some .file =>
    let bs ← openFile (dir ++ [name]) limit fun size =>
      ⟨tooLarge, s!"the {name} of {owner} has {size} bytes, more than {limit}; it is not read"⟩
    pure (some bs)
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
  match ← openPackageFile dir "package.haus" (← cfg).limits.manifest .packageManifest shown with
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
  match ← openPackageFile dir "package.json" (← cfg).limits.packageJson .fileTooLarge owner with
  | none => pure none
  | some bytes =>
    let r := parseNpm bytes
    modify fun s => { s with npm := (p, r) :: s.npm }
    pure r

/--
The `package.json` that speaks for a file outside a package (§13.3): the
nearest above its real path `p`, skipping one that has neither a `name` nor
a dependency field. Like every file a build reads ("Files read"), it is
opened without following a link, and must be a regular file: one that isn't
(a link, a directory, a FIFO) declares nothing and is not read, and so does
one that isn't valid JSON. The directories above a real path are real, so
it is read as a package's `package.json` is (`packageJsonOf`), once.
Returns where it is, and what it declares (with `devDependencies`; `none`: nothing, as it can't be read).
-/
def projectOf (p : Path) : M (Option (Path × Option (List String))) := do
  for d in ancestors p.dropLast do
    match ← look (·.childKind? d "package.json") with
    | none => continue
    | some .file =>
      match ← packageJsonOf d (showPath d) with
      | none => return some (d, none)
      | some i => if i.project then return some (d, some (i.deps ++ i.dev)) else continue
    | some _ => return some (d, none)
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
Where the npm walk (§13.3) looks for `name` (`@org/n`) from the directory
`start`: `D/node_modules/@org/n` for `D` from `start` up, nearest first,
skipping the directories of `skipped`.
-/
def walk (worldWritable : Path → Bool) (start : Path) (name : String) : List Path :=
  ((ancestors start).filter fun d => !skipped worldWritable d).map (· ++ "node_modules" :: splitPath name)

/-- The directory `D` of a place `D/node_modules/@org/n` of `walk` for `name`. -/
def placeDir (name : String) (p : Path) : Path := p.take (p.length - ((splitPath name).length + 1))

/--
The npm walk (§13.3) for the package `name` (`@org/n`) from the directory
`start` (a real path): the first place of `walk` that exists. Its real
path; an error if it has no `package.haus`, or if it is there but can't be
followed (a dangling link, a cycle of links: `Tree.stops`); `none` if there
is none. Only a place that isn't there lets the walk go on. A directory `D`
on the way up that can't be listed can't show whether it has a
`node_modules`: it stops the walk too (it fails closed). The model has no
permissions (`Tree.listable`), so this names the rule; the bindings' tests
check it.
-/
def npmLookup (start : Path) (name : String) : M (Option Path) := do
  for p in walk (← cfg).worldWritable start name do
    if !(← look (·.listable (placeDir name p))) then
      fail .importNotFound s!"{msgText name}: {showPath (placeDir name p)} can't be listed, so whether it has a node_modules can't be told; the search stops there"
    match ← look (·.realPath p) with
    | .ok real =>
      if (← look (·.childKind? real "package.haus")).isSome then return some real
      fail .importNotFound s!"{msgText name}: {showPath p} has no package.haus (not a schema package); the search stops there"
    | .error f =>
      if ← look (·.stops p f) then
        fail .importNotFound s!"{msgText name}: {showPath p} is there but can't be followed (a broken link or a cycle of links); the search stops there"
      continue
  return none

/-- A directory that stops a relative import into it (§13.3, "Imports"). -/
inductive Stop where
  /-- A package's directory: it has a `package.haus`. -/
  | pkg (d : Path)
  /-- A directory that can't be listed, so whether it is a package's can't be checked. -/
  | unchecked (d : Path)

def Stop.code : Stop → Code
  | .pkg _ => .packagePath
  | .unchecked _ => .importNotFound

/-- The message of a relative import `path` of the file `p` that `stop` stops. -/
def Stop.message (stop : Stop) (p : Path) (path : String) : String :=
  match stop with
  | .pkg d => s!"{showPath p} imports {msgText path}, a file in the package directory {showPath d}; import the package by its name"
  | .unchecked d => s!"{showPath p} imports {msgText path}, and whether {showPath d} is a package's directory can't be checked (it can't be listed); it is not read"

/--
Is the real path `p`, inside the build's root `base`, in a package's
directory (§13.3, "Imports")? The directories from `p`'s up to the root, the
root included, nearest first: the first that has a `package.haus`, or that
can't be listed (it fails closed: it is never taken as not a package's).
-/
def inPackage (t : Tree) (base p : Path) : Option Stop :=
  ((ancestors p.dropLast).filter base.isPrefixOf).findSome? fun d =>
    if !t.listable d then some (.unchecked d)
    else if (t.childKind? d "package.haus").isSome then some (.pkg d) else none

/-- What loading gives: the types defined, and for a package, its class. -/
structure Loaded where
  types : List String
  cls : Option Nat := none

/-- How many `..` names a path starts with: how far it goes up (`..` appears only at the start, grammar `path`). -/
def upCount (comps : List String) : Nat := (comps.takeWhile (· == "..")).length

/-- The names of a schema file an import of a file names (`./x` is `x.schema.haus`). -/
def fileComps (path : String) : List String :=
  (splitPath path).dropLast ++ [(splitPath path).getLastD "" ++ ".schema.haus"]

/-- Why a relative import leads to no file (§13.3). -/
inductive FileFault where
  /-- Its `..` names go above the root: nothing is looked at. -/
  | above
  /-- The name is a symbolic link, which is not followed: nothing behind it is looked at. -/
  | link (name : String)
  /-- The name is not listed in its directory with that spelling, or a name before the last isn't a directory. -/
  | missing (name : String)
  deriving DecidableEq

/--
The walk down a relative import's names (§13.3, "Resolution") from the real
directory `d`: each name must be an entry its directory lists with that
spelling, and not a symbolic link (as `lstat` sees it, not following it);
each name but the last a directory. The path reached, which has no links.
What the last name is (a regular file or not) is checked when it is opened.
-/
def walkNames (t : Tree) (d : Path) : List String → Except FileFault Path
  | [] => .ok d
  | n :: rest =>
    match t.childKind? d n with
    | none => .error (.missing n)
    | some (.link _) => .error (.link n)
    | some .dir => walkNames t (d ++ [n]) rest
    | some _ => if rest.isEmpty then .ok (d ++ [n]) else .error (.missing n)

/--
Where the relative import `path` of the file `p` (a real path) leads, in a
build whose root is `base` (§13.3, "Resolution" and "The root"): the path of
the file it names, inside the root, with no links. The `..` names are
checked first, on `p`'s real directory alone, before anything is looked at;
then the other names are walked down from there (`walkNames`). As no link is
followed, the path reached is the directory the `..` names lead to with the
import's names: inside the root.
-/
def fileTarget (t : Tree) (base p : Path) (path : String) : Except FileFault Path :=
  let up := upCount (splitPath path)
  let start := p.dropLast.take (p.dropLast.length - up)
  if !base.isPrefixOf start then .error .above
  else walkNames t start ((fileComps path).dropWhile fun c => c == "." || c == "..")

def FileFault.code : FileFault → Code
  | .above => .importOutsideRoot
  | .link _ | .missing _ => .importNotFound

def FileFault.message (f : FileFault) (p base : Path) (path : String) : String :=
  match f with
  | .above => s!"{showPath p} imports {msgText path}, which goes above the build's root {showPath base}"
  | .link n => s!"{showPath p} imports {msgText path}, in which {msgText n} is a symbolic link; a relative import follows no link, and nothing behind it is read"
  | .missing _ => s!"{showPath p} imports {msgText path}, which isn't found"

def checkNames (imp : Import) (types : List String) (what : String) : M Unit := do
  if let some n := imp.names.find? (· ∉ types) then
    fail .unknownImport s!"{what} has no type {n}"

/-- The candidates for `@org/n` from `importer` (§13.3, "Resolution" and "npm"): real directories, with how they are shown. -/
def candidates (importer : Importer) (name : String) : M (List (Path × String)) := do
  modify fun s => { s with lookups := s.lookups + 1 }
  let given ← ask (·.given)
  let byDir := given.filter fun g => g.byDir && g.name == name
  if !byDir.isEmpty then return byDir.map fun g => (g.dir, g.shown)
  let inFolders := (given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown)
  let fromNpm ← if !(← cfg).mode.npm then pure [] else do
    let (decl, where_) ← declared importer
    if name ∈ decl then
      let start := match importer with | .app p => p.dropLast | .pkg dir _ _ => dir
      pure ((← npmLookup start name).toList.map fun d => (d, showPath d))
    else if inFolders.isEmpty then
      fail .undeclaredPackage s!"{importer.show} imports {msgText name}, but {where_}"
    else pure []
  let all := inFolders ++ fromNpm.filter fun (d, _) => !inFolders.any (·.1 == d)
  if all.isEmpty then
    let broken ← ask (·.broken)
    let broken := if broken.isEmpty then "" else
      s!"; these entries of the folders given have no valid package.haus: {", ".intercalate broken}"
    fail .importNotFound s!"{importer.show} imports {msgText name}, which isn't found{broken}"
  return all

/--
One import of `importer`. `loadFn` loads a target (it is `load` with less
fuel). Returns the class of an imported package.
-/
def resolveImport (loadFn : Target → M Loaded) (importer : Importer) (imp : Import) : M (Option Nat) := do
  match imp.module with
  | .std _ => pure none  -- checked by `scan`
  | .file path =>
    match importer with
    | .pkg _ name _ => fail .packagePath s!"the schema of {name} imports the file {msgText path}; a package imports only packages, by name"
    | .app p =>
      let base ← ask (·.base)
      match ← look (fileTarget · base p path) with
      | .error f => fail f.code (f.message p base path)
      | .ok real =>
        if let some stop ← look (inPackage · base real) then
          fail stop.code (stop.message p path)
        -- Always true: the walk gives the import's names, the last spelled with `.schema.haus` (`fileComps`); R7 (`Haus.Packages.Reads`) uses it.
        if !(real.getLast?.any (·.endsWith ".schema.haus")) then
          fail .importNotFound s!"{showPath p} imports {msgText path}, which is not a schema file; it is not read"
        if (← look (·.kindAt? real)) != some .file then
          fail .importNotFound s!"{showPath p} imports {msgText path}, which is not a regular file; it is not read"
        let r ← loadFn (.file real)
        checkNames imp r.types path
        pure none
  | .pkg name major =>
    let cands ← candidates importer name
    let mut cls : Option Nat := none
    for (dir, shown) in cands do
      let some m ← manifestOf dir shown
        | fail .importNotFound s!"{importer.show} imports {msgText name}: {shown} has no package.haus"
      if m.name != name then
        fail .importNotFound s!"{importer.show} imports {msgText name}: the package in {shown} is {msgText m.name}"
      if let some n := major then
        if majorOf m.version != n then
          fail .importVersion s!"{importer.show} imports {msgText name}@{msgText n}, and {shown} has version {msgText m.version}"
      let r ← loadFn (.copy dir)
      if cls.isNone then cls := r.cls
      checkNames imp r.types name
    pure cls

/-! ## Loading -/

def countFile (what : String) : M Unit := do
  let limit := (← cfg).limits.files
  let n := (← get).count
  if n + 1 > limit then
    fail .tooManyFiles s!"{what} would be schema file {n + 1}, more than {limit}"
  modify fun s => { s with count := s.count + 1 }

/-- Notes the imports of a schema file loaded (R4). -/
def noteImports (k : Nat) : M Unit :=
  modify fun s => { s with scanned := s.scanned + 1, imports := s.imports + k, widest := max s.widest k }

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
      .error ⟨.duplicatePackage, s!"two packages named {msgText c.name}: {msgText d.version} in {showPath d.dir} and {msgText c.version} in {showPath c.dir}{differ}"⟩
    | none => .ok (cs.list.length, cs.push c (not_named h))

/-- `addClass` on the run's classes. -/
def classify (c : Class) : M Nat := do
  match addClass c (← get).classes with
  | .ok (i, cs) => modify fun st => { st with classes := cs }; pure i
  | .error e => throw e

/--
A package's own `package.json`, read leniently: one that can't be read (a
symbolic link, not a regular file, too large) is ignored, as one that isn't
JSON is (§13.3, "Package versions": beside a package given by its directory, it
only catches a version that differs, and, with `npm`, declares the package's own
dependencies).
-/
def lenientNpm (dir : Path) (owner : String) : M (Option NpmInfo) :=
  tryCatch (packageJsonOf dir owner) fun _ => pure none

/--
A copy's `package.json`: what it declares, and the version its package
manager gives it. With `npm`, a package the npm walk found, or found in a
folder given, reads it under the rule of a package's files (§13.3, npm; a
folder's `package.json` was read leniently when the folder was read, for its
version). A package given by its directory reads it leniently (`lenientNpm`),
in every ecosystem: with `npm`, for what it declares and its version;
without, for its version only, when versions are checked ("Package
versions"). Explicit packages count as declared.

Only a package given by its directory is read leniently with `npm`, not one
found in a folder: so a folder doesn't change how a package that the npm
walk finds inside it is read, and folders stay conservative (R6,
`Haus.Packages.Folders`).
-/
def copyNpm (config : Config) (dir : Path) (owner : String) : M (Option NpmInfo) := do
  let given ← ask (·.given)
  if config.mode.npm && !given.any (fun g => g.byDir && g.dir == dir) then packageJsonOf dir owner
  else if config.mode.npm || config.checkVersions then lenientNpm dir owner
  else pure none

/-- The SHOULD check of "Package versions" (§13.3): the `package.json`'s version is the manifest's. -/
def checkVersion (config : Config) (m : Manifest) (npm : Option NpmInfo) (owner : String) : M Unit := do
  if config.checkVersions then
    if let some v := npm.bind (·.version) then
      if v != m.version then
        let shown := if isSemver v then quote v else "a version that isn't a semantic version"
        fail .packageVersion s!"the package.haus of {owner} says version {quote m.version}, its package.json {shown}"

/-- An import of a file. -/
def Import.isFile (i : Import) : Bool := i.module matches .file _

/-- A package imports packages, never files: checked before anything is looked for. -/
def checkNoFiles (m : Manifest) (s : Scanned) : M Unit := do
  if let some i := s.imports.find? Import.isFile then
    fail .packagePath s!"the schema of {m.name} imports the file {i.module.show}; a package imports only packages, by name"

def load (w : Walk) : Nat → Target → M Loaded
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, .file p => do
    match (← get).files.lookup p with
    | some (some ts) => return { types := ts }
    | some none => fail .importCycle s!"{showPath p} imports itself, directly or not"
    | none => pure ()
    modify fun s => { s with files := (p, none) :: s.files }
    let config ← cfg
    let limit := config.limits.schemaFile
    let bytes ← openFile p limit fun size =>
      ⟨.fileTooLarge, s!"{showPath p} has {size} bytes, more than {limit}; it is not read"⟩
    countFile (showPath p)
    let s ← decodeScan bytes (showPath p)
    noteImports s.imports.length
    for imp in w.order s.imports do
      let _ ← resolveImport (load w n) (.app p) imp
    modify fun st => { st with files := (p, some s.types) :: st.files, finished := addNew st.finished (.file p) }
    return { types := s.types }
  | n + 1, .copy dir => do
    match (← get).copies.lookup dir with
    | some (.done c) => return { types := (← get).classes.list[c]!.types, cls := some c }
    | some .loading => fail .importCycle s!"the package in {showPath dir} imports itself, directly or not"
    | none => pure ()
    modify fun s => { s with copies := (dir, .loading) :: s.copies }
    let config ← cfg
    let some m ← manifestOf dir (showPath dir)
      | fail .importNotFound s!"{showPath dir} has no package.haus"
    let owner := s!"{m.name} ({showPath dir})"
    let npm ← copyNpm config dir owner
    checkVersion config m npm owner
    let some bytes ← openPackageFile dir "schema.haus" config.limits.schemaFile .fileTooLarge owner
      | fail .importNotFound s!"{owner} has no schema.haus"
    countFile s!"the schema.haus of {owner}"
    let s ← decodeScan bytes s!"the schema.haus of {owner}"
    noteImports s.imports.length
    checkNoFiles m s
    let mut targets : List Nat := []
    for imp in w.order s.imports do
      if let some c ← resolveImport (load w n) (.pkg dir m.name npm) imp then targets := targets ++ [c]
    let c ← classify { name := m.name, version := m.version, manifest := m.bytes, schema := bytes,
                       imports := targets, types := s.types, dir }
    modify fun st => { st with copies := (dir, .done c) :: st.copies, finished := addNew st.finished (.copy dir) }
    return { types := s.types, cls := some c }

/-! ## The explicit packages, and the whole -/

/--
The version check of a package in a folder (§13.3), when versions are
checked: its `package.json`, read leniently, gives no other version than its
manifest `m`. If it does, the subdirectory is skipped.
-/
def folderVersion (config : Config) (m : Manifest) (sub : Path) (shown : String) : M Unit := do
  if config.checkVersions then checkVersion config m (← lenientNpm sub shown) shown

/--
Reads the manifests of the packages given explicitly (§13.3), at the start.
A subdirectory of a folder whose manifest can't be read or breaks the rules,
or (when versions are checked) whose `package.json` gives another version,
is skipped, not rejected: it is named in `broken`, by the last name of the
folder's real path and its own (`schemas/broken`), however the folder was given.
-/
def givenPackages : M (List Given × List String) := do
  let config ← cfg
  let mut given : List Given := []
  let mut broken : List String := []
  for d in config.mode.packages do
    let real ← match ← look (·.realPath d) with
      | .ok r => if ← look (·.isDir r) then pure r else fail .importNotFound s!"the package directory {showPath d} given is not a directory"
      | .error _ => fail .importNotFound s!"the package directory {showPath d} given doesn't exist"
    let some m ← manifestOf real (showPath d)
      | fail .importNotFound s!"the package directory {showPath d} given has no package.haus"
    given := given ++ [{ dir := real, shown := showPath d, name := m.name, byDir := true }]
  for f in config.mode.folders do
    let real ← match ← look (·.realPath f) with
      | .ok r => if ← look (·.isDir r) then pure r else fail .importNotFound s!"the folder of packages {showPath f} given is not a directory"
      | .error _ => fail .importNotFound s!"the folder of packages {showPath f} given doesn't exist"
    let names ← look (·.list real)
    if names.length > config.limits.folderEntries then
      fail .tooManyFiles s!"the folder of packages {showPath f} has {names.length} entries, more than {config.limits.folderEntries}"
    for n in names.mergeSort (· ≤ ·) do
      let shown := showPath (real.getLast?.toList ++ [n])
      let .ok sub ← look (·.realPath (real ++ [n])) | continue
      if !(← look (·.isDir sub)) || (← look (·.childKind? sub "package.haus")).isNone then continue
      try
        if let some m ← manifestOf sub shown then
          folderVersion config m sub shown
          given := given ++ [{ dir := sub, shown, name := m.name, byDir := false }]
      catch _ => broken := broken ++ [shown]
  return (given, broken)

/-- The packages reached, as `name@version`, sorted. -/
def packagesOf (cs : List Class) : List String :=
  (cs.map fun c => c.name ++ "@" ++ c.version).mergeSort (· ≤ ·)

/-- The result of `resolveIn`, with the files read and the packages (classes) reached. -/
structure Outcome where
  result : Except Err (List String)
  reads : List Path
  /-- The packages made, also when an error ended the run. -/
  classes : Classes

/-- The outcome of a run: on success, the packages made. -/
def Outcome.of (p : Except Err Unit × St) : Outcome :=
  ⟨p.1.map fun _ => packagesOf p.2.classes.list, p.2.reads, p.2.classes⟩

/--
The build's root (§13.3, "The root"), for the entry file `root` whose real
path is `real`: the directory of `real`, or the real path of the `root`
option, which must be a directory that contains `real`.
-/
def baseRes (t : Tree) (option : Option Path) (root real : Path) : Except Err Path :=
  match option with
  | none => .ok real.dropLast
  | some r =>
    match t.realPath r with
    | .ok rr =>
      if t.isDir rr && rr.isPrefixOf real then .ok rr
      else .error ⟨.importOutsideRoot, s!"the schema file {showPath root} is not inside the root {showPath r} given"⟩
    | .error _ => .error ⟨.importNotFound, s!"the root {showPath r} given doesn't exist"⟩

/-- `baseRes` in the run: the tree and the `root` option of the settings. -/
def baseOf (root real : Path) : M Path := do
  let option := (← cfg).root
  match ← look (baseRes · option root real) with
  | .ok b => pure b
  | .error e => throw e

/-- The whole run: the explicit packages, then the schema file `root` and everything it imports. -/
def main (root : Path) (w : Walk := .file) : M Unit := do
  let (given, broken) ← givenPackages
  withReader (fun e => { e with given, broken }) do
    let real ← match ← look (·.realPath root) with
      | .ok r => pure r
      | .error _ => fail .importNotFound s!"the schema file {showPath root} doesn't exist"
    if (← look (·.kindAt? real)) != some .file then
      fail .importNotFound s!"the schema file {showPath root} is not a regular file"
    let base ← baseOf root real
    let fuel := (← cfg).limits.files + 1
    let _ ← withReader (fun e => { e with base }) (load w fuel (.file real))

/--
Loads the schema file `root` of `tree` and everything it imports. On success,
every package reached, as `name@version`, sorted.
-/
def resolveIn (tree : Tree) (config : Config) (root : Path) (w : Walk := .file) : Outcome :=
  Outcome.of ((((main root w).run { tree, config }).run).run {})

end Haus.Packages
