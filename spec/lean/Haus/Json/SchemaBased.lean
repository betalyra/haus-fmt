import Haus.Json.SelfDescribing
import Haus.Json.Normal
import Haus.Schema.Decode

/-!
# Schema-based JSON (spec §16.3)

`toJson env t x` writes a decoded value (§15) of the type `t` as the JSON a
JSON consumer expects; `fromJson env t j` reads it back. Both follow the
table of §16.3 row by row.

**`null`.** A `Maybe a` writes `None` as `null` and `Some(x)` as the JSON of
`x` when `a`'s JSON can't be `null`; otherwise it uses the tagged form. The
`Maybe`s a value passes through form a chain (`maybeChain`): each one's
argument, through named types and `Secret`s, is the next, until a type that
isn't a `Maybe`, or until the chain comes round to a `Maybe` it has passed
(`type T = Maybe T`), which uses the tagged form (§16.3). A `Maybe` is
identified by the definition it is written in (`origin`) and its type, so
with `type D = Maybe T` the `Maybe` of `D` is not the one of `T`. Going back from
there, every other `Maybe` uses `null` (`chainNull`). The chain is followed
for at most `nullFuel` steps, the number of types in the environment and in
`t`, which bounds every chain that doesn't repeat. Whatever `chainNull`
computes, `usesNull` writes `null` only where the inner JSON can't be `null`,
so the proofs don't depend on it.

**`Bool`** is the prelude's only (§16.3): a type that is the name `Bool`
(through named types and `Secret`s) whose definition is `closed < False |
True >`. A schema's own `closed < False | True >` is a closed enum.
**`Maybe`** is the prelude's only, by name too (`preludeMaybe`): a schema's
own `closed < None | Some a >` is a variant like any other.

**`Any`** is its self-describing form (§16.2) without the envelope, and so
are an unknown value's arguments, in `_args`; the self-describing value is
read as it is inside schema-based JSON, raw DEL, C1 and bidi controls
accepted.

**Errors.** A record payload with a field named `_tag` or `_args` has no
schema-based form (§16.3, `hasReservedField`): writing it is an error, and
so is reading with such a case. Errors
inside a `Secret` show nothing of the value, as when decoding (§15). Every
error has a code (spec §17): the JSON category's for the form of the JSON
(`missing-member`, `invalid-base64`, …), the decoder's where reading decodes
(`out-of-range`, `missing-field`, …).

**Reading strictly.** Where §16.3 leaves a choice, the reader is strict: an
integer string is spelled like a JSON integer (`-?(0|[1-9][0-9]*)`), a
`Decimal` string is a JSON number, a payload without a record accepts no
members but `_tag` and `value`/`values`, and base64 must be canonical. An
unlisted tag in an open variant reads as an unknown value: without other
members as bare, with only `_args` (not empty) as self-describing values,
otherwise its other members as a record payload, by the import (§16.1): so a
newer writer's `{"_tag": "Run", "args": [1, 2]}` is `Run { args: [1, 2] }`.
-/

namespace Haus.Schema
open Haus

/-! ## Which types write `null` -/

mutual
/-- The number of type nodes in a type. -/
def Ty.size : Ty → Nat
  | .secret t => t.size + 1
  | .array t => t.size + 1
  | .map t => t.size + 1
  | .record _ fields => Ty.fieldsSize fields + 1
  | .variant _ cases => Ty.casesSize cases + 1
  | _ => 1

def Ty.fieldsSize : List Field → Nat
  | [] => 0
  | .mk _ _ t :: fs => t.size + Ty.fieldsSize fs

def Ty.casesSize : List Case → Nat
  | [] => 0
  | .bare _ :: cs => 1 + Ty.casesSize cs
  | .record _ _ fields :: cs => Ty.fieldsSize fields + 1 + Ty.casesSize cs
  | .positional _ ts :: cs => Ty.listSize ts + 1 + Ty.casesSize cs

def Ty.listSize : List Ty → Nat
  | [] => 0
  | t :: ts => t.size + Ty.listSize ts
end

def Env.size (env : Env) : Nat := (env.defs.map fun d => d.2.size).sum

/--
Fuel for `canNull`: every type a chain of `Maybe` arguments from `t` meets is
part of `t` or of a definition, so a chain that doesn't repeat is shorter.
-/
def nullFuel (env : Env) (t : Ty) : Nat := t.size + env.size + 1

