import Haus.SchemaFile.Parse

/-!
# The static rules of schema files (spec §14)

`declare` turns what a file says (`Parsed`) into the definitions in scope
(`Source`), and `check` checks them: the rules of §14 that hold for a
file's definitions as written, before any generic type is applied.

* names: every type is defined, imported or the prelude's (`unknown-type`),
  with as many arguments as it has parameters (`wrong-arity`); every
  parameter is one of its definition's (`unknown-parameter`); `Stream` only as
  the whole of a definition, never referred to (`misplaced-stream`);
* definitions: none twice (`duplicate-type`), none of the prelude's
  (`redefine-prelude`), no parameter twice (`invalid-parameter`);
* spreads: of a named record into a record or a named variant into a variant,
  without parameters (`invalid-spread`), never of itself, directly or not
  (`spread-cycle`); no field or tag twice, those copied in included
  (`duplicate-field`, `duplicate-tag`);
* regular generics (§9.10, `growing-recursion`): a definition refers to
  itself only with its own parameters, and to another definition of its group
  (one that refers back to it, directly or not: `Source.reaches`) only with
  parameters of its own as arguments.

Guarded recursion (§9.9, `unguarded-recursion`) is checked on the instances
(`Haus.SchemaFile.Instances`): `type I a = a` with `type X = I X` is
unguarded, which only the instance `I X` shows.

`Haus.SchemaFile.Finite` proves what the last rule gives: from any type, a
checked file reaches finitely many instances of its generic types.
-/

namespace Haus.SchemaFile
open Haus

/-- An error of a schema file: its code (spec §17) and message. -/
structure Err where
  code : Code
  message : String
  deriving Repr

abbrev C := Except Err

def err {α : Type} (code : Code) (message : String) : C α := .error ⟨code, message⟩

/-- The first element that occurs twice. -/
def firstDup : List String → Option String
  | [] => none
  | x :: xs => if xs.contains x then some x else firstDup xs

/-! ## Declarations -/

/--
The definitions in scope: the file's own and the std/time types it imports.
Only `std/…` modules are found here; a package or another file needs package
resolution (`Haus.Packages`), which brings its definitions in as more
definitions (`import-unavailable` without it).
-/
def declare (p : Parsed) : C Source := do
  let mut std : List String := []
  for i in p.imports do
    if i.module.startsWith "std/" then
      if i.module != "std/time" then err .unknownModule s!"unknown module {i.module}: the standard modules are std/time"
      for n in i.names do
        if !(stdTime.any (·.1 == n)) then
          err .unknownImport s!"{i.module} has no type {n} (it has {", ".intercalate (stdTime.map (·.1))})"
        if std.contains n then err .duplicateImport s!"{n} is imported twice"
        std := std ++ [n]
    else err .importUnavailable s!"can't import {i.module}: no module resolver (only std modules are found here)"
  let mut seen : List String := []
  for d in p.defs do
    if seen.contains d.name then err .duplicateType s!"type {d.name} is defined twice"
    if std.contains d.name then err .duplicateType s!"type {d.name} is already imported"
    if preludeNames.contains d.name then err .redefinePrelude s!"{d.name} is a prelude type and can't be redefined"
    if let some p := firstDup d.params then err .invalidParameter s!"parameter {p} appears twice"
    seen := seen ++ [d.name]
  return { std, defs := p.defs }

/-! ## Which kids of a node are spreads -/

/-- For each kid of a node, whether it is a spread (`...Name`) rather than a type. -/
def Label.spreadKids : Label → List Bool
  | .record _ ms => ms.map fun | .spread => true | .field _ _ => false
  | .variant _ as => as.flatMap fun | .spread => [true] | .case _ n => List.replicate n false

/-! ## Names and arities -/

mutual
/-- Every name in a type, with its arguments: defined, of the right arity, not a stream. -/
def checkNames (F : Source) (d : Def) : Tm → C Unit
  | .var p =>
    if d.params.contains p then pure () else err .unknownParameter s!"unknown type parameter {p}"
  | .ref n as => do
    if n == "Stream" then err .misplacedStream "Stream can only be the whole type of a definition: type Events = Stream Event"
    match preludeGeneric.lookup n with
    | some k =>
      if as.length != k then err .wrongArity s!"{n} needs {k} argument{if k == 1 then "" else "s"}"
    | none =>
      if builtins.contains n || F.std.contains n then
        if !as.isEmpty then err .wrongArity s!"{n} takes no arguments"
      else match F.lookup n with
        | some d' =>
          if as.length != d'.params.length then
            err .wrongArity s!"{n} needs {d'.params.length} argument{if d'.params.length == 1 then "" else "s"}, got {as.length}"
          if d'.stream then err .misplacedStream s!"{n} is a Stream; a stream can only be the whole file, not part of a type"
        | none => err .unknownType s!"unknown type {n}"
    checkNamesList F d (as.map fun _ => false) as
  | .node l ks => checkNamesList F d l.spreadKids ks

