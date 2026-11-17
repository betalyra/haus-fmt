import Haus.Json.RecordCases

/-!
# Following names: the fuel is enough

`whnf`, `recordOf?`, `lastRef` and `reachesBool` follow a chain of names
with fuel `env.fuel`, one more than the number of definitions. The chain
never needs more: a chain that ends visits each name at most once
(`whnfNames_nodup`), so it ends within `env.fuel` steps (`whnf_enough`). So
with more fuel they give the same results (`whnf_fuel_iff`, `recordOf?_fuel`,
`lastRef_fuel`, `reachesBool_fuel`), which lets two environments with
different numbers of definitions be compared at one fuel
(`Haus.Json.Evolution`).
-/

namespace Haus.Schema
open Haus

variable {env : Env}

/-- The names `whnf` looks up on its way, in order. -/
def whnfNames (env : Env) : Nat → Ty → List String
  | 0, _ => []
  | f + 1, t =>
    match peel t with
    | (_, .ref n) =>
      match env.lookup n with
      | some t' => n :: whnfNames env f t'
      | none => [n]
    | _ => []

theorem whnf_zero (t : Ty) : whnf env 0 t =
    match peel t with
    | (_, .ref n) => .error s!"type {n} refers to itself without a record, array or variant in between"
    | r => .ok r := by
  rw [whnf]; generalize peel t = p; rcases p with ⟨s, c⟩; cases c <;> rfl

theorem whnf_succ_eq (f : Nat) (t : Ty) : whnf env (f + 1) t =
    match peel t with
    | (s, .ref n) =>
      match env.lookup n with
      | some t => (whnf env f t).map fun (s', c) => (s + s', c)
      | none => .error s!"unknown type {n}"
    | r => .ok r := by
  rw [whnf]; generalize peel t = p; rcases p with ⟨s, c⟩; cases c <;> rfl

/-- What `whnf` does with a type: it is not a name under its secrets, or it is the name `n` under `s` secrets. -/
theorem peel_cases (t : Ty) : (∀ s n, peel t ≠ (s, .ref n)) ∨ ∃ s n, peel t = (s, .ref n) := by
  rcases h : peel t with ⟨s, c⟩
  cases c
  case ref n => exact .inr ⟨s, n, rfl⟩
  all_goals exact .inl (fun _ _ e => by cases e)

theorem whnf_notRef {t : Ty} (h : ∀ s n, peel t ≠ (s, .ref n)) (f : Nat) : whnf env f t = .ok (peel t) := by
  cases f with
  | zero =>
    rw [whnf_zero]
    split
    · rename_i s n e; exact absurd e (h s n)
    · rfl
  | succ f =>
    rw [whnf_succ_eq]
    split
    · rename_i s n e; exact absurd e (h s n)
    · rfl

theorem whnfNames_notRef {t : Ty} (h : ∀ s n, peel t ≠ (s, .ref n)) (f : Nat) : whnfNames env f t = [] := by
  cases f with
  | zero => rfl
  | succ f =>
    unfold whnfNames
    split
    · rename_i s n e; exact absurd e (h s n)
    · rfl

theorem whnf_ref_zero {t : Ty} {s : Nat} {n : String} (h : peel t = (s, .ref n)) {r : Nat × Ty} :
    whnf env 0 t ≠ .ok r := by
  rw [whnf_zero]; simp [h]

theorem whnf_ref {t : Ty} {s : Nat} {n : String} (h : peel t = (s, .ref n)) (f : Nat) :
    whnf env (f + 1) t = match env.lookup n with
      | some t => (whnf env f t).map fun (s', c) => (s + s', c)
      | none => .error s!"unknown type {n}" := by
  rw [whnf_succ_eq]; simp [h]

theorem whnfNames_ref {t : Ty} {s : Nat} {n : String} (h : peel t = (s, .ref n)) (f : Nat) :
    whnfNames env (f + 1) t = match env.lookup n with
      | some t' => n :: whnfNames env f t'
      | none => [n] := by
  simp only [whnfNames, h]