deriving instance BEq for Ty, Field, Case

/-- The prelude's `Maybe a = closed < None | Some a >`: its argument. -/
def maybeOf? : Ty → Option Ty
  | .variant true [.bare "None", .positional "Some" [a]] => some a
  | _ => none

/--
The last named type `whnf` goes through to reach `t`'s type: the definition
it is written in. `none` when `t` itself is written out (no reference).
-/
def lastRef (env : Env) : Nat → Ty → Option String
  | 0, _ => none
  | f + 1, t =>
    match peel t with
    | (_, .ref n) =>
      match env.lookup n with
      | some t' => some ((lastRef env f t').getD n)
      | none => none
    | _ => none

/--
Where the type of `t` is written: the definition `whnf` ends in, or, for a
type written out in place, `o`, where the type around it is written.
-/
def origin (env : Env) (o : String) (t : Ty) : String := (lastRef env env.fuel t).getD o

/--
**The prelude's `Maybe`** (§16.3), by name: `haus-ref` writes each use of it
as a reference to a definition of its own, named `Maybe#…`, so it is told
apart from a schema's own `closed < None | Some a >` and each `Maybe` keeps
the place it is written.
-/
def preludeMaybe (o : String) : Bool := o.startsWith "Maybe#"

/-- The argument of `c`, if `c`, written in `o`, is the prelude's `Maybe`. -/
def maybeAt? (o : String) (c : Ty) : Option Ty := if preludeMaybe o then maybeOf? c else none

/--
The next link of a chain of `Maybe`s: the argument of the `Maybe` `c`
(written in `o`), through references and secrets, and where it is written.
A `Maybe` is identified by where it is written and its type.
-/
def nextMaybe (env : Env) (oc : String × Ty) : Option (String × Ty) :=
  match maybeAt? oc.1 oc.2 with
  | some a =>
    match whnf env env.fuel a with
    | .ok (_, c') => some (origin env oc.1 a, c')
    | .error _ => none
  | none => none

/-- The chain from `c`: `c`, its next link, …, at most `n + 1` links. -/
def maybeChain (env : Env) : Nat → String × Ty → List (String × Ty)
  | 0, oc => [oc]
  | n + 1, oc =>
    oc :: match nextMaybe env oc with
      | some oc' => maybeChain env n oc'
      | none => []

/--
The position of the first link whose JSON can't be `null` by itself: a type
that isn't a `Maybe`, or a `Maybe` the chain comes back to (or the end).
-/
def chainEnd : List (String × Ty) → Nat
  | [] => 0
  | oc :: cs => if (maybeAt? oc.1 oc.2).isNone || cs.contains oc || cs.isEmpty then 0 else chainEnd cs + 1

/--
Does the `Maybe` `c`, written in `o`, use `null` (§16.3)? The link at
`chainEnd` can't be `null`; going back from it, every other `Maybe` uses
`null`. A `Maybe` that reaches itself is such a link: it uses the tagged form.
-/
def chainNull (env : Env) (F : Nat) (o : String) (c : Ty) : Bool :=
  let k := chainEnd (maybeChain env F (o, c))
  k % 2 == 1

/--
`chainNull`, and never where the next `Maybe` uses `null` too: so the JSON of
a `Maybe` that writes `None` as `null` is never `null` for `Some(x)`.
-/
def usesNull (env : Env) (F : Nat) (o : String) (c : Ty) : Bool :=
  chainNull env F o c &&
    !(match nextMaybe env (o, c) with
      | some (o', c') => (maybeAt? o' c').isSome && chainNull env F o' c'
      | none => false)

/-- The argument of a `Maybe`, written in `o`, that writes `None` as `null`. -/
def nullArg? (env : Env) (F : Nat) (o : String) (c : Ty) : Option Ty :=
  match maybeAt? o c with
  | some a => if usesNull env F o c then some a else none
  | none => none

/-- The shape of the prelude's `Bool = closed < False | True >`. -/
def isBool : Ty → Bool
  | .variant true [.bare "False", .bare "True"] => true
  | _ => false

