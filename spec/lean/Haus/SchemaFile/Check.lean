import Haus.SchemaFile.Parse

/-!
# The static rules of schema files (spec §14)

`declare` turns what a file says (`Parsed`) into the definitions in scope
(`Source`), and `check` checks them: the rules of §14 that hold for a
file's definitions as written, before any generic type is applied.

* names: every type is defined, imported or the prelude's (`unknown-type`),
  with as many arguments as it has parameters (`wrong-arity`); every
  parameter is one of its definition's (`unknown-parameter`); `Stream` with
  one argument (`wrong-arity`, checked first), and only as the whole of a
  definition, never referred to (`misplaced-stream`);
* imports: `std/time` and its types, or a package or file import that is
  well formed (`unknown-module`, `import-version`) and then needs package
  resolution (`import-unavailable` here);
* definitions: none twice (`duplicate-type`), none of the prelude's
  (`redefine-prelude`), no parameter twice (`invalid-parameter`);
* spreads: of a named record into a record or a named variant into a variant,
  without parameters (`invalid-spread`), never of itself, directly or not,
  at any depth (`spread-cycle`, `checkSpreadCycles`); no field or tag twice,
  those copied in included (`duplicate-field`, `duplicate-tag`);
* instances that can't grow (§9.10, `growing-recursion`): no expanding
  edge of the parameter graph (`Source.paramEdges`) lies on a cycle.

Guarded recursion (§9.9, `unguarded-recursion`) is checked on the instances
(`Haus.SchemaFile.Instances`), of every definition, used or not (a generic
one with `Any` for its parameters): `type I a = a` with `type X = I X` is
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

/-- The package a package import names, without its `@major`: `@haus-fmt/money` for `@haus-fmt/money@1`. -/
def packageOf (m : String) : String :=
  match m.toList with
  | '@' :: r => "@" ++ String.ofList (r.takeWhile (· != '@'))
  | _ => m

/--
`@org/name@V`: what is wrong with `V` (`import-version`), as the bindings
say it: an import names only a major version, without leading zeros
(§13.3). `none` for a module without a version, or with a good one.
-/
def importVersion? (m : String) : Option String :=
  match m.toList with
  | '@' :: r =>
    match r.dropWhile (· != '@') with
    | '@' :: v =>
      let name := packageOf m
      let version := String.ofList v
      let ds := v.takeWhile isDigit
      let rest := v.drop ds.length
      let major := String.ofList (match ds.dropWhile (· == '0') with | [] => ['0'] | m => m)
      if ds.isEmpty || !(rest.isEmpty || rest.head? == some '.') then
        some s!"{msgText name}@{msgText version}: expected a major version after '@', like {msgText name}@1"
      else if !rest.isEmpty then
        some s!"{msgText name}@{msgText version}: an import names only the major version ({msgText name}@{msgText major})"
      else if ds.length != major.length then
        some s!"{msgText name}@{msgText version}: a major version has no leading zeros ({msgText name}@{msgText major})"
      else none
    | _ => none
  | _ => none

/--
An import of something other than `std/…`, checked as the bindings check it
(§13.3): a major version only (`import-version`), a package name in
lowercase (`Haus.Packages.isPackageName`, the package model's own check;
`unknown-module`), a package `@org/name` or a file `./…`, `../…`
(`unknown-module` otherwise). A good one needs package resolution
(`Haus.Packages`), which would bring the definitions it names in as more
definitions; reading a schema from its text alone, as here and in the
bindings' text loaders, it is `import-unavailable`.
-/
def checkModule (m : String) : C Unit := do
  if let some e := importVersion? m then err .importVersion e
  if m.startsWith "@" && !Packages.isPackageName (packageOf m) then
    err .unknownModule s!"unknown module {msgText m}: a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)"
  if !((m.startsWith "@" && m.contains '/') || m.startsWith "./" || m.startsWith "../") then
    err .unknownModule s!"unknown module {msgText m}: import std/…, a package @org/name or a file ./name"
  err .importUnavailable s!"can't import {msgText m}: no module resolver (only std modules are found here)"