/-- The kids of a node; spreads are checked by `checkSpreads`. -/
def checkNamesList (F : Source) (d : Def) : List Bool → List Tm → C Unit
  | _, [] => pure ()
  | s :: ss, t :: ts => do
    if !s then checkNames F d t
    checkNamesList F d ss ts
  | [], t :: ts => do
    checkNames F d t
    checkNamesList F d [] ts
end

/-! ## Spreads (§14) -/

/--
What a name stands for as a record or variant: its definition's body, through
names that stand for another type (`type A = B`, `type A = Pair Int`), their
parameters replaced. `none` for a name that isn't defined; out of fuel for a
cycle of names, which is unguarded recursion (§9.9).
-/
def unalias (F : Source) : Nat → Tm → C Tm
  | 0, _ => err .unguardedRecursion "a type refers to itself without a record, array or variant in between"
  | fuel + 1, t@(.ref n as) =>
    match F.lookup n with
    | some d => unalias F fuel (d.body.subst (d.params.zip as))
    | none => pure t
  | _, t => pure t

/-- The node a spread `...n` copies, after `want` (`record` or `variant`) is checked. -/
def spreadTarget (F : Source) (want : String) (n : String) : C (Label × List Tm) := do
  match F.lookup n with
  | none =>
    if builtins.contains n || F.std.contains n || (preludeGeneric.lookup n).isSome then
      err .invalidSpread s!"{n} is not a {want}, so it can't be spread here"
    else err .unknownType s!"unknown type {n}"
  | some d =>
    if !d.params.isEmpty then
      err .invalidSpread s!"{n} has parameters; only a type without parameters can be spread"
    if d.stream then err .invalidSpread s!"{n} is a Stream and can't be spread"
    match ← unalias F (F.defs.length + 1) d.body with
    | .node l@(.record _ _) ks => if want == "record" then pure (l, ks) else err .invalidSpread s!"{n} is not a {want}, so it can't be spread here"
    | .node l@(.variant _ _) ks => if want == "variant" then pure (l, ks) else err .invalidSpread s!"{n} is not a {want}, so it can't be spread here"
    | _ => err .invalidSpread s!"{n} is not a {want}, so it can't be spread here"

/-- The keys of a record's members, `spread` giving those of a spread's kid. -/
def memberNames (spread : Tm → C (List String)) : List Member → List Tm → C (List String)
  | .field k _ :: ms, _ :: ks => return k :: (← memberNames spread ms ks)
  | .spread :: ms, k :: ks => return (← spread k) ++ (← memberNames spread ms ks)
  | _, _ => pure []

/-- The tags of a variant's alternatives, `spread` giving those of a spread's kid. -/
def altNames (spread : Tm → C (List String)) : List Alt → List Tm → C (List String)
  | [], _ => pure []
  | .case tag n :: as, ks => return tag :: (← altNames spread as (ks.drop n))
  | .spread :: as, k :: ks => return (← spread k) ++ (← altNames spread as ks)
  | .spread :: as, [] => altNames spread as []

/--
The keys of a record or the tags of a variant, those its spreads copy in
included, in order. `visiting`: the definitions whose spreads are being
followed, for `spread-cycle`.
-/
def names (F : Source) (visiting : List String) : Nat → Label → List Tm → C (List String)
  | 0, _, _ => err .spreadCycle "spreads nested too deep"
  | fuel + 1, l, ks =>
    let want := match l with | .record _ _ => "record" | .variant _ _ => "variant"
    let spread (k : Tm) : C (List String) := match k with
      | .ref n [] => do
        if visiting.contains n then err .spreadCycle s!"type {n} spreads itself (directly or through another type)"
        let (l', ks') ← spreadTarget F want n
        names F (n :: visiting) fuel l' ks'
      | _ => err .invalidSpread "a spread names a type"
    match l with
    | .record _ ms => memberNames spread ms ks
    | .variant _ as => altNames spread as ks

