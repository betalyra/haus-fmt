import Haus.Lexical

/-!
# A set of keys without hashing (plan step P3; design review D2)

Spec §7: duplicate keys are found in linear time (or `n log n` with a
sorted structure), also on crafted input. The reference parser compares
each key with the keys before it, which is quadratic. Here is a set that
needs neither hashing nor balancing: a **binary trie** over the bits of the
keys' code points. Every code point is at most U+10FFFF, so it has 21 bits
(`charBits`), and a key of `n` characters is a path of `21 · n` bits
(`keyBits`), the same length for every key of `n` characters, so different
keys are different paths (`keyBits_inj`).

* `KeySet.mem_insert`: a key is in `s.insert k` exactly when it is `k` or
  in `s`; `KeySet.mem_empty`: nothing is in the empty set.
* `KeySet.insertC`, `KeySet.memC`: each walks the key's path once,
  `21 · n + 1` steps for a key of `n` characters, however many keys the
  set holds and whatever they are (`KeySet.memC_cost`, `KeySet.insertC_cost`).

So checking a record's keys takes steps linear in their characters, with
no `log n` factor and no assumption about hash collisions. The bindings'
seeded hash tables meet §7 in expectation; this is the deterministic bound.
-/

namespace Haus.Linear
open Haus

/-- A code point as 21 bits, the highest first. -/
def charBits (c : Char) : List Bool := (List.range 21).reverse.map fun i => c.toNat.testBit i

def keyBits : Text → List Bool
  | [] => []
  | c :: s => charBits c ++ keyBits s

theorem charBits_length (c : Char) : (charBits c).length = 21 := by simp [charBits]

theorem keyBits_length (s : Text) : (keyBits s).length = 21 * s.length := by
  induction s with
  | nil => rfl
  | cons c s ih => simp [keyBits, charBits_length, ih]; omega

theorem char_toNat_lt (c : Char) : c.toNat < 2 ^ 21 := by
  have h := c.valid
  simp only [UInt32.isValidChar, Nat.isValidChar] at h
  show c.val.toNat < 2 ^ 21
  omega

theorem charBits_inj {c d : Char} (h : charBits c = charBits d) : c = d := by
  apply Char.toNat_inj.mp
  apply Nat.eq_of_testBit_eq
  intro i
  by_cases hi : i < 21
  · have := congrArg (fun l => l[20 - i]?) h
    simp only [charBits, List.getElem?_map, List.getElem?_reverse (by simp; omega : 20 - i < (List.range 21).length),
      List.length_range, List.getElem?_range (by omega : 21 - 1 - (20 - i) < 21)] at this
    simpa [show 21 - 1 - (20 - i) = i by omega] using this
  · have hc : c.toNat < 2 ^ i := Nat.lt_of_lt_of_le (char_toNat_lt c) (Nat.pow_le_pow_right (by decide) (by omega))
    have hd : d.toNat < 2 ^ i := Nat.lt_of_lt_of_le (char_toNat_lt d) (Nat.pow_le_pow_right (by decide) (by omega))
    rw [Nat.testBit_lt_two_pow hc, Nat.testBit_lt_two_pow hd]

/-- Different keys have different paths. -/
theorem keyBits_inj : ∀ {s u : Text}, keyBits s = keyBits u → s = u
  | [], [], _ => rfl
  | [], d :: u, h => by have := congrArg List.length h; simp [keyBits, charBits_length] at this <;> omega
  | c :: s, [], h => by have := congrArg List.length h; simp [keyBits, charBits_length] at this <;> omega
  | c :: s, d :: u, h => by
    simp only [keyBits] at h
    obtain ⟨h1, h2⟩ := List.append_inj h (by simp [charBits_length])
    rw [charBits_inj h1, keyBits_inj h2]

/-- A binary trie: a set of bit paths. -/
inductive KeySet
  | empty
  | node (here : Bool) (zero one : KeySet)

namespace KeySet

def mem : KeySet → List Bool → Bool
  | empty, _ => false
  | node here _ _, [] => here
  | node _ z _, false :: p => z.mem p
  | node _ _ o, true :: p => o.mem p

