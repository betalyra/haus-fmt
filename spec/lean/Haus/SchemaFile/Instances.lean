import Haus.SchemaFile.Check
import Haus.Schema.Decode

/-!
# Instances: from a schema file to the types decoding reads (spec §14, §15)

A generic definition is used with arguments: `List Int`, `Pair (List a)`.
Each name applied to arguments is an *instance* (`Inst`), whose type is its
definition's body with the parameters replaced (`Source.succs` lists the
instances that type mentions in turn). From some types (`ts`), a file
reaches the instances `Reach F ts` describes; `Haus.SchemaFile.Finite`
proves that for a checked file there are finitely many, with a bound.

The reference computes them (`Source.closure`, all of them from the
definitions without parameters), turns each into a resolved type `Ty`, the
form `Haus.Schema.decode` reads (`translate`), with spreads copied in and
every instance a name of the environment (`key`), and checks guarded
recursion (§9.9) on the result: following names from any instance reaches a
record, array, variant or other type that consumes input (`guarded`, with
the decoder's own `whnf`). `load` is the whole way from text to `Env`, and
`haus-ref --schema-suite` runs the schema suite with it.
-/

namespace Haus.SchemaFile
open Haus Haus.Schema

/-- A definition applied to arguments. -/
abbrev Inst := String × List Tm

/-- The instances an instance's type mentions: its definition's body, the parameters replaced. -/
def Source.succs (F : Source) : Inst → List Inst
  | (n, args) =>
    match F.lookup n with
    | some d => (d.body.subst (d.params.zip args)).refs.filter (F.defined ·.1)
    | none => []

/-- The instances reachable from the types `ts`: those they mention, and those those mention. -/
inductive Reach (F : Source) (ts : List Tm) : Inst → Prop
  | root {i : Inst} : i ∈ ts.flatMap Tm.refs → F.defined i.1 = true → Reach F ts i
  | step {i j : Inst} : Reach F ts i → j ∈ F.succs i → Reach F ts j

/-! ## Computing them -/

/-- One round: `S` and every instance an instance of `S` mentions. -/
def Source.grow (F : Source) (S : List Inst) : List Inst := addNew S (S.flatMap F.succs)

/-- As the bindings: more instances than this is an error (`growing-recursion`). -/
def maxInstances : Nat := 10000

/--
Rounds of `grow` until nothing is added: every instance reachable from `S`,
or `none` past `maxInstances` instances (or out of fuel). For a checked file
there are finitely many (`Source.reach_finite`), and this finds exactly them
(`Source.instances_reach`, `Source.instances_some`).
-/
def Source.closure (F : Source) : Nat → List Inst → Option (List Inst)
  | 0, _ => none
  | k + 1, S =>
    let S' := F.grow S
    if S'.length == S.length then some S
    else if S'.length > maxInstances then none
    else F.closure k S'

/-- The instances the types `ts` name, each once. -/
def Source.rootInsts (F : Source) (ts : List Tm) : List Inst :=
  addNew [] ((ts.flatMap Tm.refs).filter (F.defined ·.1))

/-- The instances reachable from `ts`, computed; `none` past `maxInstances`. -/
def Source.instances (F : Source) (ts : List Tm) : Option (List Inst) :=
  F.closure (maxInstances + 1) (F.rootInsts ts)

/-- The definitions without parameters, as types: where decoding starts. -/
def Source.roots (F : Source) : List Tm :=
  (F.defs.filter (·.params.isEmpty)).map fun d => .ref d.name []

/--
Every definition as a type, a generic one with `Any` for each parameter: what
§14 checks guarded recursion on, used or not (`type Q a = Q a` is unguarded
even when nothing uses `Q`). A parameter stands for a type that consumes
input, as `Any` does.
-/
def Source.templates (F : Source) : List Tm :=
  F.defs.map fun d => .ref d.name (d.params.map fun _ => .ref "Any" [])

/-! ## Names of instances -/

mutual
/-- A type as text, for the name of an instance: `List(Pair(Int))`. -/
def render : Tm → String
  | .var p => "'" ++ p
  | .ref n [] => n
  | .ref n (a :: as) => n ++ "(" ++ ", ".intercalate (renderList (a :: as)) ++ ")"
  | .node (.record c ms) ks => (if c then "closed " else "") ++ "{" ++ ", ".intercalate (renderMembers ms ks) ++ "}"
  | .node (.variant c as) ks => (if c then "closed " else "") ++ "<" ++ " | ".intercalate (renderAlts as ks) ++ ">"

def renderList : List Tm → List String
  | [] => []
  | t :: ts => render t :: renderList ts

def renderMembers : List Member → List Tm → List String
  | .field k o :: ms, t :: ts =>
    (String.ofList (Canonical.string k) ++ (if o then "?" else "") ++ ": " ++ render t) :: renderMembers ms ts
  | .spread :: ms, t :: ts => ("..." ++ render t) :: renderMembers ms ts
  | _, _ => []

def renderAlts : List Alt → List Tm → List String
  | .case tag 0 :: as, ts => tag :: renderAlts as ts
  | .case tag (n + 1) :: as, t :: ts => renderCase tag n [render t] as ts
  | .spread :: as, t :: ts => ("..." ++ render t) :: renderAlts as ts
  | _, _ => []

/-- The rest of a case's arguments, `n` more. -/
def renderCase (tag : String) : Nat → List String → List Alt → List Tm → List String
  | 0, args, as, ts => (tag ++ "(" ++ ", ".intercalate args ++ ")") :: renderAlts as ts
  | n + 1, args, as, t :: ts => renderCase tag n (args ++ [render t]) as ts
  | _ + 1, args, as, [] => (tag ++ "(" ++ ", ".intercalate args ++ ")") :: renderAlts as []
end

/-- The name of an instance in the environment: the definition's name for one without arguments. -/
def key : Inst → String
  | (n, args) => render (.ref n args)

/-! ## Resolved types -/

/-- The built-in and std/time types without parameters (§13, §15). -/
def builtinTy (F : Source) (n : String) : Option Ty :=
  match n with
  | "String" => some .string | "Bytes" => some .bytes | "Bool" => some .bool
  | "Decimal" => some .decimal | "Any" => some .any | "Int" => some (.int .int)
  | "Int8" => some (.int (.signed 8)) | "Int16" => some (.int (.signed 16))
  | "Int32" => some (.int (.signed 32)) | "Int64" => some (.int (.signed 64))
  | "UInt8" => some (.int (.unsigned 8)) | "UInt16" => some (.int (.unsigned 16))
  | "UInt32" => some (.int (.unsigned 32)) | "UInt64" => some (.int (.unsigned 64))
  | "Float32" => some (.float .f32) | "Float64" => some (.float .f64)
  | n => if F.std.contains n then (stdTime.lookup n).map .time else none

/--
What a spread's name stands for: its definition's body, through names that
stand for another type, with the substitution its parameters get on the way.
-/
def unaliasS (F : Source) : Nat → Subst → Tm → C (Subst × Tm)
  | 0, _, _ => err .unguardedRecursion "a type refers to itself without a record, array or variant in between"
  | fuel + 1, σ, t@(.ref n as) =>
    match F.lookup n with
    | some d => unaliasS F fuel (d.params.zip (as.map (·.subst σ))) d.body
    | none => pure (σ, t)
  | _, σ, t => pure (σ, t)

mutual
/--
The resolved type of `t` with the parameters `σ`: a definition applied to
arguments becomes the name of its instance (`key`), a spread the fields or
cases it copies, a case `Tag T` with `T` a name `Case.named` (a record case
when `T` stands for a record, §15), a parameter the type it stands for.
-/
def translate (F : Source) : Nat → Subst → Tm → C Ty
  | 0, _, _ => err .outOfFuel "out of fuel"
  | f + 1, σ, .var p =>
    match σ.lookup p with
    | some u => translate F f [] u
    | none => err .unknownParameter s!"unknown type parameter {p}"
  | f + 1, σ, .ref n as =>
    match n, as with
    | "Array", [a] => return .array (← translate F f σ a)
    | "Map", [a] => return .map (← translate F f σ a)
    | "Maybe", [a] => return .maybe (← translate F f σ a)
    | "Secret", [a] => return .secret (← translate F f σ a)
    | "Result", [e, a] => return .result (← translate F f σ e) (← translate F f σ a)
    | _, _ =>
      if F.defined n then return .ref (key (n, as.map (·.subst σ)))
      else match builtinTy F n with
        | some t => pure t
        | none => err .unknownType s!"unknown type {n}"
  | f + 1, σ, .node (.record c ms) ks => return .record c (← fields F f σ ms ks)
  | f + 1, σ, .node (.variant c as) ks => return .variant c (← cases F f σ as ks)

def fields (F : Source) : Nat → Subst → List Member → List Tm → C (List Field)
  | 0, _, _, _ => err .outOfFuel "out of fuel"
  | f + 1, σ, .field k o :: ms, t :: ks => do
    let ty ← translate F f σ t
    return .mk k o ty :: (← fields F f σ ms ks)
  | f + 1, σ, .spread :: ms, t :: ks => do
    match ← unaliasS F (F.defs.length + 1) σ t with
    | (σ', .node (.record _ ms') ks') => return (← fields F f σ' ms' ks') ++ (← fields F f σ ms ks)
    | _ => err .invalidSpread "a spread of something other than a record"
  | _ + 1, _, _, _ => pure []

