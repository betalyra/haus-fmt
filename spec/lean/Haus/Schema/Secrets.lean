import Haus.Schema.Decode

/-!
# Encoding a secret (spec §15, "Encoding a secret")

A secret is not a haus value of the program: `Typed.secret` exists only in a
decoded result, and `Value` has no such node (§15, `decode.secret.not-a-value`).
An encoder refuses a secret by default, with `cannot-encode` at the secret
(`encodeWith env t false`); with `revealSecrets` (`encodeWith env t true`) it
writes every secret in full, as `encode` does, and the value it gives is
ordinary data.

`secretAt env t x` is the place of the first secret in a value `x` decoded
with the type `t`, in the order of the value, with the steps of §15: a
record case's fields are steps from the case itself, so the type is needed
to tell a record case from a positional argument that is a record. The
schema-based JSON writer refuses a secret the same way, at the same place
(`Json.SchemaBased`'s runners use `secretAt` before writing).
-/

namespace Haus.Schema
open Haus

mutual
/-- The place of the first secret in `x`, decoded with the type `t`; `none` if it holds none. -/
def secretAt (env : Env) (t : Ty) : Typed → Option (List Seg)
  | .secret _ => some []
  | .arr xs =>
    match whnf env env.fuel t with
    | .ok (_, .array e) => secretItems env e 0 xs
    | _ => none
  | .map fs =>
    match whnf env env.fuel t with
    | .ok (_, .map e) => secretEntries env e fs
    | _ => none
  | .record fs =>
    match whnf env env.fuel t with
    | .ok (_, .record _ fields) => secretFields env fields fs
    | _ => none
  | .case tag args =>
    match whnf env env.fuel t with
    | .ok (_, .variant _ cases) =>
      match caseOf? env cases tag with
      -- A record case: its fields are steps from the case itself (§15).
      | some (.record _ cl fields) => secretOne env (.record cl fields) args
      | some (.positional _ ts) => secretArgs env tag 0 ts args
      | _ => none
    | _ => none
  | _ => none

/-- The only argument of a record case. -/
def secretOne (env : Env) (t : Ty) : List Typed → Option (List Seg)
  | [x] => secretAt env t x
  | _ => none

def secretItems (env : Env) (t : Ty) (i : Nat) : List Typed → Option (List Seg)
  | [] => none
  | x :: xs =>
    match secretAt env t x with
    | some p => some (.index i :: p)
    | none => secretItems env t (i + 1) xs

def secretEntries (env : Env) (t : Ty) : List (String × Typed) → Option (List Seg)
  | [] => none
  | (k, x) :: fs =>
    match secretAt env t x with
    | some p => some (.key k :: p)
    | none => secretEntries env t fs

def secretFields (env : Env) (fields : List Field) : List (String × Typed) → Option (List Seg)
  | [] => none
  | (k, x) :: fs =>
    match (fieldOf? fields k).bind fun f => secretAt env f.ty x with
    | some p => some (.key k :: p)
    | none => secretFields env fields fs

def secretArgs (env : Env) (tag : String) (i : Nat) : List Ty → List Typed → Option (List Seg)
  | t :: ts, x :: xs =>
    match secretAt env t x with
    | some p => some (.arg tag i :: p)
    | none => secretArgs env tag (i + 1) ts xs
  | _, _ => none
end

/-- The error for a secret encoded without `revealSecrets`: its place, nothing of the value. -/
def secretRefused (p : List Seg) : Error :=
  { path := p, reason := "a secret, written only with revealSecrets (the value is not shown)", code := some .cannotEncode }

/--
**Encoding with or without `revealSecrets`** (§15, "Encoding a secret"), of
a value decoded with the type `t`: without it, a secret is refused, at the
first one; with it, every secret is written in full.
-/
def encodeWith (env : Env) (t : Ty) (reveal : Bool) (x : Typed) : Except Error Value :=
  if reveal then .ok (encode x)
  else match secretAt env t x with
    | some p => .error (secretRefused p)
    | none => .ok (encode x)

/-- With `revealSecrets`, encoding is `encode`: every secret written in full. -/
theorem encodeWith_reveal (env : Env) (t : Ty) (x : Typed) : encodeWith env t true x = .ok (encode x) := rfl

/-- A value without a secret encodes alike with and without the option. -/
theorem encodeWith_no_secret {env : Env} {t : Ty} {x : Typed} (h : secretAt env t x = none) (reveal : Bool) :
    encodeWith env t reveal x = .ok (encode x) := by
  cases reveal <;> simp [encodeWith, h]

/-- Without the option, a secret is `cannot-encode` at its place. -/
theorem encodeWith_secret {env : Env} {t : Ty} {x : Typed} {p : List Seg} (h : secretAt env t x = some p) :
    encodeWith env t false x = .error (secretRefused p) := by
  simp [encodeWith, h]

/-! ## Examples -/

private def env : Env := ⟨[("Key", .secret .string),
  ("Config", .record false [.mk "name" false .string, .mk "key" false (.ref "Key"), .mk "pin" true (.secret (.int .int))]),
  ("Vault", .map (.secret (.record false [.mk "id" false (.int .int)]))),
  ("Box", .variant true [.positional "Box" [.secret (.record false [.mk "w" false (.int .int)])]]),
  ("Shape", .variant true [.record "Circle" false [.mk "r" false (.ref "Key")]])]⟩

private def placeOf (t : String) (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] =>
    match decode env (.ref t) v with
    | .ok x =>
      match encodeWith env (.ref t) false x with
      | .error e => some e.place
      | .ok _ => none
    | .error _ => none
  | _ => none

#guard placeOf "Key" "\"sk-1\"" == some "$"
#guard placeOf "Config" "{ name: \"a\", key: \"sk-1\" }" == some "$.key"
#guard placeOf "Config" "{ pin: 1, name: \"a\", key: \"sk-1\" }" == some "$.pin"
#guard placeOf "Vault" "{ a: { id: 1 } }" == some "$.a"
#guard placeOf "Vault" "{}" == none
#guard placeOf "Box" "Box { w: 1 }" == some "$[0]"
-- A record case's fields are steps from the case itself.
#guard placeOf "Shape" "Circle { r: \"x\" }" == some "$.r"

end Haus.Schema
