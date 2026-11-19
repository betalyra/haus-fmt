import Haus.Linear.Parser
import Haus.Sound.Monad

/-!
# The counting parser returns what `parse` returns (plan step P3)

`parseC_eq`: `parseC L t` returns exactly `parse L t`, values, errors and
their positions alike. The only change, the trie of keys in `fieldsC`,
answers each duplicate check as the reference's scan does (`mem_keySet`).
Proven by induction on the fuel, all value functions together.
-/

namespace Haus.Linear
open Haus Parser Sound

@[simp] theorem res_failC {α : Type} (c : Code) (r : String) (t : Text) :
    res (failC c r : PC α) t = .error (.at c r t) := rfl
@[simp] theorem res_failAtC {α : Type} (c : Code) (r : String) (u t : Text) :
    res (failAtC c r u : PC α) t = .error (.at c r u) := rfl

/-- The value functions agree at one fuel. -/
structure AgreeAt (L : Limits) (fuel : Nat) : Prop where
  value : ∀ b t, res (valueC L fuel b) t = (value L fuel b).run t
  variant : ∀ b t, res (variantC L fuel b) t = (variant L fuel b).run t
  record : ∀ b t, res (recordC L fuel b) t = (record L fuel b).run t
  fields : ∀ b start acc t, res (fieldsC L fuel b start acc (keySet (acc.map Prod.fst))) t =
    (fields L fuel b start acc).run t
  items : ∀ b close t, res (itemsC L fuel b close) t = (items L fuel b close).run t
  itemsLoop : ∀ b close start acc t, res (itemsLoopC L fuel b close start acc) t =
    (itemsLoop L fuel b close start acc).run t

theorem agreeAt_zero (L : Limits) : AgreeAt L 0 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intros
  · simp [valueC, value]
  · simp [variantC, variant]
  · simp [recordC, record]
  · simp [fieldsC, fields]
  · simp [itemsC, items]
  · simp [itemsLoopC, itemsLoop]

theorem agreeAt_succ (L : Limits) (fuel : Nat) (ih : AgreeAt L fuel) : AgreeAt L (fuel + 1) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro b t
    simp only [valueC, value, res_bind, run_bind, res_tick, res_get, run_get]
    split <;> simp [ih.record, ih.items, ih.variant, numberC, basicStringC, blockStringC, bytesC]
    all_goals (split <;> simp_all)
  · intro b t
    simp only [variantC, variant, res_bind, run_bind, res_tick, res_get, run_get, takeWhileC, res_liftP, run_takeWhile]
    split
    · rename_i heq; rw [heq]
    · rename_i heq; rw [heq]
      split <;> simp only [res_bind, run_bind, ih.items, ih.record, res_set, run_set, res_pure, run_pure]
      all_goals (split <;> simp_all)
  · intro b t
    cases b with
    | zero => simp [recordC, record]
    | succ b =>
      simp only [recordC, record, res_bind, run_bind, res_tick, res_get, run_get, skipC, wsC, res_liftP]
      have hf : ∀ u, res (fieldsC L fuel b t [] .empty) u = (fields L fuel b t []).run u := ih.fields b t []
      split <;> simp_all <;> split <;> simp_all
  · intro b start acc t
    have hmem : ∀ k : String, ((keySet (acc.map Prod.fst)).memC (keyBits k.toList)).1 = acc.any (·.1 == k) := by
      intro k; rw [KeySet.memC_eq, mem_keySet, List.any_map]; rfl
    have hins : ∀ (k : String) (v : Value), ((keySet (acc.map Prod.fst)).insertC (keyBits k.toList)).1 =
        keySet (((k, v) :: acc).map Prod.fst) := by
      intro k v; rw [KeySet.insertC_eq]; rfl
    have hrec : ∀ (k : String) (v : Value) u, res (fieldsC L fuel b start ((k, v) :: acc)
        ((keySet (acc.map Prod.fst)).insertC (keyBits k.toList)).1) u = (fields L fuel b start ((k, v) :: acc)).run u := by
      intro k v u; rw [hins k v]; exact ih.fields b start _ u
    simp only [fieldsC, fields, res_bind, run_bind, res_tick, res_get, run_get, keyC, wsC, expectC, hmem]
    have hv := ih.value b
    clear hins
    split <;> simp only [res_bind, run_bind, res_tick, res_get, run_get, res_liftP, hv, res_set, run_set,
      res_pure, run_pure, res_ite, run_ite, res_failAtC, run_failAt]
    all_goals (repeat' (split <;> simp_all))
  · intro b close t
    cases b with
    | zero => simp [itemsC, items]
    | succ b =>
      simp only [itemsC, items, res_bind, run_bind, res_tick, res_get, run_get, skipC, wsC, res_liftP]
      have hf := ih.itemsLoop b close t []
      split <;> simp_all <;> split <;> simp_all
  · intro b close start acc t
    have hv := ih.value b
    have hrec := ih.itemsLoop b close start
    simp only [itemsLoopC, itemsLoop, res_bind, run_bind, res_tick, res_get, run_get, wsC]
    split <;> simp only [res_bind, run_bind, res_tick, res_get, run_get, res_liftP, hv, res_set, run_set,
      res_pure, run_pure, res_ite, run_ite, res_failAtC, run_failAt]
    all_goals (repeat' (split <;> simp_all))

theorem agreeAt (L : Limits) : ∀ fuel, AgreeAt L fuel
  | 0 => agreeAt_zero L
  | fuel + 1 => agreeAt_succ L fuel (agreeAt L fuel)

theorem fileLoopC_agrees (L : Limits) (fuel : Nat) :
    ∀ n acc t, res (fileLoopC L fuel n acc) t = (fileLoop L fuel n acc).run t
  | 0, _, _ => by simp [fileLoopC, fileLoop]
  | n + 1, acc, t => by
    have hv := (agreeAt L fuel).value L.maxDepth
    have hrec := fileLoopC_agrees L fuel n
    simp only [fileLoopC, fileLoop, res_bind, run_bind, res_tick, res_get, run_get, wsC]
    split <;> simp only [res_bind, run_bind, res_tick, res_get, run_get, res_liftP, hv, res_pure, run_pure]
    all_goals (repeat' (split <;> simp_all))

theorem fileC_agrees (L : Limits) (t : Text) :
    res (fileC L t) t = (do ws; fileLoop L (4 * (t.length + 1)) (4 * (t.length + 1)) []).run t := by
  simp only [fileC, res_bind, run_bind, wsC, res_liftP, fileLoopC_agrees]
  split <;> simp_all

/-- **The counting parser returns what `parse` returns**: values, errors and positions. -/
theorem parseC_eq (L : Limits) (input : Text) : (parseC L input).1 = parse L input := by
  unfold parseC parse
  dsimp only
  rw [fileC_agrees, run'_eq]
  rfl

end Haus.Linear
