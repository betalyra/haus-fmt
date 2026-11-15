import Haus.Json.Lossless
import Haus.Json.TextRoundTrip

/-!
# Values within the limits have JSON within the limits (spec §7, §16)

`lossless_fits`: the lossless JSON of a value within the haus limits
(`Value.fits`) is within the JSON limits (`Fits`, nested at most
`jsonDepth L = 4 · maxDepth + 1`), so the JSON text reader reads it back.

Two side conditions on the limits, which the defaults meet
(`Limits.losslessOk_default`):

- member names: the lossless form's own (`num`, `bytes`, `rec`, `tag`,
  `args`) have at most 5 characters;
- number literals: a number goes into a JSON string, and a haus number
  within the limits has at most `maxNumberLength · 6/5 + 4` characters (an
  integer may be longer than `maxNumberLength` when its hex form isn't).

Record keys and tags count against `maxStringLength` in haus as in JSON
(§7), and a byte string's hex has two characters a byte, as `Value.fits`
counts it. Nesting: `Tag { … }` is one level in haus and four in lossless
JSON (`{"tag", "args": [{"rec": {…}}]}`), so `4 · depth + 1` levels.
-/

namespace Haus

/-- What `lossless_fits` needs of the limits: room for the member names and the number literals. -/
def Limits.LosslessOk (L : Limits) : Prop :=
  5 ≤ L.maxStringLength ∧ L.maxNumberLength * 6 / 5 + 4 ≤ L.maxStringLength

theorem Limits.losslessOk_default : Limits.LosslessOk {} := by unfold Limits.LosslessOk; decide

namespace JSON

theorem numberFits_length {L : Limits} {lit : Text} (h : numberFits L lit = true) :
    lit.length ≤ L.maxNumberLength * 6 / 5 + 4 := by
  simp only [numberFits, Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq] at h
  rcases h.2 with h | h
  · omega
  · exact h.1

theorem hex_length (bs : List UInt8) : (Bytes.hex bs).length = 2 * bs.length := by
  induction bs with
  | nil => rfl
  | cons b bs ih => simp [Bytes.hex] at ih ⊢; omega

theorem Value.depth_variant {t : String} {xs : List Value} (hne : xs ≠ []) (hr : ∀ fs, xs ≠ [.record fs]) :
    Value.depth (.variant t xs) = Value.depthList xs + 1 := by
  rcases xs with _ | ⟨x, _ | ⟨y, ys⟩⟩
  · exact absurd rfl hne
  · cases x with
    | record fs => exact absurd rfl (hr fs)
    | _ => rfl
  · cases x <;> rfl

theorem fits_succ {d : Nat} (h : 1 ≤ d) : ∃ d', d = d' + 1 := ⟨d - 1, by omega⟩

variable {L : Limits}

theorem names_le (hL : L.LosslessOk) {ms : List (String × JSON)} (h : ∀ m ∈ ms, m.1.length ≤ 5) :
    ∀ m ∈ ms, m.1.length ≤ L.maxStringLength :=
  fun m hm => Nat.le_trans (h m hm) hL.1

mutual
theorem lossless_fitsD (hL : L.LosslessOk) :
    ∀ (v : Value) {d : Nat}, 4 * v.depth + 1 ≤ d → v.leaves L = true → Fits L d (lossless v)
  | .num s, d, hd, hl => by
    simp only [Value.leaves] at hl
    obtain ⟨d', rfl⟩ := fits_succ hd
    simp only [lossless]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    exact .str _ _ (by have := numberFits_length hl; have := hL.2; rw [String.length_toList] at *; omega)
  | .str s, d, _, hl => by
    simp only [Value.leaves, decide_eq_true_eq] at hl
    exact .str _ _ hl
  | .bytes bs, d, hd, hl => by
    simp only [Value.leaves, decide_eq_true_eq] at hl
    obtain ⟨d', rfl⟩ := fits_succ hd
    simp only [lossless]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    exact .str _ _ (by simp [hex_length]; omega)
  | .arr xs, d, hd, hl => by
    simp only [Value.leaves] at hl
    simp only [Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    simp only [lossless]
    exact .arr _ _ (losslessList_fitsD hL xs (by omega) hl)
  | .record fs, d, hd, hl => by
    simp only [Value.leaves] at hl
    simp only [Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    obtain ⟨d'', rfl⟩ := fits_succ (d := d') (by omega)
    simp only [lossless]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    have h := losslessFields_fitsD hL fs (d := d'') (by omega) hl
    exact .obj _ _ (fun m hm => (h m hm).1) (fun m hm => (h m hm).2)
  | .variant t xs, d, hd, hl => by
    simp only [Value.leaves, Bool.and_eq_true, decide_eq_true_eq] at hl
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    have tag0 : Fits L (d' + 1) (tagged t []) := by
      simp only [tagged, List.isEmpty_nil, ↓reduceIte]
      refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
      simp only [List.mem_singleton, forall_eq]
      exact .str _ _ hl.1
    have htag : ∀ (e : Nat) (args : List JSON), d' = e + 1 → args ≠ [] → (∀ j ∈ args, Fits L e j) →
        Fits L (d' + 1) (tagged t args) := by
      intro e args he hne ha
      subst he
      cases args with
      | nil => exact absurd rfl hne
      | cons a as =>
        simp only [tagged, List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte]
        refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
        intro m hm
        simp only [List.mem_cons, List.not_mem_nil, or_false] at hm
        rcases hm with rfl | rfl
        · exact .str _ _ hl.1
        · exact .arr _ _ ha
    rcases xs with _ | ⟨x, _ | ⟨y, ys⟩⟩
    · exact tag0
    · by_cases hx : ∃ fs, x = .record fs
      · -- `Tag { … }`: four levels
        obtain ⟨fs, rfl⟩ := hx
        simp only [Value.depth] at hd
        simp only [Value.leavesList, Value.leaves, Bool.and_true] at hl
        simp only [lossless, losslessList]
        obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
        refine htag e _ rfl (by simp) ?_
        simp only [List.mem_singleton, forall_eq]
        obtain ⟨a, rfl⟩ := fits_succ (d := e) (by omega)
        refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
        simp only [List.mem_singleton, forall_eq]
        obtain ⟨b, rfl⟩ := fits_succ (d := a) (by omega)
        have h := losslessFields_fitsD hL fs (d := b) (by omega) hl.2
        exact .obj _ _ (fun m hm => (h m hm).1) (fun m hm => (h m hm).2)
      · have hx' : ∀ fs, [x] ≠ [Value.record fs] := fun fs h => hx ⟨fs, by simpa using h⟩
        rw [Value.depth_variant (by simp) hx'] at hd
        simp only [lossless]
        obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
        exact htag e _ rfl (by simp [losslessList]) (losslessList_fitsD hL [x] (by omega) hl.2)
    · rw [Value.depth_variant (by simp) (by simp)] at hd
      simp only [lossless]
      obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
      exact htag e _ rfl (by simp [losslessList]) (losslessList_fitsD hL _ (by omega) hl.2)

theorem losslessList_fitsD (hL : L.LosslessOk) :
    ∀ (xs : List Value) {d : Nat}, 4 * Value.depthList xs + 1 ≤ d → Value.leavesList L xs = true →
      ∀ j ∈ losslessList xs, Fits L d j
  | [], _, _, _ => by simp [losslessList]
  | x :: xs, d, hd, hl => by
    simp only [Value.depthList] at hd
    simp only [Value.leavesList, Bool.and_eq_true] at hl
    simp only [losslessList, List.mem_cons]
    rintro j (rfl | hj)
    · exact lossless_fitsD hL x (by omega) hl.1
    · exact losslessList_fitsD hL xs (by omega) hl.2 j hj

theorem losslessFields_fitsD (hL : L.LosslessOk) :
    ∀ (fs : List (String × Value)) {d : Nat}, 4 * Value.depthFields fs + 1 ≤ d → Value.leavesFields L fs = true →
      ∀ m ∈ losslessFields fs, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2
  | [], _, _, _ => by simp [losslessFields]
  | (k, x) :: fs, d, hd, hl => by
    simp only [Value.depthFields] at hd
    simp only [Value.leavesFields, Bool.and_eq_true, decide_eq_true_eq] at hl
    simp only [losslessFields, List.mem_cons]
    rintro m (rfl | hm)
    · exact ⟨hl.1.1, lossless_fitsD hL x (by omega) hl.1.2⟩
    · exact losslessFields_fitsD hL fs (by omega) hl.2 m hm
end

/--
**Lossless JSON within the limits** (§7, §16.2): the lossless form of a value
within the haus limits is within the JSON limits, when the limits leave room
for the lossless form's member names and number literals (`LosslessOk`).
-/
theorem lossless_fits (hL : L.LosslessOk) {v : Value} (h : v.fits L = true) : Fits L (jsonDepth L) (lossless v) := by
  simp only [Value.fits, Bool.and_eq_true, decide_eq_true_eq] at h
  exact lossless_fitsD hL v (by simp [jsonDepth]; omega) h.2

end JSON
end Haus