/-- The names a `std/time` import brings in, after those of `std`: each a std/time type, none twice. -/
def stdNames (m : String) : List String → List String → C (List String)
  | std, [] => pure std
  | std, n :: ns =>
    if !(stdTime.any (·.1 == n)) then
      err .unknownImport s!"{msgText m} has no type {msgText n} (it has {", ".intercalate (stdTime.map (·.1))})"
    else if std.contains n then err .duplicateImport s!"{msgText n} is imported twice"
    else stdNames m (std ++ [n]) ns

/-- The std/time types the imports bring in, after those of `std`, in order. -/
def declareImports : List String → List Import → C (List String)
  | std, [] => pure std
  | std, i :: is =>
    if i.module.startsWith "std/" then
      if i.module != "std/time" then err .unknownModule s!"unknown module {msgText i.module}: the standard modules are std/time"
      else do declareImports (← stdNames i.module std i.names) is
    else do checkModule i.module; declareImports std is

/--
The definitions, after those named `seen`: none twice, none imported
(`std`), none of the prelude's, no parameter twice.
-/
def declareDefs (std : List String) : List String → List Def → C Unit
  | _, [] => pure ()
  | seen, d :: ds =>
    if seen.contains d.name then err .duplicateType s!"type {msgText d.name} is defined twice"
    else if std.contains d.name then err .duplicateType s!"type {msgText d.name} is already imported"
    else if preludeNames.contains d.name then err .redefinePrelude s!"{msgText d.name} is a prelude type and can't be redefined"
    else match firstDup d.params with
      | some p => err .invalidParameter s!"parameter {msgText p} appears twice"
      | none => declareDefs std (seen ++ [d.name]) ds

/--
The definitions in scope: the file's own and the std/time types it imports.
Only `std/…` modules are found here; any other import is checked
(`checkModule`), and is `import-unavailable` without package resolution.
-/
def declare (p : Parsed) : C Source := do
  let std ← declareImports [] p.imports
  declareDefs std [] p.defs
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
    if d.params.contains p then pure () else err .unknownParameter s!"unknown type parameter {msgText p}"
  | .ref n as => do
    -- Arity first, then where it is: `type Q = Stream` is `wrong-arity`.
    if n == "Stream" then
      if as.length != 1 then err .wrongArity "Stream needs 1 argument"
      err .misplacedStream "Stream can only be the whole type of a definition: type Events = Stream Event"
    match preludeGeneric.lookup n with
    | some k =>
      if as.length != k then err .wrongArity s!"{msgText n} needs {k} argument{if k == 1 then "" else "s"}"
    | none =>
      if builtins.contains n || F.std.contains n then
        if !as.isEmpty then err .wrongArity s!"{msgText n} takes no arguments"
      else match F.lookup n with
        | some d' =>
          if as.length != d'.params.length then
            err .wrongArity s!"{msgText n} needs {d'.params.length} argument{if d'.params.length == 1 then "" else "s"}, got {as.length}"
          if d'.stream then err .misplacedStream s!"{msgText n} is a Stream; a stream can only be the whole file, not part of a type"
        | none => err .unknownType s!"unknown type {msgText n}"
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
      err .invalidSpread s!"{msgText n} is not a {want}, so it can't be spread here"
    else err .unknownType s!"unknown type {msgText n}"
  | some d =>
    if !d.params.isEmpty then
      err .invalidSpread s!"{msgText n} has parameters; only a type without parameters can be spread"
    if d.stream then err .invalidSpread s!"{msgText n} is a Stream and can't be spread"
    match ← unalias F (F.defs.length + 1) d.body with
    | .node l@(.record _ _) ks => if want == "record" then pure (l, ks) else err .invalidSpread s!"{msgText n} is not a {want}, so it can't be spread here"
    | .node l@(.variant _ _) ks => if want == "variant" then pure (l, ks) else err .invalidSpread s!"{msgText n} is not a {want}, so it can't be spread here"
    | _ => err .invalidSpread s!"{msgText n} is not a {want}, so it can't be spread here"

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
        if visiting.contains n then err .spreadCycle s!"type {msgText n} spreads itself (directly or through another type)"
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
      | .record _ _ => err .duplicateField s!"field {msgText k} appears twice"
      | .variant _ _ => err .duplicateTag s!"tag {msgText k} appears twice"
    checkSpreadsList F d ks

