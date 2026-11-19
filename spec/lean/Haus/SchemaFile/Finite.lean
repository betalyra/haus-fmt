import Haus.SchemaFile.Groups
import Haus.SchemaFile.Instances

/-!
# Finitely many instances (spec §9.10, PLAN I6)

`reach_finite`: in a file with `GrowthOk` (§9.10, no expanding edge of the
parameter graph on a cycle, which `check` ensures: `check_finite`), the
instances reachable from any types `ts` are among `Source.universe F ts`, a
list of at most `Source.instBound F ts` instances, an explicit number
computed from the file and `ts` alone.

Why. Give each parameter a height (`Source.height`): how many expanding
edges lead to it, i.e. have a path from their end to it. An edge never goes
down in height (`height_edge`), and an expanding edge goes up
(`height_edge_lt`), since its own end leads to its target but, with §9.10,
not back to its start. So the argument an instance gives a parameter of
height `k` is in `argSet k` (`good_succ`, `reach_inv`): the parts of `ts`,
the parameters and the arguments written in the file at height 0, and at
height `k + 1` also each written argument with its parameters replaced by
lists of height `k`. An argument kept as it is (`v` for `v`) stays at its
height; one inside a bigger type (`Pair v v`) is built from lower ones.
There are as many heights as expanding edges, so every instance is a
definition with at most `arity` arguments from `argSet top`
(`reach_universe`). The converse is in `Haus.SchemaFile.Cycles`.

`doubling_infinite` shows the rule is needed: the file of §9.10's example,
`type A a = < X (B (P a a)) | Done >` and `type B a = < Y (A (P a a)) | Stop >`,
passes every other check (`doubling_checks_without_growth`), and reaches
infinitely many instances (`A Int`, `A (P (P Int Int) (P Int Int))`, …), so no
list holds them all; `check` rejects it with `growing-recursion`.
-/

namespace Haus.SchemaFile

/-! ## Heights -/

theorem filter_length_le {α : Type} {l : List α} {p q : α → Bool} (h : ∀ x ∈ l, p x = true → q x = true) :
    (l.filter p).length ≤ (l.filter q).length := by
  induction l with
  | nil => simp
  | cons a l ih =>
    have ih := ih (fun x hx => h x (List.mem_cons_of_mem _ hx))
    by_cases hp : p a = true
    · have hq := h a (by simp) hp
      simp [hp, hq]; omega
    · by_cases hq : q a = true
      · simp [hp, hq]; omega
      · simp [hp, hq]; omega

theorem filter_length_lt {α : Type} {l : List α} {p q : α → Bool} (h : ∀ x ∈ l, p x = true → q x = true)
    {a : α} (ha : a ∈ l) (hq : q a = true) (hp : p a = false) :
    (l.filter p).length < (l.filter q).length := by
  induction l with
  | nil => simp at ha
  | cons b l ih =>
    have hle := filter_length_le (l := l) (fun x hx => h x (List.mem_cons_of_mem _ hx))
    rcases List.mem_cons.1 ha with rfl | ha
    · simp [hp, hq]; omega
    · have ih := ih (fun x hx => h x (List.mem_cons_of_mem _ hx)) ha
      by_cases hpb : p b = true
      · have hqb := h b (by simp) hpb
        simp [hpb, hqb]; omega
      · by_cases hqb : q b = true
        · simp [hpb, hqb]; omega
        · simp [hpb, hqb]; omega

theorem Source.length_names (F : Source) : F.names.length = F.defs.length := by simp [Source.names]

/-- The expanding edges of the parameter graph. -/
def Source.expEdges (F : Source) : List (PNode × PNode) :=
  (F.paramEdges.filter (·.2.2)).map fun e => (e.1, e.2.1)

theorem Source.mem_expEdges {F : Source} {x y : PNode} (h : (x, y, true) ∈ F.paramEdges) : (x, y) ∈ F.expEdges :=
  List.mem_map.2 ⟨(x, y, true), List.mem_filter.2 ⟨h, rfl⟩, rfl⟩

open Classical in
/-- How many expanding edges lead to a parameter: from where they lead, a path leads to it. -/
noncomputable def Source.height (F : Source) (x : PNode) : Nat :=
  (F.expEdges.filter fun e => decide (F.PReach e.2 x)).length

