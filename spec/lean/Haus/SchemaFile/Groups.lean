import Haus.SchemaFile.Check
import Haus.SchemaFile.Terms

/-!
# The parameter graph (spec §9.10)

`Path next a b`: following `next` leads from `a` to `b` (or `a` is `b`).
`iterReach_complete`: a fixed number of rounds of following `next` (the
checker's `iterReach`) finds every such `b`, since the elements found grow
every round until none is added, and there are only so many of them;
`iterReach_sound`: it finds nothing else. For the parameter graph
(`Source.paramEdges`), `checkGrowth_iff`: a file passes `checkGrowth` exactly
when it has `GrowthOk`, no expanding edge on a cycle, the property the
finiteness of instances needs (`Haus.SchemaFile.Finite`).
-/

namespace Haus.SchemaFile

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

/-! ## Rounds of following `next` -/

/-- Following `next` leads from `a` to `b`, or `a` is `b`. -/
inductive Path {α : Type} (next : α → List α) : α → α → Prop
  | refl (a : α) : Path next a a
  | step {a b c : α} : b ∈ next a → Path next b c → Path next a c

theorem Path.trans {α : Type} {next : α → List α} {a b c : α} (h₁ : Path next a b) (h₂ : Path next b c) :
    Path next a c := by
  induction h₁ with
  | refl => exact h₂
  | step e _ ih => exact .step e (ih h₂)

theorem Path.single {α : Type} {next : α → List α} {a b : α} (e : b ∈ next a) : Path next a b :=
  .step e (.refl b)

section
variable {α : Type} [BEq α] [LawfulBEq α] (next : α → List α)
variable {next}

variable (next) in
/-- One round: the elements, and where `next` leads from them. -/
def round (S : List α) : List α := addNew S (S.flatMap next)

omit [LawfulBEq α] in
theorem iterReach_succ : ∀ (k : Nat) (S : List α),
    iterReach next (k + 1) S = round next (iterReach next k S)
  | 0, S => rfl
  | k + 1, S => by
    rw [iterReach, iterReach_succ k]
    rfl

omit [LawfulBEq α] in
theorem iterReach_add : ∀ (j k : Nat) (S : List α),
    iterReach next (j + k) S = iterReach next j (iterReach next k S)
  | j, 0, S => rfl
  | j, k + 1, S => by
    show iterReach next ((j + k) + 1) S = _
    rw [iterReach, iterReach_add j k]
    rfl

theorem mem_round {S : List α} {x : α} : x ∈ round next S ↔ x ∈ S ∨ ∃ y ∈ S, x ∈ next y := by
  simp [round, mem_addNew]

theorem sub_round (S : List α) : S ⊆ round next S := fun _ h => mem_round.2 (Or.inl h)

theorem round_mono {S T : List α} (h : S ⊆ T) : round next S ⊆ round next T := by
  intro x hx
  rcases mem_round.1 hx with hx | ⟨y, hy, e⟩
  · exact mem_round.2 (Or.inl (h hx))
  · exact mem_round.2 (Or.inr ⟨y, h hy, e⟩)

theorem iterReach_mono : ∀ (k : Nat) {S T : List α}, S ⊆ T → iterReach next k S ⊆ iterReach next k T
  | 0, _, _, h => h
  | k + 1, _, _, h => iterReach_mono k (round_mono h)

theorem iterReach_le {S : List α} : ∀ {j k : Nat}, j ≤ k → iterReach next j S ⊆ iterReach next k S
  | j, k, h => by
    induction k with
    | zero => have : j = 0 := by omega
              subst this; exact List.Subset.refl _
    | succ k ih =>
      rcases Nat.lt_or_ge j (k + 1) with hj | hj
      · rw [iterReach_succ]
        exact List.Subset.trans (ih (by omega)) (sub_round _)
      · have : j = k + 1 := by omega
        subst this; exact List.Subset.refl _

/-- Once a round adds nothing, no round does. -/
theorem iterReach_closed {S : List α} (h : round next S ⊆ S) : ∀ k, iterReach next k S ⊆ S
  | 0 => List.Subset.refl _
  | k + 1 => by
    rw [iterReach_succ]
    intro x hx
    rcases mem_round.1 hx with hx | ⟨y, hy, e⟩
    · exact iterReach_closed h k hx
    · exact h (mem_round.2 (Or.inr ⟨y, iterReach_closed h k hy, e⟩))

theorem iterReach_nodup : ∀ (k : Nat) {S : List α}, S.Nodup → (iterReach next k S).Nodup
  | 0, _, h => h
  | k + 1, _, h => iterReach_nodup k (nodup_addNew h)

theorem iterReach_sub {U : List α} (hU : ∀ a, ∀ b ∈ next a, b ∈ U) {m : α} : ∀ (k : Nat),
    iterReach next k [m] ⊆ m :: U
  | 0 => by simp [iterReach]
  | k + 1 => by
    rw [iterReach_succ]
    intro x hx
    rcases mem_round.1 hx with hx | ⟨y, _, e⟩
    · exact iterReach_sub hU k hx
    · exact List.mem_cons_of_mem _ (hU y x e)

omit [LawfulBEq α] in
/-- Each round that adds something makes the list longer. -/
theorem iterReach_grows {m : α} : ∀ (i : Nat),
    (∀ j < i, ¬ round next (iterReach next j [m]) ⊆ iterReach next j [m]) →
    i + 1 ≤ (iterReach next i [m]).length
  | 0, _ => by simp [iterReach]
  | i + 1, h => by
    have ih := iterReach_grows i (fun j hj => h j (by omega))
    rw [iterReach_succ]
    obtain ⟨zs, hz⟩ := addNew_prefix (iterReach next i [m]) ((iterReach next i [m]).flatMap next)
    have hne : zs ≠ [] := by
      intro e
      subst e
      apply h i (by omega)
      intro x hx
      simpa [round, hz] using hx
    have : 0 < zs.length := List.length_pos_iff.2 hne
    simp only [round, hz, List.length_append]
    omega

/-- After as many rounds as there are places to go, and one more, nothing is added. -/
theorem iterReach_all {U : List α} (hU : ∀ a, ∀ b ∈ next a, b ∈ U) (m : α) (k : Nat) :
    iterReach next k [m] ⊆ iterReach next (U.length + 1) [m] := by
  have : ∃ j ≤ U.length, round next (iterReach next j [m]) ⊆ iterReach next j [m] := by
    apply Classical.byContradiction
    intro hno
    have h := iterReach_grows (next := next) (m := m) (U.length + 1) (fun j hj hs =>
      hno ⟨j, by omega, hs⟩)
    have hle := List.Nodup.length_le_of_subset (iterReach_nodup (U.length + 1) (by simp))
      (iterReach_sub hU (m := m) (U.length + 1))
    simp at hle
    omega
  obtain ⟨j, hj, hs⟩ := this
  have hT : iterReach next j [m] ⊆ iterReach next (U.length + 1) [m] := iterReach_le (by omega)
  rcases Nat.lt_or_ge k j with hk | hk
  · exact List.Subset.trans (iterReach_le (by omega)) hT
  · have : k = (k - j) + j := by omega
    rw [this, iterReach_add]
    exact List.Subset.trans (iterReach_closed hs _) hT

theorem path_rounds {m n : α} (h : Path next m n) : ∃ k, n ∈ iterReach next k [m] := by
  induction h with
  | refl a => exact ⟨0, by simp [iterReach]⟩
  | @step a b c e _ ih =>
    obtain ⟨k, hk⟩ := ih
    refine ⟨k + 1, ?_⟩
    have : [b] ⊆ round next [a] := by
      intro x hx
      simp at hx; subst hx
      exact mem_round.2 (Or.inr ⟨a, by simp, e⟩)
    exact iterReach_mono k this hk

/-- The rounds find every element a path leads to. -/
theorem iterReach_complete {U : List α} (hU : ∀ a, ∀ b ∈ next a, b ∈ U) {m n : α} (h : Path next m n) :
    n ∈ iterReach next (U.length + 1) [m] := by
  obtain ⟨k, hk⟩ := path_rounds h
  exact iterReach_all hU m k hk

/-- The rounds find nothing a path doesn't lead to. -/
theorem iterReach_sound : ∀ (k : Nat) {S : List α} {x : α}, x ∈ iterReach next k S → ∃ s ∈ S, Path next s x
  | 0, S, x, h => ⟨x, h, .refl x⟩
  | k + 1, S, x, h => by
    obtain ⟨s, hs, p⟩ := iterReach_sound k h
    rcases mem_round.1 hs with hs | ⟨y, hy, e⟩
    · exact ⟨s, hs, p⟩
    · exact ⟨y, hy, (Path.single e).trans p⟩

end

/-! ## The parameter graph -/

/-- Following the edges of the parameter graph leads from `x` to `y`. -/
abbrev Source.PReach (F : Source) : PNode → PNode → Prop := Path F.pnext

theorem Source.mem_pnext {F : Source} {x y : PNode} : y ∈ F.pnext x ↔ ∃ b, (x, y, b) ∈ F.paramEdges := by
  simp only [Source.pnext, List.mem_map, List.mem_filter, beq_iff_eq]
  constructor
  · rintro ⟨⟨x', y', b⟩, ⟨h, rfl⟩, rfl⟩
    exact ⟨b, h⟩
  · rintro ⟨b, h⟩
    exact ⟨(x, y, b), ⟨h, rfl⟩, rfl⟩

theorem Source.pnext_targets (F : Source) : ∀ a, ∀ b ∈ F.pnext a, b ∈ F.paramEdges.map (·.2.1) := by
  intro a b hb
  obtain ⟨c, h⟩ := Source.mem_pnext.1 hb
  exact List.mem_map.2 ⟨_, h, rfl⟩

theorem Source.mem_preachable {F : Source} {x y : PNode} : y ∈ F.preachable x ↔ F.PReach x y := by
  constructor
  · intro h
    obtain ⟨s, hs, p⟩ := iterReach_sound _ h
    simp at hs; subst hs; exact p
  · intro h
    have := iterReach_complete F.pnext_targets h
    simpa [Source.preachable] using this

/--
§9.10, the property: no expanding edge of the parameter graph lies on a
cycle, i.e. from the parameter it leads to, no path leads back.
-/
def GrowthOk (F : Source) : Prop :=
  ∀ x y, (x, y, true) ∈ F.paramEdges → ¬ F.PReach y x

theorem Source.expansive?_none {F : Source} : F.expansive? = none ↔ GrowthOk F := by
  unfold Source.expansive? GrowthOk
  rw [Option.map_eq_none_iff, List.find?_eq_none]
  constructor
  · intro h x y hxy hr
    have := h _ hxy
    simp [Source.mem_preachable.2 hr] at this
  · rintro h ⟨x, y, b⟩ hxy
    cases b with
    | false => simp
    | true =>
      have := h x y hxy
      simpa [Source.mem_preachable] using this

/-- **The checker is exact**: a file passes `checkGrowth` exactly when it has `GrowthOk`. -/
theorem checkGrowth_iff {F : Source} : checkGrowth F = .ok () ↔ GrowthOk F := by
  rw [← Source.expansive?_none]
  unfold checkGrowth
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  split
  · next h => simp only [h, iff_true]; rfl
  · next h =>
    rw [h]
    constructor
    · intro e; split at e <;> cases e
    · intro e; cases e

/-- A file that passes `checkGrowth` has `GrowthOk`. -/
theorem checkGrowth_ok {F : Source} (h : checkGrowth F = .ok ()) : GrowthOk F := checkGrowth_iff.1 h

end Haus.SchemaFile
