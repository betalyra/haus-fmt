/-!
# Duplicate keys in n log n comparisons (plan step P3, first part; design review D2)

Spec §7: parsing takes linear time, also on crafted input, so duplicate
keys (§3) are found with a seeded hash table or a sorted structure, never
with a list scan. The reference parser scans (`Parser.fields`: each key
against the keys read before it, `scanDup` here), which is quadratic.

This file gives the sorted alternative and proves it right:

- `msort`: merge sort that also counts its comparisons;
  `msort_perm`, `msort_sorted`: it sorts; `msort_cost`: with `n ≤ 2^k`
  keys, at most `n · k` comparisons.
- `adjDup`: on a sorted list, a duplicate is two equal neighbours
  (`adjDup_iff`), at most `n` comparisons.
- `sortDup_iff`: sorting and comparing neighbours reports a duplicate
  exactly when the keys have one; `sortDup_eq_scanDup`: it is the
  reference check; `sortDup_cost`: at most `n · (log₂ n + 2)` comparisons.
- `keysDup`, `keysDup_eq_scanDup`, `keysDup_cost`: the same for record keys
  (`String`, ordered as their characters).

The cost model counts comparisons of two keys, each one step. A key is at
most `maxStringLength` characters (§7), so a comparison is bounded by a
constant. The hash tables of the bindings are outside the model: their
bound is probabilistic.
-/

namespace Haus.DupKeys

variable {α : Type}

/-! ## The reference: a scan -/

/-- The parser's check: each key against the keys before it (`acc`). -/
def scanDup [BEq α] : List α → List α → Bool
  | _, [] => false
  | acc, k :: ks => acc.any (· == k) || scanDup (k :: acc) ks

theorem scanDup_false [BEq α] [LawfulBEq α] (acc ks : List α) :
    scanDup acc ks = false ↔ (∀ k ∈ ks, k ∉ acc) ∧ ks.Nodup := by
  induction ks generalizing acc with
  | nil => simp [scanDup]
  | cons k ks ih =>
    simp only [scanDup, Bool.or_eq_false_iff, ih, List.any_eq_false, beq_iff_eq, List.mem_cons,
      List.nodup_cons, not_or]
    constructor
    · rintro ⟨h1, h2, h3⟩
      refine ⟨fun y hy => ?_, fun hk => (h2 k hk).1 rfl, h3⟩
      rcases hy with rfl | hy
      · exact fun hy => h1 y hy rfl
      · exact (h2 y hy).2
    · rintro ⟨h1, h2, h3⟩
      exact ⟨fun x hx e => h1 k (.inl rfl) (e ▸ hx), fun y hy => ⟨fun e => h2 (e ▸ hy), h1 y (.inr hy)⟩, h3⟩

/-- The scan from nothing: a duplicate exactly when the keys have one. -/
theorem scanDup_nil_iff [BEq α] [LawfulBEq α] (ks : List α) : scanDup [] ks = true ↔ ¬ ks.Nodup := by
  rw [← Bool.not_eq_false, scanDup_false]
  simp

/-! ## Merge sort, counting comparisons -/

section Sorting
variable (le : α → α → Bool)

/-- Merging two lists: the merged list and the number of comparisons. -/
def merge : List α → List α → List α × Nat
  | [], ys => (ys, 0)
  | x :: xs, [] => (x :: xs, 0)
  | x :: xs, y :: ys =>
    if le x y then
      let r := merge xs (y :: ys)
      (x :: r.1, r.2 + 1)
    else
      let r := merge (x :: xs) ys
      (y :: r.1, r.2 + 1)
termination_by xs ys => xs.length + ys.length

/-- Merge sort: the sorted list and the number of comparisons. -/
def msort : List α → List α × Nat
  | [] => ([], 0)
  | [x] => ([x], 0)
  | x :: y :: zs =>
    let a := msort ((x :: y :: zs).take ((zs.length + 2) / 2))
    let b := msort ((x :: y :: zs).drop ((zs.length + 2) / 2))
    let m := merge le a.1 b.1
    (m.1, a.2 + b.2 + m.2)
termination_by l => l.length
decreasing_by all_goals simp; omega