/-- Does `t` name `Bool`, through named types and secrets? -/
def reachesBool (env : Env) : Nat → Ty → Bool
  | 0, t =>
    match peel t with
    | (_, .ref n) => n == "Bool"
    | _ => false
  | f + 1, t =>
    match peel t with
    | (_, .ref n) =>
      n == "Bool" ||
        match env.lookup n with
        | some t' => reachesBool env f t'
        | none => false
    | _ => false

/-- **The prelude's `Bool`** (§16.3): the name `Bool`, defined as `closed < False | True >`. -/
def boolTy (env : Env) (t : Ty) : Bool :=
  reachesBool env env.fuel t &&
    match whnf env env.fuel t with
    | .ok (_, c) => isBool c
    | .error _ => false

def Case.isBare : Case → Bool
  | .bare _ => true
  | _ => false

/-- A closed variant whose tags have no payload: written as a string. -/
def isEnum : Ty → Bool
  | .variant true cases => cases.all Case.isBare
  | _ => false

/--
A record payload with a field named `_tag` or `_args`: it has no schema-based
form (§16.3). `_tag` would be the tag, and `_args` is what a reader that
doesn't know the case reads as an unknown value's arguments.
-/
def hasReservedField (fields : List Field) : Bool := fields.any fun f => f.key == "_tag" || f.key == "_args"

/-! ## Writing -/

def reservedFieldReason : String := "a record payload with a field named _tag or _args has no schema-based JSON form"

/-- `Int`, `Int64`, `UInt64` (more than 32 bits) are written as strings. -/
def IntType.asString : IntType → Bool
  | .int => true
  | .signed b => 32 < b
  | .unsigned b => 32 < b

def intJson (k : IntType) (n : Int) : JSON := if k.asString then .str (intLit n) else .num (intLit n)

def floatJson (k : FloatType) : Flt → JSON
  | .nan => .str "NaN"
  | .inf false => .str "Infinity"
  | .inf true => .str "-Infinity"
  | x => .num (spell k x)

/-- `{"_tag": T}`, with `"_args"` the arguments' self-describing forms (without the envelope) if there are any. -/
def unknownJson (tag : String) (vs : List Value) : JSON :=
  .obj (("_tag", .str tag) :: if vs.isEmpty then [] else [("_args", .arr (JSON.selfDescribingList vs))])

def mismatch {α : Type} (c : Ty) : Except Error α := reject .typeMismatch s!"not a value of {c.name}"

/--
The code for an object of a tagged form (§16.3) whose members aren't `_tag`
and `name`: a member it doesn't have (`unexpected-member`), or else `name`
is missing (`missing-member`).
-/
def memberCode (name : String) (ms : List (String × JSON)) : Code :=
  if ms.any fun m => m.1 != "_tag" && m.1 != name then .unexpectedMember else .missingMember