mutual
/-- Every record and variant in a type: its spreads valid, no key or tag twice. -/
def checkSpreads (F : Source) (d : Def) : Tm → C Unit
  | .var _ => pure ()
  | .ref _ as => checkSpreadsList F d as
  | .node l ks => do
    let ns ← names F [d.name] (F.defs.length + 1) l ks
    if let some k := firstDup ns then
      match l with
      | .record _ _ => err .duplicateField s!"field {k} appears twice"
      | .variant _ _ => err .duplicateTag s!"tag {k} appears twice"
    checkSpreadsList F d ks

def checkSpreadsList (F : Source) (d : Def) : List Tm → C Unit
  | [] => pure ()
  | t :: ts => do checkSpreads F d t; checkSpreadsList F d ts
end

/-! ## Regular generics (§9.10) -/

/-- The definitions `n`'s definition refers to directly. -/
def Source.next (F : Source) (n : String) : List String :=
  match F.lookup n with
  | some d => (F.edges d).map (·.1)
  | none => []

/-- Adds the elements of `ys` that aren't in `xs` yet, each once. -/
def addNew {α : Type} [BEq α] : List α → List α → List α
  | xs, [] => xs
  | xs, y :: ys => if xs.contains y then addNew xs ys else addNew (xs ++ [y]) ys

/-- `k` rounds of following references from the names in `S`. -/
def Source.reachIter (F : Source) : Nat → List String → List String
  | 0, S => S
  | k + 1, S => F.reachIter k (addNew S (S.flatMap F.next))

/-- The definitions `m` reaches by references, itself included. -/
def Source.reachable (F : Source) (m : String) : List String :=
  F.reachIter (F.defs.length + 1) [m]

/-- Whether `m` refers to `n`, directly or through other definitions (or is `n`). -/
def Source.reaches (F : Source) (m n : String) : Bool := (F.reachable m).contains n

def Tm.isVar : Tm → Bool
  | .var _ => true
  | _ => false

/--
§9.10 for the reference `(m, es)` in `d`: to itself only with its own
parameters, in order (or none, which is `wrong-arity` if it has some); to a
definition of its group only with parameters as the arguments. Without
`groups`, only the first rule (as the bindings had it before the second).
-/
def growthOk (F : Source) (groups : Bool) (d : Def) (r : String × List Tm) : Bool :=
  if r.1 == d.name then r.2.isEmpty || r.2 == d.params.map .var
  else !groups || !F.reaches r.1 d.name || r.2.all Tm.isVar

/-- The first reference that breaks §9.10, and where it is. -/
def growthViolation? (F : Source) (groups : Bool) : Option (Def × String) :=
  F.defs.findSome? fun d => ((F.edges d).find? (!growthOk F groups d ·)).map fun r => (d, r.1)

/--
§9.10: a definition refers to itself only with its own parameters, in
order; and to a definition it is mutually recursive with only with parameters
of its own as the arguments.
-/
def checkGrowth (F : Source) (groups : Bool := true) : C Unit :=
  match growthViolation? F groups with
  | none => pure ()
  | some (d, m) =>
    if m == d.name then
      err .growingRecursion s!"{d.name} must refer to itself with its own parameters; other arguments could grow without bound"
    else
      err .growingRecursion s!"{d.name} refers to {m}, which refers back to {d.name}: {d.name} may pass it only its own parameters; other arguments could grow without bound"

/-! ## All of them -/

/-- The definitions' parameters: every one a type uses is declared. -/
def checkParams (d : Def) : C Unit :=
  match d.body.vars.find? (!d.params.contains ·) with
  | some p => err .unknownParameter s!"unknown type parameter {p}"
  | none => pure ()

/--
The static rules of §14 that the definitions must follow, in the order the
bindings check them. `groups := false` leaves out §9.10's rule for groups of
definitions (only to show what it is for: `Finite.doubling_infinite`).
-/
def check (F : Source) (groups : Bool := true) : C Unit := do
  F.defs.forM checkParams
  checkGrowth F groups
  F.defs.forM fun d => do
    checkNames F d d.body
    checkSpreads F d d.body

theorem check_growth {F : Source} {groups : Bool} (h : check F groups = .ok ()) :
    checkGrowth F groups = .ok () := by
  simp only [check, bind, Except.bind] at h
  split at h
  · cases h
  · split at h
    · cases h
    · next h' => exact h'

end Haus.SchemaFile