/-- A successful step through the name `n`: its definition, and the rest of the way from there. -/
theorem whnf_ref_ok {t : Ty} {s : Nat} {n : String} (h : peel t = (s, .ref n)) {f : Nat} {r : Nat × Ty}
    (hw : whnf env (f + 1) t = .ok r) :
    ∃ d r', env.lookup n = some d ∧ whnf env f d = .ok r' ∧ r = (s + r'.1, r'.2) := by
  rw [whnf_ref h] at hw
  cases hl : env.lookup n with
  | none => simp [hl] at hw
  | some d =>
    simp only [hl] at hw
    cases hr : whnf env f d with
    | error e => simp [hr, Except.map] at hw
    | ok r' => simp only [hr, Except.map, Except.ok.injEq] at hw; exact ⟨d, r', rfl, hr, hw.symm⟩

/-! ## More fuel, the same result -/

/-- With one more step of fuel, `whnf` gives the same result and looks up the same names. -/
theorem whnf_succ : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r →
    whnf env (f + 1) t = .ok r ∧ whnfNames env (f + 1) t = whnfNames env f t
  | f, t, r, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnf_notRef hn] at h ⊢
      exact ⟨h, by rw [whnfNames_notRef hn, whnfNames_notRef hn]⟩
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        obtain ⟨ih1, ih2⟩ := whnf_succ hw
        rw [whnf_ref hp, whnfNames_ref hp, whnfNames_ref hp]
        simp [hl, ih1, ih2, Except.map]

theorem whnf_le {f g : Nat} {t : Ty} {r : Nat × Ty} (h : whnf env f t = .ok r) (hle : f ≤ g) :
    whnf env g t = .ok r ∧ whnfNames env g t = whnfNames env f t := by
  induction g with
  | zero => cases Nat.le_zero.mp hle; exact ⟨h, rfl⟩
  | succ g ih =>
    rcases Nat.lt_or_eq_of_le hle with hlt | rfl
    · obtain ⟨h1, h2⟩ := ih (by omega)
      obtain ⟨h3, h4⟩ := whnf_succ h1
      exact ⟨h3, h4.trans h2⟩
    · exact ⟨h, rfl⟩

/-! ## The names on the way -/

/-- The fuel needed is the number of names looked up. -/
theorem whnf_names_length : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r →
    whnf env (whnfNames env f t).length t = .ok r
  | f, t, r, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnfNames_notRef hn, whnf_notRef hn]; rw [whnf_notRef hn] at h; exact h
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp]
        simp only [hl, List.length_cons]
        rw [whnf_ref hp]
        simp [hl, whnf_names_length hw, Except.map]

/-- Every name looked up on a successful way is defined. -/
theorem whnfNames_defined : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r →
    ∀ n ∈ whnfNames env f t, n ∈ env.defs.map (·.1)
  | f, t, r, h, m, hm => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnfNames_notRef hn] at hm; cases hm
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp] at hm
        simp only [hl, List.mem_cons] at hm
        rcases hm with rfl | hm
        · obtain ⟨p, hp, hk⟩ := List.lookup_isSome_iff.mp (by
            have e : env.defs.lookup m = some d := hl
            rw [e]; rfl)
          simp only [beq_iff_eq] at hk
          exact List.mem_map.mpr ⟨p, hp, hk.symm⟩
        · exact whnfNames_defined hw m hm

/-- If the way from `u` passes through `n`, the way from `n`'s definition succeeds with less fuel. -/
theorem whnf_through : ∀ {f : Nat} {u : Ty} {r : Nat × Ty} {n : String} {d : Ty}, whnf env f u = .ok r →
    n ∈ whnfNames env f u → env.lookup n = some d → ∃ g < f, ∃ r', whnf env g d = .ok r'
  | f, u, r, n, d, h, hm, hd => by
    rcases peel_cases u with hn | ⟨s, m, hp⟩
    · rw [whnfNames_notRef hn] at hm; cases hm
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d', r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp] at hm
        simp only [hl, List.mem_cons] at hm
        rcases hm with rfl | hm
        · rw [hl] at hd; cases hd
          exact ⟨f, by omega, r', hw⟩
        · obtain ⟨g, hg, r'', h''⟩ := whnf_through hw hm hd
          exact ⟨g, by omega, r'', h''⟩

