import Haus.Schema.Types

/-!
# Schema files before resolution (spec §14)

What a schema file says, as resolution receives it: definitions with type
parameters, names applied to arguments, records and variants with spreads,
open or closed. Attributes are left out: decoding never reads them (§15), and
the parser checks the rules §14 has for them. Imports are reduced to what
they bring into scope: the std/time types (`Source.std`); the definitions of
imported packages would be definitions like the file's own (finding them is
package resolution, phase R, in `Haus.Packages`).

A type is a term `Tm`: a type parameter, a name applied to arguments (`Int`,
`Array a`, `List Int`, a definition of the file), or a record or variant
`node`, whose shape (keys, tags, how many arguments each case takes, where
the spreads are) is its `Label` and whose types are its `kids`. A spread
`...Name` is the kid `ref Name []`, so every name a type mentions, the
spread ones too, is a `ref` in it (`Tm.refs`), and substitution and the
proofs about instances (`Haus.SchemaFile.Finite`) treat records, variants and
applications alike.
-/

namespace Haus.SchemaFile

/-- A member of a record: `key: T`, `key?: T` (its type is the next kid), or `...Name`. -/
inductive Member where
  | field (key : String) (optional : Bool)
  | spread
  deriving Repr, DecidableEq, Inhabited

/-- An alternative of a variant: `Tag T1 … Tn` (the next `n` kids), or `...Name`. -/
inductive Alt where
  | case (tag : String) (arity : Nat)
  | spread
  deriving Repr, DecidableEq, Inhabited

/-- The shape of a record or variant. -/
inductive Label where
  | record (closed : Bool) (members : List Member)
  | variant (closed : Bool) (alts : List Alt)
  deriving Repr, DecidableEq, Inhabited

/-- A type as written in a schema file. -/
inductive Tm where
  /-- A type parameter, `a`. -/
  | var (p : String)
  /-- A name and its arguments: `Int`, `Array a`, `Pair Int`, `List (List a)`. -/
  | ref (name : String) (args : List Tm)
  /-- A record or variant: its shape and the types in it, in order. -/
  | node (l : Label) (kids : List Tm)
  deriving Repr, Inhabited

mutual
/-- Equality of types, decided structurally. -/
def Tm.beq : Tm → Tm → Bool
  | .var p, .var q => p == q
  | .ref n as, .ref m bs => n == m && Tm.beqList as bs
  | .node l ks, .node l' ks' => l == l' && Tm.beqList ks ks'
  | _, _ => false

def Tm.beqList : List Tm → List Tm → Bool
  | [], [] => true
  | a :: as, b :: bs => Tm.beq a b && Tm.beqList as bs
  | _, _ => false
end

