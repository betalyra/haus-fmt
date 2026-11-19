import Haus.Linear.Parser

/-!
# Reasoning about steps

`Spec m t S F`: run on `t`, the counting parser `m` either returns `a` with
the rest `t'` after `c` steps, and `S a t' c` holds, or fails after `c`
steps, and `F c` holds. The rules below follow the structure of a `do`
block: the steps of a sequence are the sum of its parts' steps.
-/

namespace Haus.Linear
open Haus Parser

def Spec {α : Type} (m : PC α) (t : Text) (S : α → Text → Nat → Prop) (F : Nat → Prop) : Prop :=
  match res m t with
  | .ok (a, t') => S a t' (cost m t)
  | .error _ => F (cost m t)

variable {α β : Type}

theorem spec_bind {m : PC α} {k : α → PC β} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop}
    {S2 : β → Text → Nat → Prop} {F2 : Nat → Prop} (h : Spec m t S F)
    (hk : ∀ a t' c, S a t' c → Spec (k a) t' (fun b u c' => S2 b u (c + c')) (fun c' => F2 (c + c')))
    (hf : ∀ c, F c → F2 c) : Spec (m >>= k) t S2 F2 := by
  unfold Spec at h ⊢
  rw [res_bind, cost_bind]
  rcases hm : res m t with e | ⟨a, t'⟩
  · rw [hm] at h; exact hf _ h
  · rw [hm] at h
    have := hk a t' _ h
    unfold Spec at this
    simp only
    split <;> rename_i heq <;> rw [heq] at this <;> exact this

theorem spec_mono {m : PC α} {t : Text} {S S' : α → Text → Nat → Prop} {F F' : Nat → Prop}
    (h : Spec m t S F) (hS : ∀ a u c, S a u c → S' a u c) (hF : ∀ c, F c → F' c) : Spec m t S' F' := by
  unfold Spec at h ⊢
  split <;> rename_i heq <;> rw [heq] at h
  · exact hS _ _ _ h
  · exact hF _ h

theorem spec_pure {a : α} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop} (h : S a t 0) :
    Spec (pure a : PC α) t S F := h

theorem spec_tick {n : Nat} {t : Text} {S : Unit → Text → Nat → Prop} {F : Nat → Prop} (h : S () t n) :
    Spec (tick n) t S F := h

theorem spec_get {t : Text} {S : Text → Text → Nat → Prop} {F : Nat → Prop} (h : S t t 0) :
    Spec (get : PC Text) t S F := h

theorem spec_set {s t : Text} {S : Unit → Text → Nat → Prop} {F : Nat → Prop} (h : S () s 0) :
    Spec (set s : PC Unit) t S F := h

theorem spec_ite {c : Prop} [Decidable c] {x y : PC α} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop}
    (h1 : c → Spec x t S F) (h2 : ¬ c → Spec y t S F) : Spec (if c then x else y) t S F := by
  by_cases hc : c
  · simpa [hc] using h1 hc
  · simpa [hc] using h2 hc

theorem spec_failC {code : Code} {r : String} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop} (h : F 1) :
    Spec (failC code r : PC α) t S F := h

theorem spec_failAtC {code : Code} {r : String} {u t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop}
    (h : F 1) : Spec (failAtC code r u : PC α) t S F := h

/-- A lifted reference function: its result, and its steps. -/
theorem spec_liftP {p : P α} {c : Text → Nat} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop}
    (h1 : ∀ a t', p.run t = .ok (a, t') → S a t' (c t)) (h2 : ∀ e, p.run t = .error e → F (c t)) :
    Spec (liftP p c) t S F := by
  unfold Spec
  split <;> rename_i heq
  · exact h1 _ _ heq
  · exact h2 _ heq

theorem spec_tick_bind {n : Nat} {k : Unit → PC β} {t : Text} {S : β → Text → Nat → Prop} {F : Nat → Prop}
    (h : Spec (k ()) t (fun b u c => S b u (n + c)) (fun c => F (n + c))) : Spec (tick n >>= k) t S F :=
  spec_bind (S := fun _ u c => u = t ∧ c = n) (F := fun _ => False) (spec_tick ⟨rfl, rfl⟩)
    (fun _ _ _ ⟨hu, hc⟩ => by subst hu hc; exact h) (fun _ h => h.elim)

theorem spec_get_bind {k : Text → PC β} {t : Text} {S : β → Text → Nat → Prop} {F : Nat → Prop}
    (h : Spec (k t) t S F) : Spec ((get : PC Text) >>= k) t S F :=
  spec_bind (S := fun x u c => x = t ∧ u = t ∧ c = 0) (F := fun _ => False) (spec_get ⟨rfl, rfl, rfl⟩)
    (fun _ _ _ ⟨hx, hu, hc⟩ => by subst hx hu hc; simpa using h) (fun _ h => h.elim)

theorem spec_set_bind {s : Text} {k : Unit → PC β} {t : Text} {S : β → Text → Nat → Prop} {F : Nat → Prop}
    (h : Spec (k ()) s S F) : Spec ((set s : PC Unit) >>= k) t S F :=
  spec_bind (S := fun _ u c => u = s ∧ c = 0) (F := fun _ => False) (spec_set ⟨rfl, rfl⟩)
    (fun _ _ _ ⟨hu, hc⟩ => by subst hu hc; simpa using h) (fun _ h => h.elim)

/-- `f <$> m`, as `return f (← m)` is written. -/
theorem spec_map {m : PC α} {f : α → β} {t : Text} {S : α → Text → Nat → Prop} {F : Nat → Prop}
    {S2 : β → Text → Nat → Prop} (h : Spec m t S F) (hS : ∀ a u c, S a u c → S2 (f a) u c) :
    Spec (m >>= fun a => pure (f a)) t S2 F :=
  spec_bind h (fun a u c ha => spec_pure (by simpa using hS a u c ha)) (fun _ h => h)

end Haus.Linear
