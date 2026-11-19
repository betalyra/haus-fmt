import Haus.SchemaFile.Finite

/-!
# Expansive cycles give infinitely many instances (spec §9.10)

The converse of `Source.reach_finite`: in a file where an expanding edge of
the parameter graph lies on a cycle (`¬ GrowthOk`), some type without
parameters reaches infinitely many instances (`infinite_of_expansive`):
`A Int … Int`, for the definition `A` the edge starts from. Following the
cycle once from an instance of `A`, the argument for the edge's parameter
becomes part of a bigger argument (`edge_step`), and every other edge keeps
it as a part (`path_step`), so the arguments grow without bound.

This needs what `declare` and `checkParams` ensure (`Source.WellFormed`):
every definition is the one its name finds, no parameter is declared twice,
and a body uses only its own parameters. So, for such files, §9.10 holds
exactly when every type reaches finitely many instances
(`growthOk_iff_finite`), and the checker decides it (`checkGrowth_iff_finite`).
-/

namespace Haus.SchemaFile

/-- What `declare` and `checkParams` ensure about a file's definitions. -/
structure Source.WellFormed (F : Source) : Prop where
  lookup : ∀ d ∈ F.defs, F.lookup d.name = some d
  params : ∀ d ∈ F.defs, d.params.Nodup
  vars : ∀ d ∈ F.defs, ∀ v ∈ d.body.vars, v ∈ d.params

/-! ## Sizes -/

theorem Tm.sizeList_eq (ts : List Tm) : Tm.sizeList ts = (ts.map Tm.size).sum := by
  induction ts with
  | nil => rfl
  | cons t ts ih => simp [Tm.sizeList, ih]

theorem le_sum_of_mem {l : List Nat} {x : Nat} (h : x ∈ l) : x ≤ l.sum := by
  induction l with
  | nil => simp at h
  | cons a l ih =>
    rcases List.mem_cons.1 h with rfl | h
    · simp
    · have := ih h; simp; omega

theorem Tm.size_lt_ref {n : String} {as : List Tm} {a : Tm} (h : a ∈ as) : a.size < (Tm.ref n as).size := by
  have := le_sum_of_mem (List.mem_map_of_mem (f := Tm.size) h)
  simp only [Tm.size, Tm.sizeList_eq]
  omega

theorem Tm.size_lt_node {l : Label} {ks : List Tm} {a : Tm} (h : a ∈ ks) : a.size < (Tm.node l ks).size := by
  have := le_sum_of_mem (List.mem_map_of_mem (f := Tm.size) h)
  simp only [Tm.size, Tm.sizeList_eq]
  omega

/--
What a parameter of a type is replaced by is part of the result: no bigger,
and smaller unless the type is the parameter itself.
-/
theorem Tm.size_subst {σ : Subst} {v : String} {u : Tm} (hu : σ.lookup v = some u) : ∀ (t : Tm), v ∈ t.vars →
    u.size ≤ (t.subst σ).size ∧ (t ≠ .var v → u.size < (t.subst σ).size)
  | .var p, h => by
    simp at h; subst h
    simp [hu]
  | .ref n as, h => by
    simp only [Tm.vars_ref, List.mem_flatMap] at h
    obtain ⟨a, ha, hv⟩ := h
    have := (Tm.size_subst hu a hv).1
    have := Tm.size_lt_ref (n := n) (List.mem_map_of_mem (f := Tm.subst σ) ha)
    simp only [Tm.subst_ref]
    exact ⟨by omega, fun _ => by omega⟩
  | .node l ks, h => by
    simp only [Tm.vars_node, List.mem_flatMap] at h
    obtain ⟨a, ha, hv⟩ := h
    have := (Tm.size_subst hu a hv).1
    have := Tm.size_lt_node (l := l) (List.mem_map_of_mem (f := Tm.subst σ) ha)
    simp only [Tm.subst_node]
    exact ⟨by omega, fun _ => by omega⟩
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

/-- A name written in a type is still there after substitution, its arguments substituted. -/
theorem Tm.refs_subst_mem (σ : Subst) : ∀ (t : Tm) {m : String} {es : List Tm},
    (m, es) ∈ t.refs → (m, es.map (Tm.subst σ)) ∈ (t.subst σ).refs
  | .var _, _, _, h => by simp at h
  | .ref n as, m, es, h => by
    simp only [Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap] at h
    simp only [Tm.subst_ref, Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap, List.mem_map]
    rcases h with ⟨rfl, rfl⟩ | ⟨a, ha, h⟩
    · exact Or.inl ⟨rfl, rfl⟩
    · exact Or.inr ⟨_, ⟨a, ha, rfl⟩, Tm.refs_subst_mem σ a h⟩
  | .node l ks, m, es, h => by
    simp only [Tm.refs_node, List.mem_flatMap] at h
    simp only [Tm.subst_node, Tm.refs_node, List.mem_flatMap, List.mem_map]
    obtain ⟨a, ha, h⟩ := h
    exact ⟨_, ⟨a, ha, rfl⟩, Tm.refs_subst_mem σ a h⟩
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

