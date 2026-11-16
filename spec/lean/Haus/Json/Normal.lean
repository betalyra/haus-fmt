import Haus.Json.Data
import Haus.RoundTrip.Numbers

/-!
# Normalizing a normalized literal changes nothing (spec §2)

`normalizeNumber_normal`: a normalized literal (`isNormalLit`) is its own
normalized literal. The schema-based reader normalizes a `Decimal` string
(`"1E+05"` is `1e5`); this is why the literal a decimal is written as reads
back unchanged.
-/

namespace Haus

theorem dropWhile_append_of_all {p : Char → Bool} {l₁ l₂ : Text} (h : ∀ c ∈ l₁, p c = true) :
    (l₁ ++ l₂).dropWhile p = l₂.dropWhile p := by
  induction l₁ with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.cons_append, List.dropWhile_cons, h c (by simp), ↓reduceIte]
    exact ih fun d hd => h d (by simp [hd])

theorem takeWhile_append_of_all {p : Char → Bool} {l₁ l₂ : Text} (h : ∀ c ∈ l₁, p c = true) :
    (l₁ ++ l₂).takeWhile p = l₁ ++ l₂.takeWhile p := by
  induction l₁ with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.cons_append, List.takeWhile_cons, h c (by simp), ↓reduceIte]
    rw [ih fun d hd => h d (by simp [hd])]

/-- The digits of an `isIntDigits` integer. -/
theorem isIntDigits_digits {ds : Text} (h : isIntDigits ds = true) : ∀ c ∈ ds, isDigit c = true := by
  unfold isIntDigits at h
  split at h
  · cases h
  · simp only [List.mem_singleton]; intro c hc; subst hc; rfl
  · rename_i c cs _ _
    simp only [Bool.and_eq_true, List.all_eq_true] at h
    intro d hd
    rcases List.mem_cons.mp hd with rfl | hd
    · exact h.1.1
    · exact h.2 d hd

theorem isIntDigits_ne_nil {ds : Text} (h : isIntDigits ds = true) : ds ≠ [] := by
  intro e; subst e; simp [isIntDigits] at h

/-- `stripZeros` leaves an integer without leading zeros alone. -/
theorem stripZeros_intDigits {ds : Text} (h : isIntDigits ds = true) : stripZeros ds = ds := by
  unfold isIntDigits at h
  split at h
  · cases h
  · rfl
  · rename_i _ c cs _
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h
    have h0 : (c == '0') = false := by simpa using h.1.2
    unfold stripZeros
    simp [h0]

theorem notMarker_digit {c : Char} (h : isDigit c = true) : (c != 'e' && c != 'E') = true := by
  have : c ≠ 'e' ∧ c ≠ 'E' := by
    constructor <;> (intro e; subst e; simp [isDigit] at h)
  simp [this.1, this.2]

theorem normalizeExponent_plain {c : Char} {cs : Text} (h1 : c ≠ '-') (h2 : c ≠ '+') :
    normalizeExponent (c :: cs) = stripZeros (c :: cs) := by
  simp [normalizeExponent, h1, h2]

/-- The exponent part of a normalized literal: empty, or `e` and a normalized exponent. -/
theorem normalExp_shape {e : Text} (h : normalTail.normalExp e = true) :
    e = [] ∨ ∃ x, e = 'e' :: x ∧ normalizeExponent x = x := by
  unfold normalTail.normalExp at h
  split at h
  · exact .inl rfl
  · cases h
  · rename_i ds hne
    refine .inr ⟨'-' :: ds, rfl, ?_⟩
    unfold normalizeExponent
    simp only [stripZeros_intDigits h]
    have : ds ≠ ['0'] := fun e => hne (by rw [e])
    simp [this]
  · rename_i ds h1 h2
    refine .inr ⟨ds, rfl, ?_⟩
    have hd := isIntDigits_digits h
    match ds, hd, isIntDigits_ne_nil h, h with
    | c :: cs, hd, _, h =>
      have hc := hd c (by simp)
      have : c ≠ '-' ∧ c ≠ '+' := by constructor <;> (intro e; subst e; simp [isDigit] at hc)
      rw [normalizeExponent_plain this.1 this.2, stripZeros_intDigits h]
  · cases h