def cases (F : Source) : Nat → Subst → List Alt → List Tm → C (List Case)
  | 0, _, _, _ => err .outOfFuel "out of fuel"
  | f + 1, σ, .case tag 0 :: as, ks => return .bare tag :: (← cases F f σ as ks)
  | f + 1, σ, .case tag 1 :: as, k :: ks => do
    let c ← match k with
      | .node (.record cl ms') ks' => pure (Case.record tag cl (← fields F f σ ms' ks'))
      | .ref n _ => if F.defined n then pure (Case.named tag (← translate F f σ k)) else pure (.positional tag [← translate F f σ k])
      | _ => pure (.positional tag [← translate F f σ k])
    return c :: (← cases F f σ as ks)
  | f + 1, σ, .case tag n :: as, ks => do
    let args ← args F f σ (ks.take n)
    return .positional tag args :: (← cases F f σ as (ks.drop n))
  | f + 1, σ, .spread :: as, t :: ks => do
    match ← unaliasS F (F.defs.length + 1) σ t with
    | (σ', .node (.variant _ as') ks') => return (← cases F f σ' as' ks') ++ (← cases F f σ as ks)
    | _ => err .invalidSpread "a spread of something other than a variant"
  | _ + 1, _, _, _ => pure []

def args (F : Source) : Nat → Subst → List Tm → C (List Ty)
  | 0, _, _ => err .outOfFuel "out of fuel"
  | _ + 1, _, [] => pure []
  | f + 1, σ, t :: ts => return (← translate F f σ t) :: (← args F f σ ts)
