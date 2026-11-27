import Haus.Packages.Resolve
import Haus.Packages.Official
import Haus.SchemaFile.Parse

/-!
# Package rules and compiling with packages (packages.md §3, §4, §6, §7)

`compile tree config root program` is what a binding's compile does with the
packages it is given, on top of the resolver (`resolveIn`, which is not
changed, so its proofs hold as they are):

1. **The built-in official packages** (packages.md §3) are part of every
   compile: `withOfficial` writes them into the tree and gives them by their
   directory. A package given to the compile (by its directory, or in a
   folder) whose name is an official package's must be byte for byte the
   built-in one, its `package.haus` and `schema.haus`, else
   `duplicate-package` (`officialCopies`), whether a schema imports it or not.
2. **Resolution**, as before: the packages the schema reaches, or the first
   error.
3. **The `rules` field** (packages.md §4) of every package the schema
   reaches (`checkRules`): a record from type names to rule names
   (`[a-z][a-z0-9-]*`), each type defined in the package's `schema.haus`
   without parameters and not as a `Stream`, and, for a package read from a
   directory, a regular file `rules/<name>.md` for each rule; else
   `package-manifest`. A built-in package is a value: it has no files to look
   at.
4. **`missing-codec`** (packages.md §7): every type with a rule that the
   schema reaches (`reachedTypes`: from the definitions of the application's
   schema files, through the types their definitions name, across imports)
   must have an implementation of that rule in the program, unless the
   program takes the package shape-only (`Program.shapeOnly`). The program
   has the rules of the built-in packages (a library implements every rule of
   the official packages it has built in) and those it supplies
   (`Program.withRule`, type ids). Reported once per type id, at no place;
   here, the first.

The checks of 3 and 4 run after resolution has succeeded: with one mistake
in a case, the order among them doesn't matter, and the resolver and its
proofs stay as they are. A binding reports them during its compile.
-/

namespace Haus.Packages

/-- What the program brings to a compile beyond its sources and packages (packages.md §7). -/
structure Program where
  /-- Packages taken shape-only (`Package.shapeOnly`), by name: their rules aren't checked. -/
  shapeOnly : List String := []
  /-- Type ids (`@acme/ids@1#Id`) whose package's rule the program implements (`Package.withRule`). -/
  withRule : List String := []
  deriving Repr, Inhabited

/-- A rule's name: `[a-z][a-z0-9-]*` (packages.md §4). -/
def isRuleName (s : String) : Bool :=
  match s.toList with
  | c :: cs => ('a' ≤ c && c ≤ 'z') && cs.all fun d => isLowerAlnum d || d == '-'
  | [] => false

#guard isRuleName "iso" && isRuleName "wgs84" && isRuleName "iso-4217"
#guard !isRuleName "" && !isRuleName "Iso" && !isRuleName "4217" && !isRuleName "iso_4217" && !isRuleName "-iso"

/--
The `rules` field of a valid manifest's text (packages.md §4): its pairs of a
type and a rule, in order (none without the field), or why it breaks the
field's rules.
-/
def rulesField (manifest : List UInt8) : Except String (List (String × String)) :=
  match utf8 manifest with
  | none => .error "is not valid UTF-8"
  | some t =>
    match Parser.parse {} t with
    | .ok [.record fs] =>
      match fs.lookup "rules" with
      | none => .ok []
      | some (.record rs) => rs.mapM fun (ty, v) =>
        match v with
        | .str r =>
          if isRuleName r then .ok (ty, r)
          else .error s!"names the rule \"{msgText r}\" for \"{msgText ty}\", which is not a rule name ([a-z][a-z0-9-]*)"
        | _ => .error s!"gives \"{msgText ty}\" a rule that is not a string"
      | some _ => .error "has a rules field that is not a record"
    | _ => .error "is not one record"

/-- The definitions of a package's `schema.haus`, or none if the full schema-file reader rejects it. -/
def definitions (schema : List UInt8) : Option (List Haus.SchemaFile.Def) :=
  match utf8 schema with
  | none => none
  | some t => match Haus.SchemaFile.parse t with
    | .ok p => some p.defs
    | .error _ => none

/-- The type id of a package's type: `@acme/ids@1#Id` (core §13.3). -/
def typeIdOf (c : Class) (ty : String) : String := s!"{c.name}@{majorOf c.version}#{ty}"

/-- How a reached package is shown in messages: its name, and its directory unless it is built in. -/
def Class.owner (c : Class) : String :=
  if isBuiltInDir c.dir then s!"{c.name} (built in)" else s!"{c.name} ({showPath c.dir})"