/-- The characters of a normalized literal after its sign: digits, `.`, `e`, `-`. -/
theorem normal_split {r : Text} (hn : isIntDigits (r.takeWhile isDigit) = true)
    (ht : normalTail (r.dropWhile isDigit) = true) :
    ∃ m e, r = m ++ e ∧ (∀ c ∈ m, (c != 'e' && c != 'E') = true ∧ c ≠ '_') ∧
      (e = [] ∨ ∃ x, e = 'e' :: x ∧ normalizeExponent x = x ∧ ∀ c ∈ x, c ≠ '_') := by
  have hr : r = r.takeWhile isDigit ++ r.dropWhile isDigit := (List.takeWhile_append_dropWhile).symm
  have hi := isIntDigits_digits hn
  have expNo : ∀ {e : Text}, normalTail.normalExp e = true → ∀ c ∈ e, c ≠ '_' := by
    intro e he c hc
    unfold normalTail.normalExp at he
    split at he
    · simp at hc
    · cases he
    · rename_i ds _
      have := isIntDigits_digits he
      simp only [List.mem_cons] at hc
      rcases hc with rfl | rfl | hc
      · decide
      · decide
      · intro e; subst e; exact absurd (this _ hc) (by decide)
    · rename_i ds _ _
      have := isIntDigits_digits he
      simp only [List.mem_cons] at hc
      rcases hc with rfl | hc
      · decide
      · intro e; subst e; exact absurd (this _ hc) (by decide)
    · cases he
  have dig : ∀ c, isDigit c = true → (c != 'e' && c != 'E') = true ∧ c ≠ '_' := fun c h =>
    ⟨notMarker_digit h, by intro e; subst e; simp [isDigit] at h⟩
  unfold normalTail at ht
  split at ht
  · rename_i r' he
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at ht
    have hf := List.all_takeWhile (p := isDigit) (l := r')
    refine ⟨r.takeWhile isDigit ++ '.' :: r'.takeWhile isDigit, r'.dropWhile isDigit, ?_, ?_, ?_⟩
    · have h2 : r = r.takeWhile isDigit ++ '.' :: r' := by rw [← he]; exact hr
      exact h2.trans (by simp [List.takeWhile_append_dropWhile])
    · intro c hc
      simp only [List.mem_append, List.mem_cons] at hc
      rcases hc with hc | rfl | hc
      · exact dig c (hi c hc)
      · decide
      · exact dig c (List.all_eq_true.mp hf c hc)
    · rcases normalExp_shape ht.2 with h | ⟨x, hx, hnx⟩
      · exact .inl h
      · exact .inr ⟨x, hx, hnx, fun c hc => expNo ht.2 c (by rw [hx]; simp [hc])⟩
  · refine ⟨r.takeWhile isDigit, r.dropWhile isDigit, hr, fun c hc => dig c (hi c hc), ?_⟩
    rcases normalExp_shape ht with h | ⟨x, hx, hnx⟩
    · exact .inl h
    · exact .inr ⟨x, hx, hnx, fun c hc => expNo ht c (by rw [hx]; simp [hc])⟩

/-- The body of a normalized literal, normalized, is itself. -/
theorem normalizeBody_normal (neg : Bool) {r : Text} (hn : isIntDigits (r.takeWhile isDigit) = true)
    (ht : normalTail (r.dropWhile isDigit) = true) :
    normalizeBody neg r = String.ofList ((if neg then ['-'] else []) ++ r) := by
  obtain ⟨m, e, rfl, hm, he⟩ := normal_split hn ht
  have hnu : ∀ c ∈ m ++ e, c ≠ '_' := by
    intro c hc
    rcases List.mem_append.mp hc with hc | hc
    · exact (hm c hc).2
    · rcases he with rfl | ⟨x, rfl, -, hx⟩
      · simp at hc
      · rcases List.mem_cons.mp hc with rfl | hc
        · decide
        · exact hx c hc
  have hf : (m ++ e).filter (· != '_') = m ++ e := List.filter_eq_self.mpr fun c hc => by simpa using hnu c hc
  -- The literal doesn't start with `0x` or `0b`: its integer part is `0` alone or doesn't start with `0`.
  have hx : ∀ ds, m ++ e ≠ '0' :: 'x' :: ds ∧ m ++ e ≠ '0' :: 'b' :: ds := by
    intro ds
    constructor <;> intro heq <;> rw [heq] at ht <;> simp [isDigit, normalTail, normalTail.normalExp] at ht
  unfold normalizeBody
  rw [hf]
  split
  · rename_i ds heq; exact absurd heq (hx ds).1
  · rename_i ds heq; exact absurd heq (hx ds).2
  · simp only
    rw [takeWhile_append_of_all (fun c hc => (hm c hc).1), dropWhile_append_of_all (fun c hc => (hm c hc).1)]
    rcases he with rfl | ⟨x, rfl, hnx, -⟩
    · simp
    · simp [hnx]

/-- **A normalized literal is its own normalized literal.** -/
theorem normalizeNumber_normal {s : String} (h : isNormalLit s.toList = true) : normalizeNumber s.toList = s := by
  unfold isNormalLit at h
  simp only [Bool.and_eq_true] at h
  apply String.toList_inj.mp
  generalize s.toList = t at h ⊢
  cases t with
  | nil => exact absurd h.1 (by decide)
  | cons c r =>
    by_cases hc : c = '-'
    · subst hc
      simp only [dropMinus] at h
      rw [RoundTrip.normalizeNumber_minus, normalizeBody_normal true h.1 h.2]
      simp
    · have hd : dropMinus (c :: r) = c :: r := by
        unfold dropMinus
        split
        · rename_i r' he; cases he; exact absurd rfl hc
        · rfl
      rw [hd] at h
      rw [RoundTrip.normalizeNumber_plain (by simpa using hc), normalizeBody_normal false h.1 h.2]
      simp

theorem normalExp_json {e : Text} (h : normalTail.normalExp e = true) : jsonTail.jsonExp e = true := by
  unfold normalTail.normalExp at h
  split at h
  · rfl
  · cases h
  · rename_i ds _
    have hd := isIntDigits_digits h
    simp [jsonTail.jsonExp, isIntDigits_ne_nil h, List.all_eq_true.mpr hd]
  · rename_i ds _ hm
    have hd := isIntDigits_digits h
    match ds, hd, isIntDigits_ne_nil h with
    | c :: cs, hd, _ =>
      have hc := hd c (by simp)
      have : c ≠ '-' ∧ c ≠ '+' := by constructor <;> (intro e; subst e; simp [isDigit] at hc)
      simp [jsonTail.jsonExp, this.2, List.all_eq_true.mpr hd]
  · cases h

/-- A normalized literal is a JSON number. -/
theorem isNormalLit_json {t : Text} (h : isNormalLit t = true) : isJsonNumber t = true := by
  unfold isNormalLit at h
  unfold isJsonNumber
  simp only [Bool.and_eq_true] at h ⊢
  refine ⟨h.1, ?_⟩
  have ht := h.2
  unfold normalTail at ht
  unfold jsonTail
  split at ht
  · simp only [Bool.and_eq_true] at ht ⊢
    exact ⟨ht.1, normalExp_json ht.2⟩
  · exact normalExp_json ht

#guard ["0", "-0", "19.90", "1e5", "1e-7", "-1.5e3", "1e0", "255", "0.0e-12"].all fun s =>
  normalizeNumber s.toList == s

end Haus