def insert : KeySet → List Bool → KeySet
  | empty, [] => node true empty empty
  | empty, false :: p => node false (empty.insert p) empty
  | empty, true :: p => node false empty (empty.insert p)
  | node _ z o, [] => node true z o
  | node h z o, false :: p => node h (z.insert p) o
  | node h z o, true :: p => node h z (o.insert p)

@[simp] theorem mem_empty (p : List Bool) : empty.mem p = false := by cases p <;> rfl

theorem mem_insert (s : KeySet) (p q : List Bool) : (s.insert p).mem q = (q == p || s.mem q) := by
  induction p generalizing s q with
  | nil =>
    cases s <;> cases q with
    | nil => simp [insert, mem]
    | cons b q => cases b <;> simp [insert, mem]
  | cons b p ih =>
    cases s <;> cases q with
    | nil => cases b <;> simp [insert, mem]
    | cons b' q => cases b <;> cases b' <;> simp [insert, mem, ih]

/-- Membership, counting the nodes it visits. -/
def memC : KeySet → List Bool → Bool × Nat
  | empty, _ => (false, 1)
  | node here _ _, [] => (here, 1)
  | node _ z _, false :: p => let r := z.memC p; (r.1, r.2 + 1)
  | node _ _ o, true :: p => let r := o.memC p; (r.1, r.2 + 1)

/-- Insertion, counting the nodes it visits (and copies). -/
def insertC : KeySet → List Bool → KeySet × Nat
  | empty, [] => (node true empty empty, 1)
  | empty, false :: p => let r := empty.insertC p; (node false r.1 empty, r.2 + 1)
  | empty, true :: p => let r := empty.insertC p; (node false empty r.1, r.2 + 1)
  | node _ z o, [] => (node true z o, 1)
  | node h z o, false :: p => let r := z.insertC p; (node h r.1 o, r.2 + 1)
  | node h z o, true :: p => let r := o.insertC p; (node h z r.1, r.2 + 1)

theorem memC_eq (s : KeySet) (p : List Bool) : (s.memC p).1 = s.mem p := by
  induction p generalizing s with
  | nil => cases s <;> rfl
  | cons b p ih => cases s <;> cases b <;> simp [memC, mem, ih]

theorem memC_cost (s : KeySet) (p : List Bool) : (s.memC p).2 ≤ p.length + 1 := by
  induction p generalizing s with
  | nil => cases s <;> simp [memC]
  | cons b p ih => cases s <;> cases b <;> simp [memC] <;> exact ih _

theorem insertC_eq (s : KeySet) (p : List Bool) : (s.insertC p).1 = s.insert p := by
  induction p generalizing s with
  | nil => cases s <;> rfl
  | cons b p ih => cases s <;> cases b <;> simp [insertC, insert, ih]

theorem insertC_cost (s : KeySet) (p : List Bool) : (s.insertC p).2 ≤ p.length + 1 := by
  induction p generalizing s with
  | nil => cases s <;> simp [insertC]
  | cons b p ih => cases s <;> cases b <;> simp [insertC] <;> exact ih _

end KeySet

/-- The set of the keys in `ks`. -/
def keySet (ks : List String) : KeySet := ks.foldr (fun k s => s.insert (keyBits k.toList)) .empty

/-- A key is in the set exactly when it is one of the keys. -/
theorem mem_keySet (ks : List String) (k : String) :
    (keySet ks).mem (keyBits k.toList) = ks.any (· == k) := by
  induction ks with
  | nil => simp [keySet]
  | cons k' ks ih =>
    simp only [keySet, List.foldr_cons] at ih ⊢
    rw [KeySet.mem_insert, ih, List.any_cons]
    by_cases h : k' = k
    · subst h; simp
    · have : keyBits k.toList ≠ keyBits k'.toList := fun e => h (String.toList_inj.mp (keyBits_inj e)).symm
      rw [beq_false_of_ne this, beq_false_of_ne h]

end Haus.Linear