/-- The checks of the `rules` field of one reached package (step 3): its rules, or the error. -/
def checkRulesField (tree : Tree) (c : Class) : Except Err (List (String × String)) := do
  let bad (why : String) : Err := ⟨.packageManifest, s!"the package.haus of {c.owner} {why}"⟩
  let rules ← (rulesField c.manifest).mapError bad
  if rules.isEmpty then return []
  let some defs := definitions c.schema
    | throw (bad "has rules, and its schema.haus can't be read for its definitions")
  for (ty, r) in rules do
    match defs.find? (·.name == ty) with
    | none => throw (bad s!"gives the rule {r} to \"{msgText ty}\", which its schema.haus doesn't define")
    | some d =>
      if !d.params.isEmpty then throw (bad s!"gives the rule {r} to {ty}, which takes parameters")
      if d.stream then throw (bad s!"gives the rule {r} to {ty}, which is a Stream")
    -- A package read from a directory has each rule's prose; a built-in one is a value.
    if !isBuiltInDir c.dir then
      if tree.childKind? c.dir "rules" != some .dir || tree.childKind? (c.dir ++ ["rules"]) (r ++ ".md") != some .file then
        throw (bad s!"names the rule {r}, and has no regular file rules/{r}.md")
  return rules

/-- Whether the program implements the rule of the type id `id`: built in for the official packages, or supplied. -/
def Program.implements (p : Program) (c : Class) (id : String) : Bool :=
  isBuiltInDir c.dir || p.withRule.contains id

/-! ## The types a schema reaches -/

/-- A schema file of the compile: an application's file, by its real path, or a package's `schema.haus`, by the package's name. -/
inductive Unit_ where
  | file (p : Path)
  | pkg (name : String)
  deriving DecidableEq, Repr, Inhabited

/-- A schema file's definitions and imports, read with the full schema-file reader. -/
structure Unit_.Info where
  defs : List Haus.SchemaFile.Def
  imports : List Haus.SchemaFile.Import

def infoOf (bytes : List UInt8) : Option Unit_.Info :=
  match utf8 bytes with
  | none => none
  | some t => match Haus.SchemaFile.parse t with
    | .ok p => some ⟨p.defs, p.imports⟩
    | .error _ => none

/-- The schema file an import names, from a file in the directory `dir` (a real path): a package by its name, a file by its path. -/
def importTarget (dir : Path) (module : String) : Option Unit_ :=
  if module.startsWith "@" then
    -- `@org/name` or `@org/name@N`: the name is what comes before a second `@`.
    match (module.drop 1).toString.splitOn "@" with
    | n :: _ => some (.pkg ("@" ++ n))
    | [] => none
  else if module.startsWith "./" || module.startsWith "../" then
    let comps := splitPath module
    let ups := (comps.takeWhile (· == "..")).length
    let down := (comps.drop ups).filter (· != ".")
    match down.getLast? with
    | some last => some (.file ((dir.take (dir.length - ups)) ++ down.dropLast ++ [last ++ ".schema.haus"]))
    | none => none
  else none

/--
The types the schema reaches (packages.md §7): starting from every
definition of the application's schema files (`files`, real paths), the
types each definition names, in its own file or through its file's imports,
and so on into the packages. As pairs of a schema file and a type's name.
-/
def reachedTypes (tree : Tree) (files : List Path) (classes : List Class) : List (Unit_ × String) := Id.run do
  let infoAt (u : Unit_) : Option Unit_.Info :=
    match u with
    | .file p => match tree.at? p with
      | some (.file bs) => infoOf bs
      | _ => none
    | .pkg n => (classes.find? (·.name == n)).bind (infoOf ·.schema)
  let dirOf (u : Unit_) : Path := match u with
    | .file p => p.dropLast
    | .pkg _ => []
  let mut reached : List (Unit_ × String) := []
  let mut todo : List (Unit_ × String) := files.flatMap fun p =>
    ((infoAt (.file p)).map (·.defs.map fun d => (Unit_.file p, d.name))).getD []
  -- Each round adds at least one pair or ends; there are finitely many definitions.
  let bound := (files.length + classes.length) * 4096 + 1
  for _ in [0:bound] do
    match todo with
    | [] => break
    | (u, n) :: rest =>
      todo := rest
      if reached.contains (u, n) then continue
      let some info := infoAt u | continue
      let some d := info.defs.find? (·.name == n) | continue
      reached := reached ++ [(u, n)]
      for (m, _) in Haus.SchemaFile.Tm.refsList [d.body] do
        if info.defs.any (·.name == m) then todo := todo ++ [(u, m)]
        else if let some imp := info.imports.find? (·.names.contains m) then
          if let some v := importTarget (dirOf u) imp.module then todo := todo ++ [(v, m)]
  return reached

#guard importTarget ["app"] "@acme/ids@1" == some (.pkg "@acme/ids")
#guard importTarget ["app"] "@acme/ids" == some (.pkg "@acme/ids")
#guard importTarget ["app", "x"] "../common" == some (.file ["app", "common.schema.haus"])
#guard importTarget ["app"] "./lib/a" == some (.file ["app", "lib", "a.schema.haus"])
#guard importTarget ["app"] "std/time" == none

