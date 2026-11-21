import Haus.Canonical
import Haus.Schema.Decode
import Haus.Json.SchemaBased
import Haus.Stream.Limited
import Haus.Layout.Compact

/-!
# Versions (spec §10)

From 1.0 on, haus only grows: a later version may make invalid text valid,
but never makes valid text invalid, never changes what valid text means,
what an existing schema accepts or decodes to, or the canonical form or
hash of a value. Default limits may only grow (§7). The three JSON mappings
never change (§16), and neither do the compact and minimised layouts (§11;
the pretty layout may change, as only people read it). Error codes are never renamed or removed, and an input
with one mistake gets the same code everywhere (§17). `Extends old new`
states all of that for two versions, each given by what it fixes.

Defined here, with reflexivity and transitivity; each release proves
`Extends previous release` when it is made. Design review C5 added the JSON
mappings, the hash, the default limits and the error codes.
-/

namespace Haus
open Schema

/--
Reading text: what is read, or the code of the error (§17, by its name, so
that versions with different catalogues compare).
-/
abbrev Reads (α : Type) := Text → Except String α

/--
A type of a version (built in, or of a schema), each part written on haus
values and texts, so that versions with different host types compare.
-/
structure TypeV where
  /-- Decoding (§15), written as the value its encoder writes for what it decoded (`none`: not accepted). -/
  decode : Value → Option Value
  /-- Its schema-based JSON (§16.3): the text written for a value the type decodes (`none`: not decoded, or no form). -/
  toJson : Value → Option Text
  /-- Reading its schema-based JSON (§16.3): the value the decoded result encodes to. -/
  fromJson : Reads Value

