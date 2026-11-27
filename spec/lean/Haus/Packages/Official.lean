import Haus.Packages.Fs

/-!
# The official packages, built in (packages.md §3)

Every library has the official packages built in, as values: their
`package.haus` and `schema.haus`, byte for byte the files of
`extensions/<name>/`, and an implementation of each rule their manifests
name. So does the reference: `official` holds their text, read from
`extensions/` when the model is built. The models of their rules are not
part of this library: they live with the packages
(`extensions/<name>/lean/`) and are run by `haus-rules`. What the package
model needs of them is only that the rules exist, which their manifests say.

Lake doesn't see the files `include_str` reads: after changing an official
package's files, rebuild this module (`lake build Haus.Packages.Official`
after touching it, or a clean build, as CI makes).
-/

namespace Haus.Packages

/-- An official package, as built into a library. -/
structure BuiltIn where
  /-- The manifest's name, `@haus-fmt/money`. -/
  name : String
  /-- The directory of its source, `extensions/<dir>/`. -/
  dir : String
  /-- The text of its `package.haus`. -/
  manifest : String
  /-- The text of its `schema.haus`. -/
  schema : String

def official : List BuiltIn := [
  { name := "@haus-fmt/money", dir := "money",
    manifest := include_str "../../../../extensions/money/package.haus",
    schema := include_str "../../../../extensions/money/schema.haus" },
  { name := "@haus-fmt/geo", dir := "geo",
    manifest := include_str "../../../../extensions/geo/package.haus",
    schema := include_str "../../../../extensions/geo/schema.haus" },
  { name := "@haus-fmt/uuid", dir := "uuid",
    manifest := include_str "../../../../extensions/uuid/package.haus",
    schema := include_str "../../../../extensions/uuid/schema.haus" }]

/--
Where a run puts the built-in packages in its tree, as packages given by
their directory: a directory no case of the suite uses. The bindings keep
them in memory; the model's resolver reads packages from a tree, so the
reference writes them there.
-/
def BuiltIn.path (b : BuiltIn) : Path := [".built-in", b.dir]

/-- The tree `t` with the built-in packages added. -/
def withOfficial (t : Tree) : Tree :=
  ⟨t.entries ++ [([".built-in"], .dir)] ++ official.flatMap fun b =>
    [(b.path, .dir), (b.path ++ ["package.haus"], .file b.manifest.toUTF8.toList),
     (b.path ++ ["schema.haus"], .file b.schema.toUTF8.toList)]⟩

/-- Whether a real path is the directory of a built-in package. -/
def isBuiltInDir (p : Path) : Bool := official.any (·.path == p)

end Haus.Packages
