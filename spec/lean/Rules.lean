import HausMoney
import HausGeo
import HausUuid
import Haus.Parser
import Haus.Canonical

/-!
# `haus-rules`: the official packages' rules and their test vectors (packages.md §6) — X2

The models of the official packages' rules live with the packages
(`extensions/<name>/lean/`, the libraries `HausMoney`, `HausGeo`,
`HausUuid`), outside the core library `Haus`: `haus-ref` doesn't import
them, and this second executable runs them. `all` lists the rules with their
package's schema and checker.

    haus-rules --rule NAME FILE         run the test vectors FILE of the official rule NAME
                                        (`@haus-fmt/money/iso`, `@haus-fmt/geo/wgs84`,
                                        `@haus-fmt/uuid/rfc9562`) with its reference checker
    haus-rules --rule-batch NAME FILE   for each line `TYPE HEX` of FILE (a value's haus text
                                        as hex-encoded UTF-8): decode with the type of the rule's
                                        package, then the rule: `ok <canonical form of the encoded
                                        result>`, `err <place> <code> <reason>` when the schema
                                        rejects it, or `err $ codec-rejected <reason>` when the
                                        rule does (fuzz/)

`--profile` and `--profile-batch` are the same, under their names of
`haus-ref` before the models moved.

A vectors file (`<name>.vectors.haus`) is a list of

    Accept { type: "T", value: "<haus text>", output?: "<haus text>", note?: "…" }
    Reject { type: "T", value: "<haus text>", looser?: ["U", …], note?: "…" }

`value` is haus text for the type `T` of the package's schema. An `Accept`
passes when the rule (§13.4: the schema, then the checker, as a codec that
keeps the decoded value) accepts `value`, and what it writes back is the
same value as `output`, or as `value` when there is no `output`: `output`
decoded the same way gives the same encoding. An `output`, when given, must
also be exactly what is written (§2): it says how the value is written back.
A `Reject` passes when `value` is valid for the schema of `T` (the shape) and
the rule rejects it, so the rejection comes from the rule; a `Reject` the
schema already rejects fails, with the schema's error.

`looser` names types of the package for which the bindings run the `Reject`
again with an application's codec that accepts every value of the type's
schema. Here the rule is a check on the value the schema decoded (§13.4,
`Codec.lean`; packages.md §6: a rule is checked before any codec), so no
codec can change what the rule sees: the vector runs once, and its `looser`
types must be types of the package.
-/

namespace Haus.Rules
open Haus Schema

/-- An official package's rule: its name (`package/rule`), its package's schema, and the checker of each type it decides on. -/
structure Rule where
  name : String
  env : Env
  checks : List (String × (Typed → Bool))

/-- The checker of a type of the rule. -/
def Rule.check? (p : Rule) (type : String) : Option (Typed → Bool) := p.checks.lookup type

/-- Decoding a value of a type with the rule: the schema, then the checker. -/
def Rule.decode (p : Rule) (type : String) (check : Typed → Bool) (v : Value) : Except Error Typed :=
  (Codec.check check).decode p.env (.ref type) v

def money : Rule where
  name := "@haus-fmt/money/iso"
  env := Money.env
  checks := Money.Type_.all.map fun t => (t.name, Money.check t)

def geo : Rule where
  name := "@haus-fmt/geo/wgs84"
  env := Geo.env
  checks := Geo.Type_.all.map fun t => (t.name, Geo.check t)

def uuid : Rule where
  name := "@haus-fmt/uuid/rfc9562"
  env := Uuid.env
  checks := Uuid.Type_.all.map fun t => (t.name, Uuid.check t)

def all : List Rule := [money, geo, uuid]

def find? (name : String) : Option Rule := all.find? (·.name == name)

/-! ## Vectors -/

