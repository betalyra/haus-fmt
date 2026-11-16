import Haus.Json.SelfDescribing
import Haus.Json.TextRoundTrip

/-!
# Values within the limits have JSON within the limits (spec §7, §16)

`selfDescribing_fits`: the self-describing form of a value within the haus
limits (`Value.fits`) is within the JSON limits (`Fits`, nested at most
`jsonDepth L = 4 · maxDepth + 1`); `hausJson_fits`: so is its
self-describing JSON, with the envelope one level more (`hausJsonDepth L`).
So the JSON text reader reads them back.

Side conditions on the limits, which the defaults meet
(`Limits.selfDescribingOk_default`):

- member names: the form's own (`_num`, `_bytes`, `_rec`, `_tag`, `_args`,
  `_haus`, `_value`) have at most 6 characters;
- number literals: a number goes into a JSON string, and a haus number
  within the limits has at most `maxNumberLength` characters;
- the envelope's version `1` is a number token within the limits.

Record keys and tags count against `maxStringLength` in haus as in JSON
(§7), and a byte string's hex has two characters a byte, as `Value.fits`
counts it. Nesting: `Tag { … }` is one level in haus and four in
self-describing JSON (`{"_tag", "_args": [{"_rec": {…}}]}`), so
`4 · depth + 1` levels, and one more for the envelope.
-/

namespace Haus

/-- What `hausJson_fits` needs of the limits: room for the member names, the number literals and the version. -/
def Limits.SelfDescribingOk (L : Limits) : Prop :=
  6 ≤ L.maxStringLength ∧ L.maxNumberLength ≤ L.maxStringLength ∧ 1 ≤ L.maxNumberLength

theorem Limits.selfDescribingOk_default : Limits.SelfDescribingOk {} := by unfold Limits.SelfDescribingOk; decide

namespace JSON