/-- No successful way passes through the name of the definition it starts from. -/
theorem whnf_no_loop {n : String} {d : Ty} (hd : env.lookup n = some d) :
    ∀ f, ∀ r, whnf env f d = .ok r → n ∉ whnfNames env f d := by
  intro f
  induction f using Nat.strongRecOn with
  | ind f ih =>
    intro r h hm
    obtain ⟨g, hg, r', h'⟩ := whnf_through h hm hd
    obtain ⟨-, h2⟩ := whnf_le h' (Nat.le_of_lt hg)
    exact ih g hg r' h' (h2 ▸ hm)

/-- **A successful way visits each name once.** -/
theorem whnfNames_nodup : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r → (whnfNames env f t).Nodup
  | f, t, r, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnfNames_notRef hn]; exact List.nodup_nil
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp]
        simp only [hl]
        exact List.nodup_cons.mpr ⟨whnf_no_loop hl f r' hw, whnfNames_nodup hw⟩

/-- **The fuel is enough**: a way that succeeds with any fuel succeeds with `env.fuel`. -/
theorem whnf_enough {f : Nat} {t : Ty} {r : Nat × Ty} (h : whnf env f t = .ok r) :
    whnf env env.fuel t = .ok r ∧ whnfNames env env.fuel t = whnfNames env f t := by
  have hlen : (whnfNames env f t).length < env.fuel := by
    have := (whnfNames_nodup h).length_le_of_subset (whnfNames_defined h)
    simp only [List.length_map] at this
    unfold Env.fuel; omega
  have h1 := whnf_names_length h
  obtain ⟨h2, h3⟩ := whnf_le h1 (Nat.le_of_lt hlen)
  refine ⟨h2, h3.trans ?_⟩
  rcases Nat.le_total f (whnfNames env f t).length with hle | hle
  · exact (whnf_le h hle).2
  · exact (whnf_le h1 hle).2.symm

/-- With fuel `env.fuel` or more, `whnf` succeeds with the same result, and looks up the same names. -/
theorem whnf_fuel {f : Nat} (hf : env.fuel ≤ f) (t : Ty) (r : Nat × Ty) :
    whnf env f t = .ok r ↔ whnf env env.fuel t = .ok r := by
  constructor
  · intro h; exact (whnf_enough h).1
  · intro h; exact (whnf_le h hf).1

theorem whnfNames_fuel {f : Nat} (hf : env.fuel ≤ f) {t : Ty} {r : Nat × Ty} (h : whnf env env.fuel t = .ok r) :
    whnfNames env f t = whnfNames env env.fuel t := (whnf_le h hf).2

/-- `whnf` errs with fuel `f ≥ env.fuel` exactly when it errs with `env.fuel`. -/
theorem whnf_fuel_error {f : Nat} (hf : env.fuel ≤ f) (t : Ty) :
    (∃ e, whnf env f t = .error e) ↔ ∃ e, whnf env env.fuel t = .error e := by
  constructor
  · rintro ⟨e, he⟩
    cases h : whnf env env.fuel t with
    | error e' => exact ⟨e', rfl⟩
    | ok r => rw [(whnf_fuel hf t r).mpr h] at he; cases he
  · rintro ⟨e, he⟩
    cases h : whnf env f t with
    | error e' => exact ⟨e', rfl⟩
    | ok r => rw [(whnf_fuel hf t r).mp h] at he; cases he

/-! ## The others follow the same names -/

/-- `lastRef` is the last name `whnf` looks up. -/
theorem lastRef_names : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r →
    lastRef env f t = (whnfNames env f t).getLast?
  | f, t, r, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnfNames_notRef hn]
      cases f with
      | zero => rfl
      | succ f =>
        unfold lastRef
        split
        · rename_i s n e; exact absurd e (hn s n)
        · rfl
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp]
        simp only [lastRef, hp, hl, lastRef_names hw, List.getLast?_cons]

/-- `reachesBool` asks whether `whnf` looks up the name `Bool`. -/
theorem reachesBool_names : ∀ {f : Nat} {t : Ty} {r : Nat × Ty}, whnf env f t = .ok r →
    (reachesBool env f t = true ↔ "Bool" ∈ whnfNames env f t)
  | f, t, r, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnfNames_notRef hn]
      cases f with
      | zero =>
        unfold reachesBool
        split
        · rename_i s n e; exact absurd e (hn s n)
        · simp
      | succ f =>
        unfold reachesBool
        split
        · rename_i s n e; exact absurd e (hn s n)
        · simp
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, rfl⟩ := whnf_ref_ok hp h
        rw [whnfNames_ref hp]
        simp only [reachesBool, hp, hl, Bool.or_eq_true, beq_iff_eq, List.mem_cons, reachesBool_names hw]
        constructor
        · rintro (e | e)
          · exact .inl e.symm
          · exact .inr e
        · rintro (e | e)
          · exact .inl e.symm
          · exact .inr e

