/-!
# A file-system model (spec §13.3)

The file tree that schema packages are resolved in: directories, regular
files, symbolic links and other files (a FIFO, a device). A tree is a finite
map from absolute paths to entries; the root `[]` is always a directory.

What the resolver may do with it is only what an operating system offers:

- `child?`: look a name up in a directory, without following a link (as
  `lstat`). A name is found only if the directory lists it, spelled the
  same: the model has no case folding or Unicode normalisation, so this is
  the rule "each name in the path MUST be spelled as its directory lists
  it" of §13.3, which a binding on such a file system has to check itself.
- `realPath`: a path with every symbolic link, `.` and `..` resolved (as
  `realpath(3)`), following at most `maxLinks` links, so that a cycle of
  links ends (`ELOOP`).
- `list`: a directory's names, exactly as stored.
- reading a regular file's bytes, through the resolver's monad
  (`Haus.Packages.Resolve`), which records every path it reads, so that
  what the resolver reads can be stated and proven (R7).

Paths are lists of names. A link's target is text, relative to the link's
directory, or absolute (from the model's root) when it starts with `/`.
-/

namespace Haus.Packages

/-- An absolute path: the names from the root, `[]` being the root. -/
abbrev Path := List String

/-- What is at a path. -/
inductive Entry where
  | dir
  /-- A regular file and its bytes. -/
  | file (bytes : List UInt8)
  /-- A symbolic link and its target, as written (`ln -s target`). -/
  | link (target : String)
  /-- Anything else: a FIFO, a socket, a device. Never read: opening a FIFO blocks. -/
  | other
  deriving Repr, DecidableEq, Inhabited

/-- A finite file tree: each path present, with its entry. Paths not listed don't exist. -/
structure Tree where
  entries : List (Path × Entry)
  deriving Repr, Inhabited

/-- A path as text, `/` between names (the root is `.`). -/
def showPath (p : Path) : String := if p.isEmpty then "." else "/".intercalate p

/-- The names of a path written with `/`; empty names (from `//` or a final `/`) are dropped. -/
def splitPath (s : String) : List String := (s.splitOn "/").filter (· ≠ "")

namespace Tree

/-- The entry at a path, the root being a directory. Links are not followed. -/
def get? (t : Tree) (p : Path) : Option Entry :=
  if p.isEmpty then some .dir else (t.entries.find? (·.1 == p)).map (·.2)

/-- The names a directory lists, as stored, in the order they were made. -/
def list (t : Tree) (d : Path) : List String :=
  t.entries.filterMap fun (p, _) => if p.dropLast == d && p.length == d.length + 1 then p.getLast? else none

/--
The entry `name` in the directory `d`, not following a link (`lstat`). The
name must be one the directory lists, spelled exactly the same.
-/
def child? (t : Tree) (d : Path) (name : String) : Option Entry :=
  if name ∈ t.list d then t.get? (d ++ [name]) else none

end Tree

/-- Why a path has no real path. -/
inductive Fault where
  /-- A name isn't there (also: a dangling link). -/
  | missing
  /-- A name follows a file that isn't a directory. -/
  | notDir
  /-- More than `maxLinks` links (a cycle of links). -/
  | loop
  deriving Repr, DecidableEq

/-- How many links a path may pass through (Linux's `MAXSYMLINKS`). -/
def maxLinks : Nat := 40

/-- Where a link's target starts: the root for `/…`, else the link's directory. -/
def linkBase (target : String) (dir : Path) : Path := if target.startsWith "/" then [] else dir

/--
Resolves the names `rest` from the directory `cur` (a real path), following
links with `fuel` left. `..` at the root stays at the root.
-/
def resolve (t : Tree) (fuel : Nat) (cur : Path) (rest : List String) : Except Fault Path :=
  match rest with
  | [] => .ok cur
  | c :: rest =>
    if c == "." || c == "" then resolve t fuel cur rest
    else if c == ".." then resolve t fuel cur.dropLast rest
    else match t.child? cur c with
      | none => .error .missing
      | some .dir => resolve t fuel (cur ++ [c]) rest
      | some (.link target) =>
        match fuel with
        | 0 => .error .loop
        | fuel + 1 => resolve t fuel (linkBase target cur) (splitPath target ++ rest)
      | some _ => if rest.isEmpty then .ok (cur ++ [c]) else .error .notDir
termination_by (fuel, rest.length)

/-- The real path of `p` (`realpath(3)`): no links, no `.` or `..`. -/
def Tree.realPath (t : Tree) (p : Path) : Except Fault Path := resolve t maxLinks [] p

/-- The entry at a real path, or none. -/
def Tree.at? (t : Tree) (p : Path) : Option Entry :=
  match p.getLast?, p.dropLast with
  | some n, d => t.child? d n
  | none, _ => some .dir

/--
Whether the entry at `p` itself is there, as `lstat` sees it: its directory
resolves, and lists its last name. A dangling link is there.
-/
def Tree.present (t : Tree) (p : Path) : Bool :=
  match p.getLast?, t.realPath p.dropLast with
  | some n, .ok d => (t.child? d n).isSome
  | _, _ => false

/--
Whether a place of the npm walk whose real path failed with `f` stops the
walk (§13.3): it is there but can't be followed (a dangling link), or a cycle
of links is on its way. Only a place that isn't there lets the walk go on.
-/
def Tree.stops (t : Tree) (p : Path) (f : Fault) : Bool := f == .loop || t.present p

/-- The directories from `d` up to the root, nearest first. -/
def ancestors (d : Path) : List Path := (List.range (d.length + 1)).reverse.map d.take

#guard ancestors ["a", "b"] = [["a", "b"], ["a"], []]

/-- Whether a real path is a directory. -/
def Tree.isDir (t : Tree) (p : Path) : Bool := t.at? p == some .dir

/--
Whether the directory `d` can be listed. The model has no permissions, so
every directory can: this names the case so that the checks that need a
listing say what they do without one (§13.3, "Spelling" and "Imports"). A
binding's directory that can't be listed (`EACCES`) shows no name, and the
check of a relative import's target for a package's directory fails closed
on it (`Haus.Packages.inPackage`), as the npm walk does on a directory on
its way up (`Haus.Packages.npmLookup`); the suite's cases with a `Mode`
entry, which the reference doesn't run, test that.
-/
def Tree.listable (_t : Tree) (_d : Path) : Bool := true

/--
An entry without a file's bytes: what `lstat` tells about it. Everything the
resolver learns about the tree, except the bytes of the files it opens, is
told in kinds, so that the bytes of a file it doesn't open can't matter (R7).
-/
inductive Kind where
  | dir
  | file
  | link (target : String)
  | other
  deriving Repr, DecidableEq, Inhabited

def Entry.kind : Entry → Kind
  | .dir => .dir
  | .file _ => .file
  | .link target => .link target
  | .other => .other

/-- The kind of the entry `name` in the directory `d`, not following a link (`lstat`). -/
def Tree.childKind? (t : Tree) (d : Path) (name : String) : Option Kind := (t.child? d name).map Entry.kind

/-- The kind of the entry at a real path. -/
def Tree.kindAt? (t : Tree) (p : Path) : Option Kind := (t.at? p).map Entry.kind

section Examples

private def ex : Tree := ⟨[
  (["a"], .dir), (["a", "f.txt"], .file [104, 105]),
  (["a", "up"], .link ".."), (["a", "loop"], .link "loop"),
  (["a", "dangling"], .link "../missing"),
  (["b"], .link "a/up/a")]⟩

#guard (ex.realPath ["a", "f.txt"]).toOption == some ["a", "f.txt"]
#guard (ex.realPath ["b", "f.txt"]).toOption == some ["a", "f.txt"]
#guard (ex.realPath ["a", "up", "a", "up", "b"]).toOption == some ["a"]
#guard (match ex.realPath ["a", "loop"] with | .error f => f == .loop | .ok _ => false)
#guard (match ex.realPath ["a", "dangling"] with | .error f => f == .missing | .ok _ => false)
#guard (match ex.realPath ["a", "f.txt", "x"] with | .error f => f == .notDir | .ok _ => false)
#guard (match ex.realPath ["A", "f.txt"] with | .error f => f == .missing | .ok _ => false)
#guard ex.list ["a"] = ["f.txt", "up", "loop", "dangling"]
#guard ex.present ["a", "dangling"] && ex.present ["a", "loop"] && !ex.present ["a", "missing"]
#guard !ex.present ["c", "x"] && ex.stops ["a", "dangling"] .missing && !ex.stops ["c", "x"] .missing

end Examples

end Haus.Packages