/-- A test vector. -/
structure Vector where
  accept : Bool
  type : String
  value : String
  output : Option String
  looser : List String := []

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
      unless ["type", "value", "output", "looser", "note"].contains k && (accept || k != "output") && (!accept || k != "looser") do
        throw s!"unexpected field {k}"
    let some type ← strField fs "type" | throw "no type"
    let some value ← strField fs "value" | throw "no value"
    let looser ← match fs.lookup "looser" with
      | none => pure []
      | some (.arr xs) => xs.mapM fun | .str s => pure s | _ => throw "looser is not a list of strings"
      | some _ => throw "looser is not a list of strings"
    return { accept, type, value, output := ← strField fs "output", looser }
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
def Vector.run (p : Rule) (vec : Vector) : Except String String := do
  let some check := p.check? vec.type | throw s!"{vec.type} is not a type of {p.name}"
  if let some t := vec.looser.find? (p.check? · |>.isNone) then throw s!"looser: {t} is not a type of {p.name}"
  let v ← (parseOne vec.value).mapError (s!"value: " ++ ·)
  -- A `Reject` must have the shape of its type, so that the rule rejects it.
  if !vec.accept then
    if let .error e := Schema.decode p.env (.ref vec.type) v then
      throw s!"a Reject vector must be valid for the schema of {vec.type}, so that the rejection comes from the rule; the schema already rejects it: {errorText e}"
  -- Who rejected it: the schema, with its error, or the rule.
  let why (e : Error) : String :=
    match Schema.decode p.env (.ref vec.type) v with
    | .error _ => s!"rejected by the schema: {errorText e}"
    | .ok _ => "rejected by the rule"
  match p.decode vec.type check v, vec.accept with
  | .error e, true => throw (why e)
  | .error e, false =>
    -- The rule's rejection has the code `codec-rejected` (§13.4).
    if (Schema.decode p.env (.ref vec.type) v).toBool && e.code != some .codecRejected then
      throw s!"rejected by the rule with {errorText e}, not codec-rejected"
    return why e
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

/-! ## The command line -/

def oneLine (s : String) : String := (s.replace "\r" "\\r").replace "\n" "\\n"

/-- UTF-8 bytes parsed as haus text, or why not. -/
def parseBytes (bytes : ByteArray) : Except String (List Value) :=
  match String.fromUTF8? bytes with
  | none => .error "invalid UTF-8 [invalid-utf8]"
  | some s => (Parser.parse {} s.toList).mapError fun e => s!"{e.reason} [{e.code}]"

/-- The bytes of hex text. -/
def unhex (hex : String) : ByteArray :=
  let digit (c : Char) : Nat := if c.isDigit then c.toNat - '0'.toNat else c.toNat - 'a'.toNat + 10
  let cs := hex.toList.toArray
  ⟨(Array.range (cs.size / 2)).map fun i => UInt8.ofNat (digit cs[2 * i]! * 16 + digit cs[2 * i + 1]!)⟩

def codeText : Option Code → String
  | some c => c.name
  | none => "-"

/-- `--rule NAME FILE`: every vector of FILE, with the reference checker of the rule NAME. -/
def runVectors (name : String) (file : System.FilePath) : IO UInt32 := do
  let some p := find? name
    | IO.eprintln s!"unknown rule {name} ({(all.map (·.name))})"; return 2
  let vs ← match parseBytes (← IO.FS.readBinFile file) with
    | .ok vs => pure vs
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
  let mut failed := 0
  for v in vs do
    let shown := oneLine (canonicalText v)
    match Vector.ofValue v >>= fun vec => (vec.run p).map (vec, ·) with
    | .ok (vec, what) => IO.println s!"ok   {if vec.accept then "Accept" else "Reject"} {vec.type} {vec.value}: {what}"
    | .error why => failed := failed + 1; IO.println s!"FAIL {shown}: {why}"
  IO.println s!"{vs.length - failed}/{vs.length} passed"
  return if failed == 0 then 0 else 1

/-- One line of `--rule-batch`: `TYPE HEX`. -/
def batchLine (p : Rule) (line : String) : String :=
  match line.splitOn " " with
  | [type, hex] =>
    match p.check? type, parseBytes (unhex hex) with
    | none, _ => s!"err $ - {type} is not a type of {p.name}"
    | some _, .error e => s!"err $ - {oneLine e}"
    | some check, .ok [v] =>
      match Schema.decode p.env (.ref type) v, p.decode type check v with
      | _, .ok x => s!"ok {canonicalText (Schema.encode x)}"
      | .error e, _ => s!"err {e.place} {codeText e.code} {oneLine e.reason}"
      | .ok _, .error _ => s!"err $ {Code.codecRejected.name} not accepted by {p.name}"
    | some _, .ok _ => "err $ - not a single value"
  | _ => "err $ - bad line"

def runBatch (name : String) (file : System.FilePath) : IO UInt32 := do
  let some p := find? name | IO.eprintln s!"unknown rule {name}"; return 2
  let out ← IO.getStdout
  for line in (← IO.FS.lines file) do
    if !line.isEmpty then out.putStrLn (batchLine p line)
  return 0

end Haus.Rules

def main : List String → IO UInt32
  | ["--rule", name, file] | ["--profile", name, file] => Haus.Rules.runVectors name file
  | ["--rule-batch", name, file] | ["--profile-batch", name, file] => Haus.Rules.runBatch name file
  | _ => do IO.eprintln "usage: haus-rules --rule NAME FILE | --rule-batch NAME FILE"; return 2
