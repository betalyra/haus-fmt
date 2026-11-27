import Haus.Schema.Codec

/-!
# The rule `wgs84` of `@haus-fmt/geo`, version 1 — X2

The rule of [`profiles/wgs84.md`](../profiles/wgs84.md) (packages.md §6),
stated on the values the schema decoded: a `Float64` is the
float the literal rounds to (§15), so the ranges are checked on that float,
as a number.

- `LatLng(lat, lng)`: both finite, −90 ≤ `lat` ≤ 90 and −180 ≤ `lng` ≤ 180.
  `NaN`, `Infinity` and `NegInfinity` are rejected; `-0` is accepted and
  kept (the codec keeps the value, `codec_keeps`).
- `BBox(sw, ne)`: both corners accepted as `LatLng`, and `sw.lat ≤ ne.lat`.
  The longitudes are not ordered: a box may cross the antimeridian.

The rule is stated with rational numbers (`Flt.toRat?`, the exact value of a
finite float); the checker compares products of natural numbers and
integers (`within`, `le`). `check_iff`: the checker computes the rule.
`codec` is the rule as a check on the decoded value (§13.4), so the laws of
`Haus.Schema.Codec` hold for it. Built as the library `HausGeo` of
`spec/lean`, run by `haus-rules`.
-/

namespace Haus.Rules.Geo
open Haus Schema

/-- The schema of `@haus-fmt/geo` (`extensions/geo/schema.haus`), resolved. -/
def env : Env := ⟨[
  -- type LatLng = closed < LatLng Float64 Float64 >
  ("LatLng", .variant true [.positional "LatLng" [.float .f64, .float .f64]]),
  -- type BBox = closed < BBox LatLng LatLng >
  ("BBox", .variant true [.positional "BBox" [.ref "LatLng", .ref "LatLng"]])]⟩

/-- The types the rule decides on. -/
inductive Type_ where
  | latLng
  | bbox
  deriving DecidableEq, Repr

def Type_.name : Type_ → String
  | .latLng => "LatLng"
  | .bbox => "BBox"

def Type_.all : List Type_ := [.latLng, .bbox]

/-! ## The value of a float -/

/-- The sign of a float's value as an integer: `±a`. -/
def signed (neg : Bool) (a : Nat) : Int := if neg then -(a : Int) else a

/-- The exact value of a finite float, `±m · 2^q`, as a rational number; none for `NaN` and the infinities. -/
def toRat? : Flt → Option Rat
  | .fin neg m q => let (a, b) := (Flt.fin neg m q).fraction; some ((signed neg a : Rat) / (b : Rat))
  | _ => none

/-! ## The rule -/

/-- `x` is a finite float with −`B` ≤ `x` ≤ `B`. -/
def Within (B : Nat) (x : Flt) : Prop := ∃ r, toRat? x = some r ∧ -(B : Rat) ≤ r ∧ r ≤ (B : Rat)

/-- A point the rule accepts: latitude within 90, longitude within 180. -/
def Point (lat lng : Flt) : Prop := Within 90 lat ∧ Within 180 lng

/-- A decoded `LatLng`. -/
def latLng (lat lng : Flt) : Typed := .case "LatLng" [.float .f64 lat, .float .f64 lng]

/-- A `LatLng` the rule accepts. -/
inductive LatLng : Typed → Prop
  | mk {lat lng : Flt} : Point lat lng → LatLng (latLng lat lng)

/-- A `BBox` the rule accepts: both corners accepted, and the south-west corner not north of the north-east one. -/
inductive BBox : Typed → Prop
  | mk {a b c d : Flt} {ra rc : Rat} : Point a b → Point c d → toRat? a = some ra → toRat? c = some rc → ra ≤ rc →
      BBox (.case "BBox" [latLng a b, latLng c d])

/-- **The rule**, by type: which decoded values of each type the rule accepts. -/
def Valid : Type_ → Typed → Prop
  | .latLng => LatLng
  | .bbox => BBox

/-! ## The checker -/

/-- `|x| ≤ B` for a finite float, as `a ≤ B · b` for its fraction `a / b`. -/
def within (B : Nat) : Flt → Bool
  | .fin neg m q => let (a, b) := (Flt.fin neg m q).fraction; a ≤ B * b
  | _ => false

