import Haus.Json.Evolution

/-!
# The chains of `Maybe`s: `nullFuel` is enough

Whether a `Maybe` writes `None` as `null` (§16.3) depends on the chain of
`Maybe`s its argument starts (`maybeChain`), followed for `F` steps. Every
link that continues a chain after its first is the body of a definition of the
prelude's `Maybe` (`Maybe#…`): a type written in place inside one is the
schema's own (`origin`). So a chain meets at most `env.fuel` links that go on
(`links_mem`), and from `env.fuel` steps on, a longer chain ends at the same
place (`endOf_stable`, for any chain of a function with that bound):
`chainNull_fuel`, `nullArg?_fuel`.

So the JSON functions give the same result for every fuel from `env.fuel` on
(`toJsonF_fuel`, `fromJsonF_fuel`), and `nullFuel env t`, the sizes of `t` and
of the definitions, is at least that (`fuel_le_nullFuel`): `toJson` and
`fromJson` are `toJsonF` and `fromJsonF` at any fuel from `env.fuel` on
(`toJson_eq`, `fromJson_eq`). The theorems of J9 and J11, stated for one fuel
`F` of both sides, hold for `toJson` and `fromJson` themselves
(`record_case_named_toJson`, `older_reads_newer_fromJson`, …).
-/

namespace Haus.Schema
open Haus

/-! ## Chains of a function -/

section Abstract
variable {α : Type} (next : α → Option α) (stop : α → Bool)

/-- The chain from `x`: `x`, its next, …, at most `n + 1` elements. -/
def chainOf : Nat → α → List α
  | 0, x => [x]
  | n + 1, x => x :: match next x with
    | some y => chainOf n y
    | none => []

/-- The position of the first element that stops, comes back later in the list, or is its last. -/
def endOf [BEq α] : List α → Nat
  | [] => 0
  | x :: cs => if stop x || cs.contains x || cs.isEmpty then 0 else endOf cs + 1

/-- The element `k` steps after `x`. -/
def iter : Nat → α → Option α
  | 0, x => some x
  | k + 1, x => match next x with
    | some y => iter k y
    | none => none

variable {next stop}

theorem iter_succ' : ∀ (k : Nat) (x : α), iter next (k + 1) x = (iter next k x).bind next
  | 0, x => by simp only [iter, Option.bind_some]; cases next x <;> rfl
  | k + 1, x => by
    simp only [iter]
    cases h : next x with
    | none => rfl
    | some y => exact iter_succ' k y

/-- Two places with the same element go on alike. -/
theorem iter_shift {a b : Nat} {x : α} (h : iter next a x = iter next b x) :
    ∀ m, iter next (a + m) x = iter next (b + m) x
  | 0 => h
  | m + 1 => by rw [← Nat.add_assoc, ← Nat.add_assoc, iter_succ', iter_succ', iter_shift h m]

theorem iter_some_le : ∀ {k j : Nat} {x : α}, j ≤ k → (iter next k x).isSome → (iter next j x).isSome
  | _, 0, _, _, _ => rfl
  | 0, j + 1, _, h, _ => by omega
  | k + 1, j + 1, x, h, hs => by
    simp only [iter] at hs ⊢
    cases hn : next x with
    | none => simp [hn] at hs
    | some y => simp only [hn] at hs ⊢; exact iter_some_le (by omega) hs

theorem mem_chainOf : ∀ {n : Nat} {x z : α}, z ∈ chainOf next n x → ∃ k ≤ n, iter next k x = some z
  | 0, x, z, h => by simp [chainOf] at h; exact ⟨0, Nat.le_refl _, by simp [iter, h]⟩
  | n + 1, x, z, h => by
    simp only [chainOf, List.mem_cons] at h
    rcases h with rfl | h
    · exact ⟨0, Nat.zero_le _, rfl⟩
    · cases hn : next x with
      | none => simp [hn] at h
      | some y =>
        simp only [hn] at h
        obtain ⟨k, hk, e⟩ := mem_chainOf h
        exact ⟨k + 1, by omega, by simp [iter, hn, e]⟩

