import Haus.SchemaFile.Check
import Haus.SchemaFile.Terms

/-!
# Groups of definitions (spec §9.10)

`Source.Reaches F m n`: the definition `m` refers to `n`, directly or through
other definitions (or is `n`). `reaches_complete`: the checker's
`Source.reaches`, a fixed number of rounds of following references, finds
every such `n`, since the names found grow every round until none is added
and there are only so many names. So `checkGrowth_ok`: a file that passes
`checkGrowth` has `GrowthOk`, the property the finiteness of instances needs
(`Haus.SchemaFile.Finite`).
-/

namespace Haus.SchemaFile

/-- `a`'s definition refers to the definition `b`. -/
def Source.Edge (F : Source) (a b : String) : Prop :=
  ∃ d, F.lookup a = some d ∧ ∃ es, (b, es) ∈ F.edges d

/-- `a` refers to `b`, directly or not, or is `b`. -/
inductive Source.Reaches (F : Source) : String → String → Prop
  | refl (a : String) : Source.Reaches F a a
  | step {a b c : String} : F.Edge a b → Source.Reaches F b c → Source.Reaches F a c

theorem Source.Reaches.trans {F : Source} {a b c : String} (h₁ : F.Reaches a b) (h₂ : F.Reaches b c) :
    F.Reaches a c := by
  induction h₁ with
  | refl => exact h₂
  | step e _ ih => exact .step e (ih h₂)

theorem Source.Reaches.single {F : Source} {a b : String} (e : F.Edge a b) : F.Reaches a b :=
  .step e (.refl b)

/--
§9.10, the property: wherever a definition `a` refers to a definition `m`
that refers back to it (directly or not, or is `a`), every argument is a
parameter.
-/
def GrowthOk (F : Source) : Prop :=
  ∀ a d, F.lookup a = some d → ∀ m es, (m, es) ∈ F.edges d → F.Reaches m a → ∀ e ∈ es, Tm.isVar e = true

/-! ## The definitions -/

theorem Source.lookup_mem {F : Source} {n : String} {d : Def} (h : F.lookup n = some d) :
    d ∈ F.defs ∧ d.name = n := by
  unfold Source.lookup at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

/-- The names of the definitions. -/
def Source.names (F : Source) : List String := F.defs.map (·.name)

theorem Source.mem_names {F : Source} {n : String} (h : F.defined n = true) : n ∈ F.names := by
  unfold Source.defined at h
  cases hl : F.lookup n with
  | none => simp [hl] at h
  | some d =>
    obtain ⟨hd, rfl⟩ := Source.lookup_mem hl
    exact List.mem_map_of_mem hd

theorem Source.mem_edges {F : Source} {d : Def} {r : String × List Tm} :
    r ∈ F.edges d ↔ r ∈ d.body.refs ∧ F.defined r.1 = true := by
  simp [Source.edges]

theorem Source.mem_next {F : Source} {a b : String} : b ∈ F.next a ↔ F.Edge a b := by
  unfold Source.next Source.Edge
  cases hl : F.lookup a with
  | none => simp
  | some d => simp

theorem Source.next_names {F : Source} {a b : String} (h : b ∈ F.next a) : b ∈ F.names := by
  obtain ⟨d, _, es, hb⟩ := Source.mem_next.1 h
  exact Source.mem_names (Source.mem_edges.1 hb).2

/-! ## Adding new elements -/

section
variable {α : Type} [BEq α] [LawfulBEq α]

theorem mem_addNew {x : α} : ∀ {xs ys : List α}, x ∈ addNew xs ys ↔ x ∈ xs ∨ x ∈ ys
  | xs, [] => by simp [addNew]
  | xs, y :: ys => by
    unfold addNew
    split
    · next h =>
      rw [mem_addNew]
      have : y ∈ xs := by simpa using h
      constructor
      · rintro (h | h)
        · exact Or.inl h
        · exact Or.inr (List.mem_cons_of_mem _ h)
      · rintro (h | h)
        · exact Or.inl h
        · rcases List.mem_cons.1 h with rfl | h
          · exact Or.inl this
          · exact Or.inr h
    · rw [mem_addNew]; simp [or_assoc]

theorem nodup_addNew : ∀ {xs ys : List α}, xs.Nodup → (addNew xs ys).Nodup
  | xs, [], h => by simpa [addNew] using h
  | xs, y :: ys, h => by
    unfold addNew
    split
    · exact nodup_addNew h
    · next hy =>
      apply nodup_addNew
      rw [List.nodup_append]
      refine ⟨h, by simp, ?_⟩
      intro a ha b hb
      simp at hb
      subst hb
      intro e; subst e
      simp_all

