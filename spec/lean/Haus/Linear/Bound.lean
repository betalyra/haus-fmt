import Haus.Linear.Leaves

/-!
# The reference parser takes linear time (plan step P3)

`parseC_cost`: parsing `n` characters takes at most `256 · n + 70` steps
(the cost model of `Haus.Linear.Monad`), whatever the input, valid or not,
also crafted; with `parseC_eq`, the reference parser's result in linear time.

The argument is amortized over the characters read. A value that succeeds
takes at most 128 steps per character it read; one more for each blank
after it that it looked at (a tag looks past blanks for a payload and, when
there is none, leaves them for the next `ws`, which reads them again:
`blanks`). A failure takes at most 256 steps per character left, and 64.
Proven for all value functions together, by induction on the fuel; a record
or an array also pays, one step per element, for reversing its elements
at the end (`acc.length`).
-/

namespace Haus.Linear
open Haus Parser Sound

/-- Success: a character or more read; at most 128 steps per character, with `D` to spare and `N` extra. -/
def OkB {α : Type} (D N : Nat) (t : Text) : α → Text → Nat → Prop := fun _ t' c =>
  t'.length < t.length ∧ c + D + blanks t + 128 * t'.length ≤ 128 * t.length + blanks t' + N

/-- Failure: at most 256 steps per character left, and 64, with `D` to spare. -/
def ErrB (D : Nat) (t : Text) : Nat → Prop := fun c => c + D + blanks t ≤ 256 * t.length + 64

/-- The value functions within their bounds, at one fuel. -/
structure BoundAt (L : Limits) (fuel : Nat) : Prop where
  value : ∀ b t, Spec (valueC L fuel b) t (OkB 0 0 t) (ErrB 1 t)
  variant : ∀ b c t0, isUpper c = true → Spec (variantC L fuel b) (c :: t0) (OkB 1 0 (c :: t0)) (ErrB 2 (c :: t0))
  record : ∀ b t0, Spec (recordC L fuel b) ('{' :: t0) (OkB 1 0 ('{' :: t0)) (ErrB 2 ('{' :: t0))
  fields : ∀ b start acc ks t, Spec (fieldsC L fuel b start acc ks) t (OkB 0 (acc.length + 3) t) (ErrB 0 t)
  items : ∀ b close o t0, isBlank o = false → Spec (itemsC L fuel b close) (o :: t0) (OkB 1 0 (o :: t0)) (ErrB 2 (o :: t0))
  itemsLoop : ∀ b close start acc t, Spec (itemsLoopC L fuel b close start acc) t (OkB 0 (acc.length + 3) t) (ErrB 0 t)

theorem blanks_cons (c : Char) (r : Text) : blanks (c :: r) = if isBlank c then blanks r + 1 else 0 := by
  unfold blanks; cases h : isBlank c <;> simp [h]

theorem blanks_cons_of {c : Char} (r : Text) (h : isBlank c = true → False) : blanks (c :: r) = 0 := by
  rw [blanks_cons]; cases hb : isBlank c
  · rfl
  · exact (h hb).elim

theorem okB_leaf {β : Type} {D k : Nat} {t u : Text} {c : Nat} {b : β} (hb : blanks t = 0) (hk : k + D ≤ 78)
    (h : u.length < t.length ∧ c + 50 * u.length ≤ 50 * t.length) : OkB (α := β) D 0 t b u (k + c) := by
  unfold OkB; omega

theorem errB_leaf {D k : Nat} {t : Text} {c : Nat} (hk : k + D ≤ 14) (h : c ≤ 50 * t.length + 50) :
    ErrB D t (k + c) := by
  have := blanks_le t; unfold ErrB; omega

theorem spec_takeWhileC (p : Char → Bool) (t : Text) :
    Spec (takeWhileC p) t (fun w u c => w = t.takeWhile p ∧ u = t.dropWhile p ∧ c = w.length + 1) (fun _ => False) :=
  spec_liftP (fun _ _ h => by simp [run_takeWhile] at h; obtain ⟨rfl, rfl⟩ := h; simp) (fun _ h => by simp at h)

