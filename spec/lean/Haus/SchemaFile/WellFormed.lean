import Haus.SchemaFile.Cycles
import Haus.SchemaFile.Decoding

/-!
# What the checker accepts is well formed

`Source.WellFormed` (in `Cycles.lean`) is what the converse of §9.10 needs:
every definition is the one its name finds, no parameter is declared twice,
a body uses only its own parameters. `declare` and `checkParams` check
exactly these, so it is a consequence, not an assumption:

* `wellFormed_of_declare`: a file `declare` accepts, whose definitions pass
  `checkParams`, is well formed;
* `check_wellFormed`, `load_wellFormed`: so is every file `check` accepts
  (with or without §9.10's rule) and the one behind every schema `load`
  returns;
* `declare_checkGrowth_iff_finite`: hence, unconditionally, for every file
  `declare` and `checkParams` accept, §9.10's check passes exactly when
  every type reaches finitely many instances.
-/

namespace Haus.SchemaFile
open Haus Haus.Schema

/-! ## Lists -/

theorem firstDup_none : ∀ {l : List String}, firstDup l = none → l.Nodup
  | [], _ => List.nodup_nil
  | x :: xs, h => by
    unfold firstDup at h
    split at h
    · cases h
    · next hx =>
      refine List.nodup_cons.2 ⟨?_, firstDup_none h⟩
      intro hm
      exact hx (List.contains_iff_mem.2 hm)

/-- In a list whose names are distinct, finding a definition's name finds it. -/
theorem find_name {d : Def} : ∀ {l : List Def}, (l.map (·.name)).Nodup → d ∈ l →
    l.find? (·.name == d.name) = some d
  | [], _, h => by simp at h
  | a :: l, hn, h => by
    rw [List.map_cons, List.nodup_cons] at hn
    rw [List.find?_cons]
    by_cases ha : a.name = d.name
    · have : a = d := by
        rcases List.mem_cons.1 h with rfl | h
        · rfl
        · exact absurd (ha ▸ List.mem_map_of_mem (f := (·.name)) h) hn.1
      simp [this]
    · have hd : d ∈ l := by
        rcases List.mem_cons.1 h with rfl | h
        · exact absurd rfl ha
        · exact h
      have hb : (a.name == d.name) = false := by simpa using ha
      simp [hb, find_name hn.2 hd]

theorem forM_ok {α : Type} {f : α → C Unit} : ∀ {l : List α}, l.forM f = .ok () → ∀ a ∈ l, f a = .ok ()
  | [], _, a, h => by simp at h
  | x :: xs, h, a, ha => by
    unfold List.forM at h
    cases hx : f x with
    | error e => rw [hx] at h; cases h
    | ok u =>
      rw [hx] at h
      have h' : xs.forM f = .ok () := h
      rcases List.mem_cons.1 ha with rfl | ha
      · cases u; exact hx
      · exact forM_ok h' a ha

/-! ## What `declare` and `checkParams` ensure -/

theorem declareDefs_ok {std : List String} : ∀ {seen : List String} {ds : List Def},
    declareDefs std seen ds = .ok () →
      (∀ d ∈ ds, d.name ∉ seen) ∧ (ds.map (·.name)).Nodup ∧ ∀ d ∈ ds, d.params.Nodup
  | _, [], _ => by simp
  | seen, d :: ds, h => by
    unfold declareDefs at h
    split at h
    · simp [err] at h
    · next h1 =>
      split at h
      · simp [err] at h
      · split at h
        · simp [err] at h
        · split at h
          · simp [err] at h
          · next hp =>
            obtain ⟨hs, hn, hpar⟩ := declareDefs_ok h
            have hd : d.name ∉ seen := fun hm => h1 (List.contains_iff_mem.2 hm)
            refine ⟨?_, ?_, ?_⟩
            · intro e he
              rcases List.mem_cons.1 he with rfl | he
              · exact hd
              · exact fun hm => hs e he (List.mem_append_left _ hm)
            · rw [List.map_cons, List.nodup_cons]
              refine ⟨?_, hn⟩
              intro hm
              obtain ⟨e, he, heq⟩ := List.mem_map.1 hm
              exact hs e he (heq ▸ List.mem_append_right _ (List.mem_singleton_self _))
            · intro e he
              rcases List.mem_cons.1 he with rfl | he
              · exact firstDup_none hp
              · exact hpar e he

theorem declare_ok {p : Parsed} {F : Source} (h : declare p = .ok F) :
    F.defs = p.defs ∧ declareDefs F.std [] p.defs = .ok () := by
  simp only [declare, bind, Except.bind] at h
  split at h
  · cases h
  · next std _ =>
    split at h
    · cases h
    · next u hd =>
      simp only [pure, Except.pure, Except.ok.injEq] at h
      subst h
      cases u
      exact ⟨rfl, hd⟩

theorem checkParams_ok {d : Def} (h : checkParams d = .ok ()) : ∀ v ∈ d.body.vars, v ∈ d.params := by
  unfold checkParams at h
  split at h
  · simp [err] at h
  · next hf =>
    intro v hv
    have := List.find?_eq_none.1 hf v hv
    simpa using this

/--
**What `declare` and `checkParams` accept is well formed**: names found,
parameters distinct, bodies using only their own parameters.
-/
theorem wellFormed_of_declare {p : Parsed} {F : Source} (hd : declare p = .ok F)
    (hp : F.defs.forM checkParams = .ok ()) : F.WellFormed := by
  obtain ⟨hdefs, hdd⟩ := declare_ok hd
  obtain ⟨_, hn, hpar⟩ := declareDefs_ok hdd
  rw [← hdefs] at hn hpar
  exact {
    lookup := fun d hd => find_name hn hd
    params := hpar
    vars := fun d hd => checkParams_ok (forM_ok hp d hd) }

/-- `check` runs `checkParams` on every definition first. -/
theorem check_params {F : Source} {growth : Bool} (h : check F growth = .ok ()) :
    F.defs.forM checkParams = .ok () := by
  simp only [check, bind, Except.bind] at h
  split at h
  · cases h
  · next u hp => cases u; exact hp

/-- Every file `check` accepts, §9.10's rule or not, is well formed. -/
theorem check_wellFormed {p : Parsed} {F : Source} {growth : Bool} (hd : declare p = .ok F)
    (hc : check F growth = .ok ()) : F.WellFormed :=
  wellFormed_of_declare hd (check_params hc)

/-- And the file behind every schema `load` returns. -/
theorem load_wellFormed {text : Text} {env : Env} (h : load text = .ok env) :
    ∃ p F, parse text = .ok p ∧ declare p = .ok F ∧ check F = .ok () ∧ F.WellFormed := by
  obtain ⟨p, F, _, hp, hd, hc, _⟩ := load_spec h
  exact ⟨p, F, hp, hd, hc, check_wellFormed hd hc⟩

/--
**§9.10 is exact, unconditionally**: for every file `declare` and
`checkParams` accept, §9.10's check passes exactly when every type reaches
finitely many instances.
-/
theorem declare_checkGrowth_iff_finite {p : Parsed} {F : Source} (hd : declare p = .ok F)
    (hp : F.defs.forM checkParams = .ok ()) :
    checkGrowth F = .ok () ↔ ∀ ts : List Tm, ∃ L : List Inst, ∀ i, Reach F ts i → i ∈ L :=
  checkGrowth_iff_finite (wellFormed_of_declare hd hp)

end Haus.SchemaFile