/-- `x ≤ y` for finite floats, by cross-multiplication of their fractions. -/
def le : Flt → Flt → Bool
  | .fin n m q, .fin n' m' q' =>
    let (a, b) := (Flt.fin n m q).fraction
    let (a', b') := (Flt.fin n' m' q').fraction
    signed n a * b' ≤ signed n' a' * b
  | _, _ => false

def checkPoint (lat lng : Flt) : Bool := within 90 lat && within 180 lng

def checkLatLng : Typed → Bool
  | .case tag [.float .f64 lat, .float .f64 lng] => tag == "LatLng" && checkPoint lat lng
  | _ => false

def checkBBox : Typed → Bool
  | .case tag [.case t1 [.float .f64 a, .float .f64 b], .case t2 [.float .f64 c, .float .f64 d]] =>
    tag == "BBox" && t1 == "LatLng" && t2 == "LatLng" && checkPoint a b && checkPoint c d && le a c
  | _ => false

/-- The checker: whether the rule accepts a decoded value of the type `ty`. -/
def check : Type_ → Typed → Bool
  | .latLng => checkLatLng
  | .bbox => checkBBox

/-! ## The checker computes the rule -/

theorem fraction_pos (neg : Bool) (m : Nat) (q : Int) : 0 < ((Flt.fin neg m q).fraction).2 := by
  simp only [Flt.fraction]
  split
  · exact Nat.one_pos
  · exact Nat.two_pow_pos _

theorem div_le_iff {x n b : Rat} (hb : 0 < b) : x / b ≤ n ↔ x ≤ n * b := by
  have hb0 : b ≠ 0 := by grind
  constructor
  · intro h; have := Rat.mul_le_mul_of_nonneg_right h (Rat.le_of_lt hb); rwa [Rat.div_mul_cancel hb0] at this
  · intro h; apply Rat.le_of_mul_le_mul_right _ hb; rwa [Rat.div_mul_cancel hb0]

theorem le_div_iff {x n b : Rat} (hb : 0 < b) : n ≤ x / b ↔ n * b ≤ x := by
  have hb0 : b ≠ 0 := by grind
  constructor
  · intro h; have := Rat.mul_le_mul_of_nonneg_right h (Rat.le_of_lt hb); rwa [Rat.div_mul_cancel hb0] at this
  · intro h; apply Rat.le_of_mul_le_mul_right _ hb; rwa [Rat.div_mul_cancel hb0]

theorem div_le_div_iff {x y b c : Rat} (hb : 0 < b) (hc : 0 < c) : x / b ≤ y / c ↔ x * c ≤ y * b := by
  rw [div_le_iff hb]
  have hc0 : c ≠ 0 := by grind
  have : y / c * b = (y * b) / c := by grind
  rw [this, le_div_iff hc]

/-- A fraction `z / b` with `b > 0` is within `B` exactly when `|z| ≤ B · b`. -/
theorem within_rat (B : Nat) (neg : Bool) (a b : Nat) (hb : 0 < b) :
    (-(B : Rat) ≤ (signed neg a : Rat) / (b : Rat) ∧ (signed neg a : Rat) / (b : Rat) ≤ (B : Rat)) ↔ a ≤ B * b := by
  have hb' : (0 : Rat) < (b : Rat) := by exact_mod_cast hb
  rw [le_div_iff hb', div_le_iff hb']
  have e1 : -(B : Rat) * (b : Rat) = ((-((B * b : Nat) : Int) : Int) : Rat) := by push_cast; grind
  have e2 : (B : Rat) * (b : Rat) = ((((B * b : Nat) : Int)) : Rat) := by push_cast; rfl
  rw [e1, e2, Rat.intCast_le_intCast, Rat.intCast_le_intCast]
  unfold signed
  cases neg <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

theorem within_iff (B : Nat) (x : Flt) : within B x = true ↔ Within B x := by
  unfold within Within
  cases x with
  | nan => simp [toRat?]
  | inf _ => simp [toRat?]
  | fin neg m q =>
    have hb := fraction_pos neg m q
    simp only [toRat?, Option.some.injEq, exists_eq_left', decide_eq_true_eq]
    exact (within_rat B neg _ _ hb).symm

theorem exists_le {A B : Rat} : (∃ r s, A = r ∧ B = s ∧ r ≤ s) ↔ A ≤ B :=
  ⟨fun ⟨_, _, h1, h2, h3⟩ => h1 ▸ h2 ▸ h3, fun h => ⟨_, _, rfl, rfl, h⟩⟩

theorem le_iff {x y : Flt} : le x y = true ↔ ∃ r s, toRat? x = some r ∧ toRat? y = some s ∧ r ≤ s := by
  cases x with
  | nan => simp [le, toRat?]
  | inf _ => simp [le, toRat?]
  | fin n m q =>
    cases y with
    | nan => simp [le, toRat?]
    | inf _ => simp [le, toRat?]
    | fin n' m' q' =>
      have hb := fraction_pos n m q
      have hb' := fraction_pos n' m' q'
      simp only [le, toRat?, Option.some.injEq, decide_eq_true_eq]
      rw [exists_le]
      have hb1 : (0 : Rat) < (((Flt.fin n m q).fraction).2 : Rat) := by exact_mod_cast hb
      have hb2 : (0 : Rat) < (((Flt.fin n' m' q').fraction).2 : Rat) := by exact_mod_cast hb'
      rw [div_le_div_iff hb1 hb2]
      have e1 : ∀ (z : Int) (k : Nat), (z : Rat) * (k : Rat) = ((z * (k : Int) : Int) : Rat) := by
        intro z k; push_cast; rfl
      rw [e1, e1, Rat.intCast_le_intCast]

theorem checkPoint_iff (lat lng : Flt) : checkPoint lat lng = true ↔ Point lat lng := by
  simp [checkPoint, Point, within_iff]

theorem checkLatLng_iff (x : Typed) : checkLatLng x = true ↔ LatLng x := by
  constructor
  · intro h
    unfold checkLatLng at h
    split at h
    · simp only [Bool.and_eq_true, beq_iff_eq] at h
      obtain ⟨rfl, hp⟩ := h
      exact .mk ((checkPoint_iff _ _).mp hp)
    · simp at h
  · rintro ⟨hp⟩
    simp [checkLatLng, latLng, (checkPoint_iff _ _).mpr hp]

theorem checkBBox_iff (x : Typed) : checkBBox x = true ↔ BBox x := by
  constructor
  · intro h
    unfold checkBBox at h
    split at h
    · simp only [Bool.and_eq_true, beq_iff_eq] at h
      obtain ⟨⟨⟨⟨⟨rfl, rfl⟩, rfl⟩, hp⟩, hp'⟩, hl⟩ := h
      obtain ⟨r, s, hr, hs, hrs⟩ := le_iff.mp hl
      exact .mk ((checkPoint_iff _ _).mp hp) ((checkPoint_iff _ _).mp hp') hr hs hrs
    · simp at h
  · rintro ⟨hp, hp', hr, hs, hrs⟩
    simp [checkBBox, latLng, (checkPoint_iff _ _).mpr hp, (checkPoint_iff _ _).mpr hp',
      le_iff.mpr ⟨_, _, hr, hs, hrs⟩]

/-- **The checker computes the rule**, for every type and decoded value. -/
theorem check_iff (ty : Type_) (x : Typed) : check ty x = true ↔ Valid ty x := by
  cases ty
  · exact checkLatLng_iff x
  · exact checkBBox_iff x

/-! ## The rule as a codec -/

/-- The rule as a codec (§13.4): a check on the decoded value. -/
def codec (ty : Type_) : Codec Typed := Codec.check (check ty)

/-- The codec accepts exactly the values the schema decodes that the rule accepts, and holds them as decoded. -/
theorem codec_decode {ty : Type_} {v : Value} {x : Typed} :
    (codec ty).decode env (.ref ty.name) v = .ok x ↔ Schema.decode env (.ref ty.name) v = .ok x ∧ Valid ty x := by
  rw [codec, Codec.check_decode, check_iff]

/-- Decode, encode, decode is decode (`Codec.decode_encode`): the floats it decoded, `-0` included, are written back. -/
theorem codec_decode_encode {ty : Type_} {v : Value} {x : Typed}
    (h : (codec ty).decode env (.ref ty.name) v = .ok x) :
    (codec ty).decode env (.ref ty.name) (Schema.encode x) = .ok x :=
  Codec.check_decode_encode h

/-- The codec keeps the value, so every law of `Haus.Schema.Codec` holds for it. -/
theorem codec_keeps (ty : Type_) : (codec ty).Keeps := Codec.check_keeps _

/-! ## Examples -/

private def f (lit : String) : Flt := (roundLit .f64 lit).getD .nan

#guard check .latLng (latLng (f "90") (f "-180"))
#guard check .latLng (latLng (f "-0") (f "0"))
#guard check .latLng (latLng (f "90.00000000000000001") (f "0"))
#guard !check .latLng (latLng (f "-90.0000001") (f "0"))
#guard !check .latLng (latLng (f "0") (f "180.5"))
#guard !check .latLng (latLng .nan (f "0"))
#guard !check .latLng (latLng (.inf false) (f "0"))
#guard check .bbox (.case "BBox" [latLng (f "0") (f "170"), latLng (f "10") (f "-170")])
#guard check .bbox (.case "BBox" [latLng (f "-0") (f "1"), latLng (f "0") (f "1")])
#guard !check .bbox (.case "BBox" [latLng (f "10") (f "0"), latLng (f "0") (f "1")])
#guard check .bbox (.case "BBox" [latLng (f "-1e-300") (f "0"), latLng (f "-1e-301") (f "0")])
#guard !check .bbox (.case "BBox" [latLng (f "-1e-301") (f "0"), latLng (f "-1e-300") (f "0")])

end Haus.Rules.Geo
