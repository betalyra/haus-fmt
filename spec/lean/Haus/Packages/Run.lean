import Haus.Packages.Resolve

/-!
# Running the resolver's monad, step by step

`go x env s` is what `x : M α` does from the state `s` with the settings
`env`: its result and the state after it. The lemmas here take `go` through
each construct of `M` (`pure`, `bind`, `read`, `get`, `modify`, `throw`,
`try … catch`, `withReader` and `for` over a list), so that properties of
the resolver can be proven a construct at a time (`Haus.Packages.Bounds`,
`Haus.Packages.Reads`).
-/

namespace Haus.Packages

def go {α} (x : M α) (env : Env) (s : St) : Except Err α × St := (((x.run env).run).run s)

section
variable {α β : Type} (env : Env) (s : St)

@[simp] theorem go_pure (a : α) : go (pure a : M α) env s = (.ok a, s) := rfl

theorem go_bind (x : M α) (f : α → M β) :
    go (x >>= f) env s = match go x env s with
      | (.ok a, s') => go (f a) env s'
      | (.error e, s') => (.error e, s') := by
  simp only [go, bind, ReaderT.bind, ReaderT.run, ExceptT.run, ExceptT.bind, ExceptT.mk, ExceptT.bindCont,
    StateT.run, StateT.bind]
  rcases h : (x env) s with ⟨r, s'⟩
  cases r <;> rfl

theorem go_map (f : α → β) (x : M α) :
    go (f <$> x) env s = match go x env s with
      | (.ok a, s') => (.ok (f a), s')
      | (.error e, s') => (.error e, s') := by
  rw [← bind_pure_comp, go_bind]
  rcases go x env s with ⟨r, s'⟩
  cases r <;> rfl

theorem go_seqRight (x : M α) (y : M β) :
    go (x *> y) env s = match go x env s with
      | (.ok _, s') => go y env s'
      | (.error e, s') => (.error e, s') := by
  rw [seqRight_eq_bind, go_bind]

@[simp] theorem go_look {β} (g : Tree → β) : go (look g) env s = (.ok (g env.tree), s) := rfl
@[simp] theorem go_ask {β} (g : Env → β) : go (ask g) env s = (.ok (g env), s) := rfl
@[simp] theorem go_cfg : go cfg env s = (.ok env.config, s) := rfl

@[simp] theorem go_read : go (read : M Env) env s = (.ok env, s) := rfl
@[simp] theorem go_get : go (get : M St) env s = (.ok s, s) := rfl
@[simp] theorem go_modify (f : St → St) : go (modify f : M Unit) env s = (.ok (), f s) := rfl
@[simp] theorem go_throw (e : Err) : go (throw e : M α) env s = (.error e, s) := rfl
@[simp] theorem go_fail (c : Code) (m : String) : go (fail c m : M α) env s = (.error ⟨c, m⟩, s) := rfl

theorem go_tryCatch (x : M α) (h : Err → M α) :
    go (tryCatch x h) env s = match go x env s with
      | (.error e, s') => go (h e) env s'
      | r => r := by
  show ((ExceptT.tryCatch (x env) fun e => h e env).run).run s = _
  simp only [go, ExceptT.tryCatch, ExceptT.run, ExceptT.mk, StateT.run, bind, StateT.bind, ReaderT.run]
  rcases hx : (x env) s with ⟨r, s'⟩
  cases r <;> rfl

@[simp] theorem go_withReader (f : Env → Env) (x : M α) : go (withReader f x) env s = go x (f env) s := rfl

end

end Haus.Packages

namespace Haus.Packages

/-! ## Triples

`Triple env P x Q E`: from a state with `P`, `x` ends in a state with
`Q a` when it returns `a`, and with `E` when it fails. An invariant `I` is
`Triple env I x (fun _ => I) I`.
-/

def Triple {α} (env : Env) (P : St → Prop) (x : M α) (Q : α → St → Prop) (E : St → Prop) : Prop :=
  ∀ s, P s → match go x env s with
    | (.ok a, s') => Q a s'
    | (.error _, s') => E s'

namespace Triple
variable {α β γ : Type} {env : Env} {P P' : St → Prop} {Q Q' : α → St → Prop} {E E' : St → Prop}

theorem mono {x : M α} (h : Triple env P x Q E) (hP : ∀ s, P' s → P s)
    (hQ : ∀ a s, Q a s → Q' a s) (hE : ∀ s, E s → E' s) : Triple env P' x Q' E' := by
  intro s hs
  have := h s (hP s hs)
  split <;> rename_i heq <;> rw [heq] at this
  · exact hQ _ _ this
  · exact hE _ this

theorem pure {a : α} (h : ∀ s, P s → Q a s) : Triple env P (Pure.pure a) Q E := fun s hs => h s hs

theorem bind {x : M α} {f : α → M β} {R : α → St → Prop} {Q : β → St → Prop}
    (hx : Triple env P x R E) (hf : ∀ a, Triple env (R a) (f a) Q E) : Triple env P (x >>= f) Q E := by
  intro s hs
  rw [go_bind]
  have := hx s hs
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r with
  | error e => exact id
  | ok a => exact hf a s'

theorem map {x : M α} {f : α → β} {Q : β → St → Prop}
    (h : Triple env P x (fun a => Q (f a)) E) : Triple env P (f <$> x) Q E := by
  rw [← bind_pure_comp]
  exact bind h fun a => pure fun _ h => h

theorem seqRight {x : M α} {y : M β} {R : α → St → Prop} {Q : β → St → Prop}
    (hx : Triple env P x R E) (hy : ∀ a, Triple env (R a) y Q E) : Triple env P (x *> y) Q E := by
  rw [seqRight_eq_bind]
  exact bind hx hy

theorem bind_read {f : Env → M β} {Q : β → St → Prop} (h : Triple env P (f env) Q E) :
    Triple env P (read >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_look {δ} {g : Tree → δ} {f : δ → M β} {Q : β → St → Prop} (h : Triple env P (f (g env.tree)) Q E) :
    Triple env P (look g >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_ask {δ} {g : Env → δ} {f : δ → M β} {Q : β → St → Prop} (h : Triple env P (f (g env)) Q E) :
    Triple env P (ask g >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_cfg {f : Config → M β} {Q : β → St → Prop} (h : Triple env P (f env.config) Q E) :
    Triple env P (cfg >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_get {f : St → M β} {Q : β → St → Prop} (h : ∀ s₀, Triple env (fun s => P s ∧ s = s₀) (f s₀) Q E) :
    Triple env P (get >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s s ⟨hs, rfl⟩

theorem bind_modify {g : St → St} {f : Unit → M β} {Q : β → St → Prop} (P' : St → Prop)
    (hg : ∀ s, P s → P' (g s)) (h : Triple env P' (f ()) Q E) : Triple env P (_root_.modify g >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h _ (hg s hs)

theorem modify {g : St → St} {Q : Unit → St → Prop} (hg : ∀ s, P s → Q () (g s)) :
    Triple env P (_root_.modify g : M Unit) Q E := by
  intro s hs; exact hg s hs

theorem throw {e : Err} (h : ∀ s, P s → E s) : Triple env P (MonadExcept.throw e : M α) Q E := fun s hs => h s hs

theorem fail {c : Code} {m : String} (h : ∀ s, P s → E s) : Triple env P (Haus.Packages.fail c m : M α) Q E :=
  fun s hs => h s hs

theorem tryCatch {x : M α} {h : Err → M α} {R : St → Prop}
    (hx : Triple env P x Q R) (hh : ∀ e, Triple env R (h e) Q E) : Triple env P (tryCatch x h) Q E := by
  intro s hs
  rw [go_tryCatch]
  have := hx s hs
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r with
  | error e => exact hh e s'
  | ok a => exact id

theorem withReader {f : Env → Env} {x : M α} (h : Triple (f env) P x Q E) :
    Triple env P (withReader f x) Q E := fun s hs => by rw [go_withReader]; exact h s hs

/--
A `for` loop over a list, with an invariant `Inv` on what is left of the list,
the loop's value and the state.
-/
theorem forIn {xs : List γ} {b : β} {f : γ → β → M (ForInStep β)} {Q : β → St → Prop}
    (Inv : List γ → β → St → Prop)
    (h : ∀ a rest b, a :: rest <:+ xs → Triple env (Inv (a :: rest) b) (f a b)
      (fun r s => match r with
        | .yield b' => Inv rest b' s
        | .done b' => Q b' s) E)
    (hnil : ∀ b s, Inv [] b s → Q b s) :
    Triple env (Inv xs b) (ForIn.forIn xs b f) Q E := by
  suffices ∀ ys, ys <:+ xs → ∀ b, Triple env (Inv ys b) (ForIn.forIn ys b f) Q E from this xs (List.suffix_refl _) b
  intro ys
  induction ys with
  | nil => intro _ b; rw [List.forIn_nil]; exact pure (hnil b)
  | cons a rest ih =>
    intro hs b
    rw [List.forIn_cons]
    refine bind (h a rest b hs) fun r => ?_
    cases r with
    | done b' => exact pure fun _ h => h
    | yield b' => exact ih ((List.suffix_cons a rest).trans hs) b'

theorem bind_get' {f : St → M β} {Q : β → St → Prop} (h : ∀ s₀, P s₀ → Triple env P (f s₀) Q E) :
    Triple env P (get >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs s hs

theorem bind_modify' {g : St → St} {f : Unit → M β} {Q : β → St → Prop}
    (hg : ∀ s, P s → P (g s)) (h : Triple env P (f ()) Q E) : Triple env P (_root_.modify g >>= f) Q E :=
  bind_modify P hg h

/-- A step whose postcondition is the precondition and something of its value. -/
theorem bind_keeps {x : M α} {f : α → M β} {R : α → Prop} {Q : β → St → Prop}
    (hx : Triple env P x (fun a s => P s ∧ R a) E) (hf : ∀ a, R a → Triple env P (f a) Q E) :
    Triple env P (x >>= f) Q E :=
  bind hx fun a s hs => hf a hs.2 s hs.1

theorem pre_and {x : M α} {A : Prop} (h : A → Triple env P x Q E) : Triple env (fun s => P s ∧ A) x Q E :=
  fun s hs => h hs.2 s hs.1

theorem bind_throw {e : Err} {f : α → M β} {Q : β → St → Prop} (h : ∀ s, P s → E s) :
    Triple env P (MonadExcept.throw e >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_fail {c : Code} {m : String} {f : α → M β} {Q : β → St → Prop} (h : ∀ s, P s → E s) :
    Triple env P (Haus.Packages.fail c m >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

theorem bind_pure {a : α} {f : α → M β} {Q : β → St → Prop} (h : Triple env P (f a) Q E) :
    Triple env P (Pure.pure a >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs

/-- What an invariant gives at the end, whatever the outcome. -/
theorem final {x : M α} {R : St → Prop} (h : Triple env P x (fun _ => R) R) {s : St} (hs : P s) :
    R (go x env s).2 := by
  have := h s hs
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r <;> exact id

theorem trivial {x : M α} : Triple env (fun _ => True) x (fun _ _ => True) (fun _ => True) := by
  intro s _
  rcases go x env s with ⟨r, s'⟩
  cases r <;> exact True.intro

theorem keeps_true {x : M α} (h : Triple env P x (fun _ s => P s) E) : Triple env P x (fun _ s => P s ∧ True) E :=
  mono h (fun _ h => h) (fun _ _ h => ⟨h, True.intro⟩) (fun _ h => h)

end Triple

end Haus.Packages

namespace Haus.Packages

/-- Runs `go` through a program's constructs, splitting on every `match` and `if`. -/
macro "run_go" : tactic => `(tactic| repeat (first
  | simp only [go_bind, go_map, go_seqRight, go_read, go_get, go_modify, go_pure, go_throw, go_fail,
      go_look, go_ask, go_cfg]
  | split))

theorem lookup_mem {α β} [BEq α] [LawfulBEq α] {l : List (α × β)} {a : α} {b : β} (h : l.lookup a = some b) :
    (a, b) ∈ l := by
  induction l with
  | nil => simp at h
  | cons x xs ih =>
    obtain ⟨k, v⟩ := x
    simp only [List.lookup_cons] at h
    split at h
    · rename_i hk
      simp at h hk; subst h; subst hk; exact List.mem_cons_self
    · exact List.mem_cons_of_mem _ (ih h)

end Haus.Packages