section Examples

private def file (p : String) (text : String) : Path × Entry := (splitPath p, .file text.toUTF8.toList)
private def pkgClass (name schema : String) : Class :=
  { name, version := "1.0.0", manifest := [], schema := schema.toUTF8.toList, imports := [], types := [], dir := [] }

private def exTree : Tree := ⟨[(["app"], .dir),
  file "app/app.schema.haus" "import @acme/codes@1 (Label)\nimport ./common (Box)\ntype Root = { label: Label, box: Box }",
  file "app/common.schema.haus" "import @acme/codes (Wrap)\ntype Box = Wrap Int"]⟩
private def exClasses : List Class :=
  [pkgClass "@acme/codes" "type Code = < >\ntype Label = String\ntype Wrap a = { code: Code, x: a }"]
private def exReached := reachedTypes exTree [["app", "app.schema.haus"], ["app", "common.schema.haus"]] exClasses

-- `Label` is reached, and `Code` through the generic `Wrap` that `Box` uses; a type nobody names is not.
#guard exReached.contains (.pkg "@acme/codes", "Label")
#guard exReached.contains (.pkg "@acme/codes", "Code")
#guard !exReached.contains (.pkg "@acme/codes", "Other")
-- Through the relative import too, starting from the entry file alone.
#guard (reachedTypes exTree [["app", "app.schema.haus"]] exClasses).contains (.pkg "@acme/codes", "Code")
-- A schema that names only `Label` doesn't reach `Code`.
#guard !(reachedTypes ⟨[(["app"], .dir), file "app/a.schema.haus" "import @acme/codes (Label)\ntype Root = Label"]⟩
  [["app", "a.schema.haus"]] exClasses).contains (.pkg "@acme/codes", "Code")

end Examples

/-- Steps 3 and 4 on the packages a schema reached (`classes`), the application's schema files being `files`: the first error, if any. -/
def checkRules (tree : Tree) (files : List Path) (classes : List Class) (p : Program) : Option Err := Id.run do
  -- Every package's field first: a broken manifest is reported before a rule that is missing.
  let mut all : List (Class × List (String × String)) := []
  for c in classes do
    match checkRulesField tree c with
    | .error e => return some e
    | .ok rules => all := all ++ [(c, rules)]
  let reached := reachedTypes tree files classes
  for (c, rules) in all do
    if p.shapeOnly.contains c.name then continue
    for (ty, r) in rules do
      let id := typeIdOf c ty
      -- Only a type the schema reaches counts: a rule on a type nothing decodes lets nothing through.
      if reached.contains (.pkg c.name, ty) && !p.implements c id then
        return some ⟨.missingCodec, s!"{id} has the rule {r} ({c.owner}), and this program has no implementation of it: add the package's rule (withRule), or take the package shape-only (shapeOnly)"⟩
  return none

/--
Step 1: a package given to the compile whose name is an official package's
must be byte for byte the built-in one. Reads the given packages as the
resolver does (`givenPackages`); an error there is left to the resolver.
-/
def officialCopies (tree : Tree) (config : Config) : Option Err :=
  match (((givenPackages.run { tree, config }).run).run {}).1 with
  | .error _ => none
  | .ok (given, _) => given.findSome? fun g =>
    match official.find? (·.name == g.name) with
    | none => none
    | some b =>
      let same (file text : String) := tree.at? (g.dir ++ [file]) == some (.file text.toUTF8.toList)
      if same "package.haus" b.manifest && same "schema.haus" b.schema then none
      else some ⟨.duplicatePackage, s!"{g.shown} is a copy of {b.name} that differs from the one built in; an official package can't be replaced"⟩

/-- The configuration of a compile: the built-in packages first, given by their directory. -/
def Config.withOfficial (config : Config) : Config :=
  { config with mode := { config.mode with packages := official.map (·.path) ++ config.mode.packages } }

/--
A compile with packages (steps 1–4): on success the packages reached, as
`name@version`, sorted, the built-in ones among them when reached.
-/
def compile (tree : Tree) (config : Config) (root : Path) (p : Program := {}) (w : Walk := .file) : Outcome :=
  match officialCopies tree config with
  | some e => ⟨.error e, [], .empty⟩
  | none =>
    let tree := withOfficial tree
    let o := resolveIn tree config.withOfficial root w
    match o.result with
    | .error _ => o
    | .ok _ =>
      -- The application's schema files: those read whose name ends in `.schema.haus` (a package's is `schema.haus`).
      let files := o.reads.filter fun r => r.getLast?.any (·.endsWith ".schema.haus")
      match checkRules tree files o.classes.list p with
      | some e => { o with result := .error e }
      | none => o

end Haus.Packages