/-- What a version of haus fixes. -/
structure Version where
  /-- Its default limits (§7). -/
  limits : Limits
  /-- Its default value limit of stream readers (§7). -/
  maxValueLength : Nat
  /-- Its catalogue of error codes (§17). -/
  codes : List String
  /-- Its files (§1–§8): the values of a text, or the code of the error. -/
  parse : Reads (List Value)
  /--
  The code it fixes for a text with one mistake (§17: the same in every
  implementation; the conformance suite's error cases); `none` for a valid
  text, or one whose code is not fixed (several mistakes, §8).
  -/
  fixed : Text → Option String
  /-- Its canonical form (§12). -/
  canonical : Value → Text
  /-- What `hashAll` hashes for a list of values (§12); `hash v` is `hashAll [v]`. SHA-256 itself is outside the model. -/
  hashAll : List Value → Text
  /-- Its built-in types (§13.1, §13.2), by name. -/
  builtin : String → Option TypeV
  /-- Its schema files (§14, §15): a schema's types, by name; `none` when the schema is rejected. -/
  schema : Text → Option (String → Option TypeV)
  /-- Self-describing JSON (§16.2): the text written for a value. -/
  writeHausJson : Value → Text
  /-- Reading self-describing JSON (§16.2). -/
  readHausJson : Reads Value
  /-- The JSON import (§16.1). -/
  readImport : Reads Value
  /-- The compact layout (§11): the text written for a file's values. -/
  compactAll : List Value → Text
  /-- The minimised layout (§11): the text written for a file's values. -/
  minimisedAll : List Value → Text

/-- What `hash` hashes for one value (§12). -/
def Version.hash (V : Version) (v : Value) : Text := V.hashAll [v]

/-- The values a version can write: those its files hold. -/
def Version.Expresses (V : Version) (v : Value) : Prop := ∃ t vs, V.parse t = .ok vs ∧ v ∈ vs

/-- A version reports the codes it fixes (`haus-ref --suite` checks this on the suite's error cases). -/
def Version.Conforms (V : Version) : Prop := ∀ t c, V.fixed t = some c → V.parse t = .error c

/-- `r'` reads everything `r` reads, as `r` does (and may read more). -/
def Keeps {α : Type} (r r' : Reads α) : Prop := ∀ t a, r t = .ok a → r' t = .ok a

/-- Default limits that are at least as large (§7: they may only grow). -/
def Limits.Le (L L' : Limits) : Prop :=
  L.maxDepth ≤ L'.maxDepth ∧ L.maxNumberLength ≤ L'.maxNumberLength ∧
  L.maxExponent ≤ L'.maxExponent ∧ L.maxStringLength ≤ L'.maxStringLength

/-- Two types decode alike and have the same schema-based JSON on what `V` can express, and the new one reads all JSON the old one reads. -/
def Version.SameType (V : Version) (T T' : TypeV) : Prop :=
  (∀ v, V.Expresses v → T'.decode v = T.decode v) ∧
  (∀ v, V.Expresses v → T'.toJson v = T.toJson v) ∧
  Keeps T.fromJson T'.fromJson

/-- Two schemas have the same types, alike on what `V` can express. -/
def Version.SameTypes (V : Version) (types types' : String → Option TypeV) : Prop :=
  ∀ name T, types name = some T → ∃ T', types' name = some T' ∧ V.SameType T T'

/--
**`new` extends `old`** (§10, §7, §12, §16, §17): every text `old` accepts,
`new` accepts with the same values; on what `old` can express, the
canonical form, the hash and the self-describing JSON are the same; every
built-in type and every type of a schema `old` accepts decodes alike and
has the same schema-based JSON there; each JSON reader reads what the old
one reads, alike; the default limits only grow; no code leaves the
catalogue; a text with one mistake keeps its code, unless it has
become valid; and the compact and minimised layouts write what `old` can
express as `old` does (§10).
-/
structure Extends (old new : Version) : Prop where
  parse : Keeps old.parse new.parse
  canonical : ∀ v, old.Expresses v → new.canonical v = old.canonical v
  hashAll : ∀ vs, (∀ v ∈ vs, old.Expresses v) → new.hashAll vs = old.hashAll vs
  builtin : ∀ name T, old.builtin name = some T → ∃ T', new.builtin name = some T' ∧ old.SameType T T'
  schema : ∀ s types, old.schema s = some types → ∃ types', new.schema s = some types' ∧ old.SameTypes types types'
  writeHausJson : ∀ v, old.Expresses v → new.writeHausJson v = old.writeHausJson v
  readHausJson : Keeps old.readHausJson new.readHausJson
  readImport : Keeps old.readImport new.readImport
  limits : Limits.Le old.limits new.limits
  maxValueLength : old.maxValueLength ≤ new.maxValueLength
  codes : old.codes ⊆ new.codes
  fixed : ∀ t c, old.fixed t = some c → new.fixed t = some c ∨ ∃ vs, new.parse t = .ok vs
  compactAll : ∀ vs, (∀ v ∈ vs, old.Expresses v) → new.compactAll vs = old.compactAll vs
  minimisedAll : ∀ vs, (∀ v ∈ vs, old.Expresses v) → new.minimisedAll vs = old.minimisedAll vs

namespace Keeps

theorem refl {α : Type} (r : Reads α) : Keeps r r := fun _ _ h => h

theorem trans {α : Type} {r r' r'' : Reads α} (h : Keeps r r') (h' : Keeps r' r'') : Keeps r r'' :=
  fun t a hr => h' t a (h t a hr)

end Keeps

theorem Limits.Le.refl (L : Limits) : Limits.Le L L := ⟨Nat.le_refl _, Nat.le_refl _, Nat.le_refl _, Nat.le_refl _⟩

theorem Limits.Le.trans {a b c : Limits} (h : Limits.Le a b) (h' : Limits.Le b c) : Limits.Le a c :=
  ⟨Nat.le_trans h.1 h'.1, Nat.le_trans h.2.1 h'.2.1, Nat.le_trans h.2.2.1 h'.2.2.1, Nat.le_trans h.2.2.2 h'.2.2.2⟩

namespace Extends

/-- What the old version can express, the new one can. -/
theorem expresses {old new : Version} (h : Extends old new) {v : Value} (hv : old.Expresses v) :
    new.Expresses v := by
  obtain ⟨t, vs, hp, hm⟩ := hv
  exact ⟨t, vs, h.parse t vs hp, hm⟩

/-- The hash of a value the old version can express is the same. -/
theorem hash {old new : Version} (h : Extends old new) {v : Value} (hv : old.Expresses v) :
    new.hash v = old.hash v :=
  h.hashAll [v] (by simpa using hv)

/-- The hash of an old file's values is the same, and so are their canonical forms. -/
theorem hashAll_parse {old new : Version} (h : Extends old new) {t : Text} {vs : List Value}
    (hp : old.parse t = .ok vs) :
    new.parse t = .ok vs ∧ new.hashAll vs = old.hashAll vs ∧ vs.map new.canonical = vs.map old.canonical := by
  have hx : ∀ v ∈ vs, old.Expresses v := fun v hv => ⟨t, vs, hp, hv⟩
  refine ⟨h.parse t vs hp, h.hashAll vs hx, ?_⟩
  exact List.map_congr_left fun v hv => h.canonical v (hx v hv)

/-- Self-describing JSON an old version writes, the new one reads as the old one does. -/
theorem readHausJson_write {old new : Version} (h : Extends old new) {v w : Value}
    (hr : old.readHausJson (old.writeHausJson v) = .ok w) (hv : old.Expresses v) :
    new.readHausJson (new.writeHausJson v) = .ok w := by
  rw [h.writeHausJson v hv]; exact h.readHausJson _ _ hr

theorem refl (V : Version) : Extends V V where
  parse := Keeps.refl _
  canonical _ _ := rfl
  hashAll _ _ := rfl
  builtin _ T h := ⟨T, h, fun _ _ => rfl, fun _ _ => rfl, Keeps.refl _⟩
  schema _ types h := ⟨types, h, fun _ T hT => ⟨T, hT, fun _ _ => rfl, fun _ _ => rfl, Keeps.refl _⟩⟩
  writeHausJson _ _ := rfl
  readHausJson := Keeps.refl _
  readImport := Keeps.refl _
  limits := Limits.Le.refl _
  maxValueLength := Nat.le_refl _
  codes := List.Subset.refl _
  fixed _ _ h := .inl h
  compactAll _ _ := rfl
  minimisedAll _ _ := rfl

theorem sameType_trans {a b : Version} (hab : Extends a b) {T T' T'' : TypeV}
    (s1 : a.SameType T T') (s2 : b.SameType T' T'') : a.SameType T T'' :=
  ⟨fun v hv => (s2.1 v (hab.expresses hv)).trans (s1.1 v hv),
   fun v hv => (s2.2.1 v (hab.expresses hv)).trans (s1.2.1 v hv),
   s1.2.2.trans s2.2.2⟩

theorem trans {a b c : Version} (hab : Extends a b) (hbc : Extends b c) : Extends a c where
  parse := hab.parse.trans hbc.parse
  canonical v hv := (hbc.canonical v (hab.expresses hv)).trans (hab.canonical v hv)
  hashAll vs hv := (hbc.hashAll vs fun v hm => hab.expresses (hv v hm)).trans (hab.hashAll vs hv)
  builtin name T h := by
    obtain ⟨T', h', s1⟩ := hab.builtin name T h
    obtain ⟨T'', h'', s2⟩ := hbc.builtin name T' h'
    exact ⟨T'', h'', sameType_trans hab s1 s2⟩
  schema s types h := by
    obtain ⟨types', h', s1⟩ := hab.schema s types h
    obtain ⟨types'', h'', s2⟩ := hbc.schema s types' h'
    refine ⟨types'', h'', fun name T hT => ?_⟩
    obtain ⟨T', hT', e1⟩ := s1 name T hT
    obtain ⟨T'', hT'', e2⟩ := s2 name T' hT'
    exact ⟨T'', hT'', sameType_trans hab e1 e2⟩
  writeHausJson v hv := (hbc.writeHausJson v (hab.expresses hv)).trans (hab.writeHausJson v hv)
  readHausJson := hab.readHausJson.trans hbc.readHausJson
  readImport := hab.readImport.trans hbc.readImport
  limits := hab.limits.trans hbc.limits
  maxValueLength := Nat.le_trans hab.maxValueLength hbc.maxValueLength
  codes := List.Subset.trans hab.codes hbc.codes
  fixed t c h := by
    rcases hab.fixed t c h with h' | ⟨vs, hp⟩
    · exact hbc.fixed t c h'
    · exact .inr ⟨vs, hbc.parse t vs hp⟩
  compactAll vs hv := (hbc.compactAll vs fun v hm => hab.expresses (hv v hm)).trans (hab.compactAll vs hv)
  minimisedAll vs hv := (hbc.minimisedAll vs fun v hm => hab.expresses (hv v hm)).trans (hab.minimisedAll vs hv)

end Extends

/-! ## This version -/

/-- The built-in types without parameters (§13): the prelude's and std/time's. -/
def builtinTy : String → Option Ty
  | "String" => some .string | "Bytes" => some .bytes | "Bool" => some .bool
  | "Int" => some (.int .int) | "Decimal" => some .decimal | "Any" => some .any
  | "Float32" => some (.float .f32) | "Float64" => some (.float .f64)
  | "Int8" => some (.int (.signed 8)) | "Int16" => some (.int (.signed 16))
  | "Int32" => some (.int (.signed 32)) | "Int64" => some (.int (.signed 64))
  | "UInt8" => some (.int (.unsigned 8)) | "UInt16" => some (.int (.unsigned 16))
  | "UInt32" => some (.int (.unsigned 32)) | "UInt64" => some (.int (.unsigned 64))
  | name => (Time.TimeType.all.find? (·.name == name)).map .time

/-- Decoding with a type, written as the value the encoder writes. -/
def decoder (env : Env) (t : Ty) (v : Value) : Option Value := (decode env t v).toOption.map encode

/-- The code of a schema error, by its name. -/
def Schema.Error.codeName (e : Schema.Error) : String := (e.code.map Code.name).getD ""

/-- A type of this version, with the default limits `L`. -/
def typeV (L : Limits) (env : Env) (t : Ty) : TypeV where
  decode := decoder env t
  toJson v := match decode env t v with
    | .ok x => (writeJson env t x).toOption
    | .error _ => none
  fromJson text := ((readJson L env t text).map encode).mapError Schema.Error.codeName

/--
The version this model describes. Schema files are parsed outside Lean
(the TypeScript binding's resolver, `scripts/schema-types.ts`), so the
resolver is a parameter: a schema text's types, or `none` when it is
rejected. So are the codes the conformance suite fixes (`fixed`: its error
cases, which `haus-ref --suite` checks against `parse`).
-/
def current (resolve : Text → Option Env) (fixed : Text → Option String := fun _ => none) : Version where
  limits := {}
  maxValueLength := ({} : Stream.Options).maxValueLength
  codes := Code.all.map Code.name
  parse t := (Parser.parse {} t).mapError (·.code.name)
  fixed := fixed
  canonical := Canonical.canonical
  hashAll := Canonical.canonicalAll
  builtin name := (builtinTy name).map (typeV {} ⟨[]⟩)
  schema s := (resolve s).map fun env name => (env.lookup name).map fun _ => typeV {} env (.ref name)
  writeHausJson := JSON.writeHausJson
  readHausJson t := (JSON.readHausJson {} t).mapError (·.code.name)
  readImport t := (JSON.readImport {} t).mapError (·.code.name)
  compactAll := Layout.compactAll
  minimisedAll := Layout.minimisedAll

/-- `hash v` of this version hashes the canonical form of `v` (§12). -/
theorem current_hash (resolve : Text → Option Env) (fixed : Text → Option String) (v : Value) :
    (current resolve fixed).hash v = Canonical.canonical v := rfl

/--
Every code this version's parser reports is in its catalogue, but for
running out of fuel, which no valid text does (`parse_complete`).
-/
theorem current_parse_code (resolve : Text → Option Env) (fixed : Text → Option String) {t : Text} {c : String}
    (h : (current resolve fixed).parse t = .error c) :
    c ∈ (current resolve fixed).codes ∨ c = Code.outOfFuel.name := by
  simp only [current] at h ⊢
  cases hp : Parser.parse {} t with
  | ok vs => rw [hp] at h; cases h
  | error e =>
    rw [hp] at h
    simp only [Except.mapError, Except.error.injEq] at h
    subst h
    by_cases he : e.code = .outOfFuel
    · exact .inr (by rw [he])
    · exact .inl (List.mem_map.mpr ⟨e.code, Code.mem_all _ he, rfl⟩)

/-- The current version extends itself; each release proves it extends the one before. -/
theorem current_extends_self (resolve : Text → Option Env) (fixed : Text → Option String) :
    Extends (current resolve fixed) (current resolve fixed) :=
  .refl _

end Haus