theorem chainOf_mem : ∀ {k n : Nat} {x z : α}, iter next k x = some z → k ≤ n → z ∈ chainOf next n x
  | 0, n, x, z, h, _ => by
    simp only [iter, Option.some.injEq] at h; subst h; cases n <;> simp [chainOf]
  | k + 1, 0, _, _, _, hk => by omega
  | k + 1, n + 1, x, z, h, hk => by
    simp only [iter] at h
    cases hn : next x with
    | none => simp [hn] at h
    | some y =>
      simp only [hn] at h
      simp only [chainOf, hn, List.mem_cons]
      exact .inr (chainOf_mem h (by omega))

theorem chainOf_ne_nil (n : Nat) (x : α) : chainOf next n x ≠ [] := by cases n <;> simp [chainOf]

theorem length_chainOf : ∀ {n : Nat} {x : α}, (iter next n x).isSome → (chainOf next n x).length = n + 1
  | 0, _, _ => rfl
  | n + 1, x, h => by
    simp only [iter] at h
    cases hn : next x with
    | none => simp [hn] at h
    | some y => simp only [hn] at h; simp [chainOf, hn, length_chainOf h]

/-- A chain without an element twice is without duplicates. -/
theorem nodup_chainOf : ∀ {n : Nat} {x : α},
    (∀ a b, a < b → b ≤ n → iter next a x ≠ iter next b x) → (chainOf next n x).Nodup
  | 0, _, _ => by simp [chainOf]
  | n + 1, x, h => by
    simp only [chainOf]
    cases hn : next x with
    | none => simp
    | some y =>
      refine List.nodup_cons.mpr ⟨fun hm => ?_, nodup_chainOf fun a b hab hb e => ?_⟩
      · obtain ⟨k, hk, e⟩ := mem_chainOf hm
        exact h 0 (k + 1) (by omega) (by omega) (by simp [iter, hn, e])
      · exact h (a + 1) (b + 1) (by omega) (by omega) (by simp [iter, hn, e])

/-- **Pigeonholes**: `n + 1` steps within a list of at most `n` elements meet one element twice. -/
theorem iter_dup {n : Nat} {x : α} {L : List α} (hL : ∀ z ∈ chainOf next n x, z ∈ L) (hs : (iter next n x).isSome)
    (hn : L.length ≤ n) : ∃ a b, a < b ∧ b ≤ n ∧ iter next a x = iter next b x := by
  apply Classical.byContradiction
  intro hc
  have hd : (chainOf next n x).Nodup := nodup_chainOf fun a b hab hb e => hc ⟨a, b, hab, hb, e⟩
  have := hd.length_le_of_subset hL
  rw [length_chainOf hs] at this
  omega