def checkSpreadsList (F : Source) (d : Def) : List Tm → C Unit
  | [] => pure ()
  | t :: ts => do checkSpreads F d t; checkSpreadsList F d ts
end

/-! ## Instances that can't grow (§9.10) -/

/-- Adds the elements of `ys` that aren't in `xs` yet, each once. -/
def addNew {α : Type} [BEq α] : List α → List α → List α
  | xs, [] => xs
  | xs, y :: ys => if xs.contains y then addNew xs ys else addNew (xs ++ [y]) ys

/-- `k` rounds of following `next` from the elements of `S`. -/
def iterReach {α : Type} [BEq α] (next : α → List α) : Nat → List α → List α
  | 0, S => S
  | k + 1, S => iterReach next k (addNew S (S.flatMap next))

/-- A type parameter of a definition: the definition's name and the parameter's. -/
abbrev PNode := String × String

/--
The parameter graph of §9.10: for each reference `m es` in the body of a
definition `d`, an edge from `(d, v)` to `(m, q)` for each parameter `v`
in the argument `e` that `m`'s parameter `q` gets, *expanding* (`true`)
when `e` is more than `v` itself (`Pair v v`, `Array v`, `{ x: v }`, …).
-/
def Source.paramEdges (F : Source) : List (PNode × PNode × Bool) :=
  F.defs.flatMap fun d => (F.edges d).flatMap fun r =>
    match F.lookup r.1 with
    | some d' => (d'.params.zip r.2).flatMap fun qe =>
        qe.2.vars.map fun v => ((d.name, v), (r.1, qe.1), qe.2 != .var v)
    | none => []

/-- The parameters a parameter passes into, directly. -/
def Source.pnext (F : Source) (x : PNode) : List PNode :=
  (F.paramEdges.filter (·.1 == x)).map (·.2.1)

/-- The parameters `x` passes into, directly or not, itself included. -/
def Source.preachable (F : Source) (x : PNode) : List PNode :=
  iterReach F.pnext (F.paramEdges.length + 1) [x]

/-- The first expanding edge on a cycle: its two ends. -/
def Source.expansive? (F : Source) : Option (PNode × PNode) :=
  (F.paramEdges.find? fun e => e.2.2 && (F.preachable e.2.1).contains e.1).map fun e => (e.1, e.2.1)

/--
§9.10, the expansive-cycle rule: no parameter passes, inside a bigger type,
along a cycle of references back to itself. Without `growth`, no check (only
to show what it is for: `Finite.doubling_infinite`).
-/
def checkGrowth (F : Source) (growth : Bool := true) : C Unit :=
  if !growth then pure () else
  match F.expansive? with
  | none => pure ()
  | some ((a, v), (b, q)) =>
    if (a, v) == (b, q) then
      err .growingRecursion s!"{msgText a} passes its parameter {msgText v} to itself inside a bigger type: instances could grow without bound"
    else
      err .growingRecursion s!"{msgText a} passes its parameter {msgText v} to {if a == b then "itself" else msgText b} inside a bigger type, and it comes back: instances could grow without bound"

/-! ## Spread cycles (§14)

A spread copies what it names when the type is built, wherever it is
written: `type P = { x: { ...R } }` needs `R`'s fields to build `P`, and so
does every name `R` stands for on the way (`type R = S`). A file whose types
need themselves this way, directly or not, can't be built (`spread-cycle`):
`type P = { x: { ...R } }` with `type R = { y: { ...P } }` would be an
infinite type. `spreadCycle?` finds such a cycle among the definitions,
however deep the spreads are written. -/