theorem numberFits_length {L : Limits} {lit : Text} (h : numberFits L lit = true) :
    lit.length ≤ L.maxNumberLength := by
  simp only [numberFits, Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.1

/-- A haus number within the limits is a JSON number token within them: both count the literal as written. -/
theorem numberFits_tokenFits {L : Limits} {lit : Text} (h : numberFits L lit = true) : tokenFits L lit = true := by
  simpa [numberFits, tokenFits] using h

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

theorem names_le (hL : L.SelfDescribingOk) {ms : List (String × JSON)} (h : ∀ m ∈ ms, m.1.length ≤ 6) :
    ∀ m ∈ ms, m.1.length ≤ L.maxStringLength :=
  fun m hm => Nat.le_trans (h m hm) hL.1

mutual
theorem selfDescribing_fitsD (hL : L.SelfDescribingOk) :
    ∀ (v : Value) {d : Nat}, 4 * v.depth + 1 ≤ d → v.leaves L = true → Fits L d (selfDescribing v)
  | .num s, d, hd, hl => by
    simp only [Value.leaves] at hl
    obtain ⟨d', rfl⟩ := fits_succ hd
    simp only [selfDescribing]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    exact .str _ _ (by have := numberFits_length hl; have := hL.2; rw [String.length_toList] at *; omega)
  | .str s, d, _, hl => by
    simp only [Value.leaves, decide_eq_true_eq] at hl
    exact .str _ _ hl
  | .bytes bs, d, hd, hl => by
    simp only [Value.leaves, decide_eq_true_eq] at hl
    obtain ⟨d', rfl⟩ := fits_succ hd
    simp only [selfDescribing]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    exact .str _ _ (by simp [hex_length]; omega)
  | .arr xs, d, hd, hl => by
    simp only [Value.leaves] at hl
    simp only [Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    simp only [selfDescribing]
    exact .arr _ _ (selfDescribingList_fitsD hL xs (by omega) hl)
  | .record fs, d, hd, hl => by
    simp only [Value.leaves] at hl
    simp only [Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    obtain ⟨d'', rfl⟩ := fits_succ (d := d') (by omega)
    simp only [selfDescribing]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    have h := selfDescribingFields_fitsD hL fs (d := d'') (by omega) hl
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
        simp only [selfDescribing, selfDescribingList]
        obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
        refine htag e _ rfl (by simp) ?_
        simp only [List.mem_singleton, forall_eq]
        obtain ⟨a, rfl⟩ := fits_succ (d := e) (by omega)
        refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
        simp only [List.mem_singleton, forall_eq]
        obtain ⟨b, rfl⟩ := fits_succ (d := a) (by omega)
        have h := selfDescribingFields_fitsD hL fs (d := b) (by omega) hl.2
        exact .obj _ _ (fun m hm => (h m hm).1) (fun m hm => (h m hm).2)
      · have hx' : ∀ fs, [x] ≠ [Value.record fs] := fun fs h => hx ⟨fs, by simpa using h⟩
        rw [Value.depth_variant (by simp) hx'] at hd
        simp only [selfDescribing]
        obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
        exact htag e _ rfl (by simp [selfDescribingList]) (selfDescribingList_fitsD hL [x] (by omega) hl.2)
    · rw [Value.depth_variant (by simp) (by simp)] at hd
      simp only [selfDescribing]
      obtain ⟨e, rfl⟩ := fits_succ (d := d') (by omega)
      exact htag e _ rfl (by simp [selfDescribingList]) (selfDescribingList_fitsD hL _ (by omega) hl.2)

theorem selfDescribingList_fitsD (hL : L.SelfDescribingOk) :
    ∀ (xs : List Value) {d : Nat}, 4 * Value.depthList xs + 1 ≤ d → Value.leavesList L xs = true →
      ∀ j ∈ selfDescribingList xs, Fits L d j
  | [], _, _, _ => by simp [selfDescribingList]
  | x :: xs, d, hd, hl => by
    simp only [Value.depthList] at hd
    simp only [Value.leavesList, Bool.and_eq_true] at hl
    simp only [selfDescribingList, List.mem_cons]
    rintro j (rfl | hj)
    · exact selfDescribing_fitsD hL x (by omega) hl.1
    · exact selfDescribingList_fitsD hL xs (by omega) hl.2 j hj

theorem selfDescribingFields_fitsD (hL : L.SelfDescribingOk) :
    ∀ (fs : List (String × Value)) {d : Nat}, 4 * Value.depthFields fs + 1 ≤ d → Value.leavesFields L fs = true →
      ∀ m ∈ selfDescribingFields fs, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2
  | [], _, _, _ => by simp [selfDescribingFields]
  | (k, x) :: fs, d, hd, hl => by
    simp only [Value.depthFields] at hd
    simp only [Value.leavesFields, Bool.and_eq_true, decide_eq_true_eq] at hl
    simp only [selfDescribingFields, List.mem_cons]
    rintro m (rfl | hm)
    · exact ⟨hl.1.1, selfDescribing_fitsD hL x (by omega) hl.1.2⟩
    · exact selfDescribingFields_fitsD hL fs (by omega) hl.2 m hm
end

/--
**A self-describing value within the limits** (§7, §16.2): the
self-describing form of a value within the haus limits is within the JSON
limits, when the limits leave room for the form's member names and number
literals (`SelfDescribingOk`).
-/
theorem selfDescribing_fits (hL : L.SelfDescribingOk) {v : Value} (h : v.fits L = true) : Fits L (jsonDepth L) (selfDescribing v) := by
  simp only [Value.fits, Bool.and_eq_true, decide_eq_true_eq] at h
  exact selfDescribing_fitsD hL v (by simp [jsonDepth]; omega) h.2

/--
**Self-describing JSON within the limits** (§7, §16.2): the self-describing
JSON of a value within the haus limits, its envelope included, is within the
JSON limits, nested at most `4 · maxDepth + 2`.
-/
theorem hausJson_fits (hL : L.SelfDescribingOk) {v : Value} (h : v.fits L = true) :
    Fits L (hausJsonDepth L) (hausJson v) := by
  refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
  intro m hm
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl
  · exact .num _ _ (by simp [tokenFits, exponentOf]; exact hL.2.2)
  · exact selfDescribing_fits hL h

end JSON
end Haus
