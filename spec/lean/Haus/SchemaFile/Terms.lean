import Haus.SchemaFile.Syntax

/-!
# Lemmas about types as written

What substitution does to the names a type mentions (`Tm.refs_subst`), where
the arguments of those names come from (`Tm.refs_args_subterms`,
`Tm.refs_args_vars`), and lists of bounded length over a list (`tuples`),
for the proof that instances are finite (`Haus.SchemaFile.Finite`).
-/

namespace Haus.SchemaFile

@[simp] theorem Tm.refs_var (p : String) : (Tm.var p).refs = [] := by simp [Tm.refs]
@[simp] theorem Tm.refs_ref (n : String) (as : List Tm) :
    (Tm.ref n as).refs = (n, as) :: as.flatMap Tm.refs := by simp [Tm.refs, Tm.refsList_eq]
@[simp] theorem Tm.refs_node (l : Label) (ks : List Tm) :
    (Tm.node l ks).refs = ks.flatMap Tm.refs := by simp [Tm.refs, Tm.refsList_eq]
@[simp] theorem Tm.vars_var (p : String) : (Tm.var p).vars = [p] := by simp [Tm.vars]
@[simp] theorem Tm.vars_ref (n : String) (as : List Tm) :
    (Tm.ref n as).vars = as.flatMap Tm.vars := by simp [Tm.vars, Tm.varsList_eq]
@[simp] theorem Tm.vars_node (l : Label) (ks : List Tm) :
    (Tm.node l ks).vars = ks.flatMap Tm.vars := by simp [Tm.vars, Tm.varsList_eq]
@[simp] theorem Tm.subterms_var (p : String) : (Tm.var p).subterms = [.var p] := by simp [Tm.subterms]
@[simp] theorem Tm.subterms_ref (n : String) (as : List Tm) :
    (Tm.ref n as).subterms = .ref n as :: as.flatMap Tm.subterms := by simp [Tm.subterms, Tm.subtermsList_eq]
@[simp] theorem Tm.subterms_node (l : Label) (ks : List Tm) :
    (Tm.node l ks).subterms = .node l ks :: ks.flatMap Tm.subterms := by simp [Tm.subterms, Tm.subtermsList_eq]
@[simp] theorem Tm.subst_var (σ : Subst) (p : String) : (Tm.var p).subst σ = (σ.lookup p).getD (.var p) := by
  simp [Tm.subst]
@[simp] theorem Tm.subst_ref (σ : Subst) (n : String) (as : List Tm) :
    (Tm.ref n as).subst σ = .ref n (as.map (Tm.subst σ)) := by simp [Tm.subst, Tm.substList_eq]
@[simp] theorem Tm.subst_node (σ : Subst) (l : Label) (ks : List Tm) :
    (Tm.node l ks).subst σ = .node l (ks.map (Tm.subst σ)) := by simp [Tm.subst, Tm.substList_eq]

theorem Tm.mem_subterms_self (t : Tm) : t ∈ t.subterms := by
  cases t <;> simp

/-- The names inside a name's arguments are names of the type around it. -/
theorem Tm.refs_ref_sub : ∀ (u : Tm) {m : String} {es : List Tm}, (m, es) ∈ u.refs →
    ∀ j ∈ (Tm.ref m es).refs, j ∈ u.refs
  | .var _, _, _, h, _, _ => by simp at h
  | .ref n as, m, es, h, j, hj => by
    simp only [Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap] at h
    rcases h with ⟨rfl, rfl⟩ | ⟨a, ha, h⟩
    · exact hj
    · have := Tm.refs_ref_sub a h j hj
      simp only [Tm.refs_ref, List.mem_cons, List.mem_flatMap]
      exact Or.inr ⟨a, ha, this⟩
  | .node l ks, m, es, h, j, hj => by
    simp only [Tm.refs_node, List.mem_flatMap] at h ⊢
    obtain ⟨a, ha, h⟩ := h
    exact ⟨a, ha, Tm.refs_ref_sub a h j hj⟩