mutual
/-- The names spread anywhere in a type (`...Name`), at any depth. -/
def spreadsIn : Tm → List String
  | .var _ => []
  | .ref _ as => spreadsInList as
  | .node l ks => spreadsInKids l.spreadKids ks

def spreadsInList : List Tm → List String
  | [] => []
  | t :: ts => spreadsIn t ++ spreadsInList ts

/-- The kids of a node, `true` for a spread. -/
def spreadsInKids : List Bool → List Tm → List String
  | _, [] => []
  | true :: ss, .ref n [] :: ts => n :: spreadsInKids ss ts
  | _ :: ss, t :: ts => spreadsIn t ++ spreadsInKids ss ts
  | [], t :: ts => spreadsIn t ++ spreadsInKids [] ts
end

/--
The definitions whose types are built to resolve a spread of `t`: `t`'s
name, and the names it stands for in turn (`unalias`), their parameters
replaced. Stops at anything but a defined name, or out of fuel (a cycle of
names, which `unalias` reports as unguarded recursion).
-/
def aliasChain (F : Source) : Nat → Tm → List String
  | 0, _ => []
  | fuel + 1, .ref n as =>
    match F.lookup n with
    | some d => n :: aliasChain F fuel (d.body.subst (d.params.zip as))
    | none => []
  | _ + 1, _ => []

/--
Enough fuel for `aliasChain`: following names never makes a term bigger than
the file's terms with the arguments of a definition put in, a bound the
translation's fuel (`translate`) has too.
-/
def Source.chainFuel (F : Source) : Nat :=
  (F.defs.length + 2) * (F.defs.foldl (fun n d => n + d.body.size) 0 + 2) * 2

/-- The definitions building a definition's type builds first: those of every spread in it. -/
def Source.spreadNext (F : Source) (n : String) : List String :=
  match F.lookup n with
  | some d => (spreadsIn d.body).flatMap fun m => aliasChain F F.chainFuel (.ref m [])
  | none => []

/-- The first definition that needs itself to be built, through spreads (`F.defs.length` rounds reach every definition reachable at all). -/
def Source.spreadCycle? (F : Source) : Option String :=
  (F.defs.find? fun d => (iterReach F.spreadNext F.defs.length (F.spreadNext d.name)).contains d.name).map (·.name)

/-- No type spreads itself, directly or through other types, at any depth (§14, `spread-cycle`). -/
def checkSpreadCycles (F : Source) : C Unit :=
  match F.spreadCycle? with
  | none => pure ()
  | some n => err .spreadCycle s!"type {msgText n} spreads itself (directly or through another type)"

/-! ## All of them -/

/-- The definitions' parameters: every one a type uses is declared. -/
def checkParams (d : Def) : C Unit :=
  match d.body.vars.find? (!d.params.contains ·) with
  | some p => err .unknownParameter s!"unknown type parameter {msgText p}"
  | none => pure ()

/--
The static rules of §14 that the definitions must follow, in the order the
bindings check them. `growth := false` leaves out §9.10's rule (only to show
what it is for: `Finite.doubling_infinite`).
-/
def check (F : Source) (growth : Bool := true) : C Unit := do
  F.defs.forM checkParams
  checkGrowth F growth
  -- Before what a spread copies is checked, as the bindings, which find a
  -- cycle while building the types (`< X { ...R } >` with `{ y: { ...Q } }`).
  checkSpreadCycles F
  F.defs.forM fun d => do
    checkNames F d d.body
    checkSpreads F d d.body

theorem check_growth {F : Source} {growth : Bool} (h : check F growth = .ok ()) :
    checkGrowth F growth = .ok () := by
  simp only [check, bind, Except.bind] at h
  split at h
  · cases h
  · split at h
    · cases h
    · next h' => exact h'

end Haus.SchemaFile
