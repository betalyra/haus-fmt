import Haus.Packages.Resolve
import Haus.Canonical

/-!
# The package suite (`test-suite/packages/cases.haus`)

Each `Case` (format in `test-suite/README.md`, "Package suite") becomes a
`Tree`, with no real file system: `File`, `Package`, `Npm` and `Link` map to
entries (parent directories made as needed), the tree's root being the
adapter's empty temporary directory. `Package(dir, name, version, schema)`
writes `dir/package.haus` as the record `{ name, version }` in canonical
form, and `Npm(dir, {…})` writes `dir/package.json` with each dependency
list as an object from the names to `"*"`.

`check` runs the resolver on a case and compares it with `expect`: the
packages on `Ok`; on `Err`, the code, and the message must contain each of
`mentions` and none of `hides`. It also checks two things the suite can't
see: every file read is a `package.haus`, `schema.haus`, `package.json` or a
file whose real path ends in `.schema.haus` (R7's read set), and no file is
read twice (§13.3).
-/

namespace Haus.Packages.Suite

open Haus

inductive Expect where
  | ok (packages : List String)
  | err (code : String) (mentions hides : List String)
  deriving Repr, Inhabited

structure Case where
  name : String
  tree : Tree
  root : Path
  mode : Mode
  should : Bool
  expect : Expect
  deriving Inhabited

abbrev D := Except String

def field (fs : List (String × Value)) (k : String) : Option Value := fs.lookup k

def str : Value → D String
  | .str s => .ok s
  | v => .error s!"expected a string, found {repr v}"

def strs : Option Value → D (List String)
  | none => .ok []
  | some (.arr vs) => vs.mapM str
  | some v => .error s!"expected a list of strings, found {repr v}"

def bytesOf (s : String) : List UInt8 := s.toUTF8.toList

/-- Adds `e` at `p`, with its parent directories. Fails if a parent is not a directory. -/
def put (es : List (Path × Entry)) (p : Path) (e : Entry) : D (List (Path × Entry)) := do
  let mut es := es
  for i in [1:p.length] do
    let q := p.take i
    match es.lookup q with
    | none => es := es ++ [(q, .dir)]
    | some .dir => pure ()
    | some _ => throw s!"{showPath q} is not a directory"
  return (es.filter (·.1 != p)) ++ [(p, e)]

def packageJson (fs : List (String × Value)) : D String := do
  let mut ms : List (String × JSON) := []
  for (k, v) in fs do
    if k == "name" || k == "version" then ms := ms ++ [(k, .str (← str v))]
    else ms := ms ++ [(k, .obj ((← strs (some v)).map fun n => (n, .str "*")))]
  return String.ofList (JSON.write (.obj ms))

def addFile (es : List (Path × Entry)) : Value → D (List (Path × Entry))
  | .variant "File" [.str p, .str text] => put es (splitPath p) (.file (bytesOf text))
  | .variant "Link" [.str p, .str target] => put es (splitPath p) (.link target)
  | .variant "Package" [.str dir, .str name, .str version, .str schema] => do
    let manifest := String.ofList (Canonical.canonical (.record [("name", .str name), ("version", .str version)]))
    let es ← put es (splitPath dir ++ ["package.haus"]) (.file (bytesOf manifest))
    put es (splitPath dir ++ ["schema.haus"]) (.file (bytesOf schema))
  | .variant "Npm" [.str dir, .record fs] => do
    put es (splitPath dir ++ ["package.json"]) (.file (bytesOf (← packageJson fs)))
  | v => .error s!"not a file: {repr v}"

def mode : Value → D Mode
  | .variant "Explicit" [.record fs] => do
    pure { npm := false, packages := (← strs (field fs "packages")).map splitPath,
           folders := (← strs (field fs "folders")).map splitPath }
  | .variant "Npm" [] => pure { npm := true }
  | .variant "Npm" [.record fs] => do
    pure { npm := true, packages := (← strs (field fs "packages")).map splitPath,
           folders := (← strs (field fs "folders")).map splitPath }
  | v => .error s!"not a mode: {repr v}"

def expect : Value → D Expect
  | .variant "Ok" [.record fs] => do pure (.ok (← strs (field fs "packages")))
  | .variant "Err" [.record fs] => do
    let some code := field fs "code" | .error "Err without a code"
    pure (.err (← str code) (← strs (field fs "mentions")) (← strs (field fs "hides")))
  | v => .error s!"not an expected result: {repr v}"

def decode : Value → D Case
  | .variant "Case" [.record fs] => do
    let some (.str name) := field fs "name" | .error "a case without a name"
    let some (.arr files) := field fs "files" | .error s!"{name}: no files"
    let some (.str root) := field fs "root" | .error s!"{name}: no root"
    let some m := field fs "mode" | .error s!"{name}: no mode"
    let some e := field fs "expect" | .error s!"{name}: no expect"
    let tree ← files.foldlM addFile []
    pure { name, tree := ⟨tree⟩, root := splitPath root, mode := ← mode m,
           should := field fs "should" == some (.variant "True" []),
           expect := ← expect e }
  | v => .error s!"not a case: {repr v}"

def contains (s part : String) : Bool := (s.splitOn part).length > 1

def showResult : Except Err (List String) → String
  | .ok ps => s!"Ok {ps}"
  | .error e => s!"Err {e.code}: {e.message}"

/-- A read the resolver may make (R7): a package's three files, or a schema file. -/
def allowedRead (p : Path) : Bool :=
  match p.getLast? with
  | some n => n == "package.haus" || n == "schema.haus" || n == "package.json" || n.endsWith ".schema.haus"
  | none => false

/-- Runs a case: `none` if it passes, else why not. Also the outcome, for printing. -/
def check (c : Case) : Option String × Outcome :=
  let o := resolveIn c.tree { mode := c.mode } c.root
  let bad := o.reads.toList.filter (!allowedRead ·)
  let twice := o.reads.toList.filter fun p => o.reads.toList.count p > 1
  let verdict :=
    if !bad.isEmpty then some s!"read {bad.map showPath}"
    else if !twice.isEmpty then some s!"read twice: {twice.map showPath}"
    else match c.expect, o.result with
    | .ok want, .ok got => if want == got then none else some s!"expected Ok {want}, got Ok {got}"
    | .err code mentions hides, .error e =>
      if e.code.name != code then some s!"expected {code}, got {showResult o.result}"
      else match mentions.filter (!contains e.message ·), hides.filter (contains e.message ·) with
        | [], [] => none
        | missing, [] => some s!"the message doesn't mention {missing}: {e.message}"
        | _, shown => some s!"the message shows {shown}: {e.message}"
    | .ok want, .error _ => some s!"expected Ok {want}, got {showResult o.result}"
    | .err code _ _, .ok got => some s!"expected Err {code}, got Ok {got}"
  (verdict, o)

/-! ## What the suite can't express

FIFOs, cycles of links, the limits, and two checks that need no package. -/

section Examples

private def f (p : String) (text : String) : Value := .variant "File" [.str p, .str text]
private def pkg (dir name version schema : String) : Value := .variant "Package" [.str dir, .str name, .str version, .str schema]
private def lnk (p target : String) : Value := .variant "Link" [.str p, .str target]

/-- The code of the result of resolving `app/app.schema.haus` in the tree of `files` plus `extra`. -/
private def codeOf (files : List Value) (extra : List (Path × Entry) := []) (mode : Mode := { npm := false, packages := [["vendor", "common"]] })
    (limits : Limits := {}) : String :=
  match files.foldlM addFile [] with
  | .error e => s!"bad tree: {e}"
  | .ok es =>
    match (resolveIn ⟨es ++ extra⟩ { mode, limits } ["app", "app.schema.haus"]).result with
    | .ok ps => s!"ok {ps}"
    | .error e => e.code.name

private def app (text : String) : Value := f "app/app.schema.haus" text
private def common : Value := pkg "vendor/common" "@acme/common" "1.0.0" "type Address = { city: String }"

-- A FIFO as schema.haus is not opened (it would block).
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address",
  f "vendor/common/package.haus" "{ name: \"@acme/common\", version: \"1.0.0\" }"]
  [(["vendor", "common", "schema.haus"], .other)] == "package-path"