theorem spec_checkName (L : Limits) (what : String) (w start t : Text) :
    Spec (liftP (checkName L what w start) fun _ => 0) t (fun _ u c => u = t ∧ c = 0) (fun c => c = 0) :=
  spec_liftP (fun _ _ h => by unfold checkName at h; split at h <;> simp_all) (fun _ _ => rfl)

theorem spec_skipC (t : Text) : Spec (skipC 1) t (fun _ u c => u = t.drop 1 ∧ c = 1) (fun _ => False) :=
  spec_liftP (fun _ _ h => by simp [run_skip] at h; obtain ⟨-, rfl⟩ := h; simp) (fun _ h => by simp at h)

theorem blanks_cons_le (c : Char) (r : Text) : blanks (c :: r) ≤ blanks r + 1 := by
  rw [blanks_cons]; split <;> omega

theorem spec_expectC (c : Char) (code : Code) (what : String) (t : Text) :
    Spec (expectC c code what) t (fun _ u n => t = c :: u ∧ n = 1) (fun n => n = 1) :=
  spec_liftP (fun _ _ h => ⟨expect_sound _ _ _ _ _ h, rfl⟩) (fun _ _ => rfl)

theorem keyBits_string_length (k : String) : (keyBits k.toList).length = 21 * k.length := by
  rw [keyBits_length, String.length_toList]

theorem errB_fail {D k : Nat} (t : Text) (hD : k + D ≤ 64) : ErrB D t k := by
  have := blanks_le t; unfold ErrB; omega

theorem boundAt_zero (L : Limits) : BoundAt L 0 := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> intros
  · simp only [valueC]; exact spec_failC (errB_fail _ (by omega))
  · simp only [variantC]; exact spec_failC (errB_fail _ (by omega))
  · simp only [recordC]; exact spec_failC (errB_fail _ (by omega))
  · simp only [fieldsC]; exact spec_failC (errB_fail _ (by omega))
  · simp only [itemsC]; exact spec_failC (errB_fail _ (by omega))
  · simp only [itemsLoopC]; exact spec_failC (errB_fail _ (by omega))

