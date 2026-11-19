import Haus.Packages.Suite

/-!
# Order of imports (R3, security review F4): what is and isn't proven

**Not proven** (R3): that the result doesn't depend on the order of a file's
imports or of the walk. The spec intends that on success the packages are
the same and that success or failure is the same; it does not fix *which*
error is reported when a schema has two mistakes, and the resolver reports
the first one it meets, so the error code does depend on the order
(`twoMistakes` below). The proof would relate two runs that load the same
targets in different orders, with class numbers that differ between them:
that a successful run's last state is closed (every target loaded has its
checks passed and its imports loaded before it) and that a run in another
order stays below such a state. It is the same simulation that R6 (folders
are conservative) needs, and is left for later. A first step is proven in
`Haus.Packages.Closed`: in every state of every run, a class imports only
classes made before it (`classes_topo`), the order the simulation needs for
packages.

What R2 proves already holds in every order: one package per name, and a
copy is unified with another only when its files and its imports' packages
are the same (`addClass_same`), which is the fix of F4.

**Reads** (R4): the resolver as first written could read one file twice,
because its caches are kept by kind and a file can be of two kinds. A
project's `package.json` that is a link to a schema file was read once as
JSON and once as a schema file (`linkedPackageJson`), and a root that is a
`package.json` once as the root and once as the project's `package.json`.
`openFile` now never opens a path twice (`reads_nodup`).
-/

namespace Haus.Packages.Order

open Haus Haus.Packages Haus.Packages.Suite

private def file (p text : String) : Value := .variant "File" [.str p, .str text]
private def link (p target : String) : Value := .variant "Link" [.str p, .str target]
private def npm (dir : String) : Value := .variant "Npm" [.str dir, .record [("dependencies", .arr [])]]
private def pkg (dir name version schema : String) : Value := .variant "Package" [.str dir, .str name, .str version, .str schema]

private def run (files : List Value) (root : String) (mode : Mode) : Outcome :=
  match files.foldlM addFile [] with
  | .ok es => resolveIn ⟨es⟩ { mode } (splitPath root)
  | .error e => ⟨.error ⟨.outOfFuel, e⟩, [], .empty⟩

private def code (o : Outcome) : String :=
  match o.result with
  | .ok ps => s!"ok {ps}"
  | .error e => e.code.name

/-- Two mistakes in one file: a missing file and an undeclared package. Each order reports its first. -/
private def twoMistakes (first second : String) : Outcome :=
  run [npm "app", file "app/a.schema.haus" s!"{first}\n{second}\ntype R = X"] "app/a.schema.haus" { npm := true }

#guard code (twoMistakes "import ./missing (X)" "import @acme/x (Y)") == "import-not-found"
#guard code (twoMistakes "import @acme/x (Y)" "import ./missing (X)") == "undeclared-package"

/-- A project's `package.json` that is a link to a schema file the root imports: opened once. -/
private def linkedPackageJson : Outcome :=
  run [link "app/package.json" "x.schema.haus",
    file "app/a.schema.haus" "import ./x (X)\nimport @acme/c (C)\ntype R = X",
    file "app/x.schema.haus" "type X = Int",
    pkg "vendor/c" "@acme/c" "1.0.0" "type C = Int"] "app/a.schema.haus" { npm := true, folders := [["vendor"]] }

#guard code linkedPackageJson == "ok [@acme/c@1.0.0]"
#guard linkedPackageJson.reads.count ["app", "x.schema.haus"] == 1

/-- A root that is a project's `package.json`: opened once. -/
private def rootPackageJson : Outcome :=
  run [file "app/package.json" "import ./x (X)\ntype R = X",
    file "app/x.schema.haus" "import @acme/c (C)\ntype X = C",
    pkg "vendor/c" "@acme/c" "1.0.0" "type C = Int"] "app/package.json" { npm := true, folders := [["vendor"]] }

#guard code rootPackageJson == "ok [@acme/c@1.0.0]"
#guard rootPackageJson.reads.count ["app", "package.json"] == 1

end Haus.Packages.Order