end

/-- Enough fuel for `translate`: spreads nest at most once per definition. -/
def Source.fuel (F : Source) : Nat :=
  (F.defs.length + 2) * (F.defs.foldl (fun n d => n + d.body.size) 0 + 2) * 2

/-- An instance's resolved type. -/
def Source.instTy (F : Source) (i : Inst) : C Ty :=
  match F.lookup i.1 with
  | some d => translate F F.fuel (d.params.zip i.2) d.body
  | none => err .unknownType s!"unknown type {i.1}"

/-- The environment of the instances `S`: each under its name. -/
def Source.envOf (F : Source) (S : List Inst) : C Env := do
  return ⟨← S.mapM fun i => return (key i, ← F.instTy i)⟩

/--
§9.9: from every name, following names and secrets reaches a type that
consumes input. The decoder's own `whnf` (`Haus.Schema.Decode`) follows them.
-/
def guarded (env : Env) : C Unit :=
  match env.defs.find? fun p => !(whnf env env.fuel (.ref p.1)).toBool with
  | none => pure ()
  | some (n, _) =>
    match whnf env env.fuel (.ref n) with
    | .error e => err .unguardedRecursion e
    | .ok _ => pure ()

mutual
/-- The names a resolved type mentions. -/
def tyNames : Ty → List String
  | .secret t | .array t | .map t => tyNames t
  | .record _ fs => fieldNames fs
  | .variant _ cs => caseNames cs
  | .ref n => [n]
  | _ => []