mutual
/--
**Writing schema-based JSON** (§16.3) of a decoded value, with the type it has
after references and secrets (`whnf`). `F` is the fuel for the chains of
`Maybe`s, `b` says the type is the prelude's `Bool`.
-/
def toJsonC (env : Env) (F : Nat) (b : Bool) (o : String) (c : Ty) : Typed → Except Error JSON
  | .secret x => toJsonC env F b o c x
  | .str s => match c with
    | .string => .ok (.str s)
    | c => mismatch c
  | .bytes bs => match c with
    | .bytes => .ok (.str (String.ofList (Bytes.base64 bs)))
    | c => mismatch c
  | .int n => match c with
    | .int k => .ok (intJson k n)
    | c => mismatch c
  | .float _ f => match c with
    | .float k => .ok (floatJson k f)
    | c => mismatch c
  | .decimal l => match c with
    | .decimal => .ok (.str l)
    | c => mismatch c
  | .time _ s => match c with
    | .time _ => .ok (.str s)
    | c => mismatch c
  | .any v => match c with
    | .any => .ok (JSON.selfDescribing v)
    | c => mismatch c
  | .arr xs => match c with
    | .array t => (toJsonItems env F o t 0 xs).map .arr
    | c => mismatch c
  | .map fs => match c with
    | .map t => (toJsonEntries env F o t fs).map .obj
    | c => mismatch c
  | .record fs => match c with
    | .record _ fields => (toJsonFields env F o fields fs).map .obj
    | c => mismatch c
  | .unknown tag vs => match c with
    | .variant _ _ => .ok (unknownJson tag vs)
    | c => mismatch c
  | .case tag args => match c with
    | .variant closed cases =>
      if b then .ok (.bool (tag == "True")) else
      match nullArg? env F o (.variant closed cases), args with
      | some _, [] => .ok .null
      | some a, [y] =>
        match whnf env env.fuel a with
        | .ok (_, c') => toJsonC env F (boolTy env a) (origin env o a) c' y
        | .error r => fail r (whnfCode r)
      | some _, _ => mismatch c
      | none, args =>
        if isEnum (.variant closed cases) then .ok (.str tag) else
        match caseOf? cases tag, args with
        | some (.bare _), _ => .ok (.obj [("_tag", .str tag)])
        | some (.record _ _ fields), [.record fs] =>
          if hasReservedField fields then .error ⟨[.arg tag 0], reservedFieldReason, some .noJsonForm⟩
          else (under (.arg tag 0) (toJsonFields env F o fields fs)).map fun ms => .obj (("_tag", .str tag) :: ms)
        | some (.positional _ []), _ => .ok (.obj [("_tag", .str tag)])
        | some (.positional _ [t1]), [y] =>
          (under (.arg tag 0) (match whnf env env.fuel t1 with
            | .ok (_, c') => toJsonC env F (boolTy env t1) (origin env o t1) c' y
            | .error r => fail r (whnfCode r))).map fun j => .obj [("_tag", .str tag), ("value", j)]
        | some (.positional _ ts), args =>
          (toJsonArgs env F o tag 0 ts args).map fun js => .obj [("_tag", .str tag), ("values", .arr js)]
        | _, _ => mismatch c
    | c => mismatch c

def toJsonItems (env : Env) (F : Nat) (o : String) (t : Ty) (i : Nat) : List Typed → Except Error (List JSON)
  | [] => .ok []
  | x :: xs => do
    let j ← under (.index i) (match whnf env env.fuel t with
      | .ok (_, c) => toJsonC env F (boolTy env t) (origin env o t) c x
      | .error r => fail r (whnfCode r))
    let js ← toJsonItems env F o t (i + 1) xs
    return j :: js

def toJsonEntries (env : Env) (F : Nat) (o : String) (t : Ty) :
    List (String × Typed) → Except Error (List (String × JSON))
  | [] => .ok []
  | (k, x) :: fs => do
    let j ← under (.key k) (match whnf env env.fuel t with
      | .ok (_, c) => toJsonC env F (boolTy env t) (origin env o t) c x
      | .error r => fail r (whnfCode r))
    let js ← toJsonEntries env F o t fs
    return (k, j) :: js

def toJsonFields (env : Env) (F : Nat) (o : String) (fields : List Field) :
    List (String × Typed) → Except Error (List (String × JSON))
  | [] => .ok []
  | (k, x) :: fs =>
    match fieldOf? fields k with
    | some f => do
      let j ← under (.key k) (match whnf env env.fuel f.ty with
        | .ok (_, c) => toJsonC env F (boolTy env f.ty) (origin env o f.ty) c x
        | .error r => fail r (whnfCode r))
      let js ← toJsonFields env F o fields fs
      return (k, j) :: js
    | none => .error ⟨[.key k], "not a field of this record", some .unknownField⟩

def toJsonArgs (env : Env) (F : Nat) (o : String) (tag : String) (i : Nat) :
    List Ty → List Typed → Except Error (List JSON)
  | t :: ts, x :: xs => do
    let j ← under (.arg tag i) (match whnf env env.fuel t with
      | .ok (_, c) => toJsonC env F (boolTy env t) (origin env o t) c x
      | .error r => fail r (whnfCode r))
    let js ← toJsonArgs env F o tag (i + 1) ts xs
    return j :: js
  | _, _ => .ok []
end

/-- Writing with a type `t` (written in `o`): through references and secrets, then `toJsonC`. -/
def toJsonF (env : Env) (F : Nat) (o : String) (t : Ty) (x : Typed) : Except Error JSON :=
  match whnf env env.fuel t with
  | .ok (_, c) => toJsonC env F (boolTy env t) (origin env o t) c x
  | .error r => fail r (whnfCode r)

/-- **Schema-based JSON** (§16.3) of a value decoded with the type `t`. -/
def toJson (env : Env) (t : Ty) (x : Typed) : Except Error JSON := toJsonF env (nullFuel env t) "" t x

/-! ## Reading -/

/-- A JSON number as a literal `roundLit` reads: `E` as `e`, no `+`. -/
def jsonToLit (t : Text) : Text :=
  t.filterMap fun c => if c = '+' then none else if c = 'E' then some 'e' else some c

def intOfJson (k : IntType) (j : JSON) : Except Error Typed :=
  let lit? : Option String :=
    if k.asString then (match j with | .str s => some s | _ => none)
    else (match j with | .num t => some t | _ => none)
  match lit? with
  | none =>
    reject .typeMismatch (if k.asString then s!"expected {k.name}: a string holding a whole number" else s!"expected {k.name}: a number")
  | some a =>
    match wholeLit a.toList with
    | some n => if k.inRange n then .ok (.int n) else reject .outOfRange s!"out of range for {k.name}"
    | none =>
      -- A string that isn't a JSON number at all is `invalid-number`, one that is (`"1.5"`) not an integer.
      reject (if isJsonNumber a.toList then .notAnInteger else .invalidNumber)
        s!"expected {k.name}: a whole number, without a fraction or an exponent"

def floatOfJson (k : FloatType) : JSON → Except Error Typed
  | .num t =>
    match roundLit k (String.ofList (jsonToLit t.toList)) with
    | some x => .ok (.float k x)
    | none => reject .outOfRange s!"too large for {k.name}"
  | .str "NaN" => .ok (.float k .nan)
  | .str "Infinity" => .ok (.float k (.inf false))
  | .str "-Infinity" => .ok (.float k (.inf true))
  | _ => reject .typeMismatch s!"expected {k.name}"

/-- A `Decimal`: a string holding a JSON number, kept as its normalized literal. -/
def decimalOf (s : String) : Except Error Typed :=
  if isJsonNumber s.toList then .ok (.decimal (normalizeNumber s.toList))
  else reject .invalidNumber "expected Decimal: a string holding a JSON number"

/-- A field without `?` that the object doesn't have. -/
def missingJ? (fields : List Field) (ms : List (String × JSON)) : Option String :=
  (fields.find? fun f => !f.optional && !ms.any (·.1 == f.key)).map (·.key)

mutual
/-- **Reading schema-based JSON** with a type: through references and secrets, then `fromJsonC`. -/
def fromJsonF (env : Env) (F : Nat) (o : String) (t : Ty) (j : JSON) : Except Error Typed :=
  match whnf env env.fuel t with
  | .error r => fail r (whnfCode r)
  | .ok (s, c) => hidden s c (fromJsonC env F (boolTy env t) (origin env o t) c j)
termination_by (sizeOf j, 2)

/-- A `Maybe` that uses `null` reads `null` as `None`, anything else as `Some`. -/
def fromJsonC (env : Env) (F : Nat) (b : Bool) (o : String) (c : Ty) (j : JSON) : Except Error Typed :=
  match nullArg? env F o c, j with
  | some _, .null => .ok (.case "None" [])
  | some a, j =>
    match whnf env env.fuel a with
    | .error r => fail r (whnfCode r)
    | .ok (s', c') =>
      (hidden s' c' (readCore env F (boolTy env a) (origin env o a) c' j)).map fun y => .case "Some" [y]
  | none, j => readCore env F b o c j
termination_by (sizeOf j, 1)

/-- Every other row of §16.3. -/
def readCore (env : Env) (F : Nat) (b : Bool) (o : String) (c : Ty) (j : JSON) : Except Error Typed :=
  match c, j with
  | .string, .str s => .ok (.str s)
  | .bytes, .str s =>
    match Bytes.unbase64 s.toList with
    | some bs => .ok (.bytes bs)
    | none => reject .invalidBase64 "expected Bytes: base64 with padding"
  | .int k, j => intOfJson k j
  | .float k, j => floatOfJson k j
  | .decimal, .str s => decimalOf s
  | .any, j =>
    match JSON.fromSelfDescribing j with
    | .ok v => .ok (.any v)
    | .error r => reject r.code s!"expected Any: {r.reason}"
  | .time k, .str s => if Time.check k s.toList then .ok (.time k s) else reject .invalidTime s!"not a valid {k.name}"
  | .array t, .arr xs => (readItems env F o t 0 xs).map .arr
  | .map t, .obj ms => (readEntries env F o t ms).map .map
  | .record closed fields, .obj ms =>
    match missingJ? fields ms with
    | some k => reject .missingField s!"missing field {k}"
    | none => (readFields env F o closed fields false ms).map .record
  | .variant closed cases, j =>
    if b then
      match j with
      | .bool b => .ok (.case (if b then "True" else "False") [])
      | _ => reject .typeMismatch "expected true or false"
    else if isEnum (.variant closed cases) then
      match j with
      | .str tag =>
        match caseOf? cases tag with
        | some (.bare _) => .ok (.case tag [])
        | _ => reject .unknownTag s!"unknown tag {tag}"
      | _ => reject .typeMismatch "expected a string: a tag"
    else
      match j with
      | .obj ms =>
        match ms.lookup "_tag" with
        | some (.str tag) =>
          match caseOf? cases tag with
          | some (.bare _) => if ms.length = 1 then .ok (.case tag []) else reject .unexpectedMember s!"{tag} takes no arguments"
          | some (.record _ cl fields) =>
            if hasReservedField fields then .error ⟨[.arg tag 0], reservedFieldReason, some .noJsonForm⟩ else
            match missingJ? fields ms with
            | some k => .error ⟨[.arg tag 0], s!"missing field {k}", some .missingField⟩
            | none => (under (.arg tag 0) (readFields env F o cl fields true ms)).map fun ys => .case tag [.record ys]
          | some (.positional _ []) => if ms.length = 1 then .ok (.case tag []) else reject .unexpectedMember s!"{tag} takes no arguments"
          | some (.positional _ [t1]) =>
            if ms.length = 2 then (memberValue env F o tag t1 ms).map fun y => .case tag [y]
            else reject (memberCode "value" ms) s!"{tag} takes one argument, as value"
          | some (.positional _ ts) =>
            if ms.length = 2 then (memberValues env F o tag ts ms).map (.case tag)
            else reject (memberCode "values" ms) s!"{tag} takes {ts.length} arguments, as values"
          | none =>
            if closed then reject .unknownTag s!"unknown tag {tag}"
            else if !isTag tag.toList then reject .invalidTag "_tag: not a tag"
            else
              -- An unlisted tag (§16.3): bare, its `_args` as self-describing values, or a newer writer's record payload.
              match ms.filter (·.1 != "_tag") with
              | [] => .ok (.unknown tag [])
              | [("_args", x)] =>
                match x with
                | .arr (y :: ys) =>
                  match JSON.fromSelfDescribingList (y :: ys) with
                  | .ok vs => .ok (.unknown tag vs)
                  | .error r => reject r.code s!"_args: {r.reason}"
                | _ => reject .hausJsonForm "_args: not a non-empty array"
              | rest =>
                match JSON.toValueMembers rest with
                | .ok fs => .ok (.unknown tag [.record fs])
                | .error r => reject r.code r.reason
        | _ => reject .missingMember "expected an object with _tag"
      | _ => reject .typeMismatch "expected an object with _tag"
  | c, _ => reject .typeMismatch s!"expected {c.name}"
termination_by (sizeOf j, 0)

def readItems (env : Env) (F : Nat) (o : String) (t : Ty) (i : Nat) (xs : List JSON) :
    Except Error (List Typed) :=
  match xs with
  | [] => .ok []
  | x :: xs => do
    let y ← under (.index i) (fromJsonF env F o t x)
    let ys ← readItems env F o t (i + 1) xs
    return y :: ys
termination_by (sizeOf xs, 0)

def readEntries (env : Env) (F : Nat) (o : String) (t : Ty) (ms : List (String × JSON)) :
    Except Error (List (String × Typed)) :=
  match ms with
  | [] => .ok []
  | (k, x) :: ms => do
    let y ← under (.key k) (fromJsonF env F o t x)
    let ys ← readEntries env F o t ms
    return (k, y) :: ys
termination_by (sizeOf ms, 0)

/-- An object's members as a record's fields; `skipTag`: a payload's `_tag` is not a field. -/
def readFields (env : Env) (F : Nat) (o : String) (closed : Bool) (fields : List Field) (skipTag : Bool)
    (ms : List (String × JSON)) : Except Error (List (String × Typed)) :=
  match ms with
  | [] => .ok []
  | (k, x) :: ms =>
    if skipTag && k == "_tag" then readFields env F o closed fields skipTag ms else
    match fieldOf? fields k with
    | some f => do
      let y ← under (.key k) (fromJsonF env F o f.ty x)
      let ys ← readFields env F o closed fields skipTag ms
      return (k, y) :: ys
    | none =>
      if closed then .error ⟨[.key k], "not a field of this closed record", some .unknownField⟩
      else readFields env F o closed fields skipTag ms
termination_by (sizeOf ms, 0)

def readArgs (env : Env) (F : Nat) (o : String) (tag : String) (i : Nat) (ts : List Ty) (xs : List JSON) :
    Except Error (List Typed) :=
  match ts, xs with
  | t :: ts, x :: xs => do
    let y ← under (.arg tag i) (fromJsonF env F o t x)
    let ys ← readArgs env F o tag (i + 1) ts xs
    return y :: ys
  | _, _ => .ok []
termination_by (sizeOf xs, 0)

/-- The member `value`: one positional argument. -/
def memberValue (env : Env) (F : Nat) (o : String) (tag : String) (t : Ty) (ms : List (String × JSON)) :
    Except Error Typed :=
  match ms with
  | [] => reject .unexpectedMember s!"{tag} takes one argument, as value"
  | (k, x) :: ms =>
    if k = "value" then under (.arg tag 0) (fromJsonF env F o t x) else memberValue env F o tag t ms
termination_by (sizeOf ms, 0)

/-- The member `values`: several positional arguments. -/
def memberValues (env : Env) (F : Nat) (o : String) (tag : String) (ts : List Ty) (ms : List (String × JSON)) :
    Except Error (List Typed) :=
  match ms with
  | [] => reject .unexpectedMember s!"{tag} takes {ts.length} arguments, as values"
  | (k, x) :: ms =>
    if k = "values" then
      match x with
      | .arr xs =>
        if xs.length = ts.length then readArgs env F o tag 0 ts xs else reject .wrongPayload s!"{tag} takes {ts.length} arguments"
      | _ => reject .wrongPayload "values: not an array"
    else memberValues env F o tag ts ms
termination_by (sizeOf ms, 0)
end

/-- **Reading schema-based JSON** (§16.3) with the type `t`. -/
def fromJson (env : Env) (t : Ty) (j : JSON) : Except Error Typed := fromJsonF env (nullFuel env t) "" t j

/-! ## Text -/

def errorText (e : Error) : String := s!"{e.place}: {e.reason}"

/-- An error in JSON text, at the value's root. -/
def textError (e : JSON.Error) : Error := { path := [], reason := e.reason, code := some e.code }

/-- Schema-based JSON text read with a type, within the limits: the value it encodes to (§15) must fit them. -/
def readJson (L : Limits) (env : Env) (t : Ty) (text : Text) : Except Error Typed := do
  let j ← (JSON.parse L text).mapError textError
  let x ← fromJson env t j
  if (encode x).fits L then .ok x
  else .error { path := [], reason := "outside the limits", code := some ((encode x).limitCode L) }

/-- The text of a decoded value's schema-based JSON. -/
def writeJson (env : Env) (t : Ty) (x : Typed) : Except Error Text :=
  (toJson env t x).map JSON.write

/-! ## Tests -/

private def testEnv : Env := ⟨[("T", .ref "Maybe#0"), ("Maybe#0", .maybe (.ref "T")),
  ("D", .ref "Maybe#1"), ("Maybe#1", .maybe (.ref "T")), ("I", .int (.signed 32)),
  ("N", .ref "Maybe#2"), ("Maybe#2", .maybe (.ref "Maybe#3")), ("Maybe#3", .maybe (.ref "I")),
  ("A", .ref "Maybe#4"), ("Maybe#4", .maybe (.ref "B")), ("B", .ref "Maybe#5"), ("Maybe#5", .maybe (.ref "A")),
  ("Bool", Ty.bool), ("Flag", .ref "Bool"), ("Bits", Ty.bool), ("OptFlag", .ref "Maybe#6"),
  ("Maybe#6", .maybe (.ref "Flag")), ("Mine", .maybe (.ref "I")),
  ("Pay", .variant false [.record "C" false [.mk "_tag" true .string]]),
  ("Pay2", .variant false [.record "C" false [.mk "_args" true .string]]),
  ("Shape", .variant false [.bare "Empty"]), ("Raw", .any)]⟩

private def jsonOf (t : String) (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] =>
    match decode testEnv (.ref t) v with
    | .ok x => (writeJson testEnv (.ref t) x).toOption.map String.ofList
    | .error _ => none
  | _ => none

private def readOf (t : String) (json : String) : Option String :=
  (readJson {} testEnv (.ref t) json.toList).toOption.map fun x => String.ofList (Canonical.canonical (encode x))

-- A `Maybe` that reaches itself uses the tagged form; one that only reaches such a `Maybe` doesn't.
#guard jsonOf "T" "None" == some "{\"_tag\":\"None\"}"
#guard jsonOf "T" "Some(None)" == some "{\"_tag\":\"Some\",\"value\":{\"_tag\":\"None\"}}"
#guard jsonOf "D" "None" == some "null"
#guard jsonOf "D" "Some(None)" == some "{\"_tag\":\"None\"}"
#guard jsonOf "A" "None" == some "{\"_tag\":\"None\"}" && jsonOf "B" "Some(None)" == some "{\"_tag\":\"Some\",\"value\":{\"_tag\":\"None\"}}"
#guard jsonOf "N" "None" == some "{\"_tag\":\"None\"}" && jsonOf "N" "Some(None)" == some "{\"_tag\":\"Some\",\"value\":null}"
#guard readOf "D" "null" == some "None" && readOf "D" "{\"_tag\":\"None\"}" == some "Some(None)"
-- The prelude's `Bool` is `true`/`false`, by name; a schema's own `< False | True >` is a closed enum.
#guard jsonOf "Flag" "True" == some "true" && jsonOf "Bits" "True" == some "\"True\""
#guard jsonOf "OptFlag" "None" == some "null" && jsonOf "OptFlag" "Some(False)" == some "false"
#guard readOf "Flag" "true" == some "True" && readOf "Bits" "true" == none
-- A schema's own `closed < None | Some a >` is a variant like any other.
#guard jsonOf "Mine" "None" == some "{\"_tag\":\"None\"}" && jsonOf "Mine" "Some(5)" == some "{\"_tag\":\"Some\",\"value\":5}"
#guard readOf "Mine" "null" == none
-- A record payload with a field named `_tag` or `_args` has no schema-based form.
#guard jsonOf "Pay" "C {}" == none && readOf "Pay" "{\"_tag\":\"C\"}" == none
#guard jsonOf "Pay2" "C {}" == none && readOf "Pay2" "{\"_tag\":\"C\"}" == none
-- An unknown value's arguments are `_args`, self-describing; `args` is a member like any other.
#guard jsonOf "Shape" "Hexagon(1, \"a\")" == some "{\"_tag\":\"Hexagon\",\"_args\":[{\"_num\":\"1\"},\"a\"]}"
#guard readOf "Shape" "{\"_tag\":\"Hexagon\",\"_args\":[{\"_num\":\"1\"},\"a\"]}" == some "Hexagon(1,\"a\")"
#guard readOf "Shape" "{\"_tag\":\"Run\",\"args\":[1,2]}" == some "Run{args:[1,2]}"
#guard readOf "Shape" "{\"_tag\":\"Run\",\"_args\":[]}" == none && readOf "Shape" "{\"_tag\":\"Run\",\"_args\":[1]}" == none
#guard readOf "Shape" "{\"_tag\":\"Run\",\"_args\":[{\"_num\":\"1\"}],\"x\":2}" == some "Run{_args:[{_num:\"1\"}],x:2}"
-- `Any` is the self-describing value without the envelope, and accepts raw controls.
#guard jsonOf "Raw" "[1]" == some "[{\"_num\":\"1\"}]" && readOf "Raw" "{\"_haus\":1,\"_value\":\"x\"}" == none
#guard readOf "Raw" "\"a\u007F\u202Eb\"" == some "\"a\\u{7F}\\u{202E}b\""

end Haus.Schema