/-- An element that comes back to itself does so within as many steps as there are elements that go on. -/
theorem iter_return (hstop : ∀ y, stop y = true → next y = none) {x : α} {L : List α}
    (hL : ∀ k z, iter next k x = some z → stop z = false → z ∈ L) {G : Nat} (hG : L.length ≤ G + 1) :
    ∀ k, iter next (k + 1) x = some x → ∃ k' ≤ G, iter next (k' + 1) x = some x := by
  intro k
  induction k using Nat.strongRecOn with
  | ind k ih =>
    intro hk
    if hkG : k ≤ G then exact ⟨k, hkG, hk⟩ else
    -- The elements up to `k` go on, so they are in `L`: two of them are the same.
    have hsome : ∀ i ≤ k + 1, (iter next i x).isSome := fun i hi => iter_some_le hi (by simp [hk])
    have hin : ∀ z ∈ chainOf next k x, z ∈ L := by
      intro z hz
      obtain ⟨i, hi, e⟩ := mem_chainOf hz
      refine hL i z e ?_
      cases hst : stop z
      · rfl
      · have := hsome (i + 1) (by omega)
        rw [iter_succ', e, Option.bind_some, hstop z hst] at this
        simp at this
    obtain ⟨a, b, hab, hb, e⟩ := iter_dup hin (hsome k (by omega)) (by omega)
    have := iter_shift e (k + 1 - b)
    rw [show b + (k + 1 - b) = k + 1 by omega, hk] at this
    exact ih (a + k - b) (by omega) (by rw [← this]; congr 1; omega)

/--
**One more step changes nothing** once there are at least as many steps as
elements that go on (`L`, the elements that don't stop).
-/
theorem endOf_succ [BEq α] [LawfulBEq α] (hstop : ∀ y, stop y = true → next y = none) :
    ∀ (n : Nat) (L : List α), L.length ≤ n → ∀ (x : α), (∀ k z, iter next k x = some z → stop z = false → z ∈ L) →
      ∀ F, n ≤ F → endOf stop (chainOf next F x) = endOf stop (chainOf next (F + 1) x) := by
  intro n
  induction n with
  | zero =>
    intro L hL x hx F _
    cases hs : stop x
    · have := hx 0 x rfl hs
      simp at hL; subst hL; simp at this
    · cases F <;> simp [chainOf, endOf, hs]
  | succ n ih =>
    intro L hL x hx F hF
    cases hs : stop x
    case true => cases F <;> simp [chainOf, endOf, hs]
    case false =>
    obtain ⟨G, rfl⟩ : ∃ G, F = G + 1 := ⟨F - 1, by omega⟩
    cases hn : next x with
    | none => simp [chainOf, hn]
    | some y =>
      have hxL : x ∈ L := hx 0 x rfl hs
      rw [chainOf.eq_2, chainOf.eq_2 (n := G + 1), hn]
      by_cases hp : ∃ k, iter next k y = some x
      · -- `x` comes back: it is in both chains, so both end at it.
        obtain ⟨k, hk⟩ := hp
        obtain ⟨k', hk', e⟩ := iter_return hstop hx (G := G) (by omega) k (by simp [iter, hn, hk])
        simp only [iter, hn] at e
        have h1 : (chainOf next G y).contains x := List.elem_iff.mpr (chainOf_mem e hk')
        have h2 : (chainOf next (G + 1) y).contains x := List.elem_iff.mpr (chainOf_mem e (by omega))
        simp only [endOf, h1, h2, Bool.or_true, Bool.true_or, ↓reduceIte]
      · -- It doesn't: both chains go on from `y`, which meets one element fewer that goes on.
        have h1 : (chainOf next G y).contains x = false := by
          cases e : (chainOf next G y).contains x
          · rfl
          · obtain ⟨k, _, hk⟩ := mem_chainOf (List.elem_iff.mp e); exact absurd ⟨k, hk⟩ hp
        have h2 : (chainOf next (G + 1) y).contains x = false := by
          cases e : (chainOf next (G + 1) y).contains x
          · rfl
          · obtain ⟨k, _, hk⟩ := mem_chainOf (List.elem_iff.mp e); exact absurd ⟨k, hk⟩ hp
        have e1 : (chainOf next G y).isEmpty = false := by simp [chainOf_ne_nil]
        have e2 : (chainOf next (G + 1) y).isEmpty = false := by simp [chainOf_ne_nil]
        simp only [endOf, hs, h1, h2, e1, e2, Bool.or_false, Bool.false_eq_true, ↓reduceIte]
        congr 1
        refine ih (L.erase x) (by rw [List.length_erase_of_mem hxL]; omega) y (fun k z hk hz => ?_) G (by omega)
        have hzx : z ≠ x := fun e => hp ⟨k, e ▸ hk⟩
        exact (List.mem_erase_of_ne hzx).mpr (hx (k + 1) z (by simp [iter, hn, hk]) hz)

/-- **Chains are stable**: from `L.length` steps on, a chain ends at the same place. -/
theorem endOf_stable [BEq α] [LawfulBEq α] (hstop : ∀ y, stop y = true → next y = none) {L : List α} {x : α}
    (hx : ∀ k z, iter next k x = some z → stop z = false → z ∈ L) :
    ∀ F, L.length ≤ F → endOf stop (chainOf next F x) = endOf stop (chainOf next L.length x) := by
  intro F hF
  induction F with
  | zero => rw [show L.length = 0 by omega]
  | succ F ih =>
    if h : L.length ≤ F then rw [← endOf_succ hstop L.length L (Nat.le_refl _) x hx F h, ih h]
    else rw [show L.length = F + 1 by omega]

end Abstract

/-! ## Chains of `Maybe`s -/

variable {env : Env}

theorem maybeChain_eq : ∀ (F : Nat) (x : String × Ty), maybeChain env F x = chainOf (nextMaybe env) F x
  | 0, _ => rfl
  | F + 1, x => by
    simp only [maybeChain, chainOf]
    cases nextMaybe env x with
    | none => rfl
    | some y => dsimp only; rw [maybeChain_eq F y]

/-- A link stops a chain when it isn't the prelude's `Maybe`. -/
abbrev stopsChain (x : String × Ty) : Bool := (maybeAt? x.1 x.2).isNone

theorem chainEnd_eq : ∀ l : List (String × Ty), chainEnd l = endOf stopsChain l
  | [] => rfl
  | x :: cs => by simp only [chainEnd, endOf, chainEnd_eq cs]

theorem nextMaybe_stop {x : String × Ty} (h : stopsChain x = true) : nextMaybe env x = none := by
  simp only [stopsChain, Option.isNone_iff_eq_none] at h
  simp [nextMaybe, h]

theorem lookup_mem' {n : String} {b : Ty} : ∀ {l : List (String × Ty)}, l.lookup n = some b → (n, b) ∈ l
  | [], h => by simp at h
  | (k, v) :: l, h => by
    simp only [List.lookup_cons] at h
    split at h
    · rename_i hk; simp at h hk; subst h; subst hk; exact List.mem_cons_self
    · exact List.mem_cons_of_mem _ (lookup_mem' h)

theorem whnf_of_lastRef_none {f : Nat} {d : Ty} {r : Nat × Ty} (hl : lastRef env f d = none)
    (hw : whnf env f d = .ok r) : r = peel d := by
  rcases peel_cases d with hn | ⟨s, n, hp⟩
  · rw [whnf_notRef hn] at hw; exact (Except.ok.inj hw).symm
  · cases f with
    | zero => exact absurd hw (whnf_ref_zero hp)
    | succ f =>
      obtain ⟨d', r', hd, _, _⟩ := whnf_ref_ok hp hw
      simp [lastRef, hp, hd] at hl

/-- The last name on the way to a type is defined, as that type under its secrets. -/
theorem whnf_lastRef : ∀ {f : Nat} {a : Ty} {r : Nat × Ty} {m : String},
    whnf env f a = .ok r → lastRef env f a = some m → ∃ b, env.lookup m = some b ∧ (peel b).2 = r.2
  | 0, _, _, _, _, hl => by simp [lastRef] at hl
  | f + 1, a, r, m, hw, hl => by
    rcases peel_cases a with hn | ⟨s, n, hp⟩
    · unfold lastRef at hl
      split at hl
      · rename_i s' n' e; exact absurd e (hn s' n')
      · simp at hl
    · obtain ⟨d, r', hd, hw', rfl⟩ := whnf_ref_ok hp hw
      simp only [lastRef, hp, hd, Option.some.injEq] at hl
      cases hl' : lastRef env f d with
      | some m' =>
        rw [hl', Option.getD_some] at hl; subst hl
        obtain ⟨b, hb, e⟩ := whnf_lastRef hw' hl'
        exact ⟨b, hb, e⟩
      | none =>
        rw [hl', Option.getD_none] at hl; subst hl
        exact ⟨d, hd, by rw [whnf_of_lastRef_none hl' hw']⟩

/-- The links that go on: the first, and the bodies of definitions (`Maybe#…`). -/
def goOn (env : Env) (x : String × Ty) : List (String × Ty) := x :: env.defs.map fun d => (d.1, (peel d.2).2)

theorem length_goOn (x : String × Ty) : (goOn env x).length = env.fuel := by simp [goOn, Env.fuel]

/--
**A chain goes on only at the bodies of definitions**: after the first link,
a link that isn't the end is a `Maybe#…` reached by name, so `env.fuel`
bounds the links that go on.
-/
theorem links_mem (x : String × Ty) :
    ∀ k z, iter (nextMaybe env) k x = some z → stopsChain z = false → z ∈ goOn env x
  | 0, z, h, _ => by simp only [iter, Option.some.injEq] at h; subst h; exact List.mem_cons_self
  | k + 1, z, h, hz => by
    rw [iter_succ'] at h
    cases hw : iter (nextMaybe env) k x with
    | none => simp [hw] at h
    | some w =>
      simp only [hw, Option.bind_some] at h
      unfold nextMaybe at h
      cases hm : maybeAt? w.1 w.2 with
      | none => simp [hm] at h
      | some a =>
        simp only [hm] at h
        cases hwa : whnf env env.fuel a with
        | error _ => simp [hwa] at h
        | ok r =>
          simp only [hwa, Option.some.injEq] at h
          subst h
          have hpw : preludeMaybe w.1 = true := by
            unfold maybeAt? at hm; split at hm
            · assumption
            · simp at hm
          have hpz : preludeMaybe (origin env w.1 a) = true := by
            simp only [stopsChain] at hz
            unfold maybeAt? at hz; split at hz
            · assumption
            · simp at hz
          cases hl : lastRef env env.fuel a with
          | none =>
            have : origin env w.1 a = "" := by simp only [origin, hl, Option.getD_none, inPlace, hpw, ite_true]
            rw [this] at hpz
            simp [preludeMaybe] at hpz
          | some m =>
            obtain ⟨b, hb, hbr⟩ := whnf_lastRef hwa hl
            have : origin env w.1 a = m := by simp [origin, hl]
            rw [this]
            refine List.mem_cons_of_mem _ (List.mem_map.mpr ⟨(m, b), lookup_mem' hb, ?_⟩)
            simp [hbr]

/-- **`env.fuel` is enough** for the chain of a `Maybe`: with more, `chainNull` is the same. -/
theorem chainNull_fuel {F : Nat} (hF : env.fuel ≤ F) (o : String) (c : Ty) :
    chainNull env F o c = chainNull env env.fuel o c := by
  simp only [chainNull, chainEnd_eq, maybeChain_eq]
  have hs := endOf_stable (fun y h => nextMaybe_stop (env := env) h) (links_mem (o, c))
  rw [length_goOn] at hs
  rw [hs F hF]

theorem usesNull_fuel {F : Nat} (hF : env.fuel ≤ F) (o : String) (c : Ty) :
    usesNull env F o c = usesNull env env.fuel o c := by
  simp only [usesNull, chainNull_fuel hF]

theorem nullArg?_fuel {F : Nat} (hF : env.fuel ≤ F) (o : String) (c : Ty) :
    nullArg? env F o c = nullArg? env env.fuel o c := by
  simp only [nullArg?, usesNull_fuel hF]

/-! ## The JSON functions see the fuel only through `nullArg?` -/

section Congr
variable {F G : Nat}

theorem toJson_congr (h : ∀ o c, nullArg? env F o c = nullArg? env G o c) :
    (∀ b o c x, toJsonC env F b o c x = toJsonC env G b o c x) ∧
    (∀ o tag i ts xs, toJsonArgs env F o tag i ts xs = toJsonArgs env G o tag i ts xs) ∧
    (∀ o fields fs, toJsonFields env F o fields fs = toJsonFields env G o fields fs) ∧
    (∀ o t fs, toJsonEntries env F o t fs = toJsonEntries env G o t fs) ∧
    (∀ o t i xs, toJsonItems env F o t i xs = toJsonItems env G o t i xs) := by
  apply toJsonC.mutual_induct env F
    (fun b o c x => toJsonC env F b o c x = toJsonC env G b o c x)
    (fun o tag i ts xs => toJsonArgs env F o tag i ts xs = toJsonArgs env G o tag i ts xs)
    (fun o fields fs => toJsonFields env F o fields fs = toJsonFields env G o fields fs)
    (fun o t fs => toJsonEntries env F o t fs = toJsonEntries env G o t fs)
    (fun o t i xs => toJsonItems env F o t i xs = toJsonItems env G o t i xs)
  all_goals intros
  all_goals first
    | (rw [toJsonC.eq_def, toJsonC.eq_def]; simp_all; done)
    | simp_all [toJsonC, toJsonArgs, toJsonFields, toJsonEntries, toJsonItems]

theorem fromJson_congr (h : ∀ o c, nullArg? env F o c = nullArg? env G o c) :
    (∀ o t j, fromJsonF env F o t j = fromJsonF env G o t j) ∧
    (∀ b o c j, fromJsonC env F b o c j = fromJsonC env G b o c j) ∧
    (∀ b o c j, readCore env F b o c j = readCore env G b o c j) ∧
    (∀ o tag ts ms, memberValues env F o tag ts ms = memberValues env G o tag ts ms) ∧
    (∀ o tag i ts xs, readArgs env F o tag i ts xs = readArgs env G o tag i ts xs) ∧
    (∀ o tag t ms, memberValue env F o tag t ms = memberValue env G o tag t ms) ∧
    (∀ o cl fields sk ms, readFields env F o cl fields sk ms = readFields env G o cl fields sk ms) ∧
    (∀ o t ms, readEntries env F o t ms = readEntries env G o t ms) ∧
    (∀ o t i xs, readItems env F o t i xs = readItems env G o t i xs) := by
  apply fromJsonF.mutual_induct env F
    (fun o t j => fromJsonF env F o t j = fromJsonF env G o t j)
    (fun b o c j => fromJsonC env F b o c j = fromJsonC env G b o c j)
    (fun b o c j => readCore env F b o c j = readCore env G b o c j)
    (fun o tag ts ms => memberValues env F o tag ts ms = memberValues env G o tag ts ms)
    (fun o tag i ts xs => readArgs env F o tag i ts xs = readArgs env G o tag i ts xs)
    (fun o tag t ms => memberValue env F o tag t ms = memberValue env G o tag t ms)
    (fun o cl fields sk ms => readFields env F o cl fields sk ms = readFields env G o cl fields sk ms)
    (fun o t ms => readEntries env F o t ms = readEntries env G o t ms)
    (fun o t i xs => readItems env F o t i xs = readItems env G o t i xs)
  all_goals intros
  all_goals first
    | (simp_all [fromJsonF, fromJsonC, readCore, memberValues, readArgs, memberValue, readFields, readEntries,
        readItems]; done)
    | (rw [readCore.eq_def, readCore.eq_def]; simp_all; done)
    | (rw [memberValues.eq_def, memberValues.eq_def]; simp_all; done)
    | (simp_all only [Bool.not_eq_true]; simp only [readFields, *, Bool.false_eq_true, ↓reduceIte]; done)

end Congr

theorem nullArg?_fuel₂ {F G : Nat} (hF : env.fuel ≤ F) (hG : env.fuel ≤ G) (o : String) (c : Ty) :
    nullArg? env F o c = nullArg? env G o c := by
  rw [nullArg?_fuel hF, nullArg?_fuel hG]

/-- **Writing gives the same JSON for every fuel from `env.fuel` on.** -/
theorem toJsonF_fuel {F G : Nat} (hF : env.fuel ≤ F) (hG : env.fuel ≤ G) (o : String) (t : Ty) (x : Typed) :
    toJsonF env F o t x = toJsonF env G o t x := by
  simp only [toJsonF, (toJson_congr (nullArg?_fuel₂ hF hG)).1]

/-- **Reading gives the same value for every fuel from `env.fuel` on.** -/
theorem fromJsonF_fuel {F G : Nat} (hF : env.fuel ≤ F) (hG : env.fuel ≤ G) (o : String) (t : Ty) (j : JSON) :
    fromJsonF env F o t j = fromJsonF env G o t j :=
  (fromJson_congr (nullArg?_fuel₂ hF hG)).1 o t j

/-! ## `nullFuel` is enough -/

theorem one_le_size (t : Ty) : 1 ≤ t.size := by
  cases t <;> simp only [Ty.size] <;> omega

theorem length_le_size : ∀ l : List (String × Ty), l.length ≤ (l.map fun d => d.2.size).sum
  | [] => Nat.le_refl _
  | d :: l => by simp only [List.length_cons, List.map_cons, List.sum_cons]; have := one_le_size d.2; have := length_le_size l; omega

/-- `nullFuel`, from the sizes of the types, is at least `env.fuel`. -/
theorem fuel_le_nullFuel (t : Ty) : env.fuel ≤ nullFuel env t := by
  have := length_le_size env.defs
  simp only [Env.fuel, nullFuel, Env.size]
  omega

/-- **`toJson` is `toJsonF` at any fuel from `env.fuel` on**: `nullFuel` is enough. -/
theorem toJson_eq {F : Nat} (hF : env.fuel ≤ F) (t : Ty) (x : Typed) : toJson env t x = toJsonF env F "" t x :=
  toJsonF_fuel (fuel_le_nullFuel t) hF "" t x

/-- **`fromJson` is `fromJsonF` at any fuel from `env.fuel` on.** -/
theorem fromJson_eq {F : Nat} (hF : env.fuel ≤ F) (t : Ty) (j : JSON) : fromJson env t j = fromJsonF env F "" t j :=
  fromJsonF_fuel (fuel_le_nullFuel t) hF "" t j

/-! ## J9 and J11 for `toJson` and `fromJson` -/

/--
**Record cases** (J11) for `toJson` and `fromJson` themselves: `Tag T` with
`T` a record by name and `Tag { … }` write and read alike, although
`nullFuel` counts the two types differently.
-/
theorem record_case_named_json {cl : Bool} {pre post : List Case} {tag : String} {t : Ty}
    {rc : Bool} {fields : List Field} (h : recordOf? env env.fuel t = some (rc, fields)) :
    (∀ x, toJson env (.variant cl (pre ++ .named tag t :: post)) x =
      toJson env (.variant cl (pre ++ .record tag rc fields :: post)) x) ∧
    (∀ j, fromJson env (.variant cl (pre ++ .named tag t :: post)) j =
      fromJson env (.variant cl (pre ++ .record tag rc fields :: post)) j) := by
  obtain ⟨_, ht, hf⟩ := record_case_named (cl := cl) (pre := pre) (post := post) (tag := tag) h
  exact ⟨fun x => by rw [toJson_eq (Nat.le_refl _), toJson_eq (Nat.le_refl _), ht],
    fun j => by rw [fromJson_eq (Nat.le_refl _), fromJson_eq (Nat.le_refl _), hf]⟩

/--
**An older reader accepts a newer writer** (J9) with `toJson` and
`fromJson`, each schema with its own `nullFuel`.
-/
theorem older_reads_newer_json {env env' : Env} (hE : env.Minor env') {t t' : Ty} {v : Value} {x' : Typed}
    {j : JSON} (ht : MinorTy env t t') (hd : decode env' t' v = .ok x') (hv : v.wf = true) (hu : UniqueKeys v)
    (hj : toJson env' t' x' = .ok j) : ∃ y, fromJson env t j = .ok y ∧ Older x' y := by
  rw [toJson_eq (le_max_fuel_right (env := env))] at hj
  rw [fromJson_eq (le_max_fuel_left (env' := env'))]
  exact older_reads_newer hE ht hd hv hu hj

/-! ## A schema's own `closed < None | Some a >` inside a `Maybe` -/

/-- `type T = Maybe (closed < None | Some Int >)`, as `haus-ref` writes it: the prelude's `Maybe` by name. -/
private def ownInMaybe : Env :=
  ⟨[("T", .ref "Maybe#1"),
    ("Maybe#1", .variant true [.bare "None", .positional "Some"
      [.variant true [.bare "None", .positional "Some" [.int .int]]]])]⟩

/- The inner variant is the schema's own (written in place, `origin` `""`): tagged, and the `Maybe` around it uses `null`. -/
#guard match toJson ownInMaybe (.ref "T") (.case "Some" [.case "None" []]) with
  | .ok (.obj [("_tag", .str "None")]) => true
  | _ => false
#guard match toJson ownInMaybe (.ref "T") (.case "None" []) with
  | .ok .null => true
  | _ => false

end Haus.Schema
