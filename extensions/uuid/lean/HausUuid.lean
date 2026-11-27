import Haus.Schema.Codec

/-!
# The rule `rfc9562` of `@haus-fmt/uuid`, version 1 — X2, X4

The rule of [`profiles/rfc9562.md`](../profiles/rfc9562.md) (packages.md §6),
stated on the values the schema decoded: a `Uuid` is
`Uuid(text)` where the text is the RFC 9562 form in lowercase, 32
hexadecimal digits `0`–`9`, `a`–`f` in groups of 8, 4, 4, 4 and 12, with a
hyphen between the groups. No version or variant is checked: the nil and the
max UUID are accepted.

`Valid` is the rule, `check` computes it (`check_iff`), and `codec` is the
rule as a check on the decoded value (§13.4), so the laws of
`Haus.Schema.Codec` hold for it. Built as the library `HausUuid` of
`spec/lean`, run by `haus-rules`.
`one_spelling` (X4): two accepted texts with the same 32 digit values are the
same text, so each UUID has exactly one spelling, and haus equality, the
canonical form and the hash agree with UUID equality.
-/

namespace Haus.Rules.Uuid
open Haus Schema

/-- The schema of `@haus-fmt/uuid` (`extensions/uuid/schema.haus`), resolved. -/
def env : Env := ⟨[
  -- type Uuid = closed < Uuid String >
  ("Uuid", .variant true [.positional "Uuid" [.string]])]⟩

/-- The types the rule decides on. -/
inductive Type_ where
  | uuid
  deriving DecidableEq, Repr

def Type_.name : Type_ → String
  | .uuid => "Uuid"

def Type_.all : List Type_ := [.uuid]

/-! ## The rule -/

/-- A lowercase hexadecimal digit: `0`–`9` (U+0030–U+0039) or `a`–`f` (U+0061–U+0066). -/
def Hex (c : Char) : Prop := ('0' ≤ c ∧ c ≤ '9') ∨ ('a' ≤ c ∧ c ≤ 'f')

/-- The places of the text form, one per character: `true` for a hyphen, `false` for a digit (8-4-4-4-12). -/
def pattern : List Bool :=
  List.replicate 8 false ++ [true] ++ List.replicate 4 false ++ [true] ++ List.replicate 4 false ++ [true] ++
    List.replicate 4 false ++ [true] ++ List.replicate 12 false

/-- A character fits its place: a hyphen `-` (U+002D) where the pattern has one, a digit elsewhere. -/
def Fits : Bool → Char → Prop
  | true, c => c = '-'
  | false, c => Hex c

/-- Characters fitting places one to one: as many of each, each character fitting its place. -/
inductive FitsAll : List Bool → List Char → Prop
  | nil : FitsAll [] []
  | cons {p : Bool} {c : Char} {ps : List Bool} {cs : List Char} : Fits p c → FitsAll ps cs → FitsAll (p :: ps) (c :: cs)

/-- The text form: as many characters as the pattern (36), each fitting its place. -/
def Text (cs : List Char) : Prop := FitsAll pattern cs

/-- A `Uuid` the rule accepts: its string is the text form. -/
inductive Uuid : Typed → Prop
  | mk {s : String} : Text s.toList → Uuid (.case "Uuid" [.str s])

/-- **The rule**, by type: which decoded values of each type the rule accepts. -/
def Valid : Type_ → Typed → Prop
  | .uuid => Uuid

/-! ## The checker -/

def isHex (c : Char) : Bool := ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f')

def fits : Bool → Char → Bool
  | true, c => c == '-'
  | false, c => isHex c

/-- Each character against its place of the pattern, in one pass. -/
def checkText : List Bool → List Char → Bool
  | [], [] => true
  | p :: ps, c :: cs => fits p c && checkText ps cs
  | _, _ => false

def checkUuid : Typed → Bool
  | .case tag [.str s] => tag == "Uuid" && checkText pattern s.toList
  | _ => false

