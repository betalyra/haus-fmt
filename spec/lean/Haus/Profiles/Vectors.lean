import Haus.Profiles.Money
import Haus.Profiles.Geo
import Haus.Parser

/-!
# The official profiles and their test vectors (spec §13.3) — X2

`all` lists the official profiles with their schema and checker, for
`haus-ref --profile NAME FILE` and `haus-ref --profile-batch NAME FILE`.

A vectors file (`profiles/NAME.vectors.haus`) is a list of

    Accept { type: "T", value: "<haus text>", output?: "<haus text>", note?: "…" }
    Reject { type: "T", value: "<haus text>", note?: "…" }

`value` is haus text for the type `T` of the package's schema. An `Accept`
passes when the profile's codec (§13.4: the schema, then the checker)
accepts `value`, and what it writes back is the same value as `output`, or
as `value` when there is no `output`: `output` decoded with the codec gives
the same encoding. An `output`, when given, must also be exactly what the
codec writes (§2): it says how the value is written back. A `Reject` passes
when `value` is valid for the schema of `T` (the shape) and the codec
rejects it, so the rejection comes from the profile's rule; a `Reject` the
schema already rejects fails, with the schema's error.
-/

namespace Haus.Profiles
open Haus Schema

/-- An official profile: its name, its package's schema, and the checker of each type it has a rule for. -/
structure Profile where
  name : String
  env : Env
  checks : List (String × (Typed → Bool))

/-- The checker of a type of the profile. -/
def Profile.check? (p : Profile) (type : String) : Option (Typed → Bool) := p.checks.lookup type

/-- Decoding a value of a type with the profile's codec: the schema, then the checker. -/
def Profile.decode (p : Profile) (type : String) (check : Typed → Bool) (v : Value) : Except Error Typed :=
  (Codec.check check).decode p.env (.ref type) v

def money : Profile where
  name := "@haus-fmt/money/iso"
  env := Money.env
  checks := Money.Type_.all.map fun t => (t.name, Money.check t)

def geo : Profile where
  name := "@haus-fmt/geo/wgs84"
  env := Geo.env
  checks := Geo.Type_.all.map fun t => (t.name, Geo.check t)

def all : List Profile := [money, geo]

def find? (name : String) : Option Profile := all.find? (·.name == name)

/-! ## Vectors -/

/-- A test vector. -/
structure Vector where
  accept : Bool
  type : String
  value : String
  output : Option String

def strField (fs : List (String × Value)) (k : String) : Except String (Option String) :=
  match fs.lookup k with
  | none => .ok none
  | some (.str s) => .ok (some s)
  | some _ => .error s!"{k} is not a string"

/-- A vector, read from its haus value. -/
def Vector.ofValue : Value → Except String Vector
  | .variant tag [.record fs] => do
    let accept ← if tag == "Accept" then pure true else if tag == "Reject" then pure false
      else throw s!"not Accept or Reject: {tag}"
    for (k, _) in fs do
      unless ["type", "value", "output", "note"].contains k && (accept || k != "output") do
        throw s!"unexpected field {k}"
    let some type ← strField fs "type" | throw "no type"
    let some value ← strField fs "value" | throw "no value"
    return { accept, type, value, output := ← strField fs "output" }
  | _ => .error "not a vector"

/-- Haus text that is exactly one value. -/
def parseOne (text : String) : Except String Value :=
  match Parser.parse {} text.toList with
  | .ok [v] => .ok v
  | .ok vs => .error s!"{vs.length} values instead of one"
  | .error e => .error s!"{e.reason} [{e.code}]"

def canonicalText (v : Value) : String := String.ofList (Canonical.canonical v)

def errorText (e : Error) : String :=
  let code := match e.code with | some c => s!" [{c}]" | none => ""
  s!"{e.place}: {e.reason}{code}"

/--
Running a vector: `.ok` with what happened when it passes, `.error` with why
when it fails.
-/
def Vector.run (p : Profile) (vec : Vector) : Except String String := do
  let some check := p.check? vec.type | throw s!"{vec.type} is not a type of {p.name}"
  let v ← (parseOne vec.value).mapError (s!"value: " ++ ·)
  -- A `Reject` must have the shape of its type, so that the rule rejects it.
  if !vec.accept then
    if let .error e := Schema.decode p.env (.ref vec.type) v then
      throw s!"a Reject vector must be valid for the schema of {vec.type}, so that the rejection comes from the profile's rule; the schema already rejects it: {errorText e}"
  -- Who rejected it: the schema, with its error, or the profile.
  let why (e : Error) : String :=
    match Schema.decode p.env (.ref vec.type) v with
    | .error _ => s!"rejected by the schema: {errorText e}"
    | .ok _ => "rejected by the profile"
  match p.decode vec.type check v, vec.accept with
  | .error e, true => throw (why e)
  | .error e, false => return why e
  | .ok x, false => throw s!"accepted, writes {canonicalText (Schema.encode x)}"
  | .ok x, true =>
    let wrote := canonicalText (Schema.encode x)
    let expected := vec.output.getD vec.value
    let w ← (parseOne expected).mapError (s!"output: " ++ ·)
    match p.decode vec.type check w with
    | .error e => throw s!"the expected output is rejected: {errorText e}"
    | .ok y =>
      if canonicalText (Schema.encode y) != wrote then throw s!"writes {wrote}, not the value {expected}"
      if vec.output.isSome && canonicalText w != wrote then throw s!"writes {wrote}, not {expected}"
      return s!"writes {wrote}"

end Haus.Profiles