theorem lookup_zip_map (f : String → Tm) : ∀ (ps : List String) {v : String}, v ∈ ps →
    (ps.zip (ps.map f)).lookup v = some (f v)
  | [], _, h => by simp at h
  | p :: ps, v, h => by
    simp only [List.map_cons, List.zip_cons_cons, List.lookup_cons]
    split
    · next h' => simp at h'; subst h'; rfl
    · next h' =>
      have : v ≠ p := by simpa using h'
      exact lookup_zip_map f ps (by simpa [this] using h)

/-! ## Following the parameter graph through instances -/

/-- The argument an instance gives a parameter `p` of its definition. -/
def Source.argOf (F : Source) (i : Inst) (p : String) : Option Tm :=
  match F.lookup i.1 with
  | some d => (d.params.zip i.2).lookup p
  | none => none

/--
An edge of the parameter graph, followed from a reachable instance: the
instance it leads to is reachable, and the argument at its end has the one
at its start as a part, a smaller one if the edge is expanding.
-/
theorem Source.edge_step {F : Source} (hW : F.WellFormed) {ts : List Tm} {Y Z y z : String} {b : Bool}
    (he : ((Y, y), (Z, z), b) ∈ F.paramEdges) {args : List Tm} {u : Tm}
    (hr : Reach F ts (Y, args)) (hu : F.argOf (Y, args) y = some u) :
    ∃ args' u', Reach F ts (Z, args') ∧ F.argOf (Z, args') z = some u' ∧
      u.size ≤ u'.size ∧ (b = true → u.size < u'.size) := by
  simp only [Source.paramEdges, List.mem_flatMap] at he
  obtain ⟨d, hd, ⟨m, es⟩, hr', he⟩ := he
  cases hl : F.lookup m with
  | none => simp [hl] at he
  | some d' =>
    simp only [hl, List.mem_flatMap, List.mem_map, Prod.mk.injEq] at he
    obtain ⟨⟨q, e⟩, hqe, v, hv, ⟨rfl, rfl⟩, ⟨rfl, rfl⟩, rfl⟩ := he
    have hY := hW.lookup d hd
    have hd' := (Source.lookup_mem hl).1
    simp only [Source.argOf, hY] at hu
    let σ := d.params.zip args
    refine ⟨es.map (Tm.subst σ), e.subst σ, ?_, ?_, ?_⟩
    · apply Reach.step hr
      simp only [Source.succs, hY, List.mem_filter]
      exact ⟨Tm.refs_subst_mem σ _ (Source.mem_edges.1 hr').1, by simp [Source.defined, hl]⟩
    · simp only [Source.argOf, hl]
      apply lookup_zip_nodup _ _ (hW.params d' hd')
      rw [List.zip_map_right, List.mem_map]
      exact ⟨(q, e), hqe, rfl⟩
    · have := Tm.size_subst hu e hv
      refine ⟨this.1, fun hb => this.2 fun h => ?_⟩
      subst h
      simp at hb

/-- A path of the parameter graph, followed from a reachable instance: the argument stays a part. -/
theorem Source.path_step {F : Source} (hW : F.WellFormed) {ts : List Tm} {x w : PNode} (hp : F.PReach x w) :
    ∀ {args : List Tm} {u : Tm}, Reach F ts (x.1, args) → F.argOf (x.1, args) x.2 = some u →
    ∃ args' u', Reach F ts (w.1, args') ∧ F.argOf (w.1, args') w.2 = some u' ∧ u.size ≤ u'.size := by
  induction hp with
  | refl _ => exact fun hr hu => ⟨_, _, hr, hu, Nat.le_refl _⟩
  | @step x y w e _ ih =>
    intro args u hr hu
    obtain ⟨b, he⟩ := Source.mem_pnext.1 e
    obtain ⟨args', u', hr', hu', hle, _⟩ := Source.edge_step hW he hr hu
    obtain ⟨args'', u'', hr'', hu'', hle'⟩ := ih hr' hu'
    exact ⟨args'', u'', hr'', hu'', Nat.le_trans hle hle'⟩

/--
**An expansive cycle gives infinitely many instances**: if an expanding edge
lies on a cycle, a type without parameters reaches instances without bound.
-/
theorem Source.infinite_of_expansive {F : Source} (hW : F.WellFormed) (h : ¬ GrowthOk F) :
    ∃ t : Tm, t.vars = [] ∧ ¬ ∃ L : List Inst, ∀ i, Reach F [t] i → i ∈ L := by
  have h' : ∃ x y, (x, y, true) ∈ F.paramEdges ∧ F.PReach y x := by
    apply Classical.byContradiction
    intro hn
    exact h fun x y hxy hr => hn ⟨x, y, hxy, hr⟩
  obtain ⟨⟨A, a⟩, y, hxy, hcyc⟩ := h'
  -- `A` is a definition and `a` one of its parameters.
  have hxy' := hxy
  simp only [Source.paramEdges, List.mem_flatMap] at hxy'
  obtain ⟨d, hd, ⟨m, es⟩, hr', he⟩ := hxy'
  have hpa : A = d.name ∧ a ∈ d.params := by
    cases hl : F.lookup m with
    | none => simp [hl] at he
    | some d' =>
      simp only [hl, List.mem_flatMap, List.mem_map, Prod.mk.injEq] at he
      obtain ⟨⟨q, e⟩, hqe, v, hv, ⟨rfl, rfl⟩, _⟩ := he
      refine ⟨rfl, hW.vars d hd v ?_⟩
      exact Tm.refs_args_vars d.body (Source.mem_edges.1 hr').1 e (List.of_mem_zip hqe).2 v hv
  obtain ⟨rfl, ha⟩ := hpa
  have hA := hW.lookup d hd
  let t : Tm := .ref d.name (d.params.map fun _ => .ref "Int" [])
  refine ⟨t, by simp [t, Tm.vars_ref], ?_⟩
  -- Instances of `A` with ever bigger arguments for `a`.
  have grow : ∀ N, ∃ args u, Reach F [t] (d.name, args) ∧ F.argOf (d.name, args) a = some u ∧ N ≤ u.size := by
    intro N
    induction N with
    | zero =>
      refine ⟨d.params.map fun _ => .ref "Int" [], .ref "Int" [], .root (by simp [t]) ?_, ?_, Nat.zero_le _⟩
      · simp [Source.defined, hA]
      · simp only [Source.argOf, hA]
        exact lookup_zip_map (fun _ => .ref "Int" []) d.params ha
    | succ N ih =>
      obtain ⟨args, u, hr, hu, hN⟩ := ih
      obtain ⟨args', u', hr', hu', _, hlt⟩ := Source.edge_step hW hxy hr hu
      obtain ⟨args'', u'', hr'', hu'', hle⟩ := Source.path_step hW hcyc hr' hu'
      exact ⟨args'', u'', hr'', hu'', by have := hlt rfl; omega⟩
  rintro ⟨L, hL⟩
  let M := (L.map fun i => (Tm.ref i.1 i.2).size).foldr max 0
  obtain ⟨args, u, hr, hu, hN⟩ := grow (M + 1)
  have hle : (Tm.ref d.name args).size ≤ M :=
    le_foldr_max (List.mem_map_of_mem (f := fun i : Inst => (Tm.ref i.1 i.2).size) (hL _ hr))
  simp only [Source.argOf, hA] at hu
  have := Tm.size_lt_ref (n := d.name) (lookup_zip_mem _ _ hu)
  omega

/--
**§9.10 is exact**: for a file whose definitions `declare` and `checkParams`
accept, there is no expansive cycle exactly when every type reaches finitely
many instances.
-/
theorem Source.growthOk_iff_finite {F : Source} (hW : F.WellFormed) :
    GrowthOk F ↔ ∀ ts : List Tm, ∃ L : List Inst, ∀ i, Reach F ts i → i ∈ L := by
  constructor
  · intro hG ts
    obtain ⟨L, _, hL⟩ := Source.reach_finite hG ts
    exact ⟨L, hL⟩
  · intro hfin
    apply Classical.byContradiction
    intro hG
    obtain ⟨t, _, ht⟩ := Source.infinite_of_expansive hW hG
    exact ht (hfin [t])

/-- And the checker decides it. -/
theorem checkGrowth_iff_finite {F : Source} (hW : F.WellFormed) :
    checkGrowth F = .ok () ↔ ∀ ts : List Tm, ∃ L : List Inst, ∀ i, Reach F ts i → i ∈ L :=
  checkGrowth_iff.trans (Source.growthOk_iff_finite hW)

end Haus.SchemaFile