/-- The checker: whether the rule accepts a decoded value of the type `ty`. -/
def check : Type_ → Typed → Bool
  | .uuid => checkUuid

/-! ## The checker computes the rule -/

theorem isHex_iff (c : Char) : isHex c = true ↔ Hex c := by
  simp [isHex, Hex]

theorem fits_iff (p : Bool) (c : Char) : fits p c = true ↔ Fits p c := by
  cases p <;> simp [fits, Fits, isHex_iff]

theorem checkText_iff (ps : List Bool) (cs : List Char) : checkText ps cs = true ↔ FitsAll ps cs := by
  induction ps generalizing cs with
  | nil =>
    cases cs with
    | nil => exact ⟨fun _ => .nil, fun _ => rfl⟩
    | cons => exact ⟨fun h => by simp [checkText] at h, fun h => nomatch h⟩
  | cons p ps ih =>
    cases cs with
    | nil => exact ⟨fun h => by simp [checkText] at h, fun h => nomatch h⟩
    | cons c cs =>
      simp only [checkText, Bool.and_eq_true, fits_iff, ih]
      exact ⟨fun ⟨h1, h2⟩ => .cons h1 h2, fun | .cons h1 h2 => ⟨h1, h2⟩⟩

theorem checkUuid_iff (x : Typed) : checkUuid x = true ↔ Uuid x := by
  constructor
  · intro h
    unfold checkUuid at h
    split at h
    · simp only [Bool.and_eq_true, beq_iff_eq] at h
      obtain ⟨rfl, ht⟩ := h
      exact .mk ((checkText_iff _ _).mp ht)
    · simp at h
  · rintro ⟨ht⟩
    simp [checkUuid, (checkText_iff _ _).mpr ht]

/-- **The checker computes the rule**, for every type and decoded value. -/
theorem check_iff (ty : Type_) (x : Typed) : check ty x = true ↔ Valid ty x := by
  cases ty
  exact checkUuid_iff x

/-! ## The rule as a codec -/

/-- The rule as a codec (§13.4): a check on the decoded value. -/
def codec (ty : Type_) : Codec Typed := Codec.check (check ty)

/-- The codec accepts exactly the values the schema decodes that the rule accepts, and holds them as decoded. -/
theorem codec_decode {ty : Type_} {v : Value} {x : Typed} :
    (codec ty).decode env (.ref ty.name) v = .ok x ↔ Schema.decode env (.ref ty.name) v = .ok x ∧ Valid ty x := by
  rw [codec, Codec.check_decode, check_iff]

/-- Decode, encode, decode is decode (`Codec.decode_encode`). -/
theorem codec_decode_encode {ty : Type_} {v : Value} {x : Typed}
    (h : (codec ty).decode env (.ref ty.name) v = .ok x) : (codec ty).decode env (.ref ty.name) (Schema.encode x) = .ok x :=
  Codec.check_decode_encode h

/-- The codec keeps the value, so every law of `Haus.Schema.Codec` holds for it. -/
theorem codec_keeps (ty : Type_) : (codec ty).Keeps := Codec.check_keeps _

/-! ## One spelling per value (X4)

A UUID is its 32 digits, each a number 0–15. The text form has one spelling
for each: two accepted texts whose digits have the same values are the same
text. So the rule needs no normal form, and haus equality, the canonical
form and the hash of `Uuid("…")` agree with UUID equality (packages.md §6,
`packages.rules.spellings`).
-/

/-- The value of a hexadecimal digit: `0`–`9` are 0–9, `a`–`f` are 10–15. -/
def digit (c : Char) : Nat := if c ≤ '9' then c.toNat - '0'.toNat else c.toNat - 'a'.toNat + 10