termination_by u => sizeOf u
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

/--
The names in a type after substitution: those written in it, their arguments
substituted, and those in the types substituted for its parameters.
-/
theorem Tm.refs_subst (σ : Subst) : ∀ (t : Tm) {m : String} {es' : List Tm},
    (m, es') ∈ (t.subst σ).refs →
    (∃ es, (m, es) ∈ t.refs ∧ es' = es.map (Tm.subst σ)) ∨
    (∃ v ∈ t.vars, ∃ u, σ.lookup v = some u ∧ (m, es') ∈ u.refs)
  | .var p, m, es', h => by
    simp only [Tm.subst_var] at h
    cases hl : σ.lookup p with
    | none => simp [hl] at h
    | some u => exact Or.inr ⟨p, by simp, u, hl, by simpa [hl] using h⟩
  | .ref n as, m, es', h => by
    simp only [Tm.subst_ref, Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap,
      List.mem_map] at h
    rcases h with ⟨rfl, rfl⟩ | ⟨_, ⟨a, ha, rfl⟩, h⟩
    · exact Or.inl ⟨as, by simp, rfl⟩
    · rcases Tm.refs_subst σ a h with ⟨es, hes, rfl⟩ | ⟨v, hv, u, hu, h⟩
      · exact Or.inl ⟨es, by simp only [Tm.refs_ref, List.mem_cons, List.mem_flatMap]; exact Or.inr ⟨a, ha, hes⟩, rfl⟩
      · exact Or.inr ⟨v, by simp only [Tm.vars_ref, List.mem_flatMap]; exact ⟨a, ha, hv⟩, u, hu, h⟩
  | .node l ks, m, es', h => by
    simp only [Tm.subst_node, Tm.refs_node, List.mem_flatMap, List.mem_map] at h
    obtain ⟨_, ⟨a, ha, rfl⟩, h⟩ := h
    rcases Tm.refs_subst σ a h with ⟨es, hes, rfl⟩ | ⟨v, hv, u, hu, h⟩
    · exact Or.inl ⟨es, by simp only [Tm.refs_node, List.mem_flatMap]; exact ⟨a, ha, hes⟩, rfl⟩
    · exact Or.inr ⟨v, by simp only [Tm.vars_node, List.mem_flatMap]; exact ⟨a, ha, hv⟩, u, hu, h⟩
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

/-- The arguments of a name in a type are parts of the type. -/
theorem Tm.refs_args_subterms : ∀ (t : Tm) {m : String} {es : List Tm},
    (m, es) ∈ t.refs → ∀ e ∈ es, e ∈ t.subterms
  | .var _, _, _, h, _, _ => by simp at h
  | .ref n as, m, es, h, e, he => by
    simp only [Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap] at h
    rcases h with ⟨rfl, rfl⟩ | ⟨a, ha, h⟩
    · simp only [Tm.subterms_ref, List.mem_cons, List.mem_flatMap]
      exact Or.inr ⟨e, he, Tm.mem_subterms_self e⟩
    · simp only [Tm.subterms_ref, List.mem_cons, List.mem_flatMap]
      exact Or.inr ⟨a, ha, Tm.refs_args_subterms a h e he⟩
  | .node l ks, m, es, h, e, he => by
    simp only [Tm.refs_node, List.mem_flatMap] at h
    obtain ⟨a, ha, h⟩ := h
    simp only [Tm.subterms_node, List.mem_cons, List.mem_flatMap]
    exact Or.inr ⟨a, ha, Tm.refs_args_subterms a h e he⟩
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

/-- The parameters in the arguments of a name in a type are parameters of the type. -/
theorem Tm.refs_args_vars : ∀ (t : Tm) {m : String} {es : List Tm},
    (m, es) ∈ t.refs → ∀ e ∈ es, ∀ v ∈ e.vars, v ∈ t.vars
  | .var _, _, _, h, _, _, _, _ => by simp at h
  | .ref n as, m, es, h, e, he, v, hv => by
    simp only [Tm.refs_ref, List.mem_cons, Prod.mk.injEq, List.mem_flatMap] at h
    simp only [Tm.vars_ref, List.mem_flatMap]
    rcases h with ⟨rfl, rfl⟩ | ⟨a, ha, h⟩
    · exact ⟨e, he, hv⟩
    · exact ⟨a, ha, Tm.refs_args_vars a h e he v hv⟩
  | .node l ks, m, es, h, e, he, v, hv => by
    simp only [Tm.refs_node, List.mem_flatMap] at h
    obtain ⟨a, ha, h⟩ := h
    simp only [Tm.vars_node, List.mem_flatMap]
    exact ⟨a, ha, Tm.refs_args_vars a h e he v hv⟩
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals
    have := List.sizeOf_lt_of_mem ha
    omega

/-- What a parameter is replaced by is one of the arguments. -/
theorem lookup_zip_mem : ∀ (ps : List String) (as : List Tm) {v : String} {u : Tm},
    (ps.zip as).lookup v = some u → u ∈ as
  | [], _, _, _, h => by simp at h
  | _ :: _, [], _, _, h => by simp at h
  | p :: ps, a :: as, v, u, h => by
    simp only [List.zip_cons_cons, List.lookup_cons] at h
    split at h
    · cases h; simp
    · exact List.mem_cons_of_mem _ (lookup_zip_mem ps as h)

/-- Arguments past the parameters are not used. -/
theorem zip_take : ∀ (ps : List String) (as : List Tm), ps.zip as = ps.zip (as.take ps.length)
  | [], _ => by simp
  | _ :: _, [] => by simp
  | p :: ps, a :: as => by simp [zip_take ps as]

/-! ## Lists of bounded length -/

/-- The lists of at most `n` elements of `X`. -/
def tuples (X : List Tm) : Nat → List (List Tm)
  | 0 => [[]]
  | n + 1 => [] :: X.flatMap fun x => (tuples X n).map (x :: ·)

theorem mem_tuples (X : List Tm) : ∀ (n : Nat) (as : List Tm),
    as.length ≤ n → (∀ a ∈ as, a ∈ X) → as ∈ tuples X n
  | 0, as, h, _ => by
    have : as = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this; simp [tuples]
  | n + 1, [], _, _ => by simp [tuples]
  | n + 1, a :: as, h, hX => by
    simp only [tuples, List.mem_cons, List.mem_flatMap, List.mem_map]
    refine Or.inr ⟨a, hX a (by simp), as, mem_tuples X n as (by simp at h; omega) (fun b hb => hX b (by simp [hb])), rfl⟩

theorem length_tuples_le (X : List Tm) : ∀ n : Nat, (tuples X n).length ≤ (X.length + 1) ^ n
  | 0 => by simp [tuples]
  | n + 1 => by
    have ih := length_tuples_le X n
    have h : ∀ Y : List Tm, (Y.flatMap fun x => (tuples X n).map (x :: ·)).length = Y.length * (tuples X n).length := by
      intro Y
      induction Y with
      | nil => simp
      | cons y Y ih => simp [ih, Nat.succ_mul, Nat.add_comm]
    simp only [tuples, List.length_cons, h, Nat.pow_succ]
    have h1 : 1 ≤ (X.length + 1) ^ n := Nat.one_le_pow _ _ (by omega)
    have h2 := Nat.mul_le_mul_left X.length ih
    have h3 : (X.length + 1) ^ n * (X.length + 1) = X.length * (X.length + 1) ^ n + (X.length + 1) ^ n := by
      rw [Nat.mul_succ, Nat.mul_comm]
    omega

end Haus.SchemaFile
