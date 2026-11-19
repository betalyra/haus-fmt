import Haus.SchemaFile.Groups
import Haus.SchemaFile.Instances

/-!
# Finitely many instances (spec §9.10, PLAN I6)

`reach_finite`: in a file with `GrowthOk` (§9.10, which `check` ensures:
`check_finite`), the instances reachable from any types `ts` are among
`Source.universe F ts`, a list of at most `Source.instBound F ts` instances,
an explicit number computed from the file and `ts` alone.

Why. Order the definitions by how many definitions each reaches
(`Source.level`: the fewer, the higher). A reference from `a` to `b` never
goes down a level, and goes up one unless `b` refers back to `a` (then they
are in one group, and §9.10 says the arguments are parameters of `a`: the
instance of `b` gets some of `a`'s arguments, nothing new). So the arguments
of the instances at level `k` are in `argSet k`: the parts of `ts` and the
parameters at level 0, and at level `k + 1` also each argument written in
the file with its parameters replaced by lists of level `k`. There are as
many levels as definitions, so every instance is a definition with at most
`arity` arguments from `argSet N` (`reach_universe`).

`doubling_infinite` shows the rule is needed: the file of §9.10's example,
`type A a = < X (B (P a a)) | Done >` and `type B a = < Y (A (P a a)) | Stop >`,
passes every other check (`doubling_checks_without_groups`), and reaches
infinitely many instances (`A Int`, `A (P (P Int Int) (P Int Int))`, …), so no
list holds them all; `check` rejects it with `growing-recursion`.
-/

namespace Haus.SchemaFile

/-! ## Levels -/

open Classical in
/-- `N` minus how many definitions `n` reaches: lower for definitions that reach more. -/
noncomputable def Source.level (F : Source) (n : String) : Nat :=
  F.defs.length - (F.names.filter fun x => decide (F.Reaches n x)).length

theorem filter_length_le {l : List String} {p q : String → Bool} (h : ∀ x ∈ l, p x = true → q x = true) :
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

theorem filter_length_lt {l : List String} {p q : String → Bool} (h : ∀ x ∈ l, p x = true → q x = true)
    {a : String} (ha : a ∈ l) (hq : q a = true) (hp : p a = false) :
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

theorem Source.level_le (F : Source) (n : String) : F.level n ≤ F.defs.length := by
  unfold Source.level; omega

theorem Source.edge_names {F : Source} {a b : String} (e : F.Edge a b) : a ∈ F.names := by
  obtain ⟨d, hd, _⟩ := e
  exact Source.mem_names (by simp [Source.defined, hd])

/-- A reference never goes down a level. -/
theorem Source.level_edge {F : Source} {a b : String} (e : F.Edge a b) : F.level a ≤ F.level b := by
  classical
  have := filter_length_le (l := F.names) (p := fun x => decide (F.Reaches b x))
    (q := fun x => decide (F.Reaches a x)) (fun x _ h => by simpa using (Source.Reaches.single e).trans (by simpa using h))
  have hlen := List.length_filter_le (fun x => decide (F.Reaches a x)) F.names
  rw [Source.length_names] at hlen
  unfold Source.level
  omega

/-- A reference to a definition that doesn't refer back goes up a level. -/
theorem Source.level_edge_lt {F : Source} {a b : String} (e : F.Edge a b) (h : ¬ F.Reaches b a) :
    F.level a < F.level b := by
  classical
  have := filter_length_lt (l := F.names) (p := fun x => decide (F.Reaches b x))
    (q := fun x => decide (F.Reaches a x)) (fun x _ h => by simpa using (Source.Reaches.single e).trans (by simpa using h))
    (Source.edge_names e) (by simpa using Source.Reaches.refl a) (by simpa using h)
  have hlen := List.length_filter_le (fun x => decide (F.Reaches a x)) F.names
  rw [Source.length_names] at hlen
  unfold Source.level
  omega

/-! ## The arguments instances can have -/

/-- Each argument written in a definition, with the definition's parameters. -/
def Source.argExprs (F : Source) : List (List String × Tm) :=
  F.defs.flatMap fun d => d.body.refs.flatMap fun r => r.2.map fun e => (d.params, e)

/-- The parts of `ts`, and the parameters of the definitions as types. -/
def Source.base (F : Source) (ts : List Tm) : List Tm :=
  ts.flatMap Tm.subterms ++ (F.defs.flatMap fun d => d.body.vars).map .var

/-- The arguments of instances up to level `k`. -/
def Source.argSet (F : Source) (ts : List Tm) : Nat → List Tm
  | 0 => F.base ts
  | k + 1 => F.argSet ts k ++ F.argExprs.flatMap fun (ps, e) =>
      (tuples (F.argSet ts k) ps.length).map fun as => e.subst (ps.zip as)

/-- The most arguments a name is given, in `ts` or in a definition. -/
def Source.arity (F : Source) (ts : List Tm) : Nat :=
  ((ts.flatMap Tm.refs ++ F.defs.flatMap fun d => d.body.refs).map (·.2.length)).foldr max 0

/-- The most parameters of a definition. -/
def Source.paramMax (F : Source) : Nat := (F.defs.map (·.params.length)).foldr max 0

/-- Every instance a definition with arguments of the last level could be. -/
def Source.universe (F : Source) (ts : List Tm) : List Inst :=
  F.names.flatMap fun n => (tuples (F.argSet ts F.defs.length) (F.arity ts)).map (n, ·)

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

/-! ## The invariant -/

/-- An instance's arguments are of its level, and not too many. -/
def Source.Good (F : Source) (ts : List Tm) (i : Inst) : Prop :=
  (∀ a ∈ i.2, a ∈ F.argSet ts (F.level i.1)) ∧ i.2.length ≤ F.arity ts

/-- An instance, and the instances in its arguments, are `Good`. -/
def Source.Inv (F : Source) (ts : List Tm) (i : Inst) : Prop :=
  ∀ j ∈ (Tm.ref i.1 i.2).refs, F.defined j.1 = true → F.Good ts j

theorem Source.edges_arity {F : Source} {ts : List Tm} {d : Def} (hd : d ∈ F.defs) {r : String × List Tm}
    (hr : r ∈ d.body.refs) : r.2.length ≤ F.arity ts := by
  apply le_foldr_max
  simp only [List.mem_map, List.mem_append, List.mem_flatMap]
  exact ⟨r, Or.inr ⟨d, hd, hr⟩, rfl⟩

/-- The step: the instances an instance's type mentions are `Good`. -/
theorem Source.good_succ {F : Source} {ts : List Tm} (hG : GrowthOk F) {n : String} {args : List Tm} {d : Def}
    (hd : F.lookup n = some d) (hgood : F.Good ts (n, args)) (hinv : F.Inv ts (n, args)) :
    ∀ j ∈ (d.body.subst (d.params.zip args)).refs, F.defined j.1 = true → F.Good ts j := by
  rintro ⟨m, es'⟩ hj hdef
  have hdm := (Source.lookup_mem hd).1
  rcases Tm.refs_subst _ d.body hj with ⟨es, hes, rfl⟩ | ⟨v, _, u, hu, hmu⟩
  · have edge : F.Edge n m := ⟨d, hd, es, Source.mem_edges.2 ⟨hes, hdef⟩⟩
    refine ⟨?_, by simpa using Source.edges_arity (ts := ts) hdm hes⟩
    simp only [List.mem_map]
    rintro a ⟨e, he, rfl⟩
    by_cases hr : F.Reaches m n
    · have hvar := hG n d hd m es (Source.mem_edges.2 ⟨hes, hdef⟩) hr e he
      cases e with
      | var v =>
        simp only [Tm.subst_var]
        cases hl : (d.params.zip args).lookup v with
        | some u =>
          exact F.argSet_mono ts (Source.level_edge edge) (hgood.1 u (lookup_zip_mem _ _ hl))
        | none =>
          apply F.base_sub ts
          simp only [Source.base, List.mem_append, List.mem_map, List.mem_flatMap, Option.getD_none]
          exact Or.inr ⟨v, ⟨d, hdm, Tm.refs_args_vars d.body hes (.var v) he v (by simp)⟩, rfl⟩
      | ref _ _ => simp [Tm.isVar] at hvar
      | node _ _ => simp [Tm.isVar] at hvar
    · have hlt := Source.level_edge_lt edge hr
      rw [zip_take]
      apply F.argSet_mono ts (show F.level n + 1 ≤ F.level m by omega)
      apply Source.argSet_step
      · simp only [Source.argExprs, List.mem_flatMap, List.mem_map]
        exact ⟨d, hdm, (m, es), hes, e, he, rfl⟩
      · simp only [List.length_take]; exact Nat.min_le_left _ _
      · intro a ha
        exact hgood.1 a (List.mem_of_mem_take ha)
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
    refine ⟨fun a ha => F.base_sub ts _ ?_, ?_⟩
    · simp only [Source.base, List.mem_append, List.mem_flatMap]
      exact Or.inl ⟨t, ht, Tm.refs_args_subterms t hjt a ha⟩
    · apply le_foldr_max
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

/-- `argBound b e p k`: the bound on `argSet` at level `k`. -/
def argBound (b e p : Nat) : Nat → Nat
  | 0 => b
  | k + 1 => argBound b e p k + e * (argBound b e p k + 1) ^ p

/--
The number of instances a file `F` can reach from `ts`: definitions times
the lists of at most `arity` arguments from the last level.
-/
def Source.instBound (F : Source) (ts : List Tm) : Nat :=
  F.defs.length * (argBound (F.base ts).length F.argExprs.length F.paramMax F.defs.length + 1) ^ F.arity ts

theorem length_flatMap_le {α β : Type} (l : List α) (f : α → List β) (c : Nat) (h : ∀ x ∈ l, (f x).length ≤ c) :
    (l.flatMap f).length ≤ l.length * c := by
  induction l with
  | nil => simp
  | cons a l ih =>
    have h1 := h a (by simp)
    have h2 := ih (fun x hx => h x (List.mem_cons_of_mem _ hx))
    simp only [List.flatMap_cons, List.length_append, List.length_cons, Nat.succ_mul]
    omega

theorem Source.argExprs_params {F : Source} {ps : List String} {e : Tm} (h : (ps, e) ∈ F.argExprs) :
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
          Nat.pow_le_pow_right (by omega) (Source.argExprs_params he)
        _ ≤ _ := Nat.pow_le_pow_left (by omega) _
    omega

theorem Source.length_universe (F : Source) (ts : List Tm) : (F.universe ts).length ≤ F.instBound ts := by
  unfold Source.universe Source.instBound
  have := length_flatMap_le F.names (fun n => (tuples (F.argSet ts F.defs.length) (F.arity ts)).map (n, ·))
    ((argBound (F.base ts).length F.argExprs.length F.paramMax F.defs.length + 1) ^ F.arity ts) (by
      intro n _
      simp only [List.length_map]
      exact Nat.le_trans (length_tuples_le _ _)
        (Nat.pow_le_pow_left (by have := F.length_argSet ts F.defs.length; omega) _))
  rwa [Source.length_names] at this

/-! ## Finitely many instances -/

/-- Every instance reachable from `ts` is in `universe`. -/
theorem Source.reach_universe {F : Source} {ts : List Tm} (hG : GrowthOk F) {i : Inst} (h : Reach F ts i) :
    i ∈ F.universe ts := by
  obtain ⟨hdef, hinv⟩ := Source.reach_inv hG h
  obtain ⟨hargs, hlen⟩ := hinv i (by simp) hdef
  simp only [Source.universe, List.mem_flatMap, List.mem_map]
  exact ⟨i.1, Source.mem_names hdef, i.2,
    mem_tuples _ _ _ hlen fun a ha => F.argSet_mono ts (F.level_le i.1) (hargs a ha), rfl⟩

/--
**I6.** In a file with regular generics (§9.10), the instances reachable
from any types are finitely many: at most `instBound`.
-/
theorem Source.reach_finite {F : Source} (hG : GrowthOk F) (ts : List Tm) :
    ∃ L : List Inst, L.length ≤ F.instBound ts ∧ ∀ i, Reach F ts i → i ∈ L :=
  ⟨F.universe ts, F.length_universe ts, fun _ h => Source.reach_universe hG h⟩

/-- **I6** for every file that passes `check` (spec §14). -/
theorem check_finite {F : Source} (h : check F = .ok ()) (ts : List Tm) :
    ∃ L : List Inst, L.length ≤ F.instBound ts ∧ ∀ i, Reach F ts i → i ∈ L :=
  Source.reach_finite (checkGrowth_ok (check_growth h)) ts


/-! ## Why the rule for groups is needed: the doubling example of §9.10 -/

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

/-- Every other rule holds: without §9.10's rule for groups, `check` accepts it. -/
theorem doubling_checks_without_groups : (check doubling (groups := false)).toBool = true := by decide

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
**Without §9.10's rule for groups, instances can be infinitely many**: the
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