def fieldNames : List Field → List String
  | [] => []
  | .mk _ _ t :: fs => tyNames t ++ fieldNames fs

def caseNames : List Case → List String
  | [] => []
  | .bare _ :: cs => caseNames cs
  | .record _ _ fs :: cs => fieldNames fs ++ caseNames cs
  | .positional _ ts :: cs => tyListNames ts ++ caseNames cs
  | .named _ t :: cs => tyNames t ++ caseNames cs

def tyListNames : List Ty → List String
  | [] => []
  | t :: ts => tyNames t ++ tyListNames ts
end

/--
Every name a type of the environment mentions is one of its names. Holds for
every environment `envOf` makes from the instances `instances` finds (they
are closed under the instances they mention), and is checked here.
-/
def closedEnv (env : Env) : C Unit :=
  match env.defs.find? fun p => (tyNames p.2).any fun n => (env.lookup n).isNone with
  | none => pure ()
  | some (n, _) => err .unknownType s!"{n} refers to a type that is not defined"

/-- `parse`, its error as a schema-file error. -/
def parseC (text : Text) : C Parsed :=
  match parse text with
  | .ok p => pure p
  | .error e => err e.code e.reason

/-- `instances`, `none` as the error the bindings report past their limit. -/
def Source.instancesC (F : Source) (ts : List Tm) : C (List Inst) :=
  match F.instances ts with
  | some S => pure S
  | none => err .growingRecursion s!"more than {maxInstances} type instances: a generic type grows without bound"

/--
A schema file's text to the environment decoding reads (§14, §15): parsed,
declared, checked, its instances computed and resolved, guarded recursion
checked. The definitions without parameters are in it under their names.
Guarded recursion is also checked on every definition, used or not
(`Source.templates`, §14), which adds nothing to the environment.
-/
def load (text : Text) : C Env := do
  let F ← declare (← parseC text)
  check F
  let S ← F.instancesC F.roots
  let env ← F.envOf S
  closedEnv env
  guarded env
  guarded (← F.envOf (← F.instancesC F.templates))
  return env

private def loadCode (src : String) : Option Code :=
  match load src.toList with
  | .error e => some e.code
  | .ok _ => none