omit [LawfulBEq α] in
theorem addNew_prefix : ∀ (xs ys : List α), ∃ zs, addNew xs ys = xs ++ zs
  | xs, [] => ⟨[], by simp [addNew]⟩
  | xs, y :: ys => by
    unfold addNew
    split
    · exact addNew_prefix xs ys
    · obtain ⟨zs, h⟩ := addNew_prefix (xs ++ [y]) ys
      exact ⟨y :: zs, by simp [h]⟩

/-- When nothing is added, everything was there already. -/
theorem addNew_stable {xs ys : List α} (h : (addNew xs ys).length = xs.length) :
    ∀ y ∈ ys, y ∈ xs := by
  obtain ⟨zs, hz⟩ := addNew_prefix xs ys
  have : zs = [] := by
    rw [hz, List.length_append] at h
    exact List.eq_nil_of_length_eq_zero (by omega)
  subst this
  intro y hy
  have := mem_addNew.2 (Or.inr hy : y ∈ xs ∨ y ∈ ys)
  simpa [hz] using this

end

/-! ## Rounds of following references -/

/-- One round: the names, and those they refer to. -/
def Source.round (F : Source) (S : List String) : List String := addNew S (S.flatMap F.next)

theorem Source.reachIter_succ (F : Source) : ∀ (k : Nat) (S : List String),
    F.reachIter (k + 1) S = F.round (F.reachIter k S)
  | 0, S => rfl
  | k + 1, S => by
    rw [Source.reachIter, Source.reachIter_succ F k]
    rfl

theorem Source.reachIter_add (F : Source) : ∀ (j k : Nat) (S : List String),
    F.reachIter (j + k) S = F.reachIter j (F.reachIter k S)
  | j, 0, S => rfl
  | j, k + 1, S => by
    show F.reachIter ((j + k) + 1) S = _
    rw [Source.reachIter, Source.reachIter_add F j k]
    rfl

theorem Source.mem_round {F : Source} {S : List String} {x : String} :
    x ∈ F.round S ↔ x ∈ S ∨ ∃ y ∈ S, F.Edge y x := by
  simp [Source.round, mem_addNew, Source.mem_next]

theorem Source.sub_round (F : Source) (S : List String) : S ⊆ F.round S :=
  fun _ h => Source.mem_round.2 (Or.inl h)

theorem Source.round_mono {F : Source} {S T : List String} (h : S ⊆ T) : F.round S ⊆ F.round T := by
  intro x hx
  rcases Source.mem_round.1 hx with hx | ⟨y, hy, e⟩
  · exact Source.mem_round.2 (Or.inl (h hx))
  · exact Source.mem_round.2 (Or.inr ⟨y, h hy, e⟩)

theorem Source.reachIter_mono {F : Source} : ∀ (k : Nat) {S T : List String}, S ⊆ T →
    F.reachIter k S ⊆ F.reachIter k T
  | 0, _, _, h => h
  | k + 1, _, _, h => Source.reachIter_mono k (Source.round_mono h)

theorem Source.reachIter_le {F : Source} {S : List String} : ∀ {j k : Nat}, j ≤ k →
    F.reachIter j S ⊆ F.reachIter k S
  | j, k, h => by
    induction k with
    | zero => have : j = 0 := by omega
              subst this; exact List.Subset.refl _
    | succ k ih =>
      rcases Nat.lt_or_ge j (k + 1) with hj | hj
      · rw [Source.reachIter_succ]
        exact List.Subset.trans (ih (by omega)) (Source.sub_round F _)
      · have : j = k + 1 := by omega
        subst this; exact List.Subset.refl _

/-- Once a round adds nothing, no round does. -/
theorem Source.reachIter_closed {F : Source} {S : List String} (h : F.round S ⊆ S) :
    ∀ k, F.reachIter k S ⊆ S
  | 0 => List.Subset.refl _
  | k + 1 => by
    rw [Source.reachIter_succ]
    intro x hx
    rcases Source.mem_round.1 hx with hx | ⟨y, hy, e⟩
    · exact Source.reachIter_closed h k hx
    · exact h (Source.mem_round.2 (Or.inr ⟨y, Source.reachIter_closed h k hy, e⟩))

theorem Source.reachIter_nodup {F : Source} : ∀ (k : Nat) {S : List String}, S.Nodup →
    (F.reachIter k S).Nodup
  | 0, _, h => h
  | k + 1, _, h => Source.reachIter_nodup k (nodup_addNew h)