-- A FIFO named like a schema file, imported by an application file.
#guard codeOf [app "import ./x (X)\ntype Root = X"] [(["app", "x.schema.haus"], .other)] (mode := { npm := false }) == "import-not-found"
#guard codeOf [app "import ./x (X)\ntype Root = X", f "app/x.schema.haus" "type X = Int"] (mode := { npm := false }) == "ok []"
-- A cycle of links in node_modules ends, and is not a package.
#guard codeOf [.variant "Npm" [.str "app", .record [("dependencies", .arr [.str "@acme/common"])]],
  app "import @acme/common@1 (Address)\ntype Root = Address",
  lnk "app/node_modules/@acme/common" "common"] (mode := { npm := true }) == "import-not-found"
-- An application file importing itself, through a link.
#guard codeOf [app "import ./self (Root)", lnk "app/self.schema.haus" "app.schema.haus"] (mode := { npm := false }) == "import-cycle"
-- An imported type the package doesn't define.
#guard codeOf [app "import @acme/common@1 (Adress)\ntype Root = Adress", common] == "unknown-import"
-- The limits: schema files, their size, entries in a folder.
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address", common] (limits := { files := 1 }) == "too-many-files"
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address", common] (limits := { files := 2 }) == "ok [@acme/common@1.0.0]"
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address", common] (limits := { schemaFile := 20 }) == "file-too-large"
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address", common, f "vendor/README.md" ""]
  (mode := { npm := false, folders := [["vendor"]] }) (limits := { folderEntries := 1 }) == "too-many-files"
-- A manifest of more than 64 KiB.
#guard codeOf [app "import @acme/common@1 (Address)\ntype Root = Address", common] (limits := { manifest := 10 }) == "package-manifest"
-- A relative import of a file next to a package directory, whose name starts like it: not in the package.
#guard codeOf [app "import ../vendor/common-extra/x (X)\ntype Root = X", common, f "vendor/common-extra/x.schema.haus" "type X = Int"] == "ok []"

end Examples

end Haus.Packages.Suite