theorem boundAt_succ (L : Limits) (fuel : Nat) (ih : BoundAt L fuel) : BoundAt L (fuel + 1) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro b t
    simp only [valueC]
    apply spec_tick_bind
    apply spec_get_bind
    split
    · rename_i tail
      refine spec_map (spec_mono (ih.record b tail) (fun _ _ _ h => h) (fun c h => ?_)) ?_
      · simp only [ErrB, blanks_cons] at h ⊢; simp [isBlank] at h ⊢; omega
      · intro a u c h; simp only [OkB, blanks_cons] at h ⊢; simp [isBlank] at h ⊢; omega
    · rename_i tail
      refine spec_map (spec_mono (ih.items b ']' '[' tail (by simp [isBlank])) (fun _ _ _ h => h) (fun c h => ?_)) ?_
      · simp only [ErrB, blanks_cons] at h ⊢; simp [isBlank] at h ⊢; omega
      · intro a u c h; simp only [OkB, blanks_cons] at h ⊢; simp [isBlank] at h ⊢; omega
    · refine spec_map (spec_mono (blockStringC_spec L _) (fun _ _ _ h => h) (fun c h => errB_leaf (by omega) h)) ?_
      exact fun _ _ _ h => okB_leaf (blanks_cons_of _ (by simp [isBlank])) (by omega) h
    · refine spec_map (spec_mono (basicStringC_spec L _) (fun _ _ _ h => h) (fun c h => errB_leaf (by omega) h)) ?_
      exact fun _ _ _ h => okB_leaf (blanks_cons_of _ (by simp [isBlank])) (by omega) h
    · exact spec_mono (bytesC_spec L _) (fun _ _ _ h => okB_leaf (blanks_cons_of _ (by simp [isBlank])) (by omega) h)
        (fun c h => errB_leaf (by omega) h)
    · rename_i c tail _ _ _ _ _
      refine spec_ite (fun hc => ?_) (fun _ => spec_ite (fun hu => ?_) (fun _ => spec_ite (fun _ => ?_) (fun _ => ?_)))
      · have hb : blanks (c :: tail) = 0 := blanks_cons_of _ fun h => by
          simp only [isBlank, Bool.or_eq_true, beq_iff_eq] at h hc
          rcases h with rfl | rfl <;> simp [isDigit] at hc
        exact spec_mono (numberC_spec L _) (fun _ _ _ h => okB_leaf hb (by omega) h) (fun c h => errB_leaf (by omega) h)
      · refine spec_mono (ih.variant b c tail hu) (fun _ u c' h => ?_) (fun c' h => ?_)
        · unfold OkB at h ⊢; omega
        · unfold ErrB at h ⊢; omega
      · apply spec_tick_bind
        apply spec_failC
        have := blanks_le (c :: tail)
        have : (List.takeWhile isIdentChar (c :: tail)).length ≤ (c :: tail).length :=
          List.Sublist.length_le (List.takeWhile_sublist _)
        unfold ErrB; omega
      · exact spec_failC (errB_fail _ (by omega))
    · exact spec_failC (errB_fail _ (by omega))
  · intro b c t0 hu
    have hc : isIdentChar c = true := by simp [isIdentChar, hu]
    have hb : blanks (c :: t0) = 0 := blanks_cons_of _ fun h => by
      simp only [isBlank, Bool.or_eq_true, beq_iff_eq] at h
      rcases h with rfl | rfl <;> simp [isUpper] at hu
    have hw := takeWhile_dropWhile_length isIdentChar (c :: t0)
    have hw1 : 1 ≤ ((c :: t0).takeWhile isIdentChar).length := by simp [hc]
    simp only [variantC]
    apply spec_tick_bind
    apply spec_get_bind
    refine spec_bind (spec_takeWhileC _ _) (fun w a c1 ⟨hw2, ha, hc1⟩ => ?_) (fun _ h => h.elim)
    subst hw2 ha hc1
    apply spec_tick_bind
    refine spec_bind (spec_checkName L "tag" _ _ _) (fun name a' c2 ⟨ha', hc2⟩ => ?_) (fun c2 hc2 => ?_)
    rotate_left
    · subst hc2; unfold ErrB; omega
    subst ha' hc2
    apply spec_get_bind
    refine spec_bind (spec_takeWhileC _ _) (fun bl t2 c3 ⟨hbl, ht2, hc3⟩ => ?_) (fun _ h => h.elim)
    subst hbl ht2 hc3
    have hbl := takeWhile_dropWhile_length isBlank ((c :: t0).dropWhile isIdentChar)
    apply spec_get_bind
    split
    · rename_i _ tail heq
      have hl := congrArg List.length heq
      simp only [List.length_cons] at hl
      rw [heq]
      have hb2 : blanks ('(' :: tail) = 0 := blanks_cons_of _ (by simp [isBlank])
      refine spec_bind (ih.items b ')' '(' tail (by simp [isBlank])) (fun xs t' c4 h4 => ?_) (fun c4 h4 => ?_)
      · refine spec_ite (fun _ => spec_failAtC ?_) (fun _ => spec_pure ?_)
        · have := blanks_le t'; unfold ErrB OkB at *; simp only [List.length_cons] at *; omega
        · unfold OkB at *; simp only [List.length_cons] at *; omega
      · unfold ErrB at *; simp only [List.length_cons] at *; omega
    · rename_i _ tail heq
      have hl := congrArg List.length heq
      simp only [List.length_cons] at hl
      rw [heq]
      have hb2 : blanks ('{' :: tail) = 0 := blanks_cons_of _ (by simp [isBlank])
      refine spec_map (spec_mono (ih.record b tail) (fun _ _ _ h => h) (fun c4 h4 => ?_)) (fun _ t' c4 h4 => ?_)
      · unfold ErrB at *; simp only [List.length_cons] at *; omega
      · unfold OkB at *; simp only [List.length_cons] at *; omega
    · apply spec_set_bind
      apply spec_pure
      unfold OkB blanks at *
      omega
  · intro b t0
    cases b with
    | zero => simp only [recordC]; exact spec_failC (errB_fail _ (by omega))
    | succ b =>
      have hb : blanks ('{' :: t0) = 0 := blanks_cons_of _ (by simp [isBlank])
      simp only [recordC]
      apply spec_tick_bind
      apply spec_get_bind
      refine spec_bind (spec_skipC _) (fun _ u c1 ⟨hu, hc1⟩ => ?_) (fun _ h => h.elim)
      subst hu hc1
      refine spec_bind (wsC_spec _) (fun _ t1 c2 ⟨h1, h2⟩ => ?_) (fun c2 h => ?_)
      · refine spec_mono (ih.fields b _ [] .empty t1) (fun _ t' c3 h3 => ?_) (fun c3 h3 => ?_)
        · unfold OkB at *; simp only [List.length_cons, List.length_nil, List.drop_succ_cons, List.drop_zero] at *
          omega
        · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons, List.drop_succ_cons, List.drop_zero] at *
          omega
      · unfold ErrB; simp only [List.length_cons, List.drop_succ_cons, List.drop_zero] at *; omega
  · intro b start acc ks t
    simp only [fieldsC]
    apply spec_tick_bind
    apply spec_get_bind
    split
    · apply spec_set_bind; apply spec_tick_bind; apply spec_pure
      have := blanks_cons_le '}' []
      unfold OkB; simp only [List.length_cons, blanks_cons] at *; simp [isBlank]; omega
    · exact spec_failAtC (errB_fail _ (by omega))
    · refine spec_bind (keyC_spec L t) (fun k t1 c1 ⟨h1, hb, hk, h1'⟩ => ?_) (fun c1 h1 => ?_)
      rotate_left
      · have := blanks_le t; unfold ErrB; omega
      have hkb := keyBits_string_length k
      have hm := KeySet.memC_cost ks (keyBits k.toList)
      have hi := KeySet.insertC_cost ks (keyBits k.toList)
      apply spec_tick_bind
      apply spec_tick_bind
      refine spec_ite (fun _ => spec_bind (spec_failAtC (S := fun _ _ _ => False) (F := fun n => n = 1) rfl) (fun _ _ _ h => h.elim)
        (fun c6 h6 => ?_)) (fun _ => ?_)
      · subst h6; unfold ErrB; omega
      apply spec_tick_bind
      refine spec_bind (wsC_spec t1) (fun _ t2 c2 ⟨h2, h2'⟩ => ?_) (fun c2 h2 => ?_)
      rotate_left
      · unfold ErrB; omega
      refine spec_bind (spec_expectC _ _ _ t2) (fun _ t3 c3 ⟨h3, h3'⟩ => ?_) (fun c3 h3 => ?_)
      rotate_left
      · unfold ErrB; omega
      subst h3 h3'
      refine spec_bind (wsC_spec t3) (fun _ t4 c4 ⟨h4, h4'⟩ => ?_) (fun c4 h4 => ?_)
      rotate_left
      · unfold ErrB; simp only [List.length_cons] at *; omega
      refine spec_bind (ih.value b t4) (fun v t5 c5 h5 => ?_) (fun c5 h5 => ?_)
      rotate_left
      · unfold ErrB at *; simp only [List.length_cons] at *; omega
      unfold OkB at h5
      refine spec_bind (wsC_spec t5) (fun _ t6 c6 ⟨h6, h6'⟩ => ?_) (fun c6 h6 => ?_)
      rotate_left
      · have := blanks_le t5; unfold ErrB; simp only [List.length_cons] at *; omega
      apply spec_tick_bind
      apply spec_get_bind
      split
      · apply spec_set_bind
        refine spec_bind (wsC_spec _) (fun _ t7 c7 ⟨h7, h7'⟩ => ?_) (fun c7 h7 => ?_)
        rotate_left
        · have := blanks_le t5; unfold ErrB; simp only [List.length_cons] at *; omega
        refine spec_mono (ih.fields b start ((k, v) :: acc) _ t7) (fun _ t' c8 h8 => ?_) (fun c8 h8 => ?_)
        · have := blanks_le t5; unfold OkB at *; simp only [List.length_cons] at *; omega
        · have := blanks_le t5; unfold ErrB at *; simp only [List.length_cons] at *; omega
      · apply spec_set_bind; apply spec_tick_bind; apply spec_pure
        have := blanks_le t5; unfold OkB at *; simp only [List.length_cons] at *; omega
      · apply spec_failAtC
        have := blanks_le t5; unfold ErrB; simp only [List.length_cons] at *; omega
      · apply spec_failC
        have := blanks_le t5; unfold ErrB; simp only [List.length_cons] at *; omega
  · intro b close o t0 ho
    cases b with
    | zero => simp only [itemsC]; exact spec_failC (errB_fail _ (by omega))
    | succ b =>
      have hb : blanks (o :: t0) = 0 := by rw [blanks_cons, ho]; rfl
      simp only [itemsC]
      apply spec_tick_bind
      apply spec_get_bind
      refine spec_bind (spec_skipC _) (fun _ u c1 ⟨hu, hc1⟩ => ?_) (fun _ h => h.elim)
      subst hu hc1
      refine spec_bind (wsC_spec _) (fun _ t1 c2 ⟨h1, h2⟩ => ?_) (fun c2 h => ?_)
      · refine spec_mono (ih.itemsLoop b close _ [] t1) (fun _ t' c3 h3 => ?_) (fun c3 h3 => ?_)
        · unfold OkB at *
          simp only [List.length_cons, List.length_nil, List.drop_succ_cons, List.drop_zero] at *
          omega
        · have := blanks_le t1; unfold ErrB at *
          simp only [List.length_cons, List.drop_succ_cons, List.drop_zero] at *
          omega
      · unfold ErrB; simp only [List.length_cons, List.drop_succ_cons, List.drop_zero] at *; omega
  · intro b close start acc t
    simp only [itemsLoopC]
    apply spec_tick_bind
    apply spec_get_bind
    split
    · rename_i c r
      have hbc := blanks_cons_le c r
      refine spec_ite (fun _ => ?_) (fun _ => ?_)
      · apply spec_set_bind; apply spec_tick_bind; apply spec_pure
        unfold OkB; simp only [List.length_cons]; omega
      refine spec_bind (ih.value b _) (fun v t1 c1 h1 => ?_) (fun c1 h1 => ?_)
      rotate_left
      · unfold ErrB at *; omega
      unfold OkB at h1
      refine spec_bind (wsC_spec t1) (fun _ t2 c2 ⟨h2, h2'⟩ => ?_) (fun c2 h2 => ?_)
      rotate_left
      · have := blanks_le t1; unfold ErrB at *; omega
      apply spec_tick_bind
      apply spec_get_bind
      split
      · apply spec_set_bind
        refine spec_bind (wsC_spec _) (fun _ t3 c3 ⟨h3, h3'⟩ => ?_) (fun c3 h3 => ?_)
        rotate_left
        · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons] at *; omega
        refine spec_mono (ih.itemsLoop b close start (v :: acc) t3) (fun _ t' c4 h4 => ?_) (fun c4 h4 => ?_)
        · unfold OkB at *; simp only [List.length_cons] at *; omega
        · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons] at *; omega
      · refine spec_ite (fun _ => ?_) (fun _ => spec_failC ?_)
        · apply spec_set_bind; apply spec_tick_bind; apply spec_pure
          unfold OkB; simp only [List.length_cons] at *; omega
        · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons] at *; omega
      · apply spec_failAtC
        have := blanks_le t1; unfold ErrB at *; omega
    · exact spec_failAtC (errB_fail _ (by omega))

theorem boundAt (L : Limits) : ∀ fuel, BoundAt L fuel
  | 0 => boundAt_zero L
  | fuel + 1 => boundAt_succ L fuel (boundAt L fuel)

theorem fileLoopC_bound (L : Limits) (fuel : Nat) : ∀ n acc t,
    Spec (fileLoopC L fuel n acc) t
      (fun _ t' c => c + blanks t + 128 * t'.length ≤ 128 * t.length + blanks t' + acc.length + 8) (ErrB 0 t)
  | 0, _, t => by simp only [fileLoopC]; exact spec_failC (errB_fail _ (by omega))
  | n + 1, acc, t => by
    simp only [fileLoopC]
    apply spec_tick_bind
    apply spec_get_bind
    refine spec_ite (fun he => ?_) (fun _ => ?_)
    · apply spec_tick_bind; apply spec_pure
      simp only [List.isEmpty_iff] at he; subst he; simp [blanks]; omega
    refine spec_bind ((boundAt L fuel).value L.maxDepth t) (fun v t1 c1 h1 => ?_) (fun c1 h1 => ?_)
    rotate_left
    · unfold ErrB at *; omega
    unfold OkB at h1
    refine spec_bind (wsC_spec t1) (fun _ t2 c2 ⟨h2, h2'⟩ => ?_) (fun c2 h2 => ?_)
    rotate_left
    · have := blanks_le t1; unfold ErrB at *; omega
    apply spec_tick_bind
    apply spec_get_bind
    split
    · apply spec_tick_bind; apply spec_pure
      simp only [List.length_nil] at *; omega
    · apply spec_set_bind
      refine spec_bind (wsC_spec _) (fun _ t3 c3 ⟨h3, h3'⟩ => ?_) (fun c3 h3 => ?_)
      rotate_left
      · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons] at *; omega
      refine spec_mono (fileLoopC_bound L fuel n (v :: acc) t3) (fun _ t' c4 h4 => ?_) (fun c4 h4 => ?_)
      · simp only [List.length_cons] at *; omega
      · have := blanks_le t1; unfold ErrB at *; simp only [List.length_cons] at *; omega
    · apply spec_failC
      have := blanks_le t1; unfold ErrB; omega

theorem fileC_cost (L : Limits) (t : Text) : cost (fileC L t) t ≤ 256 * t.length + 66 := by
  have h : Spec (fileC L t) t (fun _ _ c => c ≤ 256 * t.length + 66) (fun c => c ≤ 256 * t.length + 66) := by
    simp only [fileC]
    refine spec_bind (wsC_spec t) (fun _ t1 c1 ⟨h1, h1'⟩ => ?_) (fun c1 h1 => by omega)
    refine spec_mono (fileLoopC_bound L _ _ [] t1) (fun _ t' c2 h2 => ?_) (fun c2 h2 => ?_)
    · simp only [List.length_nil] at h2; have := blanks_le t'; omega
    · unfold ErrB at h2; omega
  unfold Spec at h
  split at h <;> exact h

/--
**The reference parser in linear time**: `parseC`, which returns what
`parse` returns (`parseC_eq`), takes at most `256 · n + 68` steps on any
input of `n` characters.
-/
theorem parseC_cost (L : Limits) (input : Text) : (parseC L input).2 ≤ 256 * input.length + 68 := by
  unfold parseC
  dsimp only
  split
  · rename_i r; have := fileC_cost L r; simp only [List.length_cons]; omega
  · have := fileC_cost L input; omega

end Haus.Linear