/-- The values of the digits of a text, in order, skipping the places of the hyphens. -/
def digits : List Bool → List Char → List Nat
  | true :: ps, _ :: cs => digits ps cs
  | false :: ps, c :: cs => digit c :: digits ps cs
  | _, _ => []

theorem le_toNat {c d : Char} : c ≤ d ↔ c.toNat ≤ d.toNat := .rfl

theorem digit_lt {c : Char} (h : Hex c) : digit c < 16 := by
  simp only [Hex, le_toNat] at h
  unfold digit
  simp only [le_toNat]
  split <;> simp_all <;> omega

theorem digit_inj {c d : Char} (hc : Hex c) (hd : Hex d) (h : digit c = digit d) : c = d := by
  simp only [Hex, le_toNat] at hc hd
  unfold digit at h
  simp only [le_toNat] at h
  apply Char.ext
  apply UInt32.toNat_inj.mp
  have : c.val.toNat = c.toNat := rfl
  have : d.val.toNat = d.toNat := rfl
  split at h <;> split at h <;> simp_all <;> omega

theorem digits_inj {ps : List Bool} {cs ds : List Char} (hc : FitsAll ps cs) (hd : FitsAll ps ds)
    (h : digits ps cs = digits ps ds) : cs = ds := by
  induction hc generalizing ds with
  | nil => cases hd; rfl
  | @cons p c ps cs hpc _ ih =>
    cases hd with
    | cons hpd hrest =>
      cases p
      · simp only [digits, List.cons.injEq] at h
        rw [digit_inj hpc hpd h.1, ih hrest h.2]
      · simp only [Fits] at hpc hpd
        simp only [digits] at h
        rw [hpc, hpd, ih hrest h]

/-- **One spelling**: two texts the rule accepts with the same digits are the same text. -/
theorem one_spelling {s t : String} (hs : Text s.toList) (ht : Text t.toList)
    (h : digits pattern s.toList = digits pattern t.toList) : s = t :=
  String.toList_inj.mp (digits_inj hs ht h)

/-- Every accepted text has 32 digits, each 0–15: a 128-bit number. -/
theorem digits_length {cs : List Char} (h : Text cs) : (digits pattern cs).length = 32 ∧ ∀ n ∈ digits pattern cs, n < 16 := by
  suffices ∀ {ps : List Bool} {cs : List Char}, FitsAll ps cs →
      (digits ps cs).length = ps.count false ∧ ∀ n ∈ digits ps cs, n < 16 by
    have := this h
    exact ⟨by rw [this.1]; decide, this.2⟩
  intro ps cs h
  induction h with
  | nil => simp [digits]
  | @cons p c ps cs hpc _ ih =>
    cases p
    · refine ⟨by simp [digits, ih.1], ?_⟩
      intro n hn
      simp only [digits, List.mem_cons] at hn
      rcases hn with rfl | hn
      · exact digit_lt hpc
      · exact ih.2 n hn
    · exact ⟨by simp [digits, ih.1], fun n hn => ih.2 n (by simpa [digits] using hn)⟩

#guard check .uuid (.case "Uuid" [.str "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"])
#guard check .uuid (.case "Uuid" [.str "00000000-0000-0000-0000-000000000000"])
#guard check .uuid (.case "Uuid" [.str "ffffffff-ffff-ffff-ffff-ffffffffffff"])
#guard !check .uuid (.case "Uuid" [.str "0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57"])
#guard !check .uuid (.case "Uuid" [.str "{0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57}"])
#guard !check .uuid (.case "Uuid" [.str "0190c7a85b6e7d3f9a416c2e8f1b0d57"])
#guard !check .uuid (.case "Uuid" [.str "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d5"])
#guard !check .uuid (.case "Uuid" [.str "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d570"])
#guard (digits pattern "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57".toList).take 5 == [0, 1, 9, 0, 12]
#guard (digits pattern "ffffffff-ffff-ffff-ffff-ffffffffffff".toList).all (· == 15)

end Haus.Rules.Uuid
