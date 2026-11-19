import Haus.Linear.Agree
import Haus.Linear.Spec
import Haus.Sound.Values
import Haus.RoundTrip.Digits

/-!
# The leaves take linear time (plan step P3)

For whitespace, numbers, strings, block strings, byte strings and keys
(`Leaf`): on success they read at least one character and take at most 50
steps per character read; on failure at most 50 per character left, and 50.
Whitespace takes two steps per character (`wsC_spec`), and reads the blanks
it starts at. A key is no longer than the text it was read from, so the
trie's `21 · n` steps per key are paid by its characters (`keyC_spec`).

Each count follows the reference function's recursion (`Haus.Linear.Parser`);
the lemmas bound it by what the function read: `wsSteps_ok`, `bcCost_ok`,
`lexNumberCost_le` (the lexers, `2 · literal + 13`), `normalizeNumber_length`
(a hex literal's decimal form has at most two digits per hex digit),
`charsSteps_spec` (four steps per character of a string, escapes and the
final reverse included), `blockBodyCost_ok`, `byteCharsCost_ok`.
`Haus.Linear.Bound` puts them together.
-/

namespace Haus.Linear
open Haus Parser Sound

/-- The blanks at the start of a text: what a lookahead past a tag reads twice. -/
def blanks (t : Text) : Nat := (t.takeWhile isBlank).length

theorem takeWhile_dropWhile_length (p : Char → Bool) (l : Text) :
    (l.takeWhile p).length + (l.dropWhile p).length = l.length := by
  have := congrArg List.length (List.takeWhile_append_dropWhile (p := p) (l := l))
  rw [List.length_append] at this
  exact this

theorem blanks_le (t : Text) : blanks t ≤ t.length := by
  have := takeWhile_dropWhile_length isBlank t; unfold blanks; omega

/-! ## Whitespace -/

theorem bcCost_le (d : Nat) (r : Text) : bcCost d r ≤ r.length + 1 := by
  fun_induction bcCost d r <;> simp <;> omega

theorem bcCost_ok (start : Text) (d : Nat) (r : Text) :
    ∀ rest, blockComment start d r = .ok rest → bcCost d r + rest.length + 1 ≤ r.length := by
  fun_induction bcCost d r with
  | case1 => intro rest h; simp [blockComment] at h
  | case2 d r ih => intro rest h; rw [blockComment] at h; have := ih rest h; simp; omega
  | case3 d r hle => intro rest h; simp [blockComment, hle] at h; subst h; simp; omega
  | case4 d r hle ih => intro rest h; simp [blockComment, hle] at h; have := ih rest h; simp; omega
  | case5 d c r hno1 hno2 hb => intro rest h; rw [blockComment] at h <;> simp_all
  | case6 d c r hno1 hno2 hb hc => intro rest h; rw [blockComment] at h <;> simp_all
  | case7 d c r hno1 hno2 hb hc ih =>
    intro rest h
    rw [blockComment] at h
    · split at h
      · simp at h
      · have := ih rest h
        simp; omega
    all_goals simp_all

theorem lineBody_length (r : Text) :
    (lineBody r).length + (r.dropWhile fun c => c != '\n' && c != '\r').length = r.length :=
  takeWhile_dropWhile_length _ r

theorem blockComment_length {start : Text} {d : Nat} {r rest : Text} (h : blockComment start d r = .ok rest) :
    rest.length + 1 ≤ r.length := by
  have := bcCost_ok start d r rest h; omega

theorem wsSteps_le : ∀ n t, wsSteps n t ≤ 2 * t.length + 1
  | 0, _ => by simp [wsSteps]
  | n + 1, t => by
    unfold wsSteps
    split
    · next r => have := wsSteps_le n r; simp; omega
    · next r => have := wsSteps_le n r; simp; omega
    · next r => have := wsSteps_le n r; simp; omega
    · next r => have := wsSteps_le n r; simp; omega
    · simp
    · rename_i r
      have := lineBody_length r
      split
      · simp; omega
      · have := wsSteps_le n (r.dropWhile fun c => c != '\n' && c != '\r'); simp; omega
    · rename_i r
      have := bcCost_le 1 r
      split
      · rename_i r' h
        have := bcCost_ok _ _ _ _ h
        have := wsSteps_le n r'
        simp; omega
      · simp; omega
    all_goals simp

@[simp] theorem blanks_cons_blank (c : Char) (r : Text) (h : isBlank c = true) : blanks (c :: r) = blanks r + 1 := by
  simp [blanks, h]

theorem blanks_cons_not (c : Char) (r : Text) (h : isBlank c = false) : blanks (c :: r) = 0 := by
  simp [blanks, h]

theorem wsSteps_ok : ∀ n t r, (wsLoop n).run t = .ok ((), r) →
    wsSteps n t + 2 * r.length ≤ 2 * t.length + 1 ∧ blanks t + r.length ≤ t.length
  | 0, _, _, h => by simp [wsLoop] at h
  | n + 1, t, r, h => by
    simp only [wsLoop, run_bind, run_get] at h
    unfold wsSteps
    split at h
    · simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h; simp [blanks, isBlank] at *; omega
    · simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h; simp [blanks, isBlank] at *; omega
    · simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h; simp [blanks, isBlank] at *; omega
    · simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h; simp [blanks, isBlank] at *; omega
    · simp at h
    · rename_i r0
      simp only [run_bind, run_set, run_takeWhile] at h
      split at h
      · split at h <;> simp at h
      · rename_i hnone
        obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h
        have := lineBody_length r0
        simp only [lineBody] at this
        simp [blanks, isBlank, lineBody, hnone] at *
        omega
    · rename_i r0
      cases hbc : blockComment ('/' :: '*' :: r0) 1 r0 with
      | error e => simp [hbc] at h
      | ok rest0 =>
        simp only [run_bind, run_liftM, hbc, run_set] at h
        obtain ⟨h1, h2⟩ := wsSteps_ok n _ _ h
        have := bcCost_ok _ _ _ _ hbc
        simp [blanks, isBlank, hbc] at *
        omega
    · simp at h
    · simp at h
      subst h
      rename_i h1 h2 h3 h4 h5 h6 h7 h8
      constructor
      · split <;> simp_all <;> omega
      · cases t with
        | nil => simp [blanks]
        | cons c r =>
          have hc1 : c ≠ ' ' := by rintro rfl; exact h1 r rfl
          have hc2 : c ≠ '\t' := by rintro rfl; exact h2 r rfl
          simp [blanks, isBlank, hc1, hc2]

/-- **Whitespace**: two steps per character, and two; it reads the blanks it starts at. -/
theorem wsC_spec (t : Text) :
    Spec wsC t (fun _ t' c => c + 2 * t'.length ≤ 2 * t.length + 2 ∧ blanks t + t'.length ≤ t.length)
      (fun c => c ≤ 2 * t.length + 2) := by
  apply spec_liftP
  · intro _ t' h
    simp only [ws, run_bind, run_get] at h
    have := wsSteps_ok _ _ _ h
    omega
  · intro _ _
    have := wsSteps_le (t.length + 1) t
    omega

/-! ## The other leaves -/

/-- A leaf's bound: on success it reads a character or more, `K` steps per character read; on failure `K` steps per character left, and `K`. -/
def Leaf {α : Type} (K : Nat) (m : PC α) : Prop := ∀ t,
  Spec m t (fun _ t' c => t'.length < t.length ∧ c + K * t'.length ≤ K * t.length) (fun c => c ≤ K * t.length + K)


/-! ### Numbers -/

theorem sepTailCost_le (p : Char → Bool) (t : Text) : sepTailCost p t ≤ (sepTail p t).1.length + 1 := by
  fun_induction sepTail p t <;> simp_all [sepTailCost] <;> omega

theorem digitsCost_some (p : Char → Bool) (t a b : Text) (h : digits p t = some (a, b)) :
    digitsCost p t ≤ a.length + 1 := by
  cases t with
  | nil => simp [digits] at h
  | cons c r =>
    obtain ⟨hp, rfl, rfl⟩ := digits_cons _ _ _ _ _ h
    have := sepTailCost_le p r
    simp [digitsCost, hp]; omega

theorem digitsCost_none (p : Char → Bool) (t : Text) (h : digits p t = none) : digitsCost p t ≤ 1 := by
  cases t with
  | nil => simp [digitsCost]
  | cons c r => cases hp : p c <;> simp_all [digits, digitsCost]

theorem lexIntCost_le (r : Text) :
    lexIntCost r ≤ (match lexInt r with | some (i, _) => i.length | none => 0) + 2 := by
  cases r with
  | nil => simp [lexInt, lexIntCost]
  | cons c rest =>
    by_cases hc : c = '0'
    · subst hc; simp [lexInt, lexIntCost]
    · have e1 : lexInt (c :: rest) = digits isDigit (c :: rest) := by simp [lexInt, hc]
      have e2 : lexIntCost (c :: rest) = digitsCost isDigit (c :: rest) + 1 := by simp [lexIntCost, hc]
      rw [e1, e2]
      cases hd : digits isDigit (c :: rest) with
      | none => have := digitsCost_none _ _ hd; simp; omega
      | some x => obtain ⟨a, b⟩ := x; have := digitsCost_some _ _ _ _ hd; simp; omega

theorem lexFracCost_le (r : Text) : lexFracCost r ≤ (lexFrac r).1.length + 2 := by
  cases r with
  | nil => simp [lexFracCost, lexFrac]
  | cons c r' =>
    by_cases hc : c = '.'
    · subst hc
      simp only [lexFracCost, lexFrac]
      cases hd : digits isDigit r' with
      | none => have := digitsCost_none _ _ hd; simp; omega
      | some x => obtain ⟨ds, b⟩ := x; have := digitsCost_some _ _ _ _ hd; simp; omega
    · rw [lexFracCost.eq_2 _ (by simpa using hc)]; simp

theorem lexExpCost_le (r : Text) : lexExpCost r ≤ (lexExp r).1.length + 3 := by
  cases r with
  | nil => simp [lexExpCost, lexExp]
  | cons m r' =>
    simp only [lexExpCost, lexExp]
    split
    · cases hd : digits isDigit (lexSign r').2 with
      | none => have := digitsCost_none _ _ hd; simp; omega
      | some x => obtain ⟨ds, b⟩ := x; have := digitsCost_some _ _ _ _ hd; simp; omega
    · simp

theorem lexDecimalCost_le (s r : Text) :
    lexDecimalCost s r ≤ 2 * litLen (lexDecimal s r) + 8 := by
  have hi := lexIntCost_le r
  unfold lexDecimalCost
  cases h : lexInt r with
  | none => simp [h] at hi; simp [lexDecimal, h, litLen, afterIntCost]; omega
  | some x =>
    obtain ⟨i, r'⟩ := x
    simp [h] at hi
    have := lexFracCost_le r'
    have := lexExpCost_le (lexFrac r').2
    simp [lexDecimal, h, litLen, afterIntCost]
    omega

theorem lexRadixCost_le (p : Char → Bool) (s pre r : Text) :
    lexRadixCost p s pre r ≤ 2 * litLen (lexRadix p s pre r) + 2 := by
  unfold lexRadixCost
  cases hd : digits p r with
  | none => have := digitsCost_none _ _ hd; simp [lexRadix, hd, litLen]; omega
  | some x =>
    obtain ⟨a, b⟩ := x
    have := digitsCost_some _ _ _ _ hd
    simp [lexRadix, hd, litLen]
    omega

theorem lexUnsignedCost_le (s r : Text) :
    lexUnsignedCost s r ≤ 2 * litLen (lexUnsigned s r) + 12 := by
  unfold lexUnsignedCost
  split
  · rename_i r'
    have e : lexUnsigned s ('0' :: 'x' :: r') =
        (lexRadix isHexDigit s ['0', 'x'] r' <|> lexDecimal s ('0' :: 'x' :: r')) := rfl
    rw [e]
    have h1 := lexRadixCost_le isHexDigit s ['0', 'x'] r'
    have h2 := lexDecimalCost_le s ('0' :: 'x' :: r')
    cases hr : lexRadix isHexDigit s ['0', 'x'] r' <;> simp [hr, litLen] at h1 h2 ⊢ <;> omega
  · rename_i r'
    have e : lexUnsigned s ('0' :: 'b' :: r') =
        (lexRadix isBinDigit s ['0', 'b'] r' <|> lexDecimal s ('0' :: 'b' :: r')) := rfl
    rw [e]
    have h1 := lexRadixCost_le isBinDigit s ['0', 'b'] r'
    have h2 := lexDecimalCost_le s ('0' :: 'b' :: r')
    cases hr : lexRadix isBinDigit s ['0', 'b'] r' <;> simp [hr, litLen] at h1 h2 ⊢ <;> omega
  · rename_i h1 h2
    rw [lexUnsigned.eq_3 s _ h1 h2]
    have := lexDecimalCost_le s r; omega

theorem hexValue_lt16 (c : Char) : hexValue c < 16 := by
  by_cases h1 : isDigit c = true
  · have := RoundTrip.hexValue_digit h1; omega
  · by_cases h2 : ('a' ≤ c && c ≤ 'f') = true
    · exact RoundTrip.hexValue_hex (by simp [isHexDigit, h2])
    · by_cases h3 : ('A' ≤ c && c ≤ 'F') = true
      · exact RoundTrip.hexValue_hex (by simp [isHexDigit, h3])
      · have : hexValue c = 0 := by
          unfold hexValue
          simp [h1, h2, h3]
        omega

theorem digitsValue_lt16 {b : Nat} (hb : b ≤ 16) (ds : Text) : digitsValue b ds < 16 ^ ds.length := by
  have : ∀ acc, ds.foldl (fun n c => n * b + hexValue c) acc < (acc + 1) * 16 ^ ds.length := by
    induction ds with
    | nil => intro acc; simp
    | cons c cs ih =>
      intro acc
      have hc := hexValue_lt16 c
      have := ih (acc * b + hexValue c)
      simp only [List.foldl_cons, List.length_cons, Nat.pow_succ]
      calc _ < (acc * b + hexValue c + 1) * 16 ^ cs.length := this
        _ ≤ (acc + 1) * (16 ^ cs.length * 16) := by
          rw [Nat.mul_comm (16 ^ cs.length) 16, ← Nat.mul_assoc]
          refine Nat.mul_le_mul_right _ ?_
          have := Nat.mul_le_mul_left acc hb
          rw [Nat.add_mul, Nat.one_mul]; omega
  simpa [digitsValue] using this 0

/-- The decimal form of a number of `m` hex digits has at most `2 · m + 1` digits. -/
theorem repr_length_le {b : Nat} (hb : b ≤ 16) (ds : Text) : (toString (digitsValue b ds)).length ≤ 2 * ds.length + 1 := by
  show (Nat.repr _).length ≤ _
  rw [Nat.length_repr_le_iff (by omega)]
  refine Nat.lt_of_lt_of_le (digitsValue_lt16 hb ds) ?_
  calc 16 ^ ds.length ≤ 100 ^ ds.length := Nat.pow_le_pow_left (by omega) _
    _ = 10 ^ (2 * ds.length) := by rw [Nat.pow_mul]
    _ ≤ 10 ^ (2 * ds.length + 1) := Nat.pow_le_pow_right (by omega) (by omega)

theorem stripZeros_length (ds : Text) : (stripZeros ds).length ≤ ds.length + 1 := by
  unfold stripZeros
  have := takeWhile_dropWhile_length (· == '0') ds
  split <;> simp_all <;> omega

theorem normalizeExponent_length (e : Text) : (normalizeExponent e).length ≤ e.length + 1 := by
  rcases e with _ | ⟨c, r⟩
  · simp [normalizeExponent, stripZeros]
  · by_cases h1 : c = '-'
    · subst h1; have := stripZeros_length r; simp only [normalizeExponent]; split <;> simp <;> omega
    · by_cases h2 : c = '+'
      · subst h2; have := stripZeros_length r; simp only [normalizeExponent]; split <;> simp <;> omega
      · have := stripZeros_length (c :: r)
        have e : normalizeExponent (c :: r) = stripZeros (c :: r) := by
          simp [normalizeExponent, h1, h2]
        rw [e]; simp only [List.length_cons] at *; omega

theorem filter_length_le (p : Char → Bool) (l : Text) : (l.filter p).length ≤ l.length :=
  List.Sublist.length_le (List.filter_sublist)

theorem normalizeBody_length (neg : Bool) (body : Text) : (normalizeBody neg body).length ≤ 2 * body.length + 2 := by
  have hf := filter_length_le (· != '_') body
  unfold normalizeBody
  have hs : (signText neg).length ≤ 1 := by unfold signText; split <;> decide
  split
  · rename_i ds h
    rw [h] at hf
    have := repr_length_le (by omega : 16 ≤ 16) ds
    simp only [String.length_append, List.length_cons] at *
    omega
  · rename_i ds h
    rw [h] at hf
    have := repr_length_le (by omega : 2 ≤ 16) ds
    simp only [String.length_append, List.length_cons] at *
    omega
  · have hm := takeWhile_dropWhile_length (fun c => c != 'e' && c != 'E') (body.filter (· != '_'))
    have hneg : (if neg = true then ['-'] else []).length ≤ 1 := by split <;> simp
    simp only [String.length_ofList, List.length_append]
    cases hd : List.dropWhile (fun c => c != 'e' && c != 'E') (List.filter (fun x => x != '_') body) with
    | nil => simp only [hd, List.length_nil] at *; omega
    | cons x e =>
      have := normalizeExponent_length e
      simp only [hd, List.length_cons] at *
      omega

theorem normalizeNumber_length (lit : Text) : (normalizeNumber lit).length ≤ 2 * lit.length + 2 := by
  unfold normalizeNumber
  split
  · rename_i r; have := normalizeBody_length true r; simp only [List.length_cons]; omega
  · exact normalizeBody_length false _

theorem lexNumberCost_le (t : Text) :
    lexNumberCost t ≤ 2 * litLen (lexNumber t) + 13 := by
  have := lexUnsignedCost_le (lexMinus t).1 (lexMinus t).2
  unfold lexNumberCost lexNumber
  omega

theorem numberShape_length {lit e : Text} (h : NumberShape lit e) : 1 ≤ lit.length ∧ e.length ≤ lit.length := by
  rcases h with ⟨s, i, f, _, hi, _, _, rfl⟩ | ⟨s, ds, _, _, rfl, rfl⟩ | ⟨s, ds, _, _, rfl, rfl⟩
  · have : 1 ≤ i.length := by cases hi <;> simp
    simp only [List.length_append]; omega
  · simp; omega
  · simp; omega

/-- **Numbers**: lexing, the checks and the normalized literal, within 50 steps per character read (the proof gives 28). -/
theorem numberC_spec (L : Limits) : Leaf 50 (numberC L) := by
  intro t
  have hc := lexNumberCost_le t
  apply spec_liftP
  · intro v rest h
    simp only [number, run_bind, run_get] at h
    rcases hn : lexNumber t with _ | n
    · simp [hn] at h
    · simp only [hn] at h
      obtain ⟨h1, h2⟩ := lexNumber_spec t n hn
      have h3 := numberShape_length h2
      have h4 := normalizeNumber_length n.literal
      by_cases c1 : (n.rest.head?.any fun c => isIdentChar c || c == '.') = true <;>
      by_cases c2 : n.literal.length > L.maxNumberLength <;>
      by_cases c4 : hexDigitCount n.literal > L.maxHexDigits <;>
      by_cases c3 : expMagnitude n.exponent > L.maxExponent <;>
      simp [c1, c2, c3, c4] at h
      obtain ⟨-, rfl⟩ := h
      have hl := congrArg List.length h1
      simp only [List.length_append] at hl
      simp only [numberCost, checksCost, hn, litLen] at hc ⊢
      constructor <;> omega
  · intro _ _
    unfold numberCost
    rcases hn : lexNumber t with _ | n
    · simp only [hn, litLen, checksCost] at hc ⊢; omega
    · obtain ⟨h1, h2⟩ := lexNumber_spec t n hn
      have h3 := numberShape_length h2
      have h4 := normalizeNumber_length n.literal
      have hl := congrArg List.length h1
      simp only [List.length_append] at hl
      simp only [hn, litLen, checksCost] at hc ⊢
      omega

/-! ### Byte strings -/

theorem byteCharsCost_le (t : Text) : byteCharsCost t ≤ t.length + 1 := by
  fun_induction byteCharsCost t <;> simp <;> omega

theorem byteCharsCost_ok : ∀ (t : Text) bs rest, byteChars t = .ok (bs, rest) →
    byteCharsCost t + rest.length ≤ t.length
  | [], _, _, h => by simp [byteChars] at h
  | [c], bs, rest, h => by
    by_cases hq : c = '"'
    · subst hq; simp [byteChars] at h; obtain ⟨-, rfl⟩ := h; simp [byteCharsCost]
    · rw [byteChars.eq_3 c hq] at h
      split at h
      · simp [byteChars] at h
      · split at h <;> simp at h
  | c :: l :: r', bs, rest, h => by
    by_cases hq : c = '"'
    · subst hq; simp [byteChars] at h; obtain ⟨-, rfl⟩ := h; simp [byteCharsCost]; omega
    · rw [byteChars.eq_2 c l r' hq] at h
      rw [byteCharsCost.eq_2 c l r' hq]
      split at h
      · rename_i hb; have := byteCharsCost_ok (l :: r') bs rest h; simp only [List.length_cons] at *; simp [hb]; omega
      · rename_i hb
        split at h
        · simp at h
        · rename_i hh
          split at h
          · rename_i hl
            cases h' : byteChars r' with
            | error e => simp [h', Except.map] at h
            | ok res =>
              simp only [h', Except.map, Except.ok.injEq, Prod.mk.injEq] at h
              obtain ⟨rfl, rfl⟩ := h
              have := byteCharsCost_ok r' _ _ h'
              simp [hb, hh, hl]; omega
          · simp at h
termination_by t => t.length

/-- **Byte strings**: one step per character read, and two. -/
theorem bytesC_spec (L : Limits) : Leaf 50 (bytesC L) := by
  intro t
  apply spec_liftP
  · intro v rest h
    simp only [bytes, run_bind, run_get] at h
    cases hb : byteChars (t.drop 2) with
    | error e => simp [hb] at h; split at h <;> simp at h
    | ok res =>
      obtain ⟨raw, hraw, -⟩ := byteChars_sound _ _ _ hb
      have hc := byteCharsCost_ok _ _ _ hb
      have hl := congrArg List.length hraw
      simp [hb] at h
      split at h
      · simp at h
      · simp at h; obtain ⟨-, rfl⟩ := h
        simp only [List.length_drop, List.length_append, List.length_cons] at hl hc
        unfold bytesCost; constructor <;> omega
  · intro _ _
    have := byteCharsCost_le (t.drop 2)
    unfold bytesCost; simp only [List.length_drop] at *; omega

/-! ### Strings -/

theorem escapeCost_le (t : Text) : escapeCost t ≤ 2 * t.length + 2 := by
  unfold escapeCost
  split
  · rename_i r; have := List.Sublist.length_le (List.takeWhile_sublist (p := isHexDigit) (l := r)); simp; omega
  · omega

/-- An escape takes two steps per character it reads. -/
theorem escape_cost (t r : Text) (c : Char) (h : escape.run t = .ok (c, r)) :
    escapeCost t + 2 * r.length ≤ 2 * t.length ∧ r.length + 2 ≤ t.length := by
  simp only [escape, run_bind, run_get] at h
  split at h <;> simp at h
  all_goals try (obtain ⟨rfl, rfl⟩ := h; simp [escapeCost]; omega)
  rename_i r0
  have hl := takeWhile_dropWhile_length isHexDigit r0
  split at h
  · rename_i r'' hclose
    rw [hclose] at hl
    by_cases c1 : r0.takeWhile isHexDigit = [] ∨ 6 < (r0.takeWhile isHexDigit).length <;>
    by_cases c2 : isScalar (digitsValue 16 (r0.takeWhile isHexDigit)) = false <;>
    simp [c1, c2] at h
    obtain ⟨rfl, rfl⟩ := h
    simp only [escapeCost, List.length_cons] at *
    omega
  · simp at h

/-- `chars`: four steps per character read (reading, escapes, and reversing what it read at the end). -/
theorem charsSteps_spec (what : String) (start : Text) (ok : Char → Bool) (stop : Text → Bool) :
    ∀ (n : Nat) (acc u : Text),
      (∀ s r, (chars what start ok stop n acc).run u = .ok (s, r) →
        charsSteps ok stop n acc.length u + 4 * r.length ≤ 4 * u.length + acc.length + 2 ∧
        s.length + r.length ≤ acc.length + u.length ∧ r.length ≤ u.length ∧ stop r = true) ∧
      (∀ e, (chars what start ok stop n acc).run u = .error e →
        charsSteps ok stop n acc.length u ≤ 4 * u.length + acc.length + 2) := by
  intro n
  induction n with
  | zero => intro acc u; refine ⟨fun s r h => by simp [chars] at h, fun _ _ => by simp [charsSteps]⟩
  | succ n ih =>
    intro acc u
    by_cases hs : stop u = true
    · refine ⟨fun s r h => ?_, fun e h => ?_⟩
      · simp only [chars, run_bind, run_get] at h; simp [hs] at h
        obtain ⟨rfl, rfl⟩ := h
        unfold charsSteps; simp [hs]; omega
      · simp only [chars, run_bind, run_get] at h; simp [hs] at h
    · have hs' : stop u = false := by simpa using hs
      cases u with
      | nil =>
        refine ⟨fun s r h => ?_, fun e h => ?_⟩
        · simp only [chars, run_bind, run_get] at h; simp [hs'] at h
        · unfold charsSteps; simp [hs']
      | cons c r =>
        by_cases hc : c = '\\'
        · subst hc
          rw [charsSteps.eq_3]
          simp only [hs', Bool.false_eq_true, ↓reduceIte]
          have he := escapeCost_le ('\\' :: r)
          refine ⟨fun s r' h => ?_, fun e h => ?_⟩
          · simp only [chars, run_bind, run_get, hs', Bool.false_eq_true, ↓reduceIte] at h
            split at h
            · simp at h
            · rename_i v hv
              rw [hv]
              obtain ⟨e1, e2⟩ := escape_cost _ _ _ hv
              obtain ⟨h1, h2, h3, h4⟩ := (ih _ _).1 _ _ h
              simp only [List.length_cons] at *
              exact ⟨by omega, by omega, by omega, h4⟩
          · split
            · rename_i v hv
              simp only [chars, run_bind, run_get, hs', Bool.false_eq_true, ↓reduceIte, hv] at h
              obtain ⟨e1, e2⟩ := escape_cost _ _ _ hv
              have := (ih _ _).2 _ h
              simp only [List.length_cons] at *
              omega
            · simp only [List.length_cons] at *; omega
        · rw [charsSteps.eq_4 _ _ _ _ _ _ hc]
          simp only [hs', Bool.false_eq_true, ↓reduceIte]
          refine ⟨fun s r' h => ?_, fun e h => ?_⟩
          · simp only [chars, run_bind, run_get, hs', Bool.false_eq_true, ↓reduceIte] at h
            by_cases hb : isBidi c = true <;> by_cases hok : ok c = true <;> simp [hb, hok] at h
            obtain ⟨h1, h2, h3, h4⟩ := (ih _ _).1 _ _ h
            simp only [List.length_cons] at *
            simp only [hb, hok, Bool.false_eq_true, ↓reduceIte]
            exact ⟨by omega, by omega, by omega, h4⟩
          · simp only [chars, run_bind, run_get, hs', Bool.false_eq_true, ↓reduceIte] at h
            by_cases hb : isBidi c = true
            · simp [hb]
            · by_cases hok : ok c = true
              · simp [hb, hok] at h ⊢
                have := (ih _ _).2 _ h
                simp only [List.length_cons] at *
                omega
              · simp [hb, hok]

/-- **Strings**: at most eight steps per character read. -/
theorem basicStringC_spec8 (L : Limits) (t : Text) :
    Spec (basicStringC L) t (fun str r c => r.length < t.length ∧ str.length + r.length ≤ t.length ∧
      c + 8 * r.length ≤ 8 * t.length) (fun c => c ≤ 8 * t.length + 8) := by
  apply spec_liftP
  · intro str rest h
    simp only [basicString, run_bind, run_get, run_skip, List.drop_one] at h
    unfold basicStringCost
    simp only [List.drop_one]
    cases hc : (chars "string" t basicChar (fun x => List.head? x == some '"') (List.length t + 1) []).run
      t.tail with
    | error e => simp [hc] at h
    | ok v =>
      obtain ⟨s1, r1⟩ := v
      simp only [hc] at h
      obtain ⟨h1, h2, h3, h4⟩ := (charsSteps_spec _ _ _ _ _ [] _).1 _ _ hc
      have hr : rest = r1.tail ∧ str = String.ofList s1 := by
        unfold checkLength at h; split at h <;> simp_all
      obtain ⟨rfl, rfl⟩ := hr
      have : 1 ≤ r1.length := by cases r1 <;> simp_all
      simp only [List.length_tail, List.length_nil, String.length_ofList] at *
      refine ⟨by omega, by omega, by omega⟩
  · intro _ _
    unfold basicStringCost
    have h0 := (charsSteps_spec "string" t basicChar (fun x => List.head? x == some '"') (List.length t + 1) [] (t.drop 1))
    cases hc : (chars "string" t basicChar (fun x => List.head? x == some '"') (List.length t + 1) []).run
      (t.drop 1) with
    | ok v =>
      obtain ⟨s1, r1⟩ := v
      obtain ⟨h1, h2, h3, h4⟩ := h0.1 _ _ hc
      simp only [List.length_drop, List.length_nil] at *
      omega
    | error e =>
      have := h0.2 _ hc
      simp only [List.length_drop, List.length_nil] at *
      omega

/-- **Strings** as a leaf. -/
theorem basicStringC_spec (L : Limits) : Leaf 50 (basicStringC L) := fun t =>
  spec_mono (basicStringC_spec8 L t) (fun _ _ _ ⟨h1, _, h3⟩ => ⟨h1, by omega⟩) (fun _ h => by omega)

/-! ### Block strings -/

theorem charsSteps_le (what : String) (start : Text) (ok : Char → Bool) (stop : Text → Bool) (n : Nat) (u : Text) :
    charsSteps ok stop n 0 u ≤ 4 * u.length + 2 := by
  have h := charsSteps_spec what start ok stop n [] u
  cases hc : (chars what start ok stop n []).run u with
  | ok v => obtain ⟨a, b⟩ := v; have := (h.1 a b hc).1; simp at this; omega
  | error e => have := h.2 e hc; simpa using this

theorem findCloseCost_le (u : Text) : findCloseCost u ≤ u.length + 1 := by
  fun_induction findCloseCost u <;> simp <;> omega

theorem findCloseCost_ok (u : Text) : ∀ a b, findClose u = some (a, b) → findCloseCost u ≤ a.length + 1 := by
  fun_induction findClose u with
  | case1 c r ih =>
    intro a b h
    cases h' : findClose r with
    | none => simp [h'] at h
    | some p => simp [h'] at h; obtain ⟨rfl, rfl⟩ := h; have := ih _ _ h'; simp [findCloseCost]; omega
  | case2 r => intro a b h; simp at h; obtain ⟨rfl, rfl⟩ := h; simp [findCloseCost]
  | case3 c r hesc htri ih =>
    intro a b h
    cases h' : findClose r with
    | none => simp [h'] at h
    | some p =>
      simp [h'] at h; obtain ⟨rfl, rfl⟩ := h; have := ih _ _ h'
      rw [findCloseCost.eq_3 _ _ hesc htri]; simp; omega
  | case4 => intro a b h; simp at h

theorem splitLines_sum (a : Text) : ((splitLines a).map List.length).sum + (splitLines a).length = a.length + 1 := by
  fun_induction splitLines a with
  | case1 => simp
  | case2 r ih => simp at ih ⊢; omega
  | case3 c r hc l ls hsplit ih => rw [hsplit] at ih; simp at ih ⊢; omega
  | case4 c r hc hsplit => exact absurd hsplit (splitLines_ne_nil r)

theorem blockLineCost_le (indent line : Text) : blockLineCost indent line ≤ 8 * line.length + 4 := by
  unfold blockLineCost
  have hl : (if line.getLast? == some '\r' then line.dropLast else line).length ≤ line.length := by
    split <;> simp
  generalize (if line.getLast? == some '\r' then line.dropLast else line) = l' at *
  dsimp only
  split
  · rename_i hp
    have := hp.length_le
    have := charsSteps_le "block string" (l'.drop indent.length) blockChar List.isEmpty
      (l'.length - indent.length + 1) (l'.drop indent.length)
    simp only [List.length_drop] at this
    have := Nat.min_le_right indent.length l'.length
    omega
  · have := Nat.min_le_right indent.length l'.length
    omega

theorem blockLinesCost_le (indent : Text) :
    ∀ ls, blockLinesCost indent ls ≤ 8 * (ls.map List.length).sum + 5 * ls.length + 1
  | [] => by simp [blockLinesCost]
  | l :: ls => by
    have := blockLineCost_le indent l
    have := blockLinesCost_le indent ls
    unfold blockLinesCost
    split <;> simp <;> omega

theorem blockLine_len (indent line s : Text) (h : blockLine indent line = .ok s) : s.length ≤ line.length := by
  unfold blockLine at h
  have hl : (if line.getLast? == some '\r' then line.dropLast else line).length ≤ line.length := by
    split <;> simp
  generalize (if line.getLast? == some '\r' then line.dropLast else line) = l' at *
  dsimp only at h
  split at h
  · rw [run'_eq] at h
    simp only [List.length_drop] at h
    cases hc : (chars "block string" (l'.drop indent.length) blockChar List.isEmpty
        (l'.length - indent.length + 1) []).run (l'.drop indent.length) with
    | error e => rw [hc] at h; simp [Except.map] at h
    | ok v =>
      obtain ⟨a, b⟩ := v
      rw [hc] at h; simp [Except.map] at h; subst h
      have := ((charsSteps_spec _ _ _ _ _ [] _).1 _ _ hc).2.1
      simp only [List.length_drop, List.length_nil] at this ⊢
      omega
  · split at h
    · simp at h; subst h; simp
    · simp at h

theorem mapM_blockLine_len (indent : Text) :
    ∀ (ls ds : List Text), ls.mapM (blockLine indent) = .ok ds → (ds.map List.length).sum ≤ (ls.map List.length).sum ∧ ds.length = ls.length
  | [], ds, h => by simp [List.mapM_nil] at h; subst h; simp
  | l :: ls, ds, h => by
    simp only [List.mapM_cons] at h
    cases hl : blockLine indent l with
    | error e => simp [hl] at h
    | ok s =>
      cases hls : ls.mapM (blockLine indent) with
      | error e => simp [hl, hls] at h
      | ok ss =>
        simp [hl, hls] at h
        subst h
        have := blockLine_len _ _ _ hl
        have := mapM_blockLine_len indent ls ss hls
        simp; omega

theorem intercalate_len (ds : List Text) : (List.intercalate ['\n'] ds).length ≤ (ds.map List.length).sum + ds.length := by
  induction ds with
  | nil => simp
  | cons d ds ih =>
    cases ds with
    | nil => simp
    | cons e es => rw [List.intercalate_cons_of_ne_nil (by simp)]; simp at ih ⊢; omega

theorem dropLast_sum (l : List Text) : ((l.dropLast).map List.length).sum ≤ (l.map List.length).sum := by
  induction l with
  | nil => simp
  | cons x xs ih => cases xs with
    | nil => simp
    | cons y ys => simp [List.dropLast_cons_cons] at ih ⊢; omega

theorem getLast_len (l : List Text) : (l.getLast?.getD []).length ≤ (l.map List.length).sum := by
  induction l with
  | nil => simp
  | cons x xs ih => cases xs with
    | nil => simp
    | cons y ys => simp [List.getLast?_cons_cons] at ih ⊢; omega

/-- `blockBody`'s steps when it finds the closing quotes: linear in the content. -/
theorem blockBodyCost_found (u c r : Text) (hf : findClose u = some (c, r)) :
    blockBodyCost u ≤ 14 * c.length + 19 := by
  have h1 := findCloseCost_ok u c r hf
  have h2 := splitLines_sum c
  have h3 := getLast_len (splitLines c)
  have h4 := dropLast_sum (splitLines c)
  have h5 := blockLinesCost_le (indentOf (splitLines c)) (splitLines c).dropLast
  have h6 : (splitLines c).dropLast.length ≤ (splitLines c).length := by simp
  unfold blockBodyCost
  simp only [hf, foundCost, linesCost]
  unfold indentOf at *
  split
  · omega
  · cases hm : ((splitLines c).dropLast).mapM (blockLine ((splitLines c).getLast?.getD [])) with
    | error e => simp only [joinCost]; omega
    | ok ds =>
      have h7 := mapM_blockLine_len _ _ _ hm
      have h8 := intercalate_len ds
      simp only [joinCost]
      omega

/-- `blockBody`'s steps, on any input. -/
theorem blockBodyCost_le (u : Text) : blockBodyCost u ≤ 25 * u.length + 20 := by
  cases hf : findClose u with
  | none => have := findCloseCost_le u; unfold blockBodyCost; simp only [hf, foundCost]; omega
  | some p =>
    obtain ⟨c, r⟩ := p
    have := blockBodyCost_found u c r hf
    have := congrArg List.length (findClose_spec u c r hf).1
    simp only [List.length_append] at this
    omega

/-- `blockBody`'s steps when it succeeds: at most 24 per character read. -/
theorem blockBodyCost_ok (L : Limits) (start u : Text) (str : String) (rest : Text) (h : (blockBody L start).run u = .ok (str, rest)) :
    blockBodyCost u ≤ 24 * (u.length - rest.length) ∧ rest.length + 3 ≤ u.length := by
  simp only [blockBody, run_bind, run_get] at h
  cases hf : findClose u with
  | none => simp [hf] at h
  | some p =>
    obtain ⟨c, r⟩ := p
    have hb := blockBodyCost_found u c r hf
    have hl := congrArg List.length (findClose_spec u c r hf).1
    simp only [List.length_append] at hl
    have hr : rest = r := by
      simp only [hf] at h
      split at h
      · simp at h
      · cases hm : ((splitLines c).dropLast).mapM (blockLine ((splitLines c).getLast?.getD [])) with
        | error e => simp [hm] at h
        | ok ds =>
          simp only [hm, run_bind, run_pure, run_set, checkLength] at h
          split at h <;> simp at h
          exact h.2.symm
    subst hr
    simp at hl
    omega

/-- **Block strings**: finding the end, the lines, the indent, decoding and joining; within 50 steps per character read. -/
theorem blockStringC_spec (L : Limits) : Leaf 50 (blockStringC L) := by
  intro t
  have hw := takeWhile_dropWhile_length isBlank (t.drop 3)
  simp only [List.length_drop] at hw
  apply spec_liftP
  · intro str rest h
    simp only [blockString, run_bind, run_get, run_skip, run_takeWhile] at h
    unfold blockStringCost
    generalize hd : (t.drop 3).dropWhile isBlank = d at h hw ⊢
    split at h
    · rename_i r
      simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := blockBodyCost_ok _ _ _ _ _ h
      simp only [openCost, List.length_cons] at *
      constructor <;> omega
    · rename_i r _
      simp only [run_bind, run_set] at h
      obtain ⟨h1, h2⟩ := blockBodyCost_ok _ _ _ _ _ h
      simp only [openCost, List.length_cons] at *
      constructor <;> omega
    · simp at h
  · intro _ _
    unfold blockStringCost
    generalize (t.drop 3).dropWhile isBlank = d at hw ⊢
    unfold openCost
    split
    · rename_i r; have := blockBodyCost_le r; simp only [List.length_cons] at *; omega
    · rename_i r; have := blockBodyCost_le r; simp only [List.length_cons] at *; omega
    · omega

/-- **Keys**: a leaf, that starts at no blank and is at most as long as what it read. -/
theorem keyC_spec (L : Limits) (t : Text) :
    Spec (keyC L) t (fun k t' c => t'.length < t.length ∧ blanks t = 0 ∧ k.length + t'.length ≤ t.length ∧
      c + 50 * t'.length ≤ 50 * t.length) (fun c => c ≤ 50 * t.length + 50) := by
  apply spec_liftP
  · intro k t' h
    simp only [key, run_bind, run_get] at h
    split at h
    · simp at h
    · rename_i r hne
      have hs := basicStringC_spec8 L ('"' :: r)
      unfold Spec at hs
      simp only [basicStringC, res_liftP, cost_liftP, h] at hs
      rw [keyCost.eq_2 _ hne]
      have : blanks ('"' :: r) = 0 := by simp [blanks, isBlank]
      omega
    · rename_i c r hne2 hne1
      by_cases hl : isLowerStart c = true
      · simp only [hl, ↓reduceIte, run_bind, run_takeWhile] at h
        have hc : isIdentChar c = true := by simp [isIdentChar, hl]
        have hw := takeWhile_dropWhile_length isIdentChar (c :: r)
        have hw1 : 1 ≤ ((c :: r).takeWhile isIdentChar).length := by simp [hc]
        by_cases hlen : ((c :: r).takeWhile isIdentChar).length ≤ L.maxStringLength
        · rw [checkName_ok hlen] at h
          simp only [Except.ok.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, rfl⟩ := h
          rw [keyCost.eq_3 _ _ hne2 hne1]
          have hb : blanks (c :: r) = 0 := by
            unfold blanks; rw [List.takeWhile_cons]
            have : isBlank c = false := by
              cases hb : isBlank c
              · rfl
              · simp only [isBlank, Bool.or_eq_true, beq_iff_eq] at hb
                rcases hb with rfl | rfl <;> simp [isLowerStart] at hl
            simp [this]
          simp only [hl, ↓reduceIte, String.length_ofList]
          refine ⟨by omega, hb, by omega, by omega⟩
        · rw [checkName_long hlen] at h; simp at h
      · simp only [hl, Bool.false_eq_true, ↓reduceIte] at h
        split at h <;> simp at h
    · simp at h
  · intro _ _
    unfold keyCost
    split
    · simp
    · rename_i r _ _
      have := (basicStringC_spec8 L ('"' :: r))
      unfold Spec at this
      split at this <;> simp only [basicStringC, cost_liftP] at this <;> omega
    · rename_i c r _ _ _
      split
      · have := List.Sublist.length_le (List.takeWhile_sublist (p := isIdentChar) (l := c :: r)); omega
      · omega
    · simp

end Haus.Linear
