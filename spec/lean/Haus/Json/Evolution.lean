import Haus.Json.Fuel
import Haus.Json.Correct

/-!
# An older reader accepts a newer writer (spec §13.3, §16.3)

**What "newer" means.** `Env.Minor env env'` says that `env'` is a later
minor version of `env`, as §13.3's table allows: every type of `env` is still
defined in `env'`, with a definition that is the old one with

- new optional fields (`x?: T`) in open records (`MinorFields.add`),
- new tags in open variants (`MinorCases.add`), of any payload,

anywhere inside it, and nothing else changed (`MinorTy`); `env'` may define
new types. Field keys and tags new to a record or variant are new: not the
key or tag of an old field or case after them (one before them comes first
anyway, `fieldOf?` and `caseOf?` take the first). A type that is a
`closed < None | Some a >` (the prelude's `Maybe`) is not changed in place:
its argument is the same type (it may name a type that changes). This is
what lets the two schemas agree on which `Maybe`s write `null`
(`nullArg?_minor`); see "Limits" below.

**The theorem.** `older_reads_newer`: for a well-formed value without
duplicate keys that the newer type decodes to `x'`, whose schema-based JSON
`j` the newer writer writes, the older reader reads `j` without an error, as
a `y` with `Older x' y`: `x'` with every case the older schema doesn't list
read as an unknown value (`Older.unknown`) and every field it doesn't list
left out (`OlderFields.drop`), and everything else the same. The older
reader returns `unknown` only for a tag its variant doesn't list, and leaves
out only fields its record doesn't list: that is how `readCore` and
`readFields` read.

**Limits.** The JSON functions take the fuel `F` of the chains of `Maybe`s
as an argument (as in `Haus.Json.RecordCases`), and the theorem holds for
every `F`, the same on both sides. `toJson` and `fromJson` choose `F` from
the sizes of the types and the environment (`nullFuel`), which grow from one
minor version to the next; the choice doesn't matter from `env.fuel` on, so
`older_reads_newer_json` in `Haus.Json.NullFuel` states it for them. The names a type
goes through (`whnf`, `recordOf?`, `origin`, the prelude's `Bool`) are
compared at any fuel: `Haus.Json.Fuel` proves that `env.fuel` is enough for
them. A `Maybe` whose argument is written in place can't grow (above).
-/

namespace Haus.Schema
open Haus

/-! ## Minor versions (§13.3) -/

mutual
/--
`MinorTy env t t'`: `t'` is `t` in a later minor version of the schema
`env`. The names in `t` are defined in `env`.
-/
inductive MinorTy (env : Env) : Ty → Ty → Prop
  | string : MinorTy env .string .string
  | bytes : MinorTy env .bytes .bytes
  | int (k : IntType) : MinorTy env (.int k) (.int k)
  | float (k : FloatType) : MinorTy env (.float k) (.float k)
  | decimal : MinorTy env .decimal .decimal
  | any : MinorTy env .any .any
  | time (k : Time.TimeType) : MinorTy env (.time k) (.time k)
  /-- A name stays the name: its definition changes in the environment. -/
  | ref {n : String} : (env.lookup n).isSome = true → MinorTy env (.ref n) (.ref n)
  | secret {t t' : Ty} : MinorTy env t t' → MinorTy env (.secret t) (.secret t')
  | array {t t' : Ty} : MinorTy env t t' → MinorTy env (.array t) (.array t')
  | map {t t' : Ty} : MinorTy env t t' → MinorTy env (.map t) (.map t')
  | record {cl : Bool} {fields fields' : List Field} : MinorFields env cl fields fields' →
      MinorTy env (.record cl fields) (.record cl fields')
  /-- A variant; one that is a `Maybe` stays as it is. -/
  | variant {cl : Bool} {cases cases' : List Case} : MinorCases env cl cases cases' →
      (maybeOf? (.variant cl cases) = none ∨ cases' = cases) → MinorTy env (.variant cl cases) (.variant cl cases')

inductive MinorTys (env : Env) : List Ty → List Ty → Prop
  | nil : MinorTys env [] []
  | cons {t t' : Ty} {ts ts' : List Ty} : MinorTy env t t' → MinorTys env ts ts' → MinorTys env (t :: ts) (t' :: ts')

/-- A record's fields: the same keys, `?` and order, with new optional fields in an open record. -/
inductive MinorFields (env : Env) : Bool → List Field → List Field → Prop
  | nil {cl : Bool} : MinorFields env cl [] []
  | cons {cl : Bool} {k : String} {o : Bool} {t t' : Ty} {fs fs' : List Field} : MinorTy env t t' →
      MinorFields env cl fs fs' → MinorFields env cl (.mk k o t :: fs) (.mk k o t' :: fs')
  /-- A new optional field `k?: t`, in an open record. -/
  | add {k : String} {t : Ty} {fs fs' : List Field} : MinorFields env false fs fs' → k ∉ fs.map Field.key →
      MinorFields env false fs (.mk k true t :: fs')

inductive MinorCase (env : Env) : Case → Case → Prop
  | bare {tag : String} : MinorCase env (.bare tag) (.bare tag)
  | record {tag : String} {cl : Bool} {fs fs' : List Field} : MinorFields env cl fs fs' →
      MinorCase env (.record tag cl fs) (.record tag cl fs')
  | positional {tag : String} {ts ts' : List Ty} : MinorTys env ts ts' →
      MinorCase env (.positional tag ts) (.positional tag ts')
  | named {tag : String} {t t' : Ty} : MinorTy env t t' → MinorCase env (.named tag t) (.named tag t')

/-- A variant's cases: the same tags and order, with new tags in an open variant. -/
inductive MinorCases (env : Env) : Bool → List Case → List Case → Prop
  | nil {cl : Bool} : MinorCases env cl [] []
  | cons {cl : Bool} {c c' : Case} {cs cs' : List Case} : MinorCase env c c' → MinorCases env cl cs cs' →
      MinorCases env cl (c :: cs) (c' :: cs')
  /-- A new case, in an open variant, with any payload. -/
  | add {c : Case} {cs cs' : List Case} : MinorCases env false cs cs' → c.tag ∉ cs.map Case.tag →
      isTag c.tag.toList = true → MinorCases env false cs (c :: cs')
end

/--
**A later minor version** (§13.3) of the schema `env`: every type `env`
defines, `env'` defines too, as a later minor version of it. `env'` may
define more types.
-/
def Env.Minor (env env' : Env) : Prop :=
  ∀ n t, env.lookup n = some t → ∃ t', env'.lookup n = some t' ∧ MinorTy env t t'

/-! ## What the older reader returns -/

mutual
/--
`Older x' y`: `y` is the newer value `x'` as an older schema reads it: a case
it doesn't list as an unknown value, a field it doesn't list left out.
-/
inductive Older : Typed → Typed → Prop
  | refl (x : Typed) : Older x x
  | secret {x y : Typed} : Older x y → Older (.secret x) (.secret y)
  | arr {xs ys : List Typed} : OlderList xs ys → Older (.arr xs) (.arr ys)
  | map {fs gs : List (String × Typed)} : OlderEntries fs gs → Older (.map fs) (.map gs)
  | record {fs gs : List (String × Typed)} : OlderFields fs gs → Older (.record fs) (.record gs)
  | case {tag : String} {xs ys : List Typed} : OlderList xs ys → Older (.case tag xs) (.case tag ys)
  /-- A case the older schema doesn't list: an unknown value with its tag. -/
  | unknown {tag : String} (xs : List Typed) (vs : List Value) : Older (.case tag xs) (.unknown tag vs)

inductive OlderList : List Typed → List Typed → Prop
  | nil : OlderList [] []
  | cons {x y : Typed} {xs ys : List Typed} : Older x y → OlderList xs ys → OlderList (x :: xs) (y :: ys)

inductive OlderEntries : List (String × Typed) → List (String × Typed) → Prop
  | nil : OlderEntries [] []
  | cons {k : String} {x y : Typed} {fs gs : List (String × Typed)} : Older x y → OlderEntries fs gs →
      OlderEntries ((k, x) :: fs) ((k, y) :: gs)

/-- The fields in the same order, some left out. -/
inductive OlderFields : List (String × Typed) → List (String × Typed) → Prop
  | nil : OlderFields [] []
  | keep {k : String} {x y : Typed} {fs gs : List (String × Typed)} : Older x y → OlderFields fs gs →
      OlderFields ((k, x) :: fs) ((k, y) :: gs)
  /-- A field the older schema doesn't list. -/
  | drop {k : String} {x : Typed} {fs gs : List (String × Typed)} : OlderFields fs gs →
      OlderFields ((k, x) :: fs) gs
end

theorem Older.hide {x y : Typed} (h : Older x y) : ∀ s, Older (x.hide s) (y.hide s)
  | 0 => h
  | s + 1 => .secret (Older.hide h s)

/-! ## The two schemas follow the same names -/

variable {env env' : Env}

theorem peel_minor : ∀ {t t' : Ty}, MinorTy env t t' → (peel t).1 = (peel t').1 ∧ MinorTy env (peel t).2 (peel t').2
  | _, _, .secret h => by
    obtain ⟨h1, h2⟩ := peel_minor h
    exact ⟨by simp [peel, h1], h2⟩
  | _, _, .string => ⟨rfl, .string⟩
  | _, _, .bytes => ⟨rfl, .bytes⟩
  | _, _, .int k => ⟨rfl, .int k⟩
  | _, _, .float k => ⟨rfl, .float k⟩
  | _, _, .decimal => ⟨rfl, .decimal⟩
  | _, _, .any => ⟨rfl, .any⟩
  | _, _, .time k => ⟨rfl, .time k⟩
  | _, _, .ref h => ⟨rfl, .ref h⟩
  | _, _, .array h => ⟨rfl, .array h⟩
  | _, _, .map h => ⟨rfl, .map h⟩
  | _, _, .record h => ⟨rfl, .record h⟩
  | _, _, .variant h hm => ⟨rfl, .variant h hm⟩

theorem minor_ref_left {n : String} {t' : Ty} (h : MinorTy env (.ref n) t') : t' = .ref n := by
  cases h; rfl

theorem minor_ref_right {n : String} {t : Ty} (h : MinorTy env t (.ref n)) : t = .ref n := by
  cases h; rfl

theorem minor_ref_defined {n : String} {t' : Ty} (h : MinorTy env (.ref n) t') : ∃ d, env.lookup n = some d := by
  cases h with
  | ref h => exact Option.isSome_iff_exists.mp h

/-- The way to a type: in both, after the same secrets, the name `n`; or in neither a name. -/
theorem peel_minor_cases {t t' : Ty} (h : MinorTy env t t') :
    ((∀ s n, peel t ≠ (s, .ref n)) ∧ (∀ s n, peel t' ≠ (s, .ref n)) ∧ (peel t).1 = (peel t').1 ∧
        MinorTy env (peel t).2 (peel t').2) ∨
      ∃ s n d, peel t = (s, .ref n) ∧ peel t' = (s, .ref n) ∧ env.lookup n = some d := by
  obtain ⟨h1, h2⟩ := peel_minor h
  rcases peel_cases t with hn | ⟨s, n, hp⟩
  · refine .inl ⟨hn, fun s n e => ?_, h1, h2⟩
    rw [e] at h1 h2
    exact hn s n (Prod.ext h1 (minor_ref_right h2))
  · rw [hp] at h1 h2
    obtain ⟨d, hd⟩ := minor_ref_defined h2
    exact .inr ⟨s, n, d, hp, Prod.ext h1.symm (minor_ref_left h2), hd⟩

/-- Both fail, or both give the same number of secrets and related types. -/
def WhnfRel (env : Env) : Except String (Nat × Ty) → Except String (Nat × Ty) → Prop
  | .error _, .error _ => True
  | .ok r, .ok r' => r.1 = r'.1 ∧ MinorTy env r.2 r'.2
  | _, _ => False

/-- **`whnf` in both schemas**, with the same fuel: the same way, through the same names. -/
theorem whnf_minor (hE : env.Minor env') (f : Nat) : ∀ {t t' : Ty}, MinorTy env t t' →
    WhnfRel env (whnf env f t) (whnf env' f t') ∧ whnfNames env f t = whnfNames env' f t' := by
  induction f with
  | zero =>
    intro t t' h
    rcases peel_minor_cases h with ⟨hn, hn', h1, h2⟩ | ⟨s, n, d, hp, hp', -⟩
    · rw [whnf_notRef hn, whnf_notRef hn']; exact ⟨⟨h1, h2⟩, rfl⟩
    · rw [whnf_zero, whnf_zero]; simp [hp, hp', WhnfRel, whnfNames]
  | succ f ih =>
    intro t t' h
    rcases peel_minor_cases h with ⟨hn, hn', h1, h2⟩ | ⟨s, n, d, hp, hp', hd⟩
    · rw [whnf_notRef hn, whnf_notRef hn', whnfNames_notRef hn, whnfNames_notRef hn']; exact ⟨⟨h1, h2⟩, rfl⟩
    · obtain ⟨d', hd', hm⟩ := hE n d hd
      obtain ⟨ih1, ih2⟩ := ih hm
      rw [whnf_ref hp, whnf_ref hp', whnfNames_ref hp, whnfNames_ref hp']
      simp only [hd, hd', ih2, and_true]
      revert ih1
      cases whnf env f d <;> cases whnf env' f d' <;> simp [WhnfRel, Except.map]

theorem lastRef_minor (hE : env.Minor env') (f : Nat) : ∀ {t t' : Ty}, MinorTy env t t' →
    lastRef env f t = lastRef env' f t' := by
  induction f with
  | zero => intros; rfl
  | succ f ih =>
    intro t t' h
    rcases peel_minor_cases h with ⟨hn, hn', -, -⟩ | ⟨s, n, d, hp, hp', hd⟩
    · have e1 : lastRef env (f + 1) t = none := by
        unfold lastRef; split
        · rename_i s n e; exact absurd e (hn s n)
        · rfl
      have e2 : lastRef env' (f + 1) t' = none := by
        unfold lastRef; split
        · rename_i s n e; exact absurd e (hn' s n)
        · rfl
      rw [e1, e2]
    · obtain ⟨d', hd', hm⟩ := hE n d hd
      simp only [lastRef, hp, hp', hd, hd', ih hm]

theorem reachesBool_minor (hE : env.Minor env') (f : Nat) : ∀ {t t' : Ty}, MinorTy env t t' →
    reachesBool env f t = reachesBool env' f t' := by
  induction f with
  | zero =>
    intro t t' h
    rcases peel_minor_cases h with ⟨hn, hn', -, -⟩ | ⟨s, n, d, hp, hp', -⟩
    · have e1 : reachesBool env 0 t = false := by
        unfold reachesBool; split
        · rename_i s n e; exact absurd e (hn s n)
        · rfl
      have e2 : reachesBool env' 0 t' = false := by
        unfold reachesBool; split
        · rename_i s n e; exact absurd e (hn' s n)
        · rfl
      rw [e1, e2]
    · simp only [reachesBool, hp, hp']
  | succ f ih =>
    intro t t' h
    rcases peel_minor_cases h with ⟨hn, hn', -, -⟩ | ⟨s, n, d, hp, hp', hd⟩
    · have e1 : reachesBool env (f + 1) t = false := by
        unfold reachesBool; split
        · rename_i s n e; exact absurd e (hn s n)
        · rfl
      have e2 : reachesBool env' (f + 1) t' = false := by
        unfold reachesBool; split
        · rename_i s n e; exact absurd e (hn' s n)
        · rfl
      rw [e1, e2]
    · obtain ⟨d', hd', hm⟩ := hE n d hd
      simp only [reachesBool, hp, hp', hd, hd', ih hm]

/-- Both find no record, or both find a record, its newer version in the newer schema. -/
def RecRel (env : Env) : Option (Bool × List Field) → Option (Bool × List Field) → Prop
  | none, none => True
  | some r, some r' => r.1 = r'.1 ∧ MinorFields env r.1 r.2 r'.2
  | _, _ => False

theorem recordOf?_minor (hE : env.Minor env') (f : Nat) : ∀ {t t' : Ty}, MinorTy env t t' →
    RecRel env (recordOf? env f t) (recordOf? env' f t') := by
  induction f with
  | zero =>
    intro t t' h
    cases h with
    | record h => simp only [recordOf?_record]; exact ⟨rfl, h⟩
    | _ => simp [recordOf?, RecRel]
  | succ f ih =>
    intro t t' h
    cases h with
    | record h => simp only [recordOf?_record]; exact ⟨rfl, h⟩
    | @ref n hl =>
      obtain ⟨d, hd⟩ := Option.isSome_iff_exists.mp hl
      obtain ⟨d', hd', hm⟩ := hE n d hd
      rw [recordOf?_ref hd, recordOf?_ref hd']
      exact ih hm
    | _ => simp [recordOf?, RecRel]

/-! ## With each schema's own fuel -/

theorem le_max_fuel_left : env.fuel ≤ max env.fuel env'.fuel := Nat.le_max_left _ _
theorem le_max_fuel_right : env'.fuel ≤ max env.fuel env'.fuel := Nat.le_max_right _ _

/-- **`whnf` in both schemas**, each with its own fuel. -/
theorem whnf_minor_fuel (hE : env.Minor env') {t t' : Ty} (h : MinorTy env t t') :
    WhnfRel env (whnf env env.fuel t) (whnf env' env'.fuel t') := by
  have hG := (whnf_minor hE (max env.fuel env'.fuel) h).1
  cases e1 : whnf env (max env.fuel env'.fuel) t with
  | ok r =>
    rw [(whnf_fuel le_max_fuel_left t r).mp e1]
    cases e2 : whnf env' (max env.fuel env'.fuel) t' with
    | ok r' => rw [(whnf_fuel le_max_fuel_right t' r').mp e2]; rw [e1, e2] at hG; exact hG
    | error _ => rw [e1, e2] at hG; cases hG
  | error e =>
    obtain ⟨e1', he1⟩ := (whnf_fuel_error le_max_fuel_left t).mp ⟨e, e1⟩
    rw [he1]
    cases e2 : whnf env' (max env.fuel env'.fuel) t' with
    | ok r' => rw [e1, e2] at hG; cases hG
    | error e' =>
      obtain ⟨e2', he2⟩ := (whnf_fuel_error le_max_fuel_right t').mp ⟨e', e2⟩
      rw [he2]; trivial

theorem whnf_minor_ok (hE : env.Minor env') {t t' : Ty} (h : MinorTy env t t') {r' : Nat × Ty}
    (hw : whnf env' env'.fuel t' = .ok r') : ∃ c, whnf env env.fuel t = .ok (r'.1, c) ∧ MinorTy env c r'.2 := by
  have := whnf_minor_fuel hE h
  rw [hw] at this
  revert this
  cases whnf env env.fuel t with
  | error _ => simp [WhnfRel]
  | ok r => intro h; exact ⟨r.2, by rw [← h.1], h.2⟩

theorem origin_minor (hE : env.Minor env') {t t' : Ty} (h : MinorTy env t t') {r : Nat × Ty}
    (hw : whnf env env.fuel t = .ok r) (o : String) : origin env o t = origin env' o t' := by
  have hG := whnf_minor_fuel hE h
  rw [hw] at hG
  cases hw' : whnf env' env'.fuel t' with
  | error _ => rw [hw'] at hG; cases hG
  | ok r' =>
    unfold origin
    rw [← lastRef_fuel le_max_fuel_left hw, ← lastRef_fuel le_max_fuel_right hw',
      lastRef_minor hE _ h]

/-- A related type is a variant of the same shape. -/
theorem isBool_minor {c c' : Ty} (h : MinorTy env c c') : isBool c = isBool c' := by
  cases h with
  | @variant cl cs cs' hc hm =>
    cases cl with
    | false => simp [isBool]
    | true =>
      have key : ∀ {xs ys : List Case}, MinorCases env true xs ys → (xs.all Case.isBare = true ∨ ys.all Case.isBare = true) →
          ys = xs := by
        intro xs ys hxy
        induction xs generalizing ys with
        | nil => cases hxy; intro; rfl
        | cons x xs ih =>
          cases hxy with
          | cons hc hr =>
            intro hb
            simp only [List.all_cons, Bool.and_eq_true] at hb
            have e1 : _ := ih hr (hb.elim (fun h => .inl h.2) (fun h => .inr h.2))
            rcases hb with ⟨hb, -⟩ | ⟨hb, -⟩ <;> cases hc <;> simp_all [Case.isBare]
      by_cases h1 : isBool (.variant true cs) = true
      · have := isBool_eq h1
        cases this
        rw [key hc (.inl rfl)]
      · by_cases h2 : isBool (.variant true cs') = true
        · have := isBool_eq h2
          cases this
          rw [key hc (.inr rfl)]
        · simp only [Bool.not_eq_true] at h1 h2; rw [h1, h2]
  | _ => rfl

/-- **The prelude's `Bool`** is the same in both schemas. -/
theorem boolTy_minor (hE : env.Minor env') {t t' : Ty} (h : MinorTy env t t') : boolTy env t = boolTy env' t' := by
  have hG := whnf_minor_fuel hE h
  unfold boolTy
  cases hw : whnf env env.fuel t with
  | error _ =>
    cases hw' : whnf env' env'.fuel t' with
    | error _ => simp
    | ok _ => rw [hw, hw'] at hG; cases hG
  | ok r =>
    cases hw' : whnf env' env'.fuel t' with
    | error _ => rw [hw, hw'] at hG; cases hG
    | ok r' =>
      rw [hw, hw'] at hG
      simp only [isBool_minor hG.2]
      rw [← reachesBool_fuel le_max_fuel_left hw, ← reachesBool_fuel le_max_fuel_right hw', reachesBool_minor hE _ h]

/-! ## The same `Maybe`s write `null` -/

/-- A `Maybe` in either schema is the same type in both. -/
theorem maybe_minor {c c' : Ty} (h : MinorTy env c c') (hm : maybeOf? c ≠ none ∨ maybeOf? c' ≠ none) : c' = c := by
  cases h with
  | @variant cl cs cs' hc hc' =>
    rcases hc' with hn | rfl
    · rcases hm with hm | hm
      · exact absurd hn hm
      · cases e : maybeOf? (.variant cl cs') with
        | none => exact absurd e hm
        | some a' =>
          cases maybeOf?_some e
          cases hc with
          | cons h1 h2 =>
            cases h1
            cases h2 with
            | cons h3 h4 =>
              cases h3 with
              | positional h5 =>
                cases h5 with
                | cons h6 h7 => cases h7; cases h4; simp [maybeOf?] at hn
    · rfl
  | _ => rcases hm with hm | hm <;> simp [maybeOf?] at hm

theorem maybeOf?_minor {c c' : Ty} (h : MinorTy env c c') : (maybeOf? c = none) = (maybeOf? c' = none) := by
  by_cases h1 : maybeOf? c = none
  · by_cases h2 : maybeOf? c' = none
    · simp [h1, h2]
    · rw [maybe_minor h (.inr h2)] at h2; exact absurd h1 h2
  · rw [maybe_minor h (.inl h1)]

/-- The argument of a `Maybe` is related to itself. -/
theorem minor_maybeArg {c c' a : Ty} (h : MinorTy env c c') (hm : maybeOf? c = some a) : MinorTy env a a := by
  cases maybeOf?_some hm
  cases h with
  | variant hc _ =>
    cases hc with
    | cons h1 h2 =>
      cases h2 with
      | cons h3 _ =>
        cases h3 with
        | positional h5 =>
          cases h5 with
          | cons h6 h7 => cases h7; cases maybe_minor (.variant (.cons h1 (.cons (.positional (.cons h6 .nil)) ‹_›)) ‹_›) (.inl (by simp [maybeOf?])); exact h6

/-- A link of a chain of `Maybe`s in the older schema, and in the newer one. -/
def LinkRel (env : Env) (x x' : String × Ty) : Prop := x.1 = x'.1 ∧ MinorTy env x.2 x'.2

/-- Two chains, link by link. -/
inductive Links (env : Env) : List (String × Ty) → List (String × Ty) → Prop
  | nil : Links env [] []
  | cons {x x' : String × Ty} {cs cs' : List (String × Ty)} : LinkRel env x x' → Links env cs cs' →
      Links env (x :: cs) (x' :: cs')

theorem maybeAt?_minor {x x' : String × Ty} (h : LinkRel env x x') :
    (maybeAt? x.1 x.2).isNone = (maybeAt? x'.1 x'.2).isNone := by
  obtain ⟨e, h⟩ := h
  unfold maybeAt?
  rw [← e]
  split
  · have := maybeOf?_minor h
    cases e1 : maybeOf? x.2 <;> cases e2 : maybeOf? x'.2 <;> simp_all
  · rfl

/-- A link that is a `Maybe` is the same in both chains. -/
theorem link_minor {x x' : String × Ty} (h : LinkRel env x x') (hm : (maybeAt? x.1 x.2).isSome = true) : x' = x := by
  obtain ⟨e, h⟩ := h
  have : maybeOf? x.2 ≠ none := by
    unfold maybeAt? at hm; split at hm
    · intro h'; simp [h'] at hm
    · simp at hm
  exact Prod.ext e.symm (maybe_minor h (.inl this))

theorem nextMaybe_minor (hE : env.Minor env') {x x' : String × Ty} (h : LinkRel env x x') :
    (nextMaybe env x = none ∧ nextMaybe env' x' = none) ∨
      ∃ y y', nextMaybe env x = some y ∧ nextMaybe env' x' = some y' ∧ LinkRel env y y' := by
  obtain ⟨o, c⟩ := x
  obtain ⟨o', c'⟩ := x'
  cases hm : maybeAt? o c with
  | none =>
    have := maybeAt?_minor h
    simp only [hm, Option.isNone_none] at this
    have hm' : maybeAt? o' c' = none := by simpa using this.symm
    left; simp [nextMaybe, hm, hm']
  | some a =>
    have e := link_minor h (by simp [hm])
    cases e
    have ha := minor_maybeArg h.2 (maybeAt?_some hm)
    have hG := whnf_minor_fuel hE ha
    unfold nextMaybe
    simp only [hm]
    cases hw : whnf env env.fuel a with
    | error _ =>
      cases hw' : whnf env' env'.fuel a with
      | error _ => left; simp
      | ok _ => rw [hw, hw'] at hG; cases hG
    | ok r =>
      cases hw' : whnf env' env'.fuel a with
      | error _ => rw [hw, hw'] at hG; cases hG
      | ok r' =>
        rw [hw, hw'] at hG
        right
        exact ⟨_, _, rfl, rfl, (origin_minor hE ha hw o).symm ▸ rfl, hG.2⟩

theorem maybeChain_minor (hE : env.Minor env') (F : Nat) : ∀ {x x' : String × Ty}, LinkRel env x x' →
    Links env (maybeChain env F x) (maybeChain env' F x') := by
  induction F with
  | zero => intro x x' h; exact .cons h .nil
  | succ F ih =>
    intro x x' h
    simp only [maybeChain]
    refine .cons h ?_
    rcases nextMaybe_minor hE h with ⟨h1, h2⟩ | ⟨y, y', h1, h2, h3⟩
    · simp only [h1, h2]; exact .nil
    · simp only [h1, h2]; exact ih h3

theorem mem_minor {x : String × Ty} (hx : (maybeAt? x.1 x.2).isSome = true) :
    ∀ {cs cs' : List (String × Ty)}, Links env cs cs' → (x ∈ cs ↔ x ∈ cs')
  | [], [], .nil => by simp
  | y :: ys, y' :: ys', .cons h hs => by
    simp only [List.mem_cons, mem_minor hx hs]
    constructor
    · rintro (rfl | h')
      · exact .inl (link_minor h hx).symm
      · exact .inr h'
    · rintro (rfl | h')
      · have : (maybeAt? y.1 y.2).isSome = true := by
          have := maybeAt?_minor h
          cases e1 : maybeAt? y.1 y.2 <;> cases e2 : maybeAt? x.1 x.2 <;> simp_all
        exact .inl (link_minor h this)
      · exact .inr h'

theorem chainEnd_minor : ∀ {cs cs' : List (String × Ty)}, Links env cs cs' → chainEnd cs = chainEnd cs'
  | [], [], .nil => rfl
  | x :: xs, x' :: xs', .cons h hs => by
    simp only [chainEnd]
    rw [maybeAt?_minor h, chainEnd_minor hs]
    have hl : xs.isEmpty = xs'.isEmpty := by
      cases hs <;> rfl
    rw [hl]
    cases e : (maybeAt? x'.1 x'.2).isNone
    · have hx : (maybeAt? x.1 x.2).isSome = true := by
        have := maybeAt?_minor h; rw [e] at this
        cases e1 : maybeAt? x.1 x.2 <;> simp_all
      have := link_minor h hx
      subst this
      have hc : x' ∈ xs ↔ x' ∈ xs' := mem_minor hx hs
      simp [hc]
    · simp

theorem chainNull_minor (hE : env.Minor env') (F : Nat) {o : String} {c c' : Ty} (h : MinorTy env c c') :
    chainNull env F o c = chainNull env' F o c' := by
  unfold chainNull
  rw [chainEnd_minor (maybeChain_minor hE F (x := (o, c)) (x' := (o, c')) ⟨rfl, h⟩)]

theorem usesNull_minor (hE : env.Minor env') (F : Nat) {o : String} {c c' : Ty} (h : MinorTy env c c') :
    usesNull env F o c = usesNull env' F o c' := by
  unfold usesNull
  rw [chainNull_minor hE F h]
  rcases nextMaybe_minor hE (x := (o, c)) (x' := (o, c')) ⟨rfl, h⟩ with ⟨h1, h2⟩ | ⟨y, y', h1, h2, h3⟩
  · simp [h1, h2]
  · simp only [h1, h2]
    obtain ⟨y1, y2⟩ := y
    obtain ⟨y1', y2'⟩ := y'
    obtain ⟨e, hy⟩ := h3
    simp only at e hy
    subst e
    have := maybeAt?_minor (x := (y1, y2)) (x' := (y1, y2')) ⟨rfl, hy⟩
    rw [chainNull_minor hE F hy]
    simp only at this
    cases e1 : maybeAt? y1 y2 <;> cases e2 : maybeAt? y1 y2' <;> simp_all

/-- **The same `Maybe`s write `null`** in both schemas, for the same fuel. -/
theorem nullArg?_minor (hE : env.Minor env') (F : Nat) {o : String} {c c' : Ty} (h : MinorTy env c c') :
    nullArg? env F o c = nullArg? env' F o c' := by
  unfold nullArg?
  cases hm : maybeAt? o c with
  | none =>
    have := maybeAt?_minor (x := (o, c)) (x' := (o, c')) ⟨rfl, h⟩
    simp only [hm, Option.isNone_none] at this
    have hm' : maybeAt? o c' = none := by simpa using this.symm
    simp [hm']
  | some a =>
    have e := link_minor (x := (o, c)) (x' := (o, c')) ⟨rfl, h⟩ (by simp [hm])
    simp only [Prod.mk.injEq, true_and] at e
    subst e
    simp only [hm, usesNull_minor hE F h]

/-! ## Cases and fields -/

theorem MinorCase.tag_eq {c c' : Case} (h : MinorCase env c c') : c'.tag = c.tag := by
  cases h <;> rfl

theorem find_minorCases (tag : String) : ∀ {cl : Bool} {cs cs' : List Case}, MinorCases env cl cs cs' →
    (cs.find? (·.tag == tag) = none ∧ cs'.find? (·.tag == tag) = none) ∨
      (∃ c c', cs.find? (·.tag == tag) = some c ∧ cs'.find? (·.tag == tag) = some c' ∧ MinorCase env c c') ∨
      (cs.find? (·.tag == tag) = none ∧ cl = false ∧ isTag tag.toList = true ∧
        ∃ c', cs'.find? (·.tag == tag) = some c')
  | _, _, _, .nil => .inl ⟨rfl, rfl⟩
  | _, _, _, .cons (c := c) (c' := c') hc hr => by
    by_cases ht : c.tag = tag
    · exact .inr (.inl ⟨c, c', by simp [ht], by simp [hc.tag_eq, ht], hc⟩)
    · have ht' : (c'.tag == tag) = false := by simp [hc.tag_eq, ht]
      rw [List.find?_cons_of_neg (by simp [ht]), List.find?_cons_of_neg (by simp [ht'])]
      exact find_minorCases tag hr
  | _, _, _, .add (c := c) (cs := cs) hr hn hti => by
    by_cases ht : c.tag = tag
    · subst ht
      refine .inr (.inr ⟨?_, rfl, hti, c, by simp⟩)
      rw [List.find?_eq_none]
      intro x hx
      simp only [beq_iff_eq]
      intro e
      exact hn (List.mem_map.mpr ⟨x, hx, e⟩)
    · rw [List.find?_cons_of_neg (by simp [ht])]
      exact find_minorCases tag hr

theorem recordOf?_minor_fuel (hE : env.Minor env') {t t' : Ty} (h : MinorTy env t t') :
    RecRel env (recordOf? env env.fuel t) (recordOf? env' env'.fuel t') := by
  rw [← recordOf?_fuel le_max_fuel_left, ← recordOf?_fuel le_max_fuel_right]
  exact recordOf?_minor hE _ h

theorem resolve_minor (hE : env.Minor env') {c c' : Case} (h : MinorCase env c c') :
    MinorCase env (c.resolve env) (c'.resolve env') := by
  cases h with
  | @named tag t t' h =>
    have := recordOf?_minor_fuel hE h
    simp only [Case.resolve]
    revert this
    cases recordOf? env env.fuel t <;> cases recordOf? env' env'.fuel t' <;> simp only [RecRel, false_imp_iff]
    · intro; exact .positional (.cons h .nil)
    · rename_i r r'
      rintro ⟨e, hf⟩
      obtain ⟨cl, fs⟩ := r
      obtain ⟨cl', fs'⟩ := r'
      simp only at e hf
      subst e
      exact .record hf
  | bare => exact .bare
  | record h => exact .record h
  | positional h => exact .positional h

/-- **The case of a tag** in both schemas: neither lists it, both do, or only the newer one, in an open variant. -/
theorem caseOf?_minor (hE : env.Minor env') {cl : Bool} {cs cs' : List Case} (h : MinorCases env cl cs cs')
    (tag : String) :
    (caseOf? env cs tag = none ∧ caseOf? env' cs' tag = none) ∨
      (∃ c c', caseOf? env cs tag = some c ∧ caseOf? env' cs' tag = some c' ∧ MinorCase env c c') ∨
      (caseOf? env cs tag = none ∧ cl = false ∧ isTag tag.toList = true ∧ ∃ c', caseOf? env' cs' tag = some c') := by
  unfold caseOf?
  rcases find_minorCases tag h with ⟨h1, h2⟩ | ⟨c, c', h1, h2, h3⟩ | ⟨h1, h2, h3, c', h4⟩
  · exact .inl ⟨by simp [h1], by simp [h2]⟩
  · exact .inr (.inl ⟨_, _, by simp [h1], by simp [h2], resolve_minor hE h3⟩)
  · exact .inr (.inr ⟨by simp [h1], h2, h3, c'.resolve env', by simp [h4]⟩)

theorem find_minorFields (k : String) : ∀ {cl : Bool} {fs fs' : List Field}, MinorFields env cl fs fs' →
    (fieldOf? fs k = none ∧ fieldOf? fs' k = none) ∨
      (∃ f f', fieldOf? fs k = some f ∧ fieldOf? fs' k = some f' ∧ MinorTy env f.ty f'.ty) ∨
      (fieldOf? fs k = none ∧ cl = false ∧ ∃ f', fieldOf? fs' k = some f')
  | _, _, _, .nil => .inl ⟨rfl, rfl⟩
  | _, _, _, .cons (k := k') (o := o) (t := t) (t' := t') ht hr => by
    unfold fieldOf?
    by_cases hk : k' = k
    · exact .inr (.inl ⟨.mk k' o t, .mk k' o t', by simp [Field.key, hk], by simp [Field.key, hk], ht⟩)
    · rw [List.find?_cons_of_neg (by simp [Field.key, hk]), List.find?_cons_of_neg (by simp [Field.key, hk])]
      exact find_minorFields k hr
  | _, _, _, .add (k := k') (t := t) (fs := fs) hr hn => by
    unfold fieldOf?
    by_cases hk : k' = k
    · subst hk
      refine .inr (.inr ⟨?_, rfl, .mk k' true t, by simp [Field.key]⟩)
      rw [List.find?_eq_none]
      intro x hx
      simp only [beq_iff_eq]
      intro e
      exact hn (List.mem_map.mpr ⟨x, hx, e⟩)
    · rw [List.find?_cons_of_neg (by simp [Field.key, hk])]
      exact find_minorFields k hr

/-- Every field of the older record is in the newer one, with its key and `?`. -/
theorem MinorFields.mem : ∀ {cl : Bool} {fs fs' : List Field}, MinorFields env cl fs fs' →
    ∀ f ∈ fs, ∃ f' ∈ fs', f'.key = f.key ∧ f'.optional = f.optional
  | _, _, _, .nil => by simp
  | _, _, _, .cons _ hr => by
    intro f hf
    rcases List.mem_cons.mp hf with rfl | hf
    · exact ⟨_, List.mem_cons_self .., rfl, rfl⟩
    · obtain ⟨f', h1, h2⟩ := hr.mem f hf
      exact ⟨f', List.mem_cons_of_mem _ h1, h2⟩
  | _, _, _, .add hr _ => by
    intro f hf
    obtain ⟨f', h1, h2⟩ := hr.mem f hf
    exact ⟨f', List.mem_cons_of_mem _ h1, h2⟩

/-- A member the newer record requires, so does the older one, if it lists it. -/
theorem missingJ?_minor {cl : Bool} {fs fs' : List Field} (h : MinorFields env cl fs fs') {ms : List (String × JSON)}
    (hm : missingJ? fs' ms = none) : missingJ? fs ms = none := by
  simp only [missingJ?, Option.map_eq_none_iff, List.find?_eq_none] at hm ⊢
  intro f hf
  obtain ⟨f', hf', hk, ho⟩ := h.mem f hf
  have := hm f' hf'
  rwa [hk, ho] at this

theorem hasReservedField_minor {cl : Bool} {fs fs' : List Field} (h : MinorFields env cl fs fs')
    (hr : hasReservedField fs' = false) : hasReservedField fs = false := by
  simp only [hasReservedField, List.any_eq_false] at hr ⊢
  intro f hf
  obtain ⟨f', hf', hk, -⟩ := h.mem f hf
  have := hr f' hf'
  rwa [hk] at this

theorem all_bare_minor : ∀ {cl : Bool} {cs cs' : List Case}, MinorCases env cl cs cs' → cl = true →
    cs.all Case.isBare = cs'.all Case.isBare
  | _, _, _, .nil, _ => rfl
  | _, _, _, .cons hc hr, e => by
    simp only [List.all_cons, all_bare_minor hr e]
    cases hc <;> rfl
  | _, _, _, .add _ _ _, e => by cases e

theorem isEnum_minor {cl : Bool} {cs cs' : List Case} (h : MinorCases env cl cs cs') :
    isEnum (.variant cl cs) = isEnum (.variant cl cs') := by
  cases cl with
  | false => rfl
  | true => simp only [isEnum]; exact all_bare_minor h rfl

/-! ## Reading a case the older schema doesn't list -/

mutual
/-- The import (§16.1) reads every well-formed JSON. -/
theorem toValue_ok : ∀ j : JSON, JSON.WellFormed j → ∃ v, JSON.toValue j = .ok v
  | .null, _ => ⟨_, rfl⟩
  | .bool _, _ => ⟨_, rfl⟩
  | .str _, _ => ⟨_, rfl⟩
  | .num t, h => by
    cases h with
    | num _ hn => exact ⟨.num (normalizeNumber t.toList), by simp [JSON.toValue, hn]⟩
  | .arr xs, h => by
    cases h with
    | arr _ hx =>
      obtain ⟨vs, hv⟩ := toValueList_ok xs hx
      exact ⟨.arr vs, by simp [JSON.toValue, hv, Except.map]⟩
  | .obj ms, h => by
    cases h with
    | obj _ _ hm =>
      obtain ⟨fs, hf⟩ := toValueMembers_ok ms hm
      exact ⟨.record fs, by simp [JSON.toValue, hf, Except.map]⟩

theorem toValueList_ok : ∀ xs : List JSON, (∀ x ∈ xs, JSON.WellFormed x) → ∃ vs, JSON.toValueList xs = .ok vs
  | [], _ => ⟨_, rfl⟩
  | x :: xs, h => by
    obtain ⟨v, hv⟩ := toValue_ok x (h x (List.mem_cons_self ..))
    obtain ⟨vs, hvs⟩ := toValueList_ok xs (fun y hy => h y (List.mem_cons_of_mem _ hy))
    exact ⟨v :: vs, by simp [JSON.toValueList, hv, hvs, bind, Except.bind, pure, Except.pure]⟩

theorem toValueMembers_ok : ∀ ms : List (String × JSON), (∀ m ∈ ms, JSON.WellFormed m.2) →
    ∃ fs, JSON.toValueMembers ms = .ok fs
  | [], _ => ⟨_, rfl⟩
  | (k, x) :: ms, h => by
    obtain ⟨v, hv⟩ := toValue_ok x (h (k, x) (List.mem_cons_self ..))
    obtain ⟨fs, hfs⟩ := toValueMembers_ok ms (fun y hy => h y (List.mem_cons_of_mem _ hy))
    exact ⟨(k, v) :: fs, by simp [JSON.toValueMembers, hv, hfs, bind, Except.bind, pure, Except.pure]⟩
end

/--
**A tag an open variant doesn't list** (§16.3): the older reader reads the
object as an unknown value, whatever members it has besides `_tag`, if none
of them is `_tag` or `_args` and they are well formed.
-/
theorem fromJsonC_unknown {F : Nat} {o : String} {cs : List Case} {tag : String}
    {ms : List (String × JSON)} (hn : caseOf? env cs tag = none) (ht : isTag tag.toList = true)
    (hk : ∀ m ∈ ms, m.1 ≠ "_tag" ∧ m.1 ≠ "_args") (hw : ∀ m ∈ ms, JSON.WellFormed m.2) :
    ∃ vs, fromJsonC env F false o (.variant false cs) (.obj (("_tag", .str tag) :: ms)) = .ok (.unknown tag vs) := by
  rw [fromJsonC_none _ nullArg?_open, readCore.eq_def]
  have he : isEnum (.variant false cs) = false := rfl
  have hf : (("_tag", JSON.str tag) :: ms).filter (·.1 != "_tag") = ms := by
    rw [List.filter_cons_of_neg (by simp), List.filter_eq_self]
    intro m hm; simpa using (hk m hm).1
  simp only [Bool.false_eq_true, ↓reduceIte, he, List.lookup, beq_self_eq_true, hn, ht, Bool.not_true, hf]
  match ms, hk, hw with
  | [], _, _ => exact ⟨[], rfl⟩
  | [(k, x)], hk, hw =>
    have hk' : k ≠ "_args" := (hk (k, x) (by simp)).2
    obtain ⟨fs, hfs⟩ := toValueMembers_ok [(k, x)] hw
    refine ⟨[.record fs], ?_⟩
    split
    next e => cases e
    next x' e => simp only [List.cons.injEq, Prod.mk.injEq, and_true] at e; exact absurd e.1 hk'
    next => rw [hfs]
  | m1 :: m2 :: rest, _, hw =>
    obtain ⟨fs, hfs⟩ := toValueMembers_ok (m1 :: m2 :: rest) hw
    exact ⟨[.record fs], by simp [hfs]⟩

/-- A record payload's members are fields of the payload's record. -/
theorem payload_keys {env : Env} {F : Nat} {o : String} {fields : List Field} {cl : Bool}
    {fs : List (String × Value)} {ys : List (String × Typed)} {ms : List (String × JSON)}
    (hf : Fields env cl fields fs ys) (hr : hasReservedField fields = false)
    (hms : toJsonFields env F o fields ys = .ok ms) : ∀ m ∈ ms, m.1 ≠ "_tag" ∧ m.1 ≠ "_args" := by
  intro m hm
  have hk : m.1 ∈ ys.map (·.1) := by rw [← toJsonFields_keys hms]; exact List.mem_map.mpr ⟨m, hm, rfl⟩
  have := hf.keys_listed m.1 hk
  simp only [fieldOf?, Option.isSome_iff_exists] at this
  obtain ⟨f, hfd⟩ := this
  have hmem := List.mem_of_find?_eq_some hfd
  have he := List.find?_some hfd
  simp only [beq_iff_eq] at he
  simp only [hasReservedField, List.any_eq_false] at hr
  have := hr f hmem
  rw [he] at this
  simp only [Bool.or_eq_true, beq_iff_eq, not_or] at this
  exact this

/-- What a record type decodes: a record, its fields by `Fields`. -/
theorem Dec.record_inv {env : Env} {cl : Bool} {fields : List Field} {a : Value} {y : Typed} :
    Dec env (.record cl fields) a y → ∃ fs ys, a = .record fs ∧ y = .record ys ∧ missing? fields fs = none ∧
      Fields env cl fields fs ys
  | .intro hw hc => by
    simp only [whnf, peel] at hw
    cases hw
    cases hc with
    | record hm hf => exact ⟨_, _, rfl, rfl, hm, hf⟩

theorem uniqueKeys_record {fs : List (String × Value)} (h : UniqueKeys (.record fs)) : ∀ kv ∈ fs, UniqueKeys kv.2 := by
  cases h; assumption

theorem uniqueKeys_arr {xs : List Value} (h : UniqueKeys (.arr xs)) : ∀ x ∈ xs, UniqueKeys x := by
  cases h; assumption

theorem uniqueKeys_variant {t : String} {xs : List Value} (h : UniqueKeys (.variant t xs)) : ∀ x ∈ xs, UniqueKeys x := by
  cases h; assumption

theorem MinorTys.length : ∀ {ts ts' : List Ty}, MinorTys env ts ts' → ts.length = ts'.length
  | _, _, .nil => rfl
  | _, _, .cons _ h => by simp [h.length]

/-! ## A case of a variant -/

/-- `Tag { … }`, given what the older reader does with the payload's fields. -/
theorem recordCase_older (hE : env.Minor env') {F : Nat} {o : String} {cl : Bool} {cs cs' : List Case}
    {tag tag' : String} {cl' : Bool} {fields' : List Field} {y' : Typed} {b : Bool} {j : JSON}
    (hmc : MinorCases env cl cs cs') (hmm : maybeOf? (.variant cl cs) = none ∨ cs' = cs)
    (hc : caseOf? env' cs' tag = some (.record tag' cl' fields')) (htag : isTag tag.toList = true)
    (hb : b = true → isBool (.variant cl cs) = true) (hwf : JSON.WellFormed j)
    (IH : hasReservedField fields' = false → ∃ ys', y' = .record ys' ∧ ∀ ms, toJsonFields env' F o fields' ys' = .ok ms →
      missingJ? fields' ms = none ∧ (∀ m ∈ ms, m.1 ≠ "_tag" ∧ m.1 ≠ "_args") ∧
      ∀ fields, MinorFields env cl' fields fields' →
        ∃ ys, readFields env F o cl' fields true ms = .ok ys ∧ OlderFields ys' ys)
    (h : toJsonC env' F b o (.variant cl cs') (.case tag [y']) = .ok j) :
    ∃ y, fromJsonC env F b o (.variant cl cs) j = .ok y ∧ Older (.case tag [y']) y := by
  have hmt : MinorTy env (.variant cl cs) (.variant cl cs') := .variant hmc hmm
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    have hB : isBool (.variant cl cs') = true := (isBool_minor hmt) ▸ hb rfl
    cases isBool_eq hB
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    have hN := nullArg?_minor hE F (o := o) hmt
    cases hn : nullArg? env' F o (.variant cl cs') with
    | some a' =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨-, h2⟩ <;> cases h2
    | none =>
      rw [hn] at hN
      have he := isEnum_false (closed := cl) hc rfl
      have he0 : isEnum (.variant cl cs) = false := (isEnum_minor hmc).trans he
      by_cases hr : hasReservedField fields' = true
      · cases y' <;> simp [hn, he, hc, hr, mismatch, fail] at h
      · have hr' : hasReservedField fields' = false := by simpa using hr
        obtain ⟨ys', rfl, hys⟩ := IH hr'
        simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc, hr'] at h
        obtain ⟨ms, hms, rfl⟩ := map_ok.mp h
        obtain ⟨hk, hkeys, hread⟩ := hys ms (under_ok.mp hms)
        rcases caseOf?_minor hE hmc tag with ⟨-, h2⟩ | ⟨c0, c0', h1, h2, h3⟩ | ⟨h1, hcl, hti, -⟩
        · rw [hc] at h2; cases h2
        · rw [hc] at h2
          cases h2
          cases h3 with
          | @record _ _ fields0 _ hmf =>
            obtain ⟨ys, hys0, hold⟩ := hread fields0 hmf
            refine ⟨_, ?_, .case (.cons (.record hold) .nil)⟩
            rw [fromJsonC_none _ hN, readCore.eq_def]
            simp only [Bool.false_eq_true, ↓reduceIte, he0, List.lookup, beq_self_eq_true, htag, Bool.not_true, h1,
              hasReservedField_minor hmf hr', missingJ?_cons _ (missingJ?_minor hmf hk), readFields_tag, hys0,
              Except.map]
        · subst hcl
          have hwm : ∀ m ∈ ms, JSON.WellFormed m.2 := by
            cases hwf with
            | obj _ _ hm => exact fun m hm' => hm m (List.mem_cons_of_mem _ hm')
          obtain ⟨vs, hvs⟩ := fromJsonC_unknown (o := o) (F := F) h1 hti hkeys hwm
          exact ⟨_, hvs, .unknown _ _⟩

/-- `Tag T1 … Tn`, `Some` of a `Maybe` that uses `null` included, given what the older reader does with the arguments. -/
theorem positional_older (hE : env.Minor env') {F : Nat} {o : String} {cl : Bool} {cs cs' : List Case}
    {tag tag' : String} {ts' : List Ty} {ys' : List Typed} {b : Bool} {j : JSON}
    (hmc : MinorCases env cl cs cs') (hmm : maybeOf? (.variant cl cs) = none ∨ cs' = cs)
    (hc : caseOf? env' cs' tag = some (.positional tag' ts')) (htag : isTag tag.toList = true)
    (hb : b = true → isBool (.variant cl cs) = true) (hl : ys'.length = ts'.length) (hwf : JSON.WellFormed j)
    (IHargs : ∀ ts, MinorTys env ts ts' → ∀ js, toJsonArgs env' F o tag 0 ts' ys' = .ok js →
      ∃ zs, readArgs env F o tag 0 ts js = .ok zs ∧ OlderList ys' zs)
    (IHone : ∀ t1', ts' = [t1'] → ∃ y, ys' = [y] ∧ ∀ t1, MinorTy env t1 t1' → ∀ j, toJsonF env' F o t1' y = .ok j →
      ∃ z, fromJsonF env F o t1 j = .ok z ∧ Older y z)
    (h : toJsonC env' F b o (.variant cl cs') (.case tag ys') = .ok j) :
    ∃ y, fromJsonC env F b o (.variant cl cs) j = .ok y ∧ Older (.case tag ys') y := by
  have hmt : MinorTy env (.variant cl cs) (.variant cl cs') := .variant hmc hmm
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    have hB : isBool (.variant cl cs') = true := (isBool_minor hmt) ▸ hb rfl
    cases isBool_eq hB
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    have hN := nullArg?_minor hE F (o := o) hmt
    cases hn : nullArg? env' F o (.variant cl cs') with
    | some a =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨rfl, h2⟩
      · cases h2
      · injection h2 with _ hts
        subst hts
        have hcc := maybe_minor hmt (.inr (by simp [maybeOf?]))
        injection hcc with _ hcs
        subst hcs
        have ha0 : MinorTy env a a := minor_maybeArg hmt rfl
        obtain ⟨y1, rfl, hy1⟩ := IHone a rfl
        simp only [hn] at h
        cases hw' : whnf env' env'.fuel a with
        | error r => simp [hw', fail] at h
        | ok p =>
          obtain ⟨s1, c1'⟩ := p
          simp only [hw'] at h
          have hj : j ≠ .null := fun e => toJsonC_null (nullArg?_next hn hw') y1 (e ▸ h)
          obtain ⟨c1, hw1, -⟩ := whnf_minor_ok hE ha0 hw'
          rw [hn] at hN
          rw [fromJsonC_some hN hj hw1]
          obtain ⟨z, hz, hoz⟩ := hy1 a ha0 j (by rw [toJsonF_eq _ hw']; exact h)
          exact ⟨_, by rw [hz]; rfl, .case (.cons hoz .nil)⟩
    | none =>
      rw [hn] at hN
      have he := isEnum_false (closed := cl) hc rfl
      have he0 : isEnum (.variant cl cs) = false := (isEnum_minor hmc).trans he
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      rcases caseOf?_minor hE hmc tag with ⟨-, h2⟩ | ⟨c0, c0', h1, h2, h3⟩ | ⟨h1, hcl, hti, -⟩
      · rw [hc] at h2; cases h2
      · rw [hc] at h2
        cases h2
        cases h3 with
        | @positional _ ts0 _ hts =>
          rw [fromJsonC_none _ hN, readCore.eq_def]
          match ts', ts0, hts, hl, IHone, IHargs, h with
          | [], [], .nil, hl, _, _, h =>
            cases ys' with
            | cons _ _ => simp at hl
            | nil =>
              simp only [Except.ok.injEq] at h; subst h
              exact ⟨_, by simp [he0, h1, htag, List.lookup], .refl _⟩
          | [t1'], [t1], .cons ht1 .nil, _, IHone, _, h =>
            obtain ⟨y, rfl, hy⟩ := IHone t1' rfl
            obtain ⟨j1, hj1, rfl⟩ := map_ok.mp h
            obtain ⟨z, hz, hoz⟩ := hy t1 ht1 j1 (under_ok.mp hj1)
            refine ⟨_, ?_, .case (.cons hoz .nil)⟩
            simp only [Bool.false_eq_true, ↓reduceIte, he0, List.lookup, beq_self_eq_true, htag, Bool.not_true, h1,
              List.length_cons, List.length_nil]
            rw [memberValue.eq_def]
            simp only [show ("_tag" = "value") = False by decide, ↓reduceIte]
            rw [memberValue.eq_def]
            simp [hz, under, atExtra, Except.map]
          | t1' :: t2' :: rest', t1 :: t2 :: rest0, .cons h1' (.cons h2' hr'), hl, _, IHargs, h =>
            obtain ⟨js, hjs, rfl⟩ := map_ok.mp h
            have hts : MinorTys env (t1 :: t2 :: rest0) (t1' :: t2' :: rest') := .cons h1' (.cons h2' hr')
            have hlen : js.length = (t1 :: t2 :: rest0).length := by
              rw [hts.length]; exact (toJsonArgs_length hl hjs).trans hl
            obtain ⟨zs, hzs, hoz⟩ := IHargs _ hts js hjs
            refine ⟨_, ?_, .case hoz⟩
            simp only [Bool.false_eq_true, ↓reduceIte, he0, List.lookup, beq_self_eq_true, htag, Bool.not_true, h1,
              List.length_cons, List.length_nil]
            rw [memberValues.eq_def]
            simp only [show ("_tag" = "values") = False by decide, ↓reduceIte]
            rw [memberValues.eq_def]
            simp [hlen, hzs, under, atExtra, Except.map]
      · subst hcl
        match ts', hl, IHone, h with
        | [], _, _, h =>
          simp only [Except.ok.injEq] at h; subst h
          obtain ⟨vs, hvs⟩ := fromJsonC_unknown (o := o) (F := F) (ms := []) h1 hti (by simp) (by simp)
          exact ⟨_, hvs, .unknown _ _⟩
        | [t1'], _, IHone, h =>
          obtain ⟨y, rfl, -⟩ := IHone t1' rfl
          obtain ⟨j1, -, rfl⟩ := map_ok.mp h
          have hwm : ∀ m ∈ [("value", j1)], JSON.WellFormed m.2 := by
            cases hwf with
            | obj _ _ hm => exact fun m hm' => hm m (List.mem_cons_of_mem _ hm')
          obtain ⟨vs, hvs⟩ := fromJsonC_unknown (o := o) (F := F) h1 hti (by simp) hwm
          exact ⟨_, hvs, .unknown _ _⟩
        | t1' :: t2' :: rest', _, _, h =>
          obtain ⟨js, -, rfl⟩ := map_ok.mp h
          have hwm : ∀ m ∈ [("values", JSON.arr js)], JSON.WellFormed m.2 := by
            cases hwf with
            | obj _ _ hm => exact fun m hm' => hm m (List.mem_cons_of_mem _ hm')
          obtain ⟨vs, hvs⟩ := fromJsonC_unknown (o := o) (F := F) h1 hti (by simp) hwm
          exact ⟨_, hvs, .unknown _ _⟩

/-! ## The older reader reads the newer writer -/

mutual
/-- **An older reader accepts a newer writer**, by the rules of the newer decoding. -/
theorem Dec.older (hE : env.Minor env') {F : Nat} {o : String} {t t' : Ty} {v : Value} {x' : Typed} {j : JSON} :
    Dec env' t' v x' → v.wf = true → UniqueKeys v → MinorTy env t t' → toJsonF env' F o t' x' = .ok j →
      ∃ y, fromJsonF env F o t j = .ok y ∧ Older x' y
  | .intro (s := s) hw hc, hv, hu, ht, h => by
    obtain ⟨c, hwo, hcc⟩ := whnf_minor_ok hE ht hw
    rw [toJsonF_eq _ hw, toJsonC_hide] at h
    rw [fromJsonF_eq _ hwo, boolTy_minor hE ht, origin_minor hE ht hwo]
    obtain ⟨y, hy, ho⟩ := hc.older hE hv hu hcc (fun hb => (isBool_minor hcc).trans (boolTy_isBool hb hw)) h
    exact ⟨y.hide s, hidden_of hy, ho.hide s⟩

theorem Core.older (hE : env.Minor env') {F : Nat} {o : String} {c c' : Ty} {v : Value} {x' : Typed} {b : Bool}
    {j : JSON} :
    Core env' c' v x' → v.wf = true → UniqueKeys v → MinorTy env c c' → (b = true → isBool c = true) →
      toJsonC env' F b o c' x' = .ok j → ∃ y, fromJsonC env F b o c j = .ok y ∧ Older x' y
  | .string s, _, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
  | .bytes bs, _, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [Bytes.base64_decode_encode]
  | .int (k := k) (n := n) _ hr, _, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [intOfJson, intJson]
    cases k.asString <;> simp [wholeLit_intLit, hr]
  | .float (k := k) (a := a) (x := f) hx, _, _, ht, _, h => by
    cases ht
    obtain ⟨n, m, q, rfl⟩ := roundLit_fin hx
    simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [floatOfJson, jsonToLit_spell, String.ofList_toList, floatLaw k a _ hx]
  | .floatTag (k := k) (tag := tag) hx, _, _, ht, _, h => by
    cases ht
    refine ⟨_, ?_, .refl _⟩
    unfold floatTag? at hx
    split at hx <;> cases hx <;>
    · simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
      rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
      simp [floatOfJson]
  | .decimal a, hv, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [Value.wf] at hv
    simp [decimalOf, isNormalLit_json hv, normalizeNumber_normal hv]
  | .any v, hv, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [JSON.fromSelfDescribing_selfDescribing v hv]
  | .time (k := k) (s := s) hc, _, _, ht, _, h => by
    cases ht
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [hc]
  | .array (t := t1') (xs := xs) (ys := ys') hi, hv, hu, ht, _, h => by
    cases ht with
    | @array t1 _ ht1 =>
    simp only [toJsonC, map_ok] at h
    obtain ⟨js, hjs, rfl⟩ := h
    simp only [Value.wf] at hv
    obtain ⟨ys, hys, ho⟩ := hi.older hE hv (uniqueKeys_arr hu) ht1 hjs
    refine ⟨_, ?_, .arr ho⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [hys, Except.map]
  | .map (t := t1') (fs := fs) (ys := ys') he, hv, hu, ht, _, h => by
    cases ht with
    | @map t1 _ ht1 =>
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [Value.wf] at hv
    obtain ⟨ys, hys, ho⟩ := he.older hE hv (uniqueKeys_record hu) ht1 hms
    refine ⟨_, ?_, .map ho⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [hys, Except.map]
  | .record (closed := cl) (fields := fields') (fs := fs) (ys := ys') hm hf, hv, hu, ht, _, h => by
    cases ht with
    | @record _ fields _ hmf =>
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [Value.wf] at hv
    have hk : missingJ? fields' ms = none := by
      rw [missingJ?_eq ((toJsonFields_keys hms).trans (encodeFields_keys ys').symm)]
      exact hf.missing hm
    obtain ⟨ys, hys, ho⟩ := hf.older hE hv (uniqueKeys_record hu) hmf false (by simp) hms
    refine ⟨_, ?_, .record ho⟩
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [missingJ?_minor hmf hk, hys, Except.map]
  | .bare (closed := cl) (cases := cs') (tag := tag) hc, hv, _, ht, hb, h => by
    cases ht with
    | @variant _ cs _ hmc hmm =>
    have hmt : MinorTy env (.variant cl cs) (.variant cl cs') := .variant hmc hmm
    rw [toJsonC.eq_def] at h
    simp only at h
    cases b with
    | true =>
      have hB := hb rfl
      have hB' : isBool (.variant cl cs') = true := (isBool_minor hmt) ▸ hB
      cases isBool_eq hB
      cases isBool_eq hB'
      simp only [↓reduceIte, Except.ok.injEq] at h; subst h
      refine ⟨_, ?_, .refl _⟩
      rw [fromJsonC_none _ (nullArg?_isBool hB), readCore.eq_def]
      rcases caseOf?_bool hc with rfl | rfl <;> simp
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h
      have hN := nullArg?_minor hE F (o := o) hmt
      cases hn : nullArg? env' F o (.variant cl cs') with
      | some a =>
        simp only [hn] at h
        obtain ⟨hm, -, -⟩ := nullArg?_some hn
        cases maybeOf?_some hm
        rcases caseOf?_maybe hc with ⟨rfl, -⟩ | ⟨-, h2⟩
        · simp only [Except.ok.injEq] at h; subst h
          rw [hn] at hN
          exact ⟨_, fromJsonC_null hN, .refl _⟩
        · cases h2
      | none =>
        simp only [hn] at h
        rw [hn] at hN
        have hE0 := isEnum_minor hmc
        rcases caseOf?_minor hE hmc tag with ⟨-, h2⟩ | ⟨c0, c0', h1, h2, h3⟩ | ⟨h1, hcl, hti, -⟩
        · rw [hc] at h2; cases h2
        · rw [hc] at h2
          cases h2
          cases h3
          rw [fromJsonC_none _ hN, readCore.eq_def]
          by_cases he : isEnum (.variant cl cs') = true
          · simp only [he, ↓reduceIte, Except.ok.injEq] at h; subst h
            exact ⟨_, by simp [hE0, he, h1], .refl _⟩
          · simp only [he, Bool.false_eq_true, ↓reduceIte, hc, Except.ok.injEq] at h; subst h
            have htag : isTag tag.toList = true := by simpa [Value.wf, Value.wfList] using hv
            exact ⟨_, by simp [hE0, he, h1, htag, List.lookup], .refl _⟩
        · subst hcl
          have he : isEnum (.variant false cs') = false := rfl
          simp only [he, Bool.false_eq_true, ↓reduceIte, hc, Except.ok.injEq] at h; subst h
          obtain ⟨vs, hvs⟩ := fromJsonC_unknown (o := o) (F := F) (ms := []) h1 hti (by simp) (by simp)
          exact ⟨_, hvs, .unknown _ _⟩
  | .recordCase (cases := cs') (tag := tag) hc hd, hv, hu, ht, hb, h => by
    cases ht with
    | @variant _ cs _ hmc hmm =>
    have hwf := (Core.recordCase hc hd).wellFormed hu h
    simp only [Value.wf, Value.wfList, Bool.and_eq_true, and_true] at hv
    exact recordCase_older hE hmc hmm hc hv.1 hb hwf
      (fun hr => hd.olderPayload hE rfl hv.2 (uniqueKeys_variant hu _ (List.mem_cons_self ..)) hr) h
  | .positional (cases := cs') (tag := tag) (ts := ts') hc ha, hv, hu, ht, hb, h => by
    cases ht with
    | @variant _ cs _ hmc hmm =>
    have hwf := (Core.positional hc ha).wellFormed hu h
    simp only [Value.wf, Bool.and_eq_true] at hv
    exact positional_older hE hmc hmm hc hv.1 hb ha.length_ys hwf
      (fun ts hts js h => ha.older hE hv.2 (uniqueKeys_variant hu) hts h)
      (fun t1 hts => ha.olderOne hE hts hv.2 (uniqueKeys_variant hu)) h
  | .unknown (cases := cs') (tag := tag) (args := args) hc, hv, _, ht, hb, h => by
    cases ht with
    | @variant _ cs _ hmc hmm =>
    simp only [Value.wf, Bool.and_eq_true] at hv
    have hbf : b = false := by
      cases b
      · rfl
      · exact absurd (hb rfl) (by simp [isBool])
    subst hbf
    have hc0 : caseOf? env cs tag = none := by
      rcases caseOf?_minor hE hmc tag with ⟨h1, -⟩ | ⟨c0, c0', -, h2, -⟩ | ⟨-, -, -, c0', h2⟩
      · exact h1
      · rw [hc] at h2; cases h2
      · rw [hc] at h2; cases h2
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    refine ⟨_, ?_, .refl _⟩
    rw [fromJsonC_none _ nullArg?_open, readCore.eq_def]
    have he : isEnum (.variant false cs) = false := rfl
    cases args with
    | nil => simp [unknownJson, he, hc0, hv.1, List.lookup]
    | cons w ws =>
      have hl := JSON.fromSelfDescribingList_selfDescribingList (w :: ws) hv.2
      simp only [JSON.selfDescribingList] at hl
      simp [unknownJson, he, hc0, hv.1, List.lookup, JSON.selfDescribingList, hl]

theorem Items.older (hE : env.Minor env') {F : Nat} {o : String} {t t' : Ty} {xs : List Value} {ys' : List Typed}
    {i : Nat} {js : List JSON} :
    Items env' t' xs ys' → Value.wfList xs = true → (∀ x ∈ xs, UniqueKeys x) → MinorTy env t t' →
      toJsonItems env' F o t' i ys' = .ok js → ∃ ys, readItems env F o t i js = .ok ys ∧ OlderList ys' ys
  | .nil, _, _, _, h => by
    simp only [toJsonItems, Except.ok.injEq] at h; subst h
    exact ⟨[], by rw [readItems.eq_def], .nil⟩
  | .cons hx hs, hv, hu, ht, h => by
    simp only [Value.wfList, Bool.and_eq_true] at hv
    rw [toJsonItems_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    obtain ⟨y, hy, ho⟩ := hx.older hE hv.1 (hu _ (List.mem_cons_self ..)) ht (under_ok.mp hj)
    obtain ⟨ys, hys, hos⟩ := hs.older hE hv.2 (fun x hx => hu x (List.mem_cons_of_mem _ hx)) ht hjs
    refine ⟨y :: ys, ?_, .cons ho hos⟩
    rw [readItems.eq_def]
    simp [hy, hys, under, bind, Except.bind, pure, Except.pure]

theorem Entries.older (hE : env.Minor env') {F : Nat} {o : String} {t t' : Ty} {fs : List (String × Value)}
    {ys' : List (String × Typed)} {ms : List (String × JSON)} :
    Entries env' t' fs ys' → Value.wfFields fs = true → (∀ kv ∈ fs, UniqueKeys kv.2) → MinorTy env t t' →
      toJsonEntries env' F o t' ys' = .ok ms → ∃ ys, readEntries env F o t ms = .ok ys ∧ OlderEntries ys' ys
  | .nil, _, _, _, h => by
    simp only [toJsonEntries, Except.ok.injEq] at h; subst h
    exact ⟨[], by rw [readEntries.eq_def], .nil⟩
  | .cons hx hs, hv, hu, ht, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    rw [toJsonEntries_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    obtain ⟨y, hy, ho⟩ := hx.older hE hv.1 (hu _ (List.mem_cons_self ..)) ht (under_ok.mp hj)
    obtain ⟨ys, hys, hos⟩ := hs.older hE hv.2 (fun x hx => hu x (List.mem_cons_of_mem _ hx)) ht hms
    refine ⟨_ :: ys, ?_, .cons ho hos⟩
    rw [readEntries.eq_def]
    simp [hy, hys, under, bind, Except.bind, pure, Except.pure]

theorem Fields.older (hE : env.Minor env') {F : Nat} {o : String} {cl : Bool} {fields fields' : List Field}
    {fs : List (String × Value)} {ys' : List (String × Typed)} {ms : List (String × JSON)} :
    Fields env' cl fields' fs ys' → Value.wfFields fs = true → (∀ kv ∈ fs, UniqueKeys kv.2) →
      MinorFields env cl fields fields' → ∀ skip : Bool, (skip = true → hasReservedField fields' = false) →
      toJsonFields env' F o fields' ys' = .ok ms →
      ∃ ys, readFields env F o cl fields skip ms = .ok ys ∧ OlderFields ys' ys
  | .nil, _, _, _, _, _, h => by
    simp only [toJsonFields, Except.ok.injEq] at h; subst h
    exact ⟨[], by rw [readFields.eq_def], .nil⟩
  | .keep (k := k) hf hx hs, hv, hu, hmf, skip, hsk, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    rw [toJsonFields_cons hf] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    have hs' : (skip && k == "_tag") = false := by
      cases skip
      · rfl
      · have hk := (List.find?_some hf)
        have hm := List.mem_of_find?_eq_some hf
        simp only [beq_iff_eq] at hk
        have := hsk rfl
        simp only [hasReservedField, List.any_eq_false] at this
        simp only [Bool.true_and, beq_eq_false_iff_ne, ne_eq]
        intro he; exact this _ hm (by simp [hk, he])
    obtain ⟨ys, hys, hos⟩ := hs.older hE hv.2 (fun kv h => hu kv (List.mem_cons_of_mem _ h)) hmf skip hsk hms
    rcases find_minorFields k hmf with ⟨-, h2⟩ | ⟨f0, f0', h1, h2, h3⟩ | ⟨h1, hcl, -⟩
    · rw [hf] at h2; cases h2
    · rw [hf] at h2
      cases h2
      obtain ⟨y, hy, ho⟩ := hx.older hE hv.1 (hu _ (List.mem_cons_self ..)) h3 (under_ok.mp hj)
      refine ⟨(k, y) :: ys, ?_, .keep ho hos⟩
      rw [readFields.eq_def]
      simp [hs', h1, hy, hys, under, bind, Except.bind, pure, Except.pure]
    · subst hcl
      refine ⟨ys, ?_, .drop hos⟩
      rw [readFields.eq_def]
      simp [hs', h1, hys]
  | .skip _ hs, hv, hu, hmf, skip, hsk, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    exact hs.older hE hv.2 (fun kv h => hu kv (List.mem_cons_of_mem _ h)) hmf skip hsk h

theorem Args.older (hE : env.Minor env') {F : Nat} {o : String} {ts' : List Ty} {xs : List Value}
    {ys' : List Typed} {tag : String} {i : Nat} {js : List JSON} :
    Args env' ts' xs ys' → Value.wfList xs = true → (∀ x ∈ xs, UniqueKeys x) → ∀ {ts : List Ty}, MinorTys env ts ts' →
      toJsonArgs env' F o tag i ts' ys' = .ok js → ∃ zs, readArgs env F o tag i ts js = .ok zs ∧ OlderList ys' zs
  | .nil, _, _, _, hts, h => by
    cases hts
    simp only [toJsonArgs, Except.ok.injEq] at h; subst h
    exact ⟨[], by rw [readArgs.eq_def], .nil⟩
  | .cons hx hs, hv, hu, _, hts, h => by
    cases hts with
    | cons ht hts' =>
    simp only [Value.wfList, Bool.and_eq_true] at hv
    rw [toJsonArgs_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    obtain ⟨y, hy, ho⟩ := hx.older hE hv.1 (hu _ (List.mem_cons_self ..)) ht (under_ok.mp hj)
    obtain ⟨zs, hzs, hos⟩ := hs.older hE hv.2 (fun x hx => hu x (List.mem_cons_of_mem _ hx)) hts' hjs
    refine ⟨y :: zs, ?_, .cons ho hos⟩
    rw [readArgs.eq_def]
    simp [hy, hzs, under, bind, Except.bind, pure, Except.pure]

/-- One positional argument. -/
theorem Args.olderOne (hE : env.Minor env') {F : Nat} {o : String} {ts' : List Ty} {xs : List Value}
    {ys' : List Typed} {t' : Ty} :
    Args env' ts' xs ys' → ts' = [t'] → Value.wfList xs = true → (∀ x ∈ xs, UniqueKeys x) →
      ∃ y, ys' = [y] ∧ ∀ t, MinorTy env t t' → ∀ j, toJsonF env' F o t' y = .ok j →
        ∃ z, fromJsonF env F o t j = .ok z ∧ Older y z
  | .nil, hts, _, _ => by cases hts
  | .cons hx .nil, hts, hv, hu => by
    simp only [List.cons.injEq, and_true] at hts
    subst hts
    simp only [Value.wfList, Bool.and_eq_true, and_true] at hv
    exact ⟨_, rfl, fun t ht j h => hx.older hE hv (hu _ (List.mem_cons_self ..)) ht h⟩
  | .cons _ (.cons _ _), hts, _, _ => by simp at hts

/-- A record payload: what `Tag { … }` decodes its record to, and what the older reader does with its fields. -/
theorem Dec.olderPayload (hE : env.Minor env') {F : Nat} {o : String} {t : Ty} {cl' : Bool} {fields' : List Field}
    {a : Value} {y : Typed} :
    Dec env' t a y → t = .record cl' fields' → a.wf = true → UniqueKeys a → hasReservedField fields' = false →
      ∃ ys', y = .record ys' ∧ ∀ ms, toJsonFields env' F o fields' ys' = .ok ms →
        missingJ? fields' ms = none ∧ (∀ m ∈ ms, m.1 ≠ "_tag" ∧ m.1 ≠ "_args") ∧
        ∀ fields, MinorFields env cl' fields fields' →
          ∃ ys, readFields env F o cl' fields true ms = .ok ys ∧ OlderFields ys' ys
  | .intro hw hcore, ht0, ha, hu, ht => hcore.olderPayload hE (ht0 ▸ hw) ha hu ht

theorem Core.olderPayload (hE : env.Minor env') {F : Nat} {o : String} {cl' : Bool} {fields' : List Field} {c : Ty}
    {s : Nat} {a : Value} {y : Typed} :
    Core env' c a y → whnf env' env'.fuel (.record cl' fields') = .ok (s, c) → a.wf = true → UniqueKeys a →
      hasReservedField fields' = false →
      ∃ ys', y.hide s = .record ys' ∧ ∀ ms, toJsonFields env' F o fields' ys' = .ok ms →
        missingJ? fields' ms = none ∧ (∀ m ∈ ms, m.1 ≠ "_tag" ∧ m.1 ≠ "_args") ∧
        ∀ fields, MinorFields env cl' fields fields' →
          ∃ ys, readFields env F o cl' fields true ms = .ok ys ∧ OlderFields ys' ys
  | .record (closed := cl0) (fields := fields0) (ys := ys') hm hf, hw, ha, hu, ht => by
    simp only [Value.wf] at ha
    rw [whnf_record] at hw
    have e := Prod.mk.inj (Except.ok.inj hw)
    have e2 : Ty.record cl' fields' = Ty.record cl0 fields0 := e.2
    injection e2 with ec ef
    have IH : ∀ ms, toJsonFields env' F o fields0 ys' = .ok ms → ∀ fields, MinorFields env cl0 fields fields0 →
        ∃ ys, readFields env F o cl0 fields true ms = .ok ys ∧ OlderFields ys' ys :=
      fun ms h fields hmf => hf.older hE ha (uniqueKeys_record hu) hmf true (fun _ => ef ▸ ht) h
    subst ec ef
    rw [← e.1]
    refine ⟨ys', rfl, fun ms h => ⟨?_, payload_keys hf ht h, IH ms h⟩⟩
    rw [missingJ?_eq ((toJsonFields_keys h).trans (encodeFields_keys _).symm)]
    exact hf.missing hm
  | .string _, hw, _, _, _ | .bytes _, hw, _, _, _ | .int _ _, hw, _, _, _ | .float _, hw, _, _, _
  | .floatTag _, hw, _, _, _ | .decimal _, hw, _, _, _ | .any _, hw, _, _, _ | .time _, hw, _, _, _
  | .array _, hw, _, _, _ | .map _, hw, _, _, _ | .bare _, hw, _, _, _ | .recordCase _ _, hw, _, _, _
  | .positional _ _, hw, _, _, _ | .unknown _, hw, _, _, _ => by
    rw [whnf_record] at hw; cases hw
end

/-! ## The theorems -/

/--
**An older reader accepts a newer writer** (§13.3, §16.3). `env'` is a
later minor version of `env`, `t'` the newer version of the type `t`. For a
well-formed value `v` without duplicate keys that `t'` decodes to `x'`, the
older reader reads `x'`'s schema-based JSON without an error, as `x'` with
the cases `t` doesn't list as unknown values and the fields it doesn't list
left out (`Older`). For any fuel `F` of the chains of `Maybe`s, the same for
writing and reading.
-/
theorem older_reads_newer {env env' : Env} (hE : env.Minor env') {F : Nat} {o : String} {t t' : Ty} {v : Value}
    {x' : Typed} {j : JSON} (ht : MinorTy env t t') (hd : decode env' t' v = .ok x') (hv : v.wf = true)
    (hu : UniqueKeys v) (hj : toJsonF env' F o t' x' = .ok j) :
    ∃ y, fromJsonF env F o t j = .ok y ∧ Older x' y :=
  (decode_sound hd).older hE hv hu ht hj

/-- The same for a type by its name: `T` of the newer schema written, `T` of the older one read. -/
theorem older_reads_newer_name {env env' : Env} (hE : env.Minor env') {F : Nat} {n : String} {d : Ty}
    (hn : env.lookup n = some d) {v : Value} {x' : Typed} {j : JSON} (hd : decode env' (.ref n) v = .ok x')
    (hv : v.wf = true) (hu : UniqueKeys v) (hj : toJsonF env' F "" (.ref n) x' = .ok j) :
    ∃ y, fromJsonF env F "" (.ref n) j = .ok y ∧ Older x' y :=
  older_reads_newer hE (.ref (by simp [hn])) hd hv hu hj

/-- For every value of every haus text: the parser's values are well formed, without duplicate keys. -/
theorem older_reads_newer_parsed {L : Limits} {input : Text} {vs : List Value} (hp : Parser.parse L input = .ok vs)
    {v : Value} (hvs : v ∈ vs) {env env' : Env} (hE : env.Minor env') {F : Nat} {o : String} {t t' : Ty}
    {x' : Typed} {j : JSON} (ht : MinorTy env t t') (hd : decode env' t' v = .ok x')
    (hj : toJsonF env' F o t' x' = .ok j) : ∃ y, fromJsonF env F o t j = .ok y ∧ Older x' y :=
  older_reads_newer hE ht hd (parse_wf hp v hvs) (parse_uniqueKeys hp v hvs) hj

/-! ## Example: a new tag and a new optional field -/

/-- Version 1.0: `type Shape = < Circle { r: Int32 } >`. -/
private def shapes10 : Env := ⟨[("Shape", .variant false [.record "Circle" false [.mk "r" false (.int (.signed 32))]])]⟩

/-- Version 1.1: `Circle` gets `label?: String`, and `Square { side: Int32 }` is new. -/
private def shapes11 : Env := ⟨[("Shape", .variant false
  [.record "Circle" false [.mk "r" false (.int (.signed 32)), .mk "label" true .string],
   .record "Square" false [.mk "side" false (.int (.signed 32))]])]⟩

/-- 1.1 is a later minor version of 1.0, so `older_reads_newer` applies. -/
example : shapes10.Minor shapes11 := by
  intro n t h
  simp only [shapes10, Env.lookup, List.lookup] at h
  split at h
  · rename_i hn
    simp only [beq_iff_eq] at hn
    subst hn
    cases h
    refine ⟨_, rfl, .variant (.cons (.record (.cons (.int _) (.add .nil (by simp)))) (.add .nil (by simp) rfl))
      (.inl rfl)⟩
  · cases h

/-- 1.1 writes, 1.0 reads (the canonical text of what it reads). -/
private def readOld (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] =>
    match decode shapes11 (.ref "Shape") v with
    | .ok x =>
      match toJson shapes11 (.ref "Shape") x with
      | .ok j => (fromJson shapes10 (.ref "Shape") j).toOption.map fun y => String.ofList (Canonical.canonical (encode y))
      | .error _ => none
    | .error _ => none
  | _ => none

#guard readOld "Circle { r: 1, label: \"one\" }" == some "Circle{r:1}"
#guard readOld "Square { side: 2 }" == some "Square{side:2}"

end Haus.Schema