/-- Sorted: every element is `le` every later one. -/
abbrev Sorted (l : List α) : Prop := l.Pairwise fun a b => le a b = true

theorem merge_perm : ∀ xs ys : List α, (merge le xs ys).1.Perm (xs ++ ys)
  | [], ys => by simp [merge]
  | x :: xs, [] => by simp [merge]
  | x :: xs, y :: ys => by
    unfold merge
    split
    · exact (merge_perm xs (y :: ys)).cons x
    · refine ((merge_perm (x :: xs) ys).cons y).trans ?_
      simpa using (List.perm_middle (a := y) (l₁ := x :: xs) (l₂ := ys)).symm
termination_by xs ys => xs.length + ys.length

theorem merge_cost : ∀ xs ys : List α, (merge le xs ys).2 ≤ xs.length + ys.length
  | [], ys => by simp [merge]
  | x :: xs, [] => by simp [merge]
  | x :: xs, y :: ys => by
    unfold merge
    split
    · have := merge_cost xs (y :: ys); simp at this ⊢; omega
    · have := merge_cost (x :: xs) ys; simp at this ⊢; omega
termination_by xs ys => xs.length + ys.length

theorem merge_sorted (htot : ∀ a b, le a b = true ∨ le b a = true)
    (htrans : ∀ a b c, le a b = true → le b c = true → le a c = true) :
    ∀ xs ys : List α, Sorted le xs → Sorted le ys → Sorted le (merge le xs ys).1
  | [], ys, _, hy => by simpa [merge] using hy
  | x :: xs, [], hx, _ => by simpa [merge] using hx
  | x :: xs, y :: ys, hx, hy => by
    unfold merge
    have hx' := List.pairwise_cons.mp hx
    have hy' := List.pairwise_cons.mp hy
    split
    · rename_i hxy
      refine List.pairwise_cons.mpr ⟨fun z hz => ?_, merge_sorted htot htrans xs (y :: ys) hx'.2 hy⟩
      rcases List.mem_append.mp ((merge_perm le xs (y :: ys)).mem_iff.mp hz) with hz | hz
      · exact hx'.1 z hz
      · rcases List.mem_cons.mp hz with rfl | hz
        · exact hxy
        · exact htrans _ _ _ hxy (hy'.1 z hz)
    · rename_i hxy
      have hyx : le y x = true := (htot x y).resolve_left hxy
      refine List.pairwise_cons.mpr ⟨fun z hz => ?_, merge_sorted htot htrans (x :: xs) ys hx hy'.2⟩
      rcases List.mem_append.mp ((merge_perm le (x :: xs) ys).mem_iff.mp hz) with hz | hz
      · rcases List.mem_cons.mp hz with rfl | hz
        · exact hyx
        · exact htrans _ _ _ hyx (hx'.1 z hz)
      · exact hy'.1 z hz
termination_by xs ys => xs.length + ys.length

theorem msort_perm : ∀ l : List α, (msort le l).1.Perm l
  | [] => by simp [msort]
  | [x] => by simp [msort]
  | x :: y :: zs => by
    unfold msort
    have ha := msort_perm ((x :: y :: zs).take ((zs.length + 2) / 2))
    have hb := msort_perm ((x :: y :: zs).drop ((zs.length + 2) / 2))
    refine (merge_perm le _ _).trans ?_
    have := ha.append hb
    rwa [List.take_append_drop] at this
termination_by l => l.length
decreasing_by all_goals simp; omega

theorem msort_sorted (htot : ∀ a b, le a b = true ∨ le b a = true)
    (htrans : ∀ a b c, le a b = true → le b c = true → le a c = true) : ∀ l : List α, Sorted le (msort le l).1
  | [] => by simp [msort]
  | [x] => by simp [msort]
  | x :: y :: zs => by
    unfold msort
    exact merge_sorted le htot htrans _ _ (msort_sorted htot htrans _) (msort_sorted htot htrans _)
termination_by l => l.length
decreasing_by all_goals simp; omega

/-- **Merge sort's bound**: `n ≤ 2^k` keys take at most `n · k` comparisons. -/
theorem msort_cost : ∀ (l : List α) (k : Nat), l.length ≤ 2 ^ k → (msort le l).2 ≤ l.length * k
  | [], _, _ => by simp [msort]
  | [x], _, _ => by simp [msort]
  | x :: y :: zs, k, hk => by
    unfold msort
    simp only [List.length_cons] at hk ⊢
    obtain ⟨k, rfl⟩ : ∃ k', k = k' + 1 := ⟨k - 1, by
      cases k with
      | zero => simp at hk
      | succ k => simp⟩
    have hp : 2 ^ (k + 1) = 2 * 2 ^ k := by rw [Nat.pow_succ, Nat.mul_comm]
    have lt : ((x :: y :: zs).take ((zs.length + 2) / 2)).length = (zs.length + 2) / 2 := by simp; omega
    have ld : ((x :: y :: zs).drop ((zs.length + 2) / 2)).length = zs.length + 2 - (zs.length + 2) / 2 := by simp
    have ca := msort_cost ((x :: y :: zs).take ((zs.length + 2) / 2)) k (by rw [lt]; omega)
    have cb := msort_cost ((x :: y :: zs).drop ((zs.length + 2) / 2)) k (by rw [ld]; omega)
    have cm := merge_cost le (msort le ((x :: y :: zs).take ((zs.length + 2) / 2))).1
      (msort le ((x :: y :: zs).drop ((zs.length + 2) / 2))).1
    rw [(msort_perm le _).length_eq, (msort_perm le _).length_eq, lt, ld] at cm
    rw [lt] at ca; rw [ld] at cb
    have split : (zs.length + 2) / 2 * k + (zs.length + 2 - (zs.length + 2) / 2) * k = (zs.length + 2) * k := by
      rw [← Nat.add_mul]; congr 1; omega
    show _ ≤ (zs.length + 2) * (k + 1)
    rw [Nat.mul_succ]
    calc _ ≤ (zs.length + 2) / 2 * k + (zs.length + 2 - (zs.length + 2) / 2) * k +
          ((zs.length + 2) / 2 + (zs.length + 2 - (zs.length + 2) / 2)) := Nat.add_le_add (Nat.add_le_add ca cb) cm
      _ = (zs.length + 2) * k + (zs.length + 2) := by rw [split]; omega
termination_by l => l.length
decreasing_by all_goals simp; omega

end Sorting

/-! ## Equal neighbours -/

/-- Any two neighbours equal, and the number of comparisons. -/
def adjDup [DecidableEq α] : List α → Bool × Nat
  | a :: b :: r =>
    let t := adjDup (b :: r)
    (decide (a = b) || t.1, t.2 + 1)
  | _ => (false, 0)

theorem adjDup_cost [DecidableEq α] : ∀ l : List α, (adjDup l).2 ≤ l.length
  | [] | [_] => by simp [adjDup]
  | a :: b :: r => by
    have := adjDup_cost (b :: r)
    simp only [adjDup, List.length_cons] at this ⊢
    omega

/-- **On a sorted list, a duplicate is two equal neighbours.** -/
theorem adjDup_iff [DecidableEq α] {le : α → α → Bool} (hanti : ∀ a b, le a b = true → le b a = true → a = b) :
    ∀ l : List α, Sorted le l → ((adjDup l).1 = true ↔ ¬ l.Nodup)
  | [], _ => by simp [adjDup]
  | [a], _ => by simp [adjDup]
  | a :: b :: r, hs => by
    have hs' := List.pairwise_cons.mp hs
    have ih := adjDup_iff hanti (b :: r) hs'.2
    simp only [adjDup, Bool.or_eq_true, decide_eq_true_eq, ih]
    rw [List.nodup_cons (a := a)]
    constructor
    · rintro (rfl | h)
      · exact fun hn => hn.1 (List.mem_cons_self ..)
      · exact fun hn => h hn.2
    · intro h
      by_cases hab : a = b
      · exact .inl hab
      · refine .inr fun hn => h ⟨fun ha => ?_, hn⟩
        rcases List.mem_cons.mp ha with rfl | ha
        · exact hab rfl
        · have hb := List.pairwise_cons.mp hs'.2
          exact hab (hanti a b (hs'.1 b (List.mem_cons_self ..)) (hb.1 a ha))

/-! ## Sorting and comparing neighbours -/

section Check
variable (le : α → α → Bool)

/-- **The sorted check**: sort, then compare neighbours. A duplicate, and the comparisons it took. -/
def sortDup [DecidableEq α] (ks : List α) : Bool × Nat :=
  let s := msort le ks
  let d := adjDup s.1
  (d.1, s.2 + d.2)

variable [DecidableEq α] (htot : ∀ a b, le a b = true ∨ le b a = true)
  (htrans : ∀ a b c, le a b = true → le b c = true → le a c = true)
  (hanti : ∀ a b, le a b = true → le b a = true → a = b)
include htot htrans hanti

/-- **The sorted check reports a duplicate exactly when the keys have one.** -/
theorem sortDup_iff (ks : List α) : (sortDup le ks).1 = true ↔ ¬ ks.Nodup := by
  simp only [sortDup]
  rw [adjDup_iff hanti _ (msort_sorted le htot htrans ks), (msort_perm le ks).nodup_iff]

/-- **It is the reference check**: the parser's scan gives the same answer. -/
theorem sortDup_eq_scanDup (ks : List α) : (sortDup le ks).1 = scanDup [] ks := by
  apply Bool.eq_iff_iff.mpr
  rw [sortDup_iff le htot htrans hanti, scanDup_nil_iff]

omit htot htrans hanti in
/-- **At most `n · k + n` comparisons** for `n ≤ 2^k` keys. -/
theorem sortDup_cost_pow (ks : List α) (k : Nat) (hk : ks.length ≤ 2 ^ k) :
    (sortDup le ks).2 ≤ ks.length * k + ks.length := by
  simp only [sortDup]
  have h1 := msort_cost le ks k hk
  have h2 := adjDup_cost (msort le ks).1
  rw [(msort_perm le ks).length_eq] at h2
  omega

omit htot htrans hanti in
/-- **O(n log n)**: at most `n · (log₂ n + 2)` comparisons for `n` keys. -/
theorem sortDup_cost (ks : List α) : (sortDup le ks).2 ≤ ks.length * (ks.length.log2 + 2) := by
  have := sortDup_cost_pow le ks (ks.length.log2 + 1) (Nat.le_of_lt Nat.lt_log2_self)
  rw [Nat.mul_succ] at this ⊢
  exact this

end Check

/-! ## Record keys -/

/-- Keys ordered as their characters (`String`'s `≤`). -/
def keyLe (a b : String) : Bool := decide (a ≤ b)

theorem keyLe_total (a b : String) : keyLe a b = true ∨ keyLe b a = true := by
  simpa [keyLe] using String.le_total a b

theorem keyLe_trans (a b c : String) (h1 : keyLe a b = true) (h2 : keyLe b c = true) : keyLe a c = true := by
  simp only [keyLe, decide_eq_true_eq] at *; exact String.le_trans h1 h2

theorem keyLe_antisymm (a b : String) (h1 : keyLe a b = true) (h2 : keyLe b a = true) : a = b := by
  simp only [keyLe, decide_eq_true_eq] at *; exact String.le_antisymm h1 h2

/-- The sorted check for a record's keys. -/
def keysDup (ks : List String) : Bool × Nat := sortDup keyLe ks

/-- **For record keys: a duplicate exactly when the parser's scan finds one**, and so when the keys aren't distinct (`Grammar`'s `Record` rule). -/
theorem keysDup_eq_scanDup (ks : List String) : (keysDup ks).1 = scanDup [] ks :=
  sortDup_eq_scanDup keyLe keyLe_total keyLe_trans keyLe_antisymm ks

theorem keysDup_iff (ks : List String) : (keysDup ks).1 = true ↔ ¬ ks.Nodup :=
  sortDup_iff keyLe keyLe_total keyLe_trans keyLe_antisymm ks

theorem keysDup_cost (ks : List String) : (keysDup ks).2 ≤ ks.length * (ks.length.log2 + 2) :=
  sortDup_cost keyLe ks

#guard keysDup ["b", "a", "c", "a"] |>.1
#guard !(keysDup ["b", "a", "c", "d"]).1

end Haus.DupKeys