theorem lastRef_fuel {f : Nat} (hf : env.fuel ≤ f) {t : Ty} {r : Nat × Ty} (h : whnf env env.fuel t = .ok r) :
    lastRef env f t = lastRef env env.fuel t := by
  rw [lastRef_names ((whnf_fuel hf t r).mpr h), lastRef_names h, whnfNames_fuel hf h]

theorem reachesBool_fuel {f : Nat} (hf : env.fuel ≤ f) {t : Ty} {r : Nat × Ty} (h : whnf env env.fuel t = .ok r) :
    reachesBool env f t = reachesBool env env.fuel t := by
  have h1 := reachesBool_names ((whnf_fuel hf t r).mpr h)
  have h2 := reachesBool_names h
  rw [whnfNames_fuel hf h] at h1
  cases e1 : reachesBool env f t <;> cases e2 : reachesBool env env.fuel t <;> simp_all

/-- A record through names, without secrets on the way, is what `whnf` reaches with no secrets. -/
theorem recordOf?_whnf : ∀ {f : Nat} {t : Ty} {cl : Bool} {fields : List Field},
    recordOf? env f t = some (cl, fields) → whnf env f t = .ok (0, .record cl fields)
  | f, .record cl' fields', cl, fields, h => by
    cases f <;> simp only [recordOf?, Option.some.injEq, Prod.mk.injEq] at h <;> obtain ⟨rfl, rfl⟩ := h <;>
      exact whnf_notRef (by simp [peel]) _
  | f + 1, .ref n, cl, fields, h => by
    simp only [recordOf?] at h
    cases hl : env.lookup n with
    | none => simp [hl] at h
    | some d =>
      simp only [hl] at h
      rw [whnf_ref (show peel (.ref n) = (0, .ref n) from rfl), hl]
      simp [recordOf?_whnf h, Except.map]
  | 0, .ref _, _, _, h => by simp [recordOf?] at h
  | f, .string, _, _, h | f, .bytes, _, _, h | f, .int _, _, _, h | f, .float _, _, _, h
  | f, .decimal, _, _, h | f, .any, _, _, h | f, .time _, _, _, h | f, .secret _, _, _, h | f, .array _, _, _, h
  | f, .map _, _, _, h | f, .variant _ _, _, _, h => by cases f <;> simp [recordOf?] at h

theorem peel_zero {t c : Ty} (h : peel t = (0, c)) : t = c := by
  cases t <;> simp [peel] at h <;> first | exact h | omega

theorem whnf_recordOf? : ∀ {f : Nat} {t : Ty} {cl : Bool} {fields : List Field},
    whnf env f t = .ok (0, .record cl fields) → recordOf? env f t = some (cl, fields)
  | f, t, cl, fields, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnf_notRef hn] at h
      cases peel_zero (Except.ok.inj h)
      cases f <;> rfl
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hl, hw, hr⟩ := whnf_ref_ok hp h
        simp only [Prod.mk.injEq] at hr
        obtain ⟨hs, hc⟩ := hr
        have hs0 : s = 0 := by omega
        have hr0 : r'.1 = 0 := by omega
        subst hs0
        cases peel_zero hp
        simp only [recordOf?, hl]
        have e : r' = (0, .record cl fields) := Prod.ext hr0 hc.symm
        subst e
        exact whnf_recordOf? hw

/-- With fuel `env.fuel` or more, `recordOf?` finds the same record. -/
theorem recordOf?_fuel {f : Nat} (hf : env.fuel ≤ f) (t : Ty) : recordOf? env f t = recordOf? env env.fuel t := by
  cases h : recordOf? env env.fuel t with
  | some r => exact recordOf?_mono hf h
  | none =>
    cases h' : recordOf? env f t with
    | none => rfl
    | some r =>
      obtain ⟨cl, fields⟩ := r
      have := whnf_recordOf? (whnf_enough (recordOf?_whnf h')).1
      rw [h] at this; cases this

end Haus.Schema