theorem Source.reachIter_names {F : Source} {m : String} : ∀ (k : Nat),
    F.reachIter k [m] ⊆ m :: F.names
  | 0 => by simp [Source.reachIter]
  | k + 1 => by
    rw [Source.reachIter_succ]
    intro x hx
    rcases Source.mem_round.1 hx with hx | ⟨y, _, e⟩
    · exact Source.reachIter_names k hx
    · exact List.mem_cons_of_mem _ (Source.next_names (Source.mem_next.2 e))

/-- Each round that adds something makes the list longer. -/
theorem Source.reachIter_grows {F : Source} {m : String} : ∀ (i : Nat),
    (∀ j < i, ¬ F.round (F.reachIter j [m]) ⊆ F.reachIter j [m]) → i + 1 ≤ (F.reachIter i [m]).length
  | 0, _ => by simp [Source.reachIter]
  | i + 1, h => by
    have ih := Source.reachIter_grows i (fun j hj => h j (by omega))
    rw [Source.reachIter_succ]
    obtain ⟨zs, hz⟩ := addNew_prefix (F.reachIter i [m]) ((F.reachIter i [m]).flatMap F.next)
    have hne : zs ≠ [] := by
      intro e
      subst e
      apply h i (by omega)
      intro x hx
      simpa [Source.round, hz] using hx
    have : 0 < zs.length := List.length_pos_iff.2 hne
    simp only [Source.round, hz, List.length_append]
    omega

/-- After as many rounds as there are definitions, and one more, nothing is added. -/
theorem Source.reachIter_all (F : Source) (m : String) (k : Nat) :
    F.reachIter k [m] ⊆ F.reachable m := by
  have : ∃ j ≤ F.defs.length, F.round (F.reachIter j [m]) ⊆ F.reachIter j [m] := by
    apply Classical.byContradiction
    intro hno
    have h := Source.reachIter_grows (F := F) (m := m) (F.defs.length + 1) (fun j hj hs =>
      hno ⟨j, by omega, hs⟩)
    have hle := List.Nodup.length_le_of_subset (Source.reachIter_nodup (F.defs.length + 1) (by simp))
      (Source.reachIter_names (F := F) (m := m) (F.defs.length + 1))
    simp [Source.names] at hle
    omega
  obtain ⟨j, hj, hs⟩ := this
  have hT : F.reachIter j [m] ⊆ F.reachable m := Source.reachIter_le (by omega)
  rcases Nat.lt_or_ge k j with hk | hk
  · exact List.Subset.trans (Source.reachIter_le (by omega)) hT
  · have : k = (k - j) + j := by omega
    rw [this, Source.reachIter_add]
    exact List.Subset.trans (Source.reachIter_closed hs _) hT

theorem Source.reaches_rounds {F : Source} {m n : String} (h : F.Reaches m n) :
    ∃ k, n ∈ F.reachIter k [m] := by
  induction h with
  | refl a => exact ⟨0, by simp [Source.reachIter]⟩
  | @step a b c e _ ih =>
    obtain ⟨k, hk⟩ := ih
    refine ⟨k + 1, ?_⟩
    have : [b] ⊆ F.round [a] := by
      intro x hx
      simp at hx; subst hx
      exact Source.mem_round.2 (Or.inr ⟨a, by simp, e⟩)
    exact Source.reachIter_mono k this hk

/-- The checker finds every definition a definition reaches. -/
theorem Source.reaches_complete {F : Source} {m n : String} (h : F.Reaches m n) : F.reaches m n = true := by
  obtain ⟨k, hk⟩ := Source.reaches_rounds h
  simpa [Source.reaches] using Source.reachIter_all F m k hk

/-- A file that passes `checkGrowth` has `GrowthOk`. -/
theorem checkGrowth_ok {F : Source} (h : checkGrowth F = .ok ()) : GrowthOk F := by
  have hv : growthViolation? F true = none := by
    unfold checkGrowth at h
    split at h
    · assumption
    · split at h <;> cases h
  intro a d hd m es hm hr e he
  obtain ⟨hdm, rfl⟩ := Source.lookup_mem hd
  have hok : growthOk F true d (m, es) = true := by
    unfold growthViolation? at hv
    rw [List.findSome?_eq_none_iff] at hv
    have := hv d hdm
    rw [Option.map_eq_none_iff, List.find?_eq_none] at this
    simpa using this (m, es) hm
  unfold growthOk at hok
  split at hok
  · next hmn =>
    simp at hok
    rcases hok with rfl | rfl
    · simp at he
    · simp at he
      obtain ⟨p, _, rfl⟩ := he
      rfl
  · have hreach := Source.reaches_complete hr
    simp [hreach] at hok
    exact hok e he

end Haus.SchemaFile
