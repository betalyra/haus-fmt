import Haus.Schema.Decode

/-!
# Decoding in linear time (plan step I7, spec §9.8, §15)

§15: "Decoding is linear in the input whatever the schema". `decode`
(`Haus.Schema.Decode`) returns `Except`, so its steps are counted next to it
by functions that follow its recursion (`decodeSteps`, as P3 counts the
parser's leaves), with P1's cost model (`Haus.Linear.Monad`): following a
reference is a lookup in the environment, one step per definition; finding
a field or a case compares a key or tag with each the type lists, one step
per character of the input's key or tag, plus one; a list of the input
costs one step per element; an integer literal one step per character.
Where `decode` stops at the first error, the count goes on as if every part
were decoded, so it is an upper bound.

Two leaves are counted by what they are given (`LeafCost`): rounding a float
literal and checking a std/time string. Their own steps aren't counted here;
`decode_linear` holds for any leaf costs linear in the literal's characters
(`LeafCost.Linear`).

The input's size (`inputSize`) is its number of parts plus the characters
of its numbers, strings, byte strings, tags and keys: at most the length of
its text.

**`decode_linear`**: for every environment and type, decoding any value
takes at most `K · size` steps, `K` a number computed from the schema alone
(`costK`: the number of definitions, the size of the largest type, and the
leaves' constant). Each part of the input is looked at with one type, and
everything done there is bounded by the schema: following names at most
`env.fuel` times (`whnf`, `whnfSteps_le`), secrets at most as many as there
are steps of that (`whnf_size`), a record's fields and a variant's cases
at most the size of the type (`length_le_sizeOf`), whose parts are smaller
(`whnf_size`, `recordOf_size`, `caseOf_size`). A record type compares each
of its fields with each key of the input, so one step per field per
character of the keys: that is where the size of the largest type multiplies
the input.
-/

namespace Haus.Linear
open Haus Haus.Schema

/-! ## The size of the input -/

mutual
/-- Parts, and the characters of numbers, strings, byte strings, tags and keys. -/
def inputSize : Value → Nat
  | .num a => a.length + 1
  | .str s => s.length + 1
  | .bytes bs => bs.length + 1
  | .arr xs => sizeItems xs + 1
  | .record fs => sizeFields fs + 1
  | .variant tag args => tag.length + sizeItems args + 1

def sizeItems : List Value → Nat
  | [] => 0
  | x :: xs => inputSize x + 1 + sizeItems xs

def sizeFields : List (String × Value) → Nat
  | [] => 0
  | (k, x) :: fs => k.length + 1 + inputSize x + sizeFields fs
end

theorem length_le_sizeItems : ∀ xs : List Value, xs.length ≤ sizeItems xs
  | [] => by simp [sizeItems]
  | x :: xs => by have := length_le_sizeItems xs; simp [sizeItems]; omega

/-! ## Counting the steps -/

/-- The steps of the leaves this file doesn't count itself. -/
structure LeafCost where
  /-- Rounding a number to a float (`roundLit`). -/
  float : FloatType → String → Nat
  /-- Checking a std/time string (`Time.check`). -/
  time : Time.TimeType → String → Nat

/-- Leaf costs at most `k` steps per character of the literal, and `k`. -/
def LeafCost.Linear (lc : LeafCost) (k : Nat) : Prop :=
  (∀ f a, lc.float f a ≤ k * (a.length + 1)) ∧ (∀ tt x, lc.time tt x ≤ k * (x.length + 1))

/-- `peel`: one step per secret, and one. -/
def peelSteps : Ty → Nat
  | .secret t => peelSteps t + 1
  | _ => 1

/-- `whnf`: `peel`, and for a reference a lookup (one step per definition) and what follows. -/
def whnfSteps (env : Env) : Nat → Ty → Nat
  | fuel, t =>
    match peel t with
    | (_, .ref n) =>
      match fuel with
      | 0 => peelSteps t
      | fuel + 1 =>
        match env.lookup n with
        | some u => peelSteps t + env.defs.length + 1 + whnfSteps env fuel u
        | none => peelSteps t + env.defs.length + 1
    | _ => peelSteps t

/-- `recordOf?`: a lookup per reference followed. -/
def recordOfSteps (env : Env) : Nat → Ty → Nat
  | f + 1, .ref n =>
    match env.lookup n with
    | some t => env.defs.length + 1 + recordOfSteps env f t
    | none => env.defs.length + 1
  | _, _ => 1

/-- Comparing each key of the input once: one step per character, and one. -/
def keysSteps : List (String × Value) → Nat
  | [] => 1
  | (k, _) :: fs => k.length + 1 + keysSteps fs

/-- `caseOf?`: the tag compared with each case, and `Case.resolve`. -/
def caseSteps (env : Env) (cases : List Case) (tag : String) : Nat :=
  cases.length * (tag.length + 1) +
    match cases.find? (·.tag == tag) with
    | some (.named _ t) => recordOfSteps env env.fuel t
    | _ => 1

mutual
/-- The steps of `decode env t v`, at most (`decode_linear`). -/
def decodeSteps (lc : LeafCost) (env : Env) (t : Ty) (v : Value) : Nat :=
  whnfSteps env env.fuel t +
  match whnf env env.fuel t with
  | .error _ => 1
  | .ok (s, c) => s + 1 +
    match c, v with
    | .int _, .num a => a.length + 1
    | .float k, .num a => lc.float k a + 1
    | .float _, .variant tag [] => tag.length + 1
    | .time k, .variant tag [.str x] => tag.length + lc.time k x + 1
    | .array t, .arr xs => itemsSteps lc env t xs + 1
    | .map t, .record fs => entriesSteps lc env t fs + 1
    | .record _ fields, .record fs => fields.length * keysSteps fs + fieldsSteps lc env fields fs + 1
    | .variant _ cases, .variant tag args =>
      caseSteps env cases tag + 1 +
      match caseOf? env cases tag, args with
      | some (.record _ cl fields), [.record fs] => decodeSteps lc env (.record cl fields) (.record fs)
      | some (.positional _ ts), args => ts.length + args.length + argsSteps lc env ts args
      | _, _ => 0
    | _, _ => 1

def itemsSteps (lc : LeafCost) (env : Env) (t : Ty) : List Value → Nat
  | [] => 1
  | x :: xs => decodeSteps lc env t x + 1 + itemsSteps lc env t xs

def entriesSteps (lc : LeafCost) (env : Env) (t : Ty) : List (String × Value) → Nat
  | [] => 1
  | (_, x) :: fs => decodeSteps lc env t x + 1 + entriesSteps lc env t fs

/-- A field of the input: its key compared with the type's fields, and its value decoded. -/
def fieldsSteps (lc : LeafCost) (env : Env) (fields : List Field) : List (String × Value) → Nat
  | [] => 1
  | (k, x) :: fs =>
    fields.length * (k.length + 1) +
      (match fieldOf? fields k with
        | some f => decodeSteps lc env f.ty x
        | none => 0) + 1 + fieldsSteps lc env fields fs

def argsSteps (lc : LeafCost) (env : Env) : List Ty → List Value → Nat
  | t :: ts, x :: xs => decodeSteps lc env t x + 1 + argsSteps lc env ts xs
  | _, _ => 1
end

/-! ## Sizes of types -/

theorem one_le_sizeOf_ty (t : Ty) : 1 ≤ sizeOf t := by
  cases t <;> simp <;> omega

theorem length_le_sizeOf {α : Type} [SizeOf α] : ∀ l : List α, l.length ≤ sizeOf l
  | [] => by simp
  | a :: l => by have := length_le_sizeOf l; simp; omega

theorem peelSteps_le : ∀ t : Ty, peelSteps t ≤ sizeOf t
  | .secret t => by have := peelSteps_le t; simp [peelSteps]; omega
  | .string | .bytes | .int _ | .float _ | .decimal | .any | .time _ | .array _ | .map _ | .record _ _
  | .variant _ _ | .ref _ => by
    simp only [peelSteps]; exact one_le_sizeOf_ty _

theorem peel_size : ∀ t : Ty, sizeOf (peel t).2 ≤ sizeOf t ∧ (peel t).1 ≤ peelSteps t
  | .secret t => by
    have := peel_size t
    simp only [peel, peelSteps]; simp; omega
  | .string | .bytes | .int _ | .float _ | .decimal | .any | .time _ | .array _ | .map _ | .record _ _
  | .variant _ _ | .ref _ => by simp [peel, peelSteps]

/-- Every type of the environment is at most `M`. -/
def EnvBound (env : Env) (M : Nat) : Prop := ∀ p ∈ env.defs, sizeOf p.2 ≤ M

theorem lookup_bound {env : Env} {M : Nat} (hE : EnvBound env M) {n : String} {u : Ty}
    (h : env.lookup n = some u) : sizeOf u ≤ M := by
  unfold Env.lookup at h
  suffices ∀ l : List (String × Ty), (∀ p ∈ l, sizeOf p.2 ≤ M) → l.lookup n = some u → sizeOf u ≤ M from
    this _ hE h
  intro l
  induction l with
  | nil => intro _ h; simp at h
  | cons p l ih =>
    intro hl h
    obtain ⟨a, b⟩ := p
    simp only [List.lookup] at h
    split at h
    · cases h; exact hl _ (List.mem_cons_self ..)
    · exact ih (fun q hq => hl q (List.mem_cons_of_mem _ hq)) h

/-! ## Following names -/

theorem whnfSteps_le {env : Env} {M : Nat} (hE : EnvBound env M) :
    ∀ (f : Nat) (t : Ty), sizeOf t ≤ M → whnfSteps env f t ≤ (f + 1) * (M + env.defs.length + 1)
  | f, t, ht => by
    have hp := peelSteps_le t
    have hX : M + env.defs.length + 1 ≤ (f + 1) * (M + env.defs.length + 1) :=
      Nat.le_mul_of_pos_left _ (Nat.succ_pos f)
    cases hpt : peel t with
    | mk s0 c0 =>
      unfold whnfSteps
      rw [hpt]
      cases c0 with
      | ref n =>
        cases f with
        | zero => simp only; omega
        | succ f =>
          simp only
          cases hu : env.lookup n with
          | none => simp only; omega
          | some u =>
            simp only
            have := whnfSteps_le hE f u (lookup_bound hE hu)
            rw [Nat.succ_mul (f + 1)]
            omega
      | _ => simp only; omega

/-- What `whnf` returns is no bigger than the largest type, and its secrets at most its steps. -/
theorem whnf_size {env : Env} {M : Nat} (hE : EnvBound env M) :
    ∀ (f : Nat) (t : Ty) {s : Nat} {c : Ty}, sizeOf t ≤ M → whnf env f t = .ok (s, c) →
      sizeOf c ≤ M ∧ s ≤ whnfSteps env f t
  | f, t, s, c, ht, h => by
    have hp := peel_size t
    cases hpt : peel t with
    | mk s0 c0 =>
      rw [hpt] at hp
      simp only at hp
      unfold whnf at h
      unfold whnfSteps
      rw [hpt] at h ⊢
      cases c0 with
      | ref n =>
        cases f with
        | zero => simp at h
        | succ f =>
          simp only at h ⊢
          cases hu : env.lookup n with
          | none => simp [hu] at h
          | some u =>
            simp only [hu] at h ⊢
            cases hw : whnf env f u with
            | error e => simp [hw, Except.map] at h
            | ok r =>
              obtain ⟨s', c'⟩ := r
              simp only [hw, Except.map, Except.ok.injEq, Prod.mk.injEq] at h
              obtain ⟨rfl, rfl⟩ := h
              obtain ⟨h1, h2⟩ := whnf_size hE f u (lookup_bound hE hu) hw
              exact ⟨h1, by omega⟩
      | _ =>
        simp only [Except.ok.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        dsimp only
        exact ⟨by omega, by omega⟩

/-- `recordOf?` takes a lookup per reference, at most `f` of them. -/
theorem recordOfSteps_le (env : Env) : ∀ (f : Nat) (t : Ty), recordOfSteps env f t ≤ (f + 1) * (env.defs.length + 1)
  | f + 1, .ref n => by
    unfold recordOfSteps
    rw [Nat.succ_mul (f + 1)]
    split
    · next t _ => have := recordOfSteps_le env f t; omega
    · omega
  | 0, t => by
    cases t <;> simp [recordOfSteps]
  | _ + 1, .string | _ + 1, .bytes | _ + 1, .int _ | _ + 1, .float _ | _ + 1, .decimal | _ + 1, .any
  | _ + 1, .time _ | _ + 1, .secret _ | _ + 1, .array _ | _ + 1, .map _ | _ + 1, .record _ _
  | _ + 1, .variant _ _ => by
    simp only [recordOfSteps]
    exact Nat.le_trans (Nat.succ_le_succ (Nat.zero_le _)) (Nat.le_mul_of_pos_left _ (Nat.succ_pos _))

/-- The record `recordOf?` finds is no bigger than the largest type. -/
theorem recordOf_size {env : Env} {M : Nat} (hE : EnvBound env M) :
    ∀ (f : Nat) (t : Ty) {cl : Bool} {fields : List Field}, sizeOf t ≤ M →
      recordOf? env f t = some (cl, fields) → sizeOf (Ty.record cl fields) ≤ M
  | _, .record cl' fields', cl, fields, ht, h => by
    simp only [recordOf?, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h; exact ht
  | f + 1, .ref n, cl, fields, _, h => by
    simp only [recordOf?] at h
    split at h
    · next u hu => exact recordOf_size hE f u (lookup_bound hE hu) h
    · cases h
  | 0, .ref _, _, _, _, h => by simp [recordOf?] at h
  | _, .string, _, _, _, h | _, .bytes, _, _, _, h | _, .int _, _, _, _, h | _, .float _, _, _, _, h
  | _, .decimal, _, _, _, h | _, .any, _, _, _, h | _, .time _, _, _, _, h | _, .secret _, _, _, _, h
  | _, .array _, _, _, _, h | _, .map _, _, _, _, h | _, .variant _ _, _, _, _, h => by
    simp [recordOf?] at h

theorem field_size {cl : Bool} {fields : List Field} {f : Field} (hf : f ∈ fields) :
    sizeOf f.ty < sizeOf (Ty.record cl fields) := by
  have := List.sizeOf_lt_of_mem hf
  obtain ⟨k, o, ty⟩ := f
  simp [Field.ty] at *
  omega

theorem fieldOf_mem {fields : List Field} {k : String} {f : Field} (h : fieldOf? fields k = some f) : f ∈ fields :=
  List.mem_of_find?_eq_some h

/-- What a case `caseOf?` finds holds is no bigger than the largest type. -/
theorem caseOf_size {env : Env} {M : Nat} (hE : EnvBound env M) {cl : Bool} {cases : List Case} {tag : String}
    (hc : sizeOf (Ty.variant cl cases) ≤ M) {c : Case} (h : caseOf? env cases tag = some c) :
    (∀ tg cl' fields, c = .record tg cl' fields → sizeOf (Ty.record cl' fields) ≤ M) ∧
    (∀ tg ts, c = .positional tg ts → ts.length ≤ M ∧ ∀ t ∈ ts, sizeOf t ≤ M) := by
  unfold caseOf? at h
  cases hf : cases.find? (·.tag == tag) with
  | none => rw [hf] at h; cases h
  | some c0 =>
    rw [hf] at h
    simp only [Option.map_some, Option.some.injEq] at h
    subst h
    have hmem := List.mem_of_find?_eq_some hf
    have hlt := List.sizeOf_lt_of_mem hmem
    have hcs : sizeOf cases < M := by simp at hc; omega
    cases c0 with
    | bare _ => simp [Case.resolve]
    | record tg cl' fields =>
      simp only [Case.resolve]
      refine ⟨fun _ _ _ he => ?_, fun _ _ he => by cases he⟩
      cases he; simp at hlt ⊢; omega
    | positional tg ts =>
      simp only [Case.resolve]
      refine ⟨fun _ _ _ he => (by cases he), fun _ _ he => ?_⟩
      cases he
      have hl := length_le_sizeOf ts
      refine ⟨by simp at hlt; omega, fun t ht => ?_⟩
      have := List.sizeOf_lt_of_mem ht
      simp at hlt; omega
    | named tg u =>
      have hu : sizeOf u ≤ M := by simp at hlt; omega
      simp only [Case.resolve]
      split
      · next cl' fields hr =>
        exact ⟨fun _ _ _ he => by cases he; exact recordOf_size hE _ u hu hr, fun _ _ he => by cases he⟩
      · refine ⟨fun _ _ _ he => (by cases he), fun _ _ he => ?_⟩
        cases he
        have := one_le_sizeOf_ty u
        refine ⟨by simp; omega, fun t ht => ?_⟩
        simp at ht; subst ht; exact hu

/-! ## The bound -/

/-- At most the steps of following names: `whnfSteps_le` with `env.fuel`. -/
def whnfBound (env : Env) (M : Nat) : Nat := (env.fuel + 1) * (M + env.defs.length + 1)

/--
**The constant**: from the number of definitions, the size `M` of the largest
type, and the leaves' constant `k`, nothing of the input.
-/
def costK (env : Env) (M k : Nat) : Nat := 3 * whnfBound env M + 2 * M + k + 8

theorem mul_ge {b x : Nat} (hx : 1 ≤ x) : b ≤ b * x := Nat.le_mul_of_pos_right b hx

theorem split_mul {a b K : Nat} (x : Nat) (h : a + b ≤ K) : a * x + b * x ≤ K * x := by
  rw [← Nat.add_mul]; exact Nat.mul_le_mul_right x h

theorem one_le_inputSize (v : Value) : 1 ≤ inputSize v := by
  cases v <;> simp [inputSize] <;> omega

theorem mem_sizeItems {x : Value} : ∀ {xs : List Value}, x ∈ xs → inputSize x + 1 ≤ sizeItems xs
  | [], h => by simp at h
  | y :: ys, h => by
    simp only [sizeItems]
    rcases List.mem_cons.1 h with rfl | h
    · omega
    · have := mem_sizeItems h; omega

theorem mem_sizeFields {k : String} {x : Value} : ∀ {fs : List (String × Value)}, (k, x) ∈ fs →
    inputSize x + 1 ≤ sizeFields fs
  | [], h => by simp at h
  | (k', y) :: ys, h => by
    simp only [sizeFields]
    rcases List.mem_cons.1 h with h | h
    · cases h; omega
    · have := mem_sizeFields h; omega

theorem keysSteps_le : ∀ fs : List (String × Value), keysSteps fs ≤ sizeFields fs + 1
  | [] => by simp [keysSteps, sizeFields]
  | (k, x) :: fs => by
    have := keysSteps_le fs
    have := one_le_inputSize x
    simp only [keysSteps, sizeFields]; omega

section
variable {lc : LeafCost} {env : Env} {M K : Nat}

/-- What the induction gives for the parts of a value. -/
def Bounded (lc : LeafCost) (env : Env) (M K : Nat) (x : Value) : Prop :=
  ∀ t : Ty, sizeOf t ≤ M → decodeSteps lc env t x ≤ K * inputSize x

theorem itemsSteps_le {t : Ty} (ht : sizeOf t ≤ M) (hK : 1 ≤ K) :
    ∀ xs : List Value, (∀ x ∈ xs, Bounded lc env M K x) → itemsSteps lc env t xs ≤ K * sizeItems xs + 1
  | [], _ => by simp [itemsSteps, sizeItems]
  | x :: xs, h => by
    have hx := h x (List.mem_cons_self ..) t ht
    have hs := itemsSteps_le ht hK xs (fun y hy => h y (List.mem_cons_of_mem _ hy))
    have := mul_ge (b := K) (Nat.le_refl 1)
    simp only [itemsSteps, sizeItems, Nat.mul_add, Nat.mul_one]
    omega

theorem entriesSteps_le {t : Ty} (ht : sizeOf t ≤ M) (hK : 1 ≤ K) :
    ∀ fs : List (String × Value), (∀ p ∈ fs, Bounded lc env M K p.2) →
      entriesSteps lc env t fs ≤ K * sizeFields fs + 1
  | [] => by simp [entriesSteps, sizeFields]
  | (k, x) :: fs => fun h => by
    have hx : decodeSteps lc env t x ≤ K * inputSize x := h (k, x) (List.mem_cons_self ..) t ht
    have hs := entriesSteps_le ht hK fs (fun p hp => h p (List.mem_cons_of_mem _ hp))
    simp only [entriesSteps, sizeFields, Nat.mul_add, Nat.mul_one]
    omega

/-- A record: each key compared twice with the type's fields (`missing?`, `fieldOf?`), each value decoded. -/
theorem fieldsSteps_le {fields : List Field} {cl : Bool} (hc : sizeOf (Ty.record cl fields) ≤ M)
    (hK : 2 * M + 1 ≤ K) :
    ∀ fs : List (String × Value), (∀ p ∈ fs, Bounded lc env M K p.2) →
      fields.length * keysSteps fs + fieldsSteps lc env fields fs ≤ K * sizeFields fs + M + 1
  | [] => fun _ => by
    have : fields.length ≤ M := by
      have := length_le_sizeOf fields; simp at hc; omega
    simp [keysSteps, fieldsSteps, sizeFields]; omega
  | (k, x) :: fs => fun h => by
    have hs := fieldsSteps_le hc hK fs (fun p hp => h p (List.mem_cons_of_mem _ hp))
    have hL : fields.length ≤ M := by
      have := length_le_sizeOf fields; simp at hc; omega
    have hx : (match fieldOf? fields k with | some f => decodeSteps lc env f.ty x | none => 0) ≤
        K * inputSize x := by
      split
      · next f hf =>
        exact h (k, x) (List.mem_cons_self ..) f.ty
          (Nat.le_of_lt (Nat.lt_of_lt_of_le (field_size (fieldOf_mem hf)) hc))
      · exact Nat.zero_le _
    have h1 : fields.length * (k.length + 1) ≤ M * (k.length + 1) := Nat.mul_le_mul_right _ hL
    have h3 : (2 * M + 1) * (k.length + 1) = 2 * (M * (k.length + 1)) + (k.length + 1) := by
      rw [Nat.add_mul, Nat.one_mul, Nat.mul_assoc]
    have h4 : (2 * M + 1) * (k.length + 1) ≤ K * (k.length + 1) := Nat.mul_le_mul_right _ hK
    have e1 : fields.length * (k.length + 1 + keysSteps fs) =
        fields.length * (k.length + 1) + fields.length * keysSteps fs := Nat.mul_add ..
    have e2 : K * (k.length + 1 + inputSize x + sizeFields fs) =
        K * (k.length + 1) + K * inputSize x + K * sizeFields fs := by
      rw [Nat.mul_add, Nat.mul_add]
    simp only [keysSteps, fieldsSteps, sizeFields]
    omega

/-- A case's arguments, and counting them. -/
theorem argsSteps_le (hK : 2 ≤ K) :
    ∀ (ts : List Ty) (xs : List Value), (∀ t ∈ ts, sizeOf t ≤ M) → (∀ x ∈ xs, Bounded lc env M K x) →
      argsSteps lc env ts xs + xs.length ≤ K * sizeItems xs + 1
  | t :: ts, x :: xs, hts, h => by
    have hx := h x (List.mem_cons_self ..) t (hts t (List.mem_cons_self ..))
    have hs := argsSteps_le hK ts xs (fun u hu => hts u (List.mem_cons_of_mem _ hu))
      (fun y hy => h y (List.mem_cons_of_mem _ hy))
    simp only [argsSteps, sizeItems, List.length_cons, Nat.mul_add, Nat.mul_one]
    omega
  | [], xs, _, _ => by
    have := length_le_sizeItems xs
    have : sizeItems xs ≤ K * sizeItems xs := Nat.le_mul_of_pos_left _ (by omega)
    simp only [argsSteps]; omega
  | _ :: _, [], _, _ => by simp [argsSteps]

end

theorem recordBound_le (env : Env) (M : Nat) : (env.fuel + 1) * (env.defs.length + 1) ≤ whnfBound env M :=
  Nat.mul_le_mul_left _ (by omega)

theorem one_le_whnfBound (env : Env) (M : Nat) : 1 ≤ whnfBound env M :=
  Nat.mul_pos (Nat.succ_pos _) (Nat.succ_pos _)

/-- `caseOf?`: the tag against at most `M` cases, and following names for a `Tag T`. -/
theorem caseSteps_le {env : Env} {M : Nat} {cases : List Case} (hl : cases.length ≤ M) (tag : String) :
    caseSteps env cases tag ≤ M * (tag.length + 1) + whnfBound env M := by
  have h1 : cases.length * (tag.length + 1) ≤ M * (tag.length + 1) := Nat.mul_le_mul_right _ hl
  have h2 := recordBound_le env M
  have h3 := one_le_whnfBound env M
  unfold caseSteps
  split
  · next t _ => have := recordOfSteps_le env env.fuel t; omega
  · omega

/-- The steps around a part: following names, its secrets, and `y` more, at most `c` per unit of size. -/
theorem finish {K W x ws s y c : Nat} (hws : ws ≤ W) (hs : s ≤ ws) (hx : 1 ≤ x)
    (hK : 2 * W + 1 + c ≤ K) (hy : y ≤ c * x) : ws + (s + 1 + y) ≤ K * x := by
  have h1 := split_mul x hK
  have h2 : 2 * W + 1 ≤ (2 * W + 1) * x := mul_ge hx
  omega

/--
**Every part of the input bounded**: decoding a value of size at most `n`
with a type of size at most `M` takes at most `costK env M k · size` steps.
-/
theorem decodeSteps_le {lc : LeafCost} {k : Nat} (hlc : lc.Linear k) {env : Env} {M : Nat}
    (hE : EnvBound env M) : ∀ (n : Nat) (v : Value), inputSize v ≤ n → Bounded lc env M (costK env M k) v
  | 0, v, hv => absurd (one_le_inputSize v) (by omega)
  | n + 1, v, hv => by
    intro t ht
    have ih : ∀ x, inputSize x < inputSize v → Bounded lc env M (costK env M k) x :=
      fun x hx => decodeSteps_le hlc hE n x (by omega)
    have hws : whnfSteps env env.fuel t ≤ whnfBound env M := whnfSteps_le hE env.fuel t ht
    have hW : costK env M k = 3 * whnfBound env M + 2 * M + k + 8 := rfl
    have hW1 := one_le_whnfBound env M
    have hv1 := one_le_inputSize v
    generalize hWdef : whnfBound env M = W at hws hW hW1
    generalize costK env M k = K at ih hW ⊢
    unfold decodeSteps
    cases hw : whnf env env.fuel t with
    | error e =>
      simp only
      have : K ≤ K * inputSize v := mul_ge hv1
      omega
    | ok r =>
      obtain ⟨s, c⟩ := r
      obtain ⟨hc, hs⟩ := whnf_size hE env.fuel t ht hw
      simp only
      have hKW : 3 * W + 2 * M + k + 8 ≤ K := by omega
      split
      -- .int, .num
      · next a =>
        exact finish hws hs hv1 (c := 1) (by omega) (by simp [inputSize])
      -- .float, .num
      · next fk a =>
        refine finish hws hs hv1 (c := k + 1) (by omega) ?_
        have := hlc.1 fk a
        simp only [inputSize, Nat.add_mul, Nat.one_mul]
        omega
      -- .float, a tag
      · next tag =>
        exact finish hws hs hv1 (c := 1) (by omega) (by simp [inputSize, sizeItems])
      -- .time
      · next tk tag x =>
        refine finish hws hs hv1 (c := k + 1) (by omega) ?_
        have h1 := hlc.2 tk x
        have h2 : k * (x.length + 1) ≤ k * (tag.length + (x.length + 1 + 1 + 0) + 1) :=
          Nat.mul_le_mul_left _ (by omega)
        simp only [inputSize, sizeItems, Nat.add_mul, Nat.one_mul] at h2 ⊢
        omega
      -- .array
      · next it xs =>
        have hit : sizeOf it ≤ M := by
          have : sizeOf (Ty.array it) ≤ M := hc
          simp at this; omega
        have hi := itemsSteps_le (lc := lc) (env := env) (M := M) (K := K) hit (by omega) xs
          (fun x hx => ih x (by have := mem_sizeItems hx; simp [inputSize]; omega))
        simp only [inputSize, Nat.mul_add, Nat.mul_one]
        omega
      -- .map
      · next it fs =>
        have hit : sizeOf it ≤ M := by
          have : sizeOf (Ty.map it) ≤ M := hc
          simp at this; omega
        have hi := entriesSteps_le (lc := lc) (env := env) (M := M) (K := K) hit (by omega) fs
          (fun p hp => ih p.2 (by have := mem_sizeFields (k := p.1) (x := p.2) hp; simp [inputSize]; omega))
        simp only [inputSize, Nat.mul_add, Nat.mul_one]
        omega
      -- .record
      · next cl fields fs =>
        have hi := fieldsSteps_le (lc := lc) (env := env) (M := M) (K := K) hc (by omega) fs
          (fun p hp => ih p.2 (by have := mem_sizeFields (k := p.1) (x := p.2) hp; simp [inputSize]; omega))
        simp only [inputSize, Nat.mul_add, Nat.mul_one]
        omega
      -- .variant
      · next cl cases tag args =>
        have hl : cases.length ≤ M := by
          have := length_le_sizeOf cases; simp at hc; omega
        have hcs := caseSteps_le (env := env) hl tag
        rw [hWdef] at hcs
        have hm : M * tag.length ≤ K * tag.length := Nat.mul_le_mul_right _ (by omega)
        have hsz := hc
        split
        · next tg cl' fields fs hcase =>
          have hr := (caseOf_size hE hsz hcase).1 _ _ _ rfl
          have hrec := ih (.record fs) (by simp [inputSize, sizeItems]; omega) _ hr
          simp only [inputSize, sizeItems, Nat.mul_add, Nat.mul_one] at hrec hcs ⊢
          omega
        · next _ _ ts hcase =>
          rename_i args _ _ _
          obtain ⟨htl, hts⟩ := (caseOf_size hE hsz hcase).2 _ _ rfl
          have ha := argsSteps_le (lc := lc) (env := env) (M := M) (K := K) (by omega) ts args hts
            (fun x hx => ih x (by have := mem_sizeItems hx; simp [inputSize]; omega))
          have hy : ts.length + args.length + argsSteps lc env ts args ≤ M + K * sizeItems args + 1 := by omega
          refine Nat.le_trans (Nat.add_le_add_left (Nat.add_le_add_left (Nat.add_le_add_left hy _) _) _) ?_
          simp only [inputSize, Nat.mul_add, Nat.mul_one] at hcs ⊢
          omega
        · simp only [inputSize, Nat.mul_add, Nat.mul_one] at hcs ⊢
          omega
      -- anything else
      · exact finish hws hs hv1 (c := 1) (by omega) (by simp; omega)


/-- The size of the largest type: those of the environment and `t`. -/
noncomputable def maxTySize (env : Env) (t : Ty) : Nat := (env.defs.map fun p => sizeOf p.2).foldr max (sizeOf t)

theorem le_foldr_max' {b x : Nat} : ∀ {l : List Nat}, x ∈ l → x ≤ l.foldr max b
  | [], h => by simp at h
  | y :: l, h => by
    simp only [List.foldr_cons]
    rcases List.mem_cons.1 h with rfl | h
    · exact Nat.le_max_left _ _
    · exact Nat.le_trans (le_foldr_max' h) (Nat.le_max_right _ _)

theorem base_le_foldr_max {b : Nat} : ∀ l : List Nat, b ≤ l.foldr max b
  | [] => Nat.le_refl _
  | _ :: l => Nat.le_trans (base_le_foldr_max l) (Nat.le_max_right _ _)

theorem envBound_max (env : Env) (t : Ty) : EnvBound env (maxTySize env t) :=
  fun _ hp => le_foldr_max' (List.mem_map_of_mem (f := fun p : String × Ty => sizeOf p.2) hp)

/--
**I7, decoding is linear in the input** (§9.8, §15): decoding a value with a
type takes at most `K · size` steps, `K = costK env (maxTySize env t) k` a
number of the schema alone, for any leaf costs linear in their literals.
-/
theorem decode_linear {lc : LeafCost} {k : Nat} (hlc : lc.Linear k) (env : Env) (t : Ty) (v : Value) :
    decodeSteps lc env t v ≤ costK env (maxTySize env t) k * inputSize v :=
  decodeSteps_le hlc (envBound_max env t) _ v (Nat.le_refl _) t (base_le_foldr_max _)

/-- **And a stream** (§6): its items, each with the type, at most `K` steps per unit of their size, and one. -/
theorem decodeStream_linear {lc : LeafCost} {k : Nat} (hlc : lc.Linear k) (env : Env) (t : Ty)
    (items : List Value) :
    itemsSteps lc env t items ≤ costK env (maxTySize env t) k * sizeItems items + 1 :=
  itemsSteps_le (base_le_foldr_max _) (by unfold costK; omega) items
    (fun x _ => decodeSteps_le hlc (envBound_max env t) _ x (Nat.le_refl _))

end Haus.Linear
