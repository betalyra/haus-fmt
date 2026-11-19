import Haus.Parser

/-!
# Parsers that count their steps (plan step P1, for the parser)

`PC α` is the reference parser's monad `P α` with a step count next to the
result: run on the rest of the input, it returns what `P` returns and the
number of steps it took, also when it fails. Steps are only ever added
(`tick`), never read, so the result never depends on them.

`Agrees m p`: the counting parser `m` returns exactly what `p` returns,
values, rest and errors alike. The lemmas below compose it.

**The cost model.** The input is an array: the rest of the input is a
position in it, so `get`, `set`, skipping a character and an error's
position (`Error.at`, the characters left) take one step. A function on
lists (scanning, copying, reversing, comparing) takes one step per element
it visits, plus one. Arithmetic on natural numbers takes one step per
operation (the only large numbers are number literals, at most
`maxNumberLength` characters, §7). An error message is built at most once
per parse and is not counted beyond one step.
-/

namespace Haus.Linear
open Haus Parser

/-- A parser that counts its steps. -/
def PC (α : Type) : Type := Text → Except Error (α × Text) × Nat

namespace PC

def ret {α : Type} (a : α) : PC α := fun t => (.ok (a, t), 0)

def seq {α β : Type} (m : PC α) (k : α → PC β) : PC β := fun t =>
  match m t with
  | (.ok (a, t'), c) => ((k a t').1, c + (k a t').2)
  | (.error e, c) => (.error e, c)

instance : Monad PC where
  pure := PC.ret
  bind := PC.seq

instance : MonadStateOf Text PC where
  get := fun t => (.ok (t, t), 0)
  set s := fun _ => (.ok ((), s), 0)
  modifyGet f := fun t => (.ok ((f t).1, (f t).2), 0)

instance : MonadExceptOf Error PC where
  throw e := fun _ => (.error e, 0)
  tryCatch m h := fun t =>
    match m t with
    | (.error e, c) => ((h e t).1, c + (h e t).2)
    | r => r

end PC

/-- The result, as `P` would return it. -/
def res {α : Type} (m : PC α) (t : Text) : Except Error (α × Text) := (m t).1

/-- The steps taken. -/
def cost {α : Type} (m : PC α) (t : Text) : Nat := (m t).2

/-- Takes `n` steps. -/
def tick (n : Nat) : PC Unit := fun t => (.ok ((), t), n)


@[simp] theorem res_pure {α : Type} (a : α) (t : Text) : res (pure a : PC α) t = .ok (a, t) := rfl
@[simp] theorem cost_pure {α : Type} (a : α) (t : Text) : cost (pure a : PC α) t = 0 := rfl

theorem bind_apply {α β : Type} (m : PC α) (k : α → PC β) (t : Text) :
    (m >>= k) t = match m t with
      | (.ok (a, t'), c) => ((k a t').1, c + (k a t').2)
      | (.error e, c) => (.error e, c) := rfl

@[simp] theorem res_bind {α β : Type} (m : PC α) (k : α → PC β) (t : Text) :
    res (m >>= k) t = match res m t with
      | .error e => .error e
      | .ok v => res (k v.1) v.2 := by
  simp only [res, bind_apply]
  rcases m t with ⟨_ | ⟨a, t'⟩, c⟩ <;> rfl

@[simp] theorem cost_bind {α β : Type} (m : PC α) (k : α → PC β) (t : Text) :
    cost (m >>= k) t = cost m t + match res m t with
      | .ok (a, t') => cost (k a) t'
      | .error _ => 0 := by
  simp only [res, cost, bind_apply]
  rcases m t with ⟨_ | ⟨a, t'⟩, c⟩ <;> rfl

@[simp] theorem res_tick (n : Nat) (t : Text) : res (tick n) t = .ok ((), t) := rfl
@[simp] theorem cost_tick (n : Nat) (t : Text) : cost (tick n) t = n := rfl
@[simp] theorem res_get (t : Text) : res (get : PC Text) t = .ok (t, t) := rfl
@[simp] theorem cost_get (t : Text) : cost (get : PC Text) t = 0 := rfl
@[simp] theorem res_set (s t : Text) : res (set s : PC Unit) t = .ok ((), s) := rfl
@[simp] theorem cost_set (s t : Text) : cost (set s : PC Unit) t = 0 := rfl
@[simp] theorem res_throw {α : Type} (e : Error) (t : Text) : res (throw e : PC α) t = .error e := rfl
@[simp] theorem cost_throw {α : Type} (e : Error) (t : Text) : cost (throw e : PC α) t = 0 := rfl
@[simp] theorem res_modifyGet {α : Type} (f : Text → α × Text) (t : Text) :
    res (modifyGet f : PC α) t = .ok ((f t).1, (f t).2) := rfl
@[simp] theorem cost_modifyGet {α : Type} (f : Text → α × Text) (t : Text) :
    cost (modifyGet f : PC α) t = 0 := rfl

@[simp] theorem res_ite {α : Type} (c : Prop) [Decidable c] (x y : PC α) (t : Text) :
    res (if c then x else y) t = if c then res x t else res y t := by
  split <;> rfl
@[simp] theorem cost_ite {α : Type} (c : Prop) [Decidable c] (x y : PC α) (t : Text) :
    cost (if c then x else y) t = if c then cost x t else cost y t := by
  split <;> rfl

theorem res_map {α β : Type} (f : α → β) (x : PC α) (t : Text) :
    res (f <$> x) t = (res x t).map fun (a, t') => (f a, t') := by
  show res (x >>= fun a => pure (f a)) t = _
  simp only [res_bind, res_pure]
  cases res x t <;> rfl

theorem cost_map {α β : Type} (f : α → β) (x : PC α) (t : Text) : cost (f <$> x) t = cost x t := by
  show cost (x >>= fun a => pure (f a)) t = _
  simp only [cost_bind, cost_pure]
  split <;> rfl

/-- The counting parser `m` returns what `p` returns. -/
def Agrees {α : Type} (m : PC α) (p : P α) : Prop := ∀ t, res m t = p.run t

end Haus.Linear