-- The rules of §14, one each.
#guard loadCode "type A = B" == some .unknownType
#guard loadCode "type A = Array" == some .wrongArity
#guard loadCode "type P a = { x: a }\ntype A = P" == some .wrongArity
#guard loadCode "type A = { x: b }" == some .unknownParameter
#guard loadCode "type A = Int\ntype A = String" == some .duplicateType
#guard loadCode "type Maybe = Int" == some .redefinePrelude
#guard loadCode "type P a a = { x: a }" == some .invalidParameter
#guard loadCode "type A = { x: _ }" == some .underscoreType
#guard loadCode "type A = { x: Int, x: String }" == some .duplicateField
#guard loadCode "type B = { x: Int }\ntype A = { ...B, x: String }" == some .duplicateField
#guard loadCode "type B = < X >\ntype A = closed < X | ...B >" == some .duplicateTag
#guard loadCode "type B = { x: Int }\ntype A = < ...B >" == some .invalidSpread
#guard loadCode "type B a = { x: a }\ntype A = { ...B }" == some .invalidSpread
#guard loadCode "type A = { ...Int }" == some .invalidSpread
#guard loadCode "type A = { x: { ...A } }" == some .spreadCycle
#guard loadCode "type P = { x: { ...R } }\ntype R = { y: { ...P } }" == some .spreadCycle
#guard loadCode "type P = { x: Array { ...R } }\ntype R = { y: { ...S } }\ntype S = P" == some .spreadCycle
#guard loadCode "type E = Stream Int\ntype A = { e: E }" == some .misplacedStream
#guard loadCode "type A = { e: Stream Int }" == some .misplacedStream
#guard loadCode "type A = Stream" == some .wrongArity
#guard loadCode "type A = { e: Stream }" == some .wrongArity
#guard loadCode "type A = Stream Int Int" == some .wrongArity
#guard loadCode "type A = Secret A" == some .unguardedRecursion
#guard loadCode "type I a = a\ntype X = I X" == some .unguardedRecursion
#guard loadCode "type Q a = Q a\ntype R = Int" == some .unguardedRecursion
#guard loadCode "type Q a = Secret (Q a)" == some .unguardedRecursion
#guard loadCode "type I a = a\ntype J a = I a" == none
#guard loadCode "type L a = < Nil | Cons a (L (L a)) >\ntype X = L Int" == some .growingRecursion
#guard loadCode "type P a b = { l: a, r: b }\ntype T a = < X (T (P a a)) | E >" == some .growingRecursion
#guard loadCode "type L a = < X (L (Array a)) | E >" == some .growingRecursion
#guard loadCode "type S a b = < X a (S b (Array a)) | E >" == some .growingRecursion
#guard loadCode "type A a = < X (B a) | E >\ntype B b = < Y (C (Array b)) >\ntype C c = < Z (A c) >" == some .growingRecursion
#guard loadCode "import std/money (Money)\ntype A = Money" == some .unknownModule
#guard loadCode "import std/time (Date, Date)\ntype A = Date" == some .duplicateImport
#guard loadCode "import std/time (Day)\ntype A = Day" == some .unknownImport
#guard loadCode "import ./common (A)\ntype B = A" == some .importUnavailable
-- `~` is no character of a module (grammar `path`): the same code as the package reader gives.
#guard loadCode "import ./a~b (A)\ntype B = A" == some .schemaSyntax
#guard loadCode "import @haus-fmt/money@1 (Money)\ntype A = Money" == some .importUnavailable
#guard loadCode "import @Haus/money@1 (Money)\ntype A = Money" == some .unknownModule
#guard loadCode "import @haus-fmt/node_modules (Money)\ntype A = Money" == some .unknownModule
#guard loadCode "import .x (A)\ntype B = A" == some .unknownModule
#guard loadCode "import @haus-fmt/money@1.1 (Money)\ntype A = Money" == some .importVersion
#guard loadCode "import @haus-fmt/money@01 (Money)\ntype A = Money" == some .importVersion
#guard loadCode "import @haus-fmt/money@ (Money)\ntype A = Money" == some .importVersion
-- Accepted: spreads through names and instances, mutually recursive generics, Result, std/time.
#guard loadCode "type P a = { x: a }\ntype Q = P Int\ntype A = closed { ...Q, y: Int }" == none
#guard loadCode "type T a = { kids: F a }\ntype F a = Array (T a)\ntype X = T Int" == none
-- No expansive cycle (§9.10): a parameter grows only off every cycle, or arguments only permute.
#guard loadCode "type Node a = { value: a, meta: Meta }\ntype Meta = { history: Node String }\ntype X = Node Int" == none
#guard loadCode "type Expr = < Num Int | Call (Apply Expr) >\ntype Apply a = { f: a, args: Array Expr }" == none
#guard loadCode "type Swap a b = < S a (Swap b a) | E >\ntype X = Swap Int String" == none
#guard loadCode "type K a = < X (K Int) | Y a >\ntype Z = K String" == none
#guard loadCode "type P a b = { l: a, r: b }\ntype A a = < X (B (P a a)) >\ntype B b = < Y b | Z (A Int) >\ntype R = A String" == none
#guard loadCode "import std/time (Date)\ntype A = Result String (Maybe Date)\ntype E = Stream A" == none
#guard (load "type P a = { x: a }\ntype Q = P (P Int)".toList).toOption.map (·.defs.map (·.1)) ==
  some ["Q", "P(P(Int))", "P(Int)"]

end Haus.SchemaFile