theorem Source.height_le (F : Source) (x : PNode) : F.height x ≤ F.expEdges.length := by
  unfold Source.height; exact List.length_filter_le _ _

/-- An edge never goes down in height. -/
theorem Source.height_edge {F : Source} {x y : PNode} {b : Bool} (e : (x, y, b) ∈ F.paramEdges) :
    F.height x ≤ F.height y := by
  classical
  unfold Source.height
  apply filter_length_le
  intro z _ h
  have hxy : F.PReach x y := Path.single (Source.mem_pnext.2 ⟨b, e⟩)
  simpa using (of_decide_eq_true h).trans hxy

/-- With §9.10, an expanding edge goes up: it leads to `y` itself, but not to `x`. -/
theorem Source.height_edge_lt {F : Source} (hG : GrowthOk F) {x y : PNode} (e : (x, y, true) ∈ F.paramEdges) :
    F.height x < F.height y := by
  classical
  unfold Source.height
  apply filter_length_lt (a := (x, y)) _ (Source.mem_expEdges e)
  · simpa using (Path.refl y : F.PReach y y)
  · simpa using hG x y e
  intro z _ h
  have hxy : F.PReach x y := Path.single (Source.mem_pnext.2 ⟨true, e⟩)
  simpa using (of_decide_eq_true h).trans hxy