mutual
theorem Tm.beq_iff : (a b : Tm) → Tm.beq a b = true ↔ a = b
  | .var p, .var q => by simp [Tm.beq]
  | .ref n as, .ref m bs => by simp [Tm.beq, Tm.beqList_iff as bs]
  | .node l ks, .node l' ks' => by simp [Tm.beq, Tm.beqList_iff ks ks']
  | .var _, .ref _ _ | .var _, .node _ _ | .ref _ _, .var _ | .ref _ _, .node _ _
  | .node _ _, .var _ | .node _ _, .ref _ _ => by simp [Tm.beq]

theorem Tm.beqList_iff : (as bs : List Tm) → Tm.beqList as bs = true ↔ as = bs
  | [], [] => by simp [Tm.beqList]
  | a :: as, b :: bs => by simp [Tm.beqList, Tm.beq_iff a b, Tm.beqList_iff as bs]
  | [], _ :: _ | _ :: _, [] => by simp [Tm.beqList]
end

instance : DecidableEq Tm := fun a b =>
  if h : Tm.beq a b then isTrue ((Tm.beq_iff a b).1 h) else isFalse fun e => h ((Tm.beq_iff a b).2 e)

/-! ## Names, parameters and substitution -/

mutual
/--
Every name a type mentions with the arguments it is given there, outside in:
`ref n as` itself, then the names in `as`. Spreads are `ref Name []`.
-/
def Tm.refs : Tm → List (String × List Tm)
  | .var _ => []
  | .ref n as => (n, as) :: Tm.refsList as
  | .node _ ks => Tm.refsList ks

def Tm.refsList : List Tm → List (String × List Tm)
  | [] => []
  | t :: ts => t.refs ++ Tm.refsList ts
end

mutual
/-- The type parameters a type uses. -/
def Tm.vars : Tm → List String
  | .var p => [p]
  | .ref _ as => Tm.varsList as
  | .node _ ks => Tm.varsList ks

def Tm.varsList : List Tm → List String
  | [] => []
  | t :: ts => t.vars ++ Tm.varsList ts
end

mutual
/-- The parts of a type, itself included. -/
def Tm.subterms : Tm → List Tm
  | t@(.var _) => [t]
  | t@(.ref _ as) => t :: Tm.subtermsList as
  | t@(.node _ ks) => t :: Tm.subtermsList ks

def Tm.subtermsList : List Tm → List Tm
  | [] => []
  | t :: ts => t.subterms ++ Tm.subtermsList ts
end

/-- A substitution: parameters and the types they stand for. -/
abbrev Subst := List (String × Tm)

mutual
/-- Replaces each parameter `σ` has by its type; others stay. -/
def Tm.subst (σ : Subst) : Tm → Tm
  | .var p => (σ.lookup p).getD (.var p)
  | .ref n as => .ref n (Tm.substList σ as)
  | .node l ks => .node l (Tm.substList σ ks)

def Tm.substList (σ : Subst) : List Tm → List Tm
  | [] => []
  | t :: ts => t.subst σ :: Tm.substList σ ts
end

mutual
/-- The size of a type: how many parameters, names and nodes it has. -/
def Tm.size : Tm → Nat
  | .var _ => 1
  | .ref _ as => Tm.sizeList as + 1
  | .node _ ks => Tm.sizeList ks + 1

def Tm.sizeList : List Tm → Nat
  | [] => 0
  | t :: ts => t.size + Tm.sizeList ts
end

theorem Tm.refsList_eq (ts : List Tm) : Tm.refsList ts = ts.flatMap Tm.refs := by
  induction ts with
  | nil => rfl
  | cons t ts ih => simp [Tm.refsList, ih]

theorem Tm.varsList_eq (ts : List Tm) : Tm.varsList ts = ts.flatMap Tm.vars := by
  induction ts with
  | nil => rfl
  | cons t ts ih => simp [Tm.varsList, ih]

theorem Tm.subtermsList_eq (ts : List Tm) : Tm.subtermsList ts = ts.flatMap Tm.subterms := by
  induction ts with
  | nil => rfl
  | cons t ts ih => simp [Tm.subtermsList, ih]

theorem Tm.substList_eq (σ : Subst) (ts : List Tm) : Tm.substList σ ts = ts.map (Tm.subst σ) := by
  induction ts with
  | nil => rfl
  | cons t ts ih => simp [Tm.substList, ih]

/-! ## Definitions and files -/

/-- `type Name p1 … pn = body`; for `type Name = Stream T`, `stream` and the body `T`. -/
structure Def where
  name : String
  params : List String
  body : Tm
  stream : Bool := false
  deriving Repr, Inhabited

/--
A schema file once its imports are found: the std/time types it imports, and
the definitions in scope (its own, and those of the packages it imports).
-/
structure Source where
  std : List String := []
  defs : List Def
  deriving Repr, Inhabited

/-- The definition with this name. -/
def Source.lookup (F : Source) (n : String) : Option Def := F.defs.find? (·.name == n)

/-- Whether a name is one of the file's definitions (not a built-in or prelude type). -/
def Source.defined (F : Source) (n : String) : Bool := (F.lookup n).isSome

/-- The names the definition refers to: those of its definitions, with their arguments. -/
def Source.edges (F : Source) (d : Def) : List (String × List Tm) :=
  d.body.refs.filter (F.defined ·.1)

/-! ## The prelude (spec §13, `prelude.schema.haus`) -/

/-- The prelude's types without parameters, and the built-in ones. -/
def builtins : List String :=
  ["String", "Bytes", "Bool", "Decimal", "Int", "Int8", "Int16", "Int32", "Int64",
   "UInt8", "UInt16", "UInt32", "UInt64", "Float32", "Float64", "Any"]

/-- The prelude's types with parameters, and how many each takes. -/
def preludeGeneric : List (String × Nat) :=
  [("Array", 1), ("Map", 1), ("Maybe", 1), ("Result", 2), ("Secret", 1), ("Stream", 1)]

/-- Every name the prelude defines: none of them can be defined again. -/
def preludeNames : List String := builtins ++ preludeGeneric.map (·.1)

/-- The std/time types (§13.2), by the name a schema imports them with. -/
def stdTime : List (String × Time.TimeType) :=
  Time.TimeType.all.map fun k => (k.name, k)

end Haus.SchemaFile