theorem Source.mem_paramEdges {F : Source} {d d' : Def} {m q v : String} {es : List Tm} {e : Tm}
    (hd : d ∈ F.defs) (hr : (m, es) ∈ F.edges d) (hl : F.lookup m = some d') (hq : (q, e) ∈ d'.params.zip es)
    (hv : v ∈ e.vars) : ((d.name, v), (m, q), e != .var v) ∈ F.paramEdges := by
  simp only [Source.paramEdges, List.mem_flatMap]
  refine ⟨d, hd, (m, es), hr, ?_⟩
  simp only [hl, List.mem_flatMap, List.mem_map]
  exact ⟨(q, e), hq, v, hv, rfl⟩

/-! ## The arguments instances can have -/

/-- Each argument written in a definition, with the definition's parameters. -/
def Source.argExprs (F : Source) : List (List String × Tm) :=
  F.defs.flatMap fun d => d.body.refs.flatMap fun r => r.2.map fun e => (d.params, e)

/-- The parts of `ts`, the parameters of the definitions as types, and the arguments written. -/
def Source.base (F : Source) (ts : List Tm) : List Tm :=
  ts.flatMap Tm.subterms ++ (F.defs.flatMap fun d => d.body.vars ++ d.params).map .var ++
    F.argExprs.map (·.2)

/-- The arguments of instances up to height `k`. -/
def Source.argSet (F : Source) (ts : List Tm) : Nat → List Tm
  | 0 => F.base ts
  | k + 1 => F.argSet ts k ++ F.argExprs.flatMap fun (ps, e) =>
      (tuples (F.argSet ts k) ps.length).map fun as => e.subst (ps.zip as)

/-- The most arguments a name is given, in `ts` or in a definition. -/
def Source.arity (F : Source) (ts : List Tm) : Nat :=
  ((ts.flatMap Tm.refs ++ F.defs.flatMap fun d => d.body.refs).map (·.2.length)).foldr max 0

/-- The most parameters of a definition. -/
def Source.paramMax (F : Source) : Nat := (F.defs.map (·.params.length)).foldr max 0

/-- The height every argument is within: one more than the number of expanding edges. -/
def Source.top (F : Source) : Nat := F.expEdges.length + 1

/-- Every instance a definition with arguments of the top height could be. -/
def Source.universe (F : Source) (ts : List Tm) : List Inst :=
  F.names.flatMap fun n => (tuples (F.argSet ts F.top) (F.arity ts)).map (n, ·)

theorem le_foldr_max {l : List Nat} {x : Nat} (h : x ∈ l) : x ≤ l.foldr max 0 := by
  induction l with
  | nil => simp at h
  | cons a l ih =>
    rcases List.mem_cons.1 h with rfl | h
    · exact Nat.le_max_left _ _
    · simp only [List.foldr_cons]; exact Nat.le_trans (ih h) (Nat.le_max_right _ _)

theorem Source.argSet_succ_sub (F : Source) (ts : List Tm) (k : Nat) : F.argSet ts k ⊆ F.argSet ts (k + 1) :=
  fun _ h => List.mem_append_left _ h

theorem Source.argSet_mono (F : Source) (ts : List Tm) {j k : Nat} (h : j ≤ k) : F.argSet ts j ⊆ F.argSet ts k := by
  induction k with
  | zero => have : j = 0 := by omega
            subst this; exact List.Subset.refl _
  | succ k ih =>
    rcases Nat.lt_or_ge j (k + 1) with hj | hj
    · exact List.Subset.trans (ih (by omega)) (F.argSet_succ_sub ts k)
    · have : j = k + 1 := by omega
      subst this; exact List.Subset.refl _

theorem Source.base_sub (F : Source) (ts : List Tm) (k : Nat) : F.base ts ⊆ F.argSet ts k :=
  F.argSet_mono ts (Nat.zero_le k)

theorem Source.argSet_step {F : Source} {ts : List Tm} {k : Nat} {ps : List String} {e : Tm} {as : List Tm}
    (he : (ps, e) ∈ F.argExprs) (hl : as.length ≤ ps.length) (ha : ∀ a ∈ as, a ∈ F.argSet ts k) :
    e.subst (ps.zip as) ∈ F.argSet ts (k + 1) := by
  simp only [Source.argSet, List.mem_append, List.mem_flatMap, List.mem_map]
  exact Or.inr ⟨(ps, e), he, as, mem_tuples _ _ _ hl ha, rfl⟩

theorem Source.argExprs_base {F : Source} {ps : List String} {e : Tm} (he : (ps, e) ∈ F.argExprs) (ts : List Tm) :
    e ∈ F.base ts := by
  simp only [Source.base, List.mem_append]
  exact Or.inr (List.mem_map.2 ⟨(ps, e), he, rfl⟩)

theorem Source.argExprs_params {F : Source} {ps : List String} {e : Tm} (he : (ps, e) ∈ F.argExprs)
    (ts : List Tm) : ∀ p ∈ ps, Tm.var p ∈ F.base ts := by
  simp only [Source.argExprs, List.mem_flatMap, List.mem_map, Prod.mk.injEq] at he
  obtain ⟨d, hd, _, _, _, _, rfl, _⟩ := he
  intro p hp
  simp only [Source.base, List.mem_append, List.mem_map, List.mem_flatMap]
  exact Or.inl (Or.inr ⟨p, ⟨d, hd, Or.inr hp⟩, rfl⟩)

/-- A written argument, its parameters replaced by arguments of height `k`, is of height `k + 1`. -/
theorem Source.subst_step {F : Source} {ts : List Tm} {k : Nat} {ps : List String} {e : Tm} {args : List Tm}
    (he : (ps, e) ∈ F.argExprs) (ha : ∀ p a, (p, a) ∈ ps.zip args → p ∈ e.vars → a ∈ F.argSet ts k) :
    e.subst (ps.zip args) ∈ F.argSet ts (k + 1) := by
  obtain ⟨bs, hl, hm, hk⟩ := zip_restrict (fun p => decide (p ∈ e.vars)) ps args
  have : e.subst (ps.zip args) = e.subst (ps.zip bs) :=
    Tm.subst_congr e fun v hv => (hk v (by simpa using hv)).symm
  rw [this]
  apply Source.argSet_step he hl
  intro b hb
  rcases hm b hb with ⟨p, hp, hP⟩ | ⟨p, hp, rfl⟩
  · exact ha p b hp (by simpa using hP)
  · exact F.base_sub ts k (Source.argExprs_params he ts p hp)

/-- A parameter, replaced by an argument of height `k`, is of height `k`. -/
theorem Source.subst_var {F : Source} {ts : List Tm} {k : Nat} {ps : List String} {v : String} {args : List Tm}
    (hv : Tm.var v ∈ F.base ts) (ha : ∀ a, (v, a) ∈ ps.zip args → a ∈ F.argSet ts k) :
    (Tm.var v).subst (ps.zip args) ∈ F.argSet ts k := by
  simp only [Tm.subst_var]
  cases hl : (ps.zip args).lookup v with
  | some u => exact ha u (lookup_mem_pair _ hl)
  | none => exact F.base_sub ts k hv

/-! ## The invariant -/

/--
An instance's arguments are of the top height, each of the height of the
parameter it is for, and not too many.
-/
def Source.Good (F : Source) (ts : List Tm) (i : Inst) : Prop :=
  (∀ a ∈ i.2, a ∈ F.argSet ts F.top) ∧
  (∀ d, F.lookup i.1 = some d → ∀ p a, (p, a) ∈ d.params.zip i.2 → a ∈ F.argSet ts (F.height (i.1, p))) ∧
  i.2.length ≤ F.arity ts

/-- An instance, and the instances in its arguments, are `Good`. -/
def Source.Inv (F : Source) (ts : List Tm) (i : Inst) : Prop :=
  ∀ j ∈ (Tm.ref i.1 i.2).refs, F.defined j.1 = true → F.Good ts j

theorem Source.edges_arity {F : Source} {ts : List Tm} {d : Def} (hd : d ∈ F.defs) {r : String × List Tm}
    (hr : r ∈ d.body.refs) : r.2.length ≤ F.arity ts := by
  apply le_foldr_max
  simp only [List.mem_map, List.mem_append, List.mem_flatMap]
  exact ⟨r, Or.inr ⟨d, hd, hr⟩, rfl⟩

theorem Source.argExprs_mem {F : Source} {d : Def} (hd : d ∈ F.defs) {m : String} {es : List Tm}
    (hes : (m, es) ∈ d.body.refs) {e : Tm} (he : e ∈ es) : (d.params, e) ∈ F.argExprs := by
  simp only [Source.argExprs, List.mem_flatMap, List.mem_map]
  exact ⟨d, hd, (m, es), hes, e, he, rfl⟩

/-- The step: the instances an instance's type mentions are `Good`. -/
theorem Source.good_succ {F : Source} {ts : List Tm} (hG : GrowthOk F) {n : String} {args : List Tm} {d : Def}
    (hd : F.lookup n = some d) (hgood : F.Good ts (n, args)) (hinv : F.Inv ts (n, args)) :
    ∀ j ∈ (d.body.subst (d.params.zip args)).refs, F.defined j.1 = true → F.Good ts j := by
  rintro ⟨m, es'⟩ hj hdef
  obtain ⟨hdm, hdn⟩ := Source.lookup_mem hd
  have hH : ∀ p a, (p, a) ∈ d.params.zip args → a ∈ F.argSet ts (F.height (n, p)) := hgood.2.1 d hd
  have hTop : ∀ p a, (p, a) ∈ d.params.zip args → a ∈ F.argSet ts F.expEdges.length :=
    fun p a h => F.argSet_mono ts (F.height_le _) (hH p a h)
  rcases Tm.refs_subst _ d.body hj with ⟨es, hes, rfl⟩ | ⟨v, _, u, hu, hmu⟩
  · have hedge : (m, es) ∈ F.edges d := Source.mem_edges.2 ⟨hes, hdef⟩
    have hx : ∀ e ∈ es, (d.params, e) ∈ F.argExprs := fun e he => Source.argExprs_mem hdm hes he
    refine ⟨?_, ?_, by simpa using Source.edges_arity (ts := ts) hdm hes⟩
    · -- every argument is of the top height
      simp only [List.mem_map]
      rintro a ⟨e, he, rfl⟩
      cases e with
      | var v =>
        exact F.argSet_mono ts (Nat.le_succ _)
          (Source.subst_var (Source.argExprs_base (hx _ he) ts) fun a h => hTop v a h)
      | ref _ _ | node _ _ => exact Source.subst_step (hx _ he) fun p a h _ => hTop p a h
    · -- each argument is of the height of its parameter
      intro d' hl q a' hq
      rw [List.zip_map_right, List.mem_map] at hq
      obtain ⟨⟨q', e⟩, hqe, he⟩ := hq
      simp only [Prod.map, id, Prod.mk.injEq] at he
      obtain ⟨rfl, rfl⟩ := he
      have hem : e ∈ es := (List.of_mem_zip hqe).2
      have hedges : ∀ v ∈ e.vars, ((n, v), (m, q'), e != .var v) ∈ F.paramEdges := fun v hv => by
        simpa [hdn] using Source.mem_paramEdges hdm hedge hl hqe hv
      have hexp : (∀ w, e ≠ .var w) → ∀ v ∈ e.vars, ((n, v), (m, q'), true) ∈ F.paramEdges := fun hne v hv => by
        have := hedges v hv
        rwa [bne_iff_ne.2 (hne v)] at this
      cases e with
      | var v =>
        apply Source.subst_var (Source.argExprs_base (hx _ hem) ts)
        intro a ha
        exact F.argSet_mono ts (Source.height_edge (hedges v (by simp))) (hH v a ha)
      | ref _ _ | node _ _ =>
        cases hvars : Tm.vars _ with
        | nil =>
          rw [Tm.subst_closed hvars]
          exact F.base_sub ts _ (Source.argExprs_base (hx _ hem) ts)
        | cons v0 _ =>
          have hlt := Source.height_edge_lt hG (hexp (fun w h => by cases h) v0 (by simp [hvars]))
          have : F.height (m, q') = (F.height (m, q') - 1) + 1 := by omega
          rw [this]
          apply Source.subst_step (hx _ hem)
          intro p a ha hp
          have := Source.height_edge_lt hG (hexp (fun w h => by cases h) p hp)
          exact F.argSet_mono ts (by omega) (hH p a ha)
  · have hua := lookup_zip_mem _ _ hu
    apply hinv (m, es') _ hdef
    simp only [Tm.refs_ref, List.mem_cons, List.mem_flatMap]
    exact Or.inr ⟨u, hua, hmu⟩

/-- Every reachable instance is a definition, and `Inv` holds for it. -/
theorem Source.reach_inv {F : Source} {ts : List Tm} (hG : GrowthOk F) {i : Inst} (h : Reach F ts i) :
    F.defined i.1 = true ∧ F.Inv ts i := by
  induction h with
  | @root i hi hdef =>
    refine ⟨hdef, ?_⟩
    simp only [List.mem_flatMap] at hi
    obtain ⟨t, ht, hi⟩ := hi
    intro j hj _
    have hjt := Tm.refs_ref_sub t hi j hj
    have hbase : ∀ a ∈ j.2, a ∈ F.base ts := fun a ha => by
      simp only [Source.base, List.mem_append, List.mem_flatMap]
      exact Or.inl (Or.inl ⟨t, ht, Tm.refs_args_subterms t hjt a ha⟩)
    refine ⟨fun a ha => F.base_sub ts _ (hbase a ha), fun d _ p a hpa => F.base_sub ts _ (hbase a (List.of_mem_zip hpa).2), ?_⟩
    apply le_foldr_max
    simp only [List.mem_map, List.mem_append, List.mem_flatMap]
    exact ⟨j, Or.inl ⟨t, ht, hjt⟩, rfl⟩
  | @step i j _ hj ih =>
    obtain ⟨n, args⟩ := i
    simp only [Source.succs] at hj
    split at hj
    · next d hd =>
      rw [List.mem_filter] at hj
      obtain ⟨hj, hdef⟩ := hj
      refine ⟨hdef, fun k hk hkdef => ?_⟩
      have hgood : F.Good ts (n, args) := ih.2 (n, args) (by simp) ih.1
      exact Source.good_succ hG hd hgood ih.2 k (Tm.refs_ref_sub _ hj k hk) hkdef
    · simp at hj

/-! ## The bound -/

/-- `argBound b e p k`: the bound on `argSet` at height `k`. -/
def argBound (b e p : Nat) : Nat → Nat
  | 0 => b
  | k + 1 => argBound b e p k + e * (argBound b e p k + 1) ^ p

/--
The number of instances a file `F` can reach from `ts`: definitions times
the lists of at most `arity` arguments of the top height.
-/
def Source.instBound (F : Source) (ts : List Tm) : Nat :=
  F.defs.length * (argBound (F.base ts).length F.argExprs.length F.paramMax F.top + 1) ^ F.arity ts

theorem length_flatMap_le {α β : Type} (l : List α) (f : α → List β) (c : Nat) (h : ∀ x ∈ l, (f x).length ≤ c) :
    (l.flatMap f).length ≤ l.length * c := by
  induction l with
  | nil => simp
  | cons a l ih =>
    have h1 := h a (by simp)
    have h2 := ih (fun x hx => h x (List.mem_cons_of_mem _ hx))
    simp only [List.flatMap_cons, List.length_append, List.length_cons, Nat.succ_mul]
    omega

theorem Source.argExprs_paramMax {F : Source} {ps : List String} {e : Tm} (h : (ps, e) ∈ F.argExprs) :
    ps.length ≤ F.paramMax := by
  simp only [Source.argExprs, List.mem_flatMap, List.mem_map, Prod.mk.injEq] at h
  obtain ⟨d, hd, _, _, _, _, rfl, _⟩ := h
  apply le_foldr_max
  exact List.mem_map_of_mem hd

theorem Source.length_argSet (F : Source) (ts : List Tm) : ∀ k : Nat,
    (F.argSet ts k).length ≤ argBound (F.base ts).length F.argExprs.length F.paramMax k
  | 0 => by simp [Source.argSet, argBound]
  | k + 1 => by
    have ih := F.length_argSet ts k
    simp only [Source.argSet, argBound, List.length_append]
    have : (F.argExprs.flatMap fun (x : List String × Tm) =>
        (tuples (F.argSet ts k) x.1.length).map fun as => x.2.subst (x.1.zip as)).length ≤
        F.argExprs.length * (argBound (F.base ts).length F.argExprs.length F.paramMax k + 1) ^ F.paramMax := by
      apply length_flatMap_le
      rintro ⟨ps, e⟩ he
      simp only [List.length_map]
      calc (tuples (F.argSet ts k) ps.length).length
          ≤ ((F.argSet ts k).length + 1) ^ ps.length := length_tuples_le _ _
        _ ≤ ((F.argSet ts k).length + 1) ^ F.paramMax :=
          Nat.pow_le_pow_right (by omega) (Source.argExprs_paramMax he)
        _ ≤ _ := Nat.pow_le_pow_left (by omega) _
    omega

theorem Source.length_universe (F : Source) (ts : List Tm) : (F.universe ts).length ≤ F.instBound ts := by
  unfold Source.universe Source.instBound
  have := length_flatMap_le F.names (fun n => (tuples (F.argSet ts F.top) (F.arity ts)).map (n, ·))
    ((argBound (F.base ts).length F.argExprs.length F.paramMax F.top + 1) ^ F.arity ts) (by
      intro n _
      simp only [List.length_map]
      exact Nat.le_trans (length_tuples_le _ _)
        (Nat.pow_le_pow_left (by have := F.length_argSet ts F.top; omega) _))
  rwa [Source.length_names] at this

/-! ## Finitely many instances -/

/-- Every instance reachable from `ts` is in `universe`. -/
theorem Source.reach_universe {F : Source} {ts : List Tm} (hG : GrowthOk F) {i : Inst} (h : Reach F ts i) :
    i ∈ F.universe ts := by
  obtain ⟨hdef, hinv⟩ := Source.reach_inv hG h
  obtain ⟨hargs, _, hlen⟩ := hinv i (by simp) hdef
  simp only [Source.universe, List.mem_flatMap, List.mem_map]
  exact ⟨i.1, Source.mem_names hdef, i.2, mem_tuples _ _ _ hlen hargs, rfl⟩

/--
**I6.** In a file without an expansive cycle (§9.10), the instances
reachable from any types are finitely many: at most `instBound`.
-/
theorem Source.reach_finite {F : Source} (hG : GrowthOk F) (ts : List Tm) :
    ∃ L : List Inst, L.length ≤ F.instBound ts ∧ ∀ i, Reach F ts i → i ∈ L :=
  ⟨F.universe ts, F.length_universe ts, fun _ h => Source.reach_universe hG h⟩

/-- **I6** for every file that passes `check` (spec §14). -/
theorem check_finite {F : Source} (h : check F = .ok ()) (ts : List Tm) :
    ∃ L : List Inst, L.length ≤ F.instBound ts ∧ ∀ i, Reach F ts i → i ∈ L :=
  Source.reach_finite (checkGrowth_ok (check_growth h)) ts


/-! ## Why the rule is needed: the doubling example of §9.10 -/

/-- The example of §9.10: `A Int` needs `B (P Int Int)`, which needs `A (P (P Int Int) (P Int Int))`, … -/
def doublingText : String :=
  "type P a b = { l: a, r: b }\ntype A a = < X (B (P a a)) | Done >\ntype B a = < Y (A (P a a)) | Stop >\ntype Root = A Int"

/-- `P x y` -/
def pairTm (x y : Tm) : Tm := .ref "P" [x, y]

/-- The definitions of `doublingText`. -/
def doubling : Source where
  defs := [
    { name := "P", params := ["a", "b"],
      body := .node (.record false [.field "l" false, .field "r" false]) [.var "a", .var "b"] },
    { name := "A", params := ["a"],
      body := .node (.variant false [.case "X" 1, .case "Done" 0]) [.ref "B" [pairTm (.var "a") (.var "a")]] },
    { name := "B", params := ["a"],
      body := .node (.variant false [.case "Y" 1, .case "Stop" 0]) [.ref "A" [pairTm (.var "a") (.var "a")]] },
    { name := "Root", params := [], body := .ref "A" [.ref "Int" []] }]

-- The parser reads `doublingText` as `doubling`.
#guard ((parse doublingText.toList).toOption.map fun p => p.defs.map fun d => (d.name, d.params, d.body, d.stream)) ==
  some (doubling.defs.map fun d => (d.name, d.params, d.body, d.stream))
-- `check` rejects it with `growing-recursion`, and so does the whole way from text.
#guard match check doubling with
  | .error e => e.code == .growingRecursion
  | .ok _ => false
#guard match load doublingText.toList with
  | .error e => e.code == .growingRecursion
  | .ok _ => false

/-- Every other rule holds: without §9.10's rule, `check` accepts it. -/
theorem doubling_checks_without_growth : (check doubling (growth := false)).toBool = true := by decide

/-- The instances `A Int`, `A (P (P Int Int) (P Int Int))`, …: the argument doubles twice per step. -/
def doubled : Nat → Tm
  | 0 => .ref "Int" []
  | k + 1 => pairTm (pairTm (doubled k) (doubled k)) (pairTm (doubled k) (doubled k))

theorem doubling_succ_A (x : Tm) : ("B", [pairTm x x]) ∈ doubling.succs ("A", [x]) := by
  simp [Source.succs, Source.lookup, Source.defined, doubling, pairTm]

theorem doubling_succ_B (x : Tm) : ("A", [pairTm x x]) ∈ doubling.succs ("B", [x]) := by
  simp [Source.succs, Source.lookup, Source.defined, doubling, pairTm]

/-- From `Root`, every `A (doubled k)` is reachable. -/
theorem doubling_reach : ∀ k, Reach doubling [.ref "Root" []] ("A", [doubled k])
  | 0 => by
    have root : Reach doubling [.ref "Root" []] ("Root", []) :=
      .root (by simp) (by simp [Source.defined, Source.lookup, doubling])
    exact .step root (by simp [Source.succs, Source.lookup, Source.defined, doubling, doubled])
  | k + 1 => .step (.step (doubling_reach k) (doubling_succ_A _)) (doubling_succ_B _)

theorem size_pairTm (x y : Tm) : (pairTm x y).size = x.size + y.size + 1 := by
  simp [pairTm, Tm.size, Tm.sizeList, Nat.add_comm]

theorem size_doubled : ∀ k, k + 1 ≤ (doubled k).size
  | 0 => by simp [doubled, Tm.size, Tm.sizeList]
  | k + 1 => by
    have := size_doubled k
    simp only [doubled, size_pairTm]
    omega

/--
**Without §9.10's rule, instances can be infinitely many**: the
doubling example passes every other check, yet no list holds all the
instances it reaches.
-/
theorem doubling_infinite : ¬ ∃ L : List Inst, ∀ i, Reach doubling [.ref "Root" []] i → i ∈ L := by
  rintro ⟨L, hL⟩
  let M := (L.map fun i => (Tm.ref i.1 i.2).size).foldr max 0
  have hmem := hL _ (doubling_reach (M + 1))
  have hle : (Tm.ref "A" [doubled (M + 1)]).size ≤ M :=
    le_foldr_max (List.mem_map_of_mem (f := fun i : Inst => (Tm.ref i.1 i.2).size) hmem)
  have hsize := size_doubled (M + 1)
  simp [Tm.size, Tm.sizeList] at hle
  omega

/-- So `check` must reject it, and does. -/
theorem doubling_rejected : (check doubling).toBool = false := by decide

end Haus.SchemaFile
