import Haus.Grammar
import Haus.Canonical
import Haus.RoundTrip.Digits
import Haus.Complete.Lexical

/-!
# Numbers in canonical form

A number's canonical text is its normalized literal, always in decimal
(spec §12). It is a valid literal again, it normalizes to the same value,
and it stays within the limits the number was parsed with
(`normalized_lit`, `NumberLit.normalize_fits`): a decimal literal only gets
shorter, and a hex literal has at most `maxHexDigits` hex digits (§7), few
enough for its decimal form.
-/

namespace Haus.RoundTrip
open Haus Grammar Canonical Complete

variable {L : Limits}

theorem normalizeNumber_minus (r : Text) : normalizeNumber ('-' :: r) = normalizeBody true r := rfl

theorem normalizeNumber_plain {r : Text} (h : r.head? ≠ some '-') : normalizeNumber r = normalizeBody false r := by
  unfold normalizeNumber
  split
  · simp at h
  · rfl

theorem normalizeNumber_sign {s r : Text} (hs : Sign s) (h : r.head? ≠ some '-') :
    normalizeNumber (s ++ r) = normalizeBody (s == ['-']) r := by
  rcases hs with rfl | rfl
  · simpa using normalizeNumber_plain h
  · rfl

theorem sepTail_all {p : Char → Bool} : ∀ {l : Text}, (∀ c ∈ l, p c = true) → SepTail p l
  | [], _ => .nil
  | c :: cs, h => .digit c cs (h c (by simp)) (sepTail_all fun x hx => h x (by simp [hx]))

theorem filter_all {l : Text} (h : ∀ c ∈ l, isDigit c = true ∨ isHexDigit c = true) :
    l.filter (· != '_') = l :=
  List.filter_eq_self.mpr fun c hc => by
    rcases h c hc with h | h <;> (simp; rintro rfl; revert h; decide)

/-! ## Integers -/

/-- The decimal digits of `v` start with a nonzero digit, unless `v` is 0. -/
theorem toDigits_head {v : Nat} (hv : 0 < v) : ∃ c rest, Nat.toDigits 10 v = c :: rest ∧ c ≠ '0' := by
  induction v using Nat.strongRecOn with
  | _ v ih =>
    rw [Nat.toDigits_eq_ite (by decide)]
    split
    · rename_i h
      refine ⟨_, [], rfl, ?_⟩
      have : ∀ d < 10, 0 < d → Nat.digitChar d ≠ '0' := by decide
      exact this v h hv
    · obtain ⟨c, rest, he, hc⟩ := ih (v / 10) (by omega) (by omega)
      exact ⟨c, rest ++ _, by rw [he]; rfl, hc⟩

theorem intPart_toDigits (v : Nat) : IntPart (Nat.toDigits 10 v) := by
  rcases Nat.eq_zero_or_pos v with rfl | hv
  · rw [Nat.toDigits_zero]; exact .zero
  · obtain ⟨c, rest, he, hc⟩ := toDigits_head hv
    have hd := toDigits_decimal (n := v)
    rw [he] at hd ⊢
    exact .nonzero c rest (hd c (by simp)) hc (sepTail_all fun x hx => hd x (by simp [hx]))

/--
The normalized literal of a hex or binary integer: its sign, kept also on
zero (`-0x0` is `-0`), and its decimal digits.
-/
def signedText (neg : Bool) (v : Nat) : Text := (if neg then ['-'] else []) ++ Nat.toDigits 10 v

theorem integer_toList (neg : Bool) (v : Nat) :
    (signText neg ++ toString v).toList = signedText neg v := by
  unfold signText signedText; split <;> simp [Nat.toString_eq_repr]

/-- Without a sign on zero, the literal is the integer's. -/
theorem signedText_intText (neg : Bool) (v : Nat) : signedText (neg && v != 0) v = intText neg v := by
  unfold signedText intText; cases neg <;> by_cases hv : v = 0 <;> simp [hv]

/-- A hex or binary literal's value is an integer's literal, or `-0`. -/
theorem signedText_cases (neg : Bool) (v : Nat) :
    signedText neg v = intText neg v ∨ (neg = true ∧ v = 0 ∧ signedText neg v = ['-', '0']) := by
  by_cases h : neg = true ∧ v = 0
  · obtain ⟨rfl, rfl⟩ := h; right; exact ⟨rfl, rfl, by decide⟩
  · left; rw [← signedText_intText]; congr 1; cases neg <;> by_cases hv : v = 0 <;> simp_all

theorem toDigits_head_ne {v : Nat} {c : Char} (h : (Nat.toDigits 10 v).head? = some c) :
    isDigit c = true := toDigits_decimal c (List.mem_of_head? h)

theorem normalizeBody_digits (neg : Bool) (v : Nat) :
    normalizeBody neg (Nat.toDigits 10 v) = String.ofList ((if neg then ['-'] else []) ++ Nat.toDigits 10 v) := by
  have hd := toDigits_decimal (n := v)
  have hf : (Nat.toDigits 10 v).filter (· != '_') = Nat.toDigits 10 v := filter_all fun c hc => .inl (hd c hc)
  have hnoE : ∀ c ∈ Nat.toDigits 10 v, (c != 'e' && c != 'E') = true := by
    intro c hc; have := hd c hc; revert this; simp [isDigit]; rintro h1 h2; constructor <;> rintro rfl <;> simp_all
  obtain ⟨htw, hdw⟩ := takeWhile_append hnoE (x := []) (by simp)
  simp only [List.append_nil] at htw hdw
  unfold normalizeBody
  rw [hf]
  split
  · rename_i ds heq
    have := hd 'x' (by rw [heq]; simp)
    simp [isDigit] at this
  · rename_i ds heq
    have := hd 'b' (by rw [heq]; simp)
    simp [isDigit] at this
  · simp [htw, hdw]

theorem toDigits_not_minus (b v : Nat) (hb : 1 < b) (h16 : b ≤ 16) : (Nat.toDigits b v).head? ≠ some '-' := by
  intro h
  obtain ⟨d, hd, he⟩ := mem_toDigits hb (List.mem_of_head? h)
  have : ∀ d < 16, Nat.digitChar d ≠ '-' := by decide
  exact this d (by omega) he.symm

/-! ## Decimal literals -/

/-- The exponent part after normalizing: `e` and the exponent's value, or nothing. -/
def normE (e : Text) : Text :=
  match e.filter (· != '_') with
  | _ :: rest => 'e' :: normalizeExponent rest
  | [] => []

theorem sepTail_chars {p : Char → Bool} {l : Text} (h : SepTail p l) : ∀ c ∈ l, p c = true ∨ c = '_' := by
  induction h with
  | nil => simp
  | digit c rest hc _ ih => exact List.forall_mem_cons.mpr ⟨.inl hc, ih⟩
  | sep c rest hc _ ih =>
    intro x hx
    simp only [List.mem_cons] at hx
    rcases hx with rfl | rfl | hx
    · exact .inr rfl
    · exact .inl hc
    · exact ih x hx

theorem digits_chars {p : Char → Bool} {l : Text} (h : Digits p l) : ∀ c ∈ l, p c = true ∨ c = '_' := by
  obtain ⟨c, rest, rfl, hc, hs⟩ := h
  exact List.forall_mem_cons.mpr ⟨.inl hc, sepTail_chars hs⟩

theorem intPart_chars {i : Text} (h : IntPart i) : ∀ c ∈ i, isDigit c = true ∨ c = '_' := by
  cases h with
  | zero => simp; decide
  | nonzero c rest hc _ hs => exact List.forall_mem_cons.mpr ⟨.inl hc, sepTail_chars hs⟩

/-- No exponent marker among digits, `_` and `.`. -/
theorem not_marker {c : Char} (h : isDigit c = true ∨ c = '_' ∨ c = '.') : (c != 'e' && c != 'E') = true := by
  rcases h with h | rfl | rfl
  · have : c ≠ 'e' ∧ c ≠ 'E' := by constructor <;> rintro rfl <;> simp [isDigit] at h
    simp [this.1, this.2]
  all_goals decide

theorem filter_chars {l : Text} {P : Char → Prop} (h : ∀ c ∈ l, P c) : ∀ c ∈ l.filter (· != '_'), P c :=
  fun c hc => h c (List.mem_filter.mp hc).1

theorem filter_exp {m : Char} {sgn ds : Text} (hm : m = 'e' ∨ m = 'E') (hs : sgn = [] ∨ sgn = ['+'] ∨ sgn = ['-']) :
    (m :: (sgn ++ ds)).filter (· != '_') = m :: (sgn ++ ds.filter (· != '_')) := by
  rcases hm with rfl | rfl <;> rcases hs with rfl | rfl | rfl <;> simp 

/-- After the integer part: a fraction, an exponent marker, or nothing. -/
theorem after_int_head {f e : Text} (hf : f = [] ∨ Frac f) (he : e = [] ∨ Exp e) :
    ∀ c, (f.filter (· != '_') ++ e.filter (· != '_')).head? = some c → c = '.' ∨ c = 'e' ∨ c = 'E' := by
  intro c hc
  rcases hf with rfl | ⟨fs, rfl, -⟩
  · rcases he with rfl | ⟨m, sgn, ds, rfl, hm, hsg, -⟩
    · simp at hc
    · rw [List.filter_nil, List.nil_append, List.cons_append, filter_exp hm hsg] at hc
      simp at hc; subst hc; rcases hm with h | h <;> simp [h]
  · simp at hc; simp [← hc]

/-- What normalization makes of a decimal literal. -/
theorem normalize_decimal {sg i f e : Text} (hs : Sign sg) (hi : IntPart i) (hf : f = [] ∨ Frac f)
    (he : e = [] ∨ Exp e) :
    normalizeNumber (sg ++ i ++ f ++ e) = String.ofList (sg ++ i.filter (· != '_') ++ f.filter (· != '_') ++ normE e) := by
  obtain ⟨c0, i0, rfl, hc0⟩ := intPart_head hi
  have hc0' : c0 ≠ '_' := by rintro rfl; simp [isDigit] at hc0
  have hci := intPart_chars hi
  have hcf : ∀ c ∈ f, isDigit c = true ∨ c = '_' ∨ c = '.' := by
    rcases hf with rfl | ⟨ds, rfl, hds⟩
    · simp
    · exact List.forall_mem_cons.mpr ⟨.inr (.inr rfl), fun c hc => (digits_chars hds c hc).elim .inl (.inr ∘ .inl)⟩
  have hce : ∀ c, (e.filter (· != '_')).head? = some c → (c != 'e' && c != 'E') = false := by
    intro c hc
    rcases he with rfl | ⟨m, sgn, ds, rfl, hm, hsg, -⟩
    · simp at hc
    · rw [List.cons_append, filter_exp hm hsg] at hc
      simp at hc; subst hc; rcases hm with rfl | rfl <;> decide
  have hab : ∀ c ∈ (c0 :: i0).filter (· != '_') ++ f.filter (· != '_'), (c != 'e' && c != 'E') = true := by
    intro c hc
    rcases List.mem_append.mp hc with hc | hc
    · exact not_marker ((filter_chars hci c hc).elim .inl (.inr ∘ .inl))
    · exact not_marker (filter_chars hcf c hc)
  obtain ⟨htw, hdw⟩ := takeWhile_append hab hce
  have hsg : (if (sg == ['-']) = true then ['-'] else []) = sg := by rcases hs with rfl | rfl <;> rfl
  -- the filtered body never starts with `0x` or `0b`
  have hfirst : (c0 :: i0).filter (· != '_') = c0 :: i0.filter (· != '_') := by simp [hc0']
  have hno : ∀ (r : Char) ds, (r = 'x' ∨ r = 'b') →
      (c0 :: i0).filter (· != '_') ++ f.filter (· != '_') ++ e.filter (· != '_') ≠ '0' :: r :: ds := by
    intro r ds hr heq
    rw [hfirst, List.append_assoc, List.cons_append] at heq
    have h1 := (List.cons.inj heq).1
    have h2 := (List.cons.inj heq).2
    cases hi with
    | nonzero _ _ _ h0 _ => exact h0 h1
    | zero =>
      simp only [List.filter_nil, List.nil_append] at h2
      have := after_int_head hf he r (by rw [h2]; rfl)
      rcases hr with rfl | rfl <;> simp at this
  rw [List.append_assoc, List.append_assoc, normalizeNumber_sign hs (by simp ; intro h; subst h; simp [isDigit] at hc0)]
  unfold normalizeBody
  rw [List.filter_append, List.filter_append, ← List.append_assoc]
  split
  · rename_i ds heq; exact absurd heq (hno 'x' ds (.inl rfl))
  · rename_i ds heq; exact absurd heq (hno 'b' ds (.inr rfl))
  · simp only [List.append_assoc] at htw hdw
    simp only [htw, hdw, hsg, normE, List.append_assoc]
    -- the same match, from two definitions
    generalize e.filter (· != '_') = E
    cases E <;> rfl

/-! ## Exponents -/

theorem normalizeExponent_eq {sgn ds : Text} (hs : sgn = [] ∨ sgn = ['+'] ∨ sgn = ['-'])
    (hd : ∀ c, ds.head? = some c → isDigit c = true) :
    normalizeExponent (sgn ++ ds) =
      (if sgn == ['-'] && stripZeros ds != ['0'] then ['-'] else []) ++ stripZeros ds := by
  have hplain : ∀ c, ds.head? = some c → c ≠ '-' ∧ c ≠ '+' := by
    intro c hc; have := hd c hc
    constructor <;> rintro rfl <;> simp [isDigit] at this
  rcases hs with rfl | rfl | rfl
  · simp only [List.nil_append]
    cases ds with
    | nil => rfl
    | cons c r =>
      obtain ⟨h1, h2⟩ := hplain c rfl
      simp [normalizeExponent, h1, h2]
  · simp [normalizeExponent]
  · unfold normalizeExponent; simp only [List.cons_append, List.nil_append]
    split <;> simp_all

theorem stripZeros_chars {ds : Text} (h : ∀ c ∈ ds, isDigit c = true) : ∀ c ∈ stripZeros ds, isDigit c = true := by
  have hsub : ∀ x ∈ ds.dropWhile (· == '0'), isDigit x = true := fun x hx => h x ((List.dropWhile_sublist _).subset hx)
  unfold stripZeros
  generalize ds.dropWhile (· == '0') = d at hsub
  cases d with
  | nil => simp; decide
  | cons c r => exact hsub

theorem stripZeros_ne_nil (ds : Text) : stripZeros ds ≠ [] := by
  unfold stripZeros
  cases ds.dropWhile (· == '0') <;> simp

theorem stripZeros_value (ds : Text) : digitsValue 10 (stripZeros ds) = digitsValue 10 ds := by
  rw [← digitsValue_dropZeros 10 ds]
  unfold stripZeros
  cases ds.dropWhile (· == '0') <;> rfl

theorem stripZeros_length {ds : Text} (h : ds ≠ []) : (stripZeros ds).length ≤ ds.length := by
  unfold stripZeros
  have hl : (ds.dropWhile (· == '0')).length ≤ ds.length := (List.dropWhile_sublist _).length_le
  have h1 : 1 ≤ ds.length := by cases ds with
    | nil => exact absurd rfl h
    | cons => simp
  generalize ds.dropWhile (· == '0') = d at hl
  cases d with
  | nil => simpa using h1
  | cons c r => exact hl

/-- No leading zero: the first digit isn't `0`, or the digits are just `0`. -/
theorem stripZeros_head (ds : Text) : (stripZeros ds).head? = some '0' → stripZeros ds = ['0'] := by
  unfold stripZeros
  cases hd : ds.dropWhile (· == '0') with
  | nil => simp
  | cons c r =>
    intro h
    have := head_dropWhile (p := (· == '0')) (l := ds) (c := c) (by rw [hd]; rfl)
    simp at h; subst h; simp at this

theorem stripZeros_stripZeros (ds : Text) : stripZeros (stripZeros ds) = stripZeros ds := by
  unfold stripZeros
  cases hd : ds.dropWhile (· == '0') with
  | nil => rfl
  | cons c r =>
    have := head_dropWhile (p := (· == '0')) (l := ds) (c := c) (by rw [hd]; rfl)
    simp only [List.dropWhile, this]

theorem digits_head {p : Char → Bool} {ds : Text} (h : Digits p ds) : ∀ c, ds.head? = some c → p c = true := by
  obtain ⟨c, r, rfl, hc, -⟩ := h
  intro x hx; simp at hx; subst hx; exact hc

theorem filter_isDigit {l : Text} (h : ∀ c ∈ l, isDigit c = true ∨ c = '_') :
    l.filter isDigit = l.filter (· != '_') :=
  List.filter_congr fun c hc => by
    rcases h c hc with h | rfl
    · have : c ≠ '_' := by rintro rfl; simp [isDigit] at h
      simp [h, this]
    · decide

/-- The normalized exponent: a valid exponent, of the same magnitude, no longer, and normalized already. -/
theorem normE_exp {e : Text} (he : Exp e) :
    Exp (normE e) ∧ expMagnitude (normE e) = expMagnitude e ∧ (normE e).length ≤ e.length ∧
      (normE e).filter (· != '_') = normE e ∧ normE (normE e) = normE e := by
  obtain ⟨m, sgn, ds, rfl, hm, hsg, hds⟩ := he
  have hdc := digits_chars hds
  have hdf : ∀ c ∈ ds.filter (· != '_'), isDigit c = true := by
    intro c hc
    obtain ⟨hc1, hc2⟩ := List.mem_filter.mp hc
    rcases hdc c hc1 with h | rfl
    · exact h
    · simp at hc2
  obtain ⟨d0, dr, hds0, hd0, -⟩ := hds
  have hne : ds.filter (· != '_') ≠ [] := by
    rw [hds0]; have : d0 ≠ '_' := by rintro rfl; simp [isDigit] at hd0
    simp [this]
  have hhead : ∀ c, (ds.filter (· != '_')).head? = some c → isDigit c = true :=
    fun c hc => hdf c (List.mem_of_head? hc)
  have hn : normE (m :: sgn ++ ds) =
      'e' :: ((if sgn == ['-'] && stripZeros (ds.filter (· != '_')) != ['0'] then ['-'] else []) ++
        stripZeros (ds.filter (· != '_'))) := by
    unfold normE; rw [List.cons_append, filter_exp hm hsg]; simp only
    rw [normalizeExponent_eq hsg hhead]
  generalize hzdef : stripZeros (ds.filter (· != '_')) = z at hn
  have hz : ∀ c ∈ z, isDigit c = true := hzdef ▸ stripZeros_chars hdf
  have hzne : z ≠ [] := hzdef ▸ stripZeros_ne_nil _
  have hzr : ∀ c ∈ z, c ≠ '_' := fun c hc h => by subst h; simp [isDigit] at hz; exact absurd (hz '_' hc) (by decide)
  generalize hsdef : (if sgn == ['-'] && z != ['0'] then ['-'] else []) = sg' at hn
  have hsg' : sg' = [] ∨ sg' = ['+'] ∨ sg' = ['-'] := by
    rw [← hsdef]; split
    · exact .inr (.inr rfl)
    · exact .inl rfl
  have hfilter : (('e' :: (sg' ++ z)).filter (· != '_')) = 'e' :: (sg' ++ z) := by
    rw [filter_exp (.inl rfl) hsg', List.filter_eq_self.mpr (fun c hc => by simp [hzr c hc])]
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · rw [hn]
    obtain ⟨c, r, hcr⟩ : ∃ c r, z = c :: r := match z, hzne with | c :: r, _ => ⟨c, r, rfl⟩
    exact ⟨'e', sg', z, rfl, .inl rfl, hsg', c, r, hcr, hz c (by simp [hcr]),
      sepTail_all fun x hx => hz x (by simp [hcr, hx])⟩
  · rw [hn]
    have hfz : z.filter isDigit = z := List.filter_eq_self.mpr hz
    have hfs : (sg' ++ z).filter isDigit = z := by
      rcases hsg' with rfl | rfl | rfl <;> simp [List.filter_cons, hfz] <;> decide
    simp only [expMagnitude, List.filter_cons, show isDigit 'e' = false by decide, hfs, Bool.false_eq_true,
      ↓reduceIte]
    rw [← hzdef, stripZeros_value]
    have : (m :: (sgn ++ ds)).filter isDigit = ds.filter isDigit := by
      rcases hm with rfl | rfl <;> rcases hsg with rfl | rfl | rfl <;>
        simp (config := { decide := true }) 
    simp only [List.cons_append, this, filter_isDigit hdc]
  · rw [hn]
    have hzl : z.length ≤ (ds.filter (· != '_')).length := hzdef ▸ stripZeros_length hne
    have hfl : (ds.filter (· != '_')).length ≤ ds.length := List.length_filter_le _ _
    simp only [List.length_cons, List.length_append, List.length_cons]
    have : sg'.length ≤ sgn.length := by
      rw [← hsdef]; split
      · rename_i h; simp at h; rw [h.1]; exact Nat.le_refl _
      · simp
    omega
  · rw [hn, hfilter]
  · rw [hn]
    unfold normE
    rw [hfilter]
    simp only
    have hzh : ∀ c, z.head? = some c → isDigit c = true := fun c hc => hz c (List.mem_of_head? hc)
    rw [normalizeExponent_eq hsg' hzh, show stripZeros z = z by rw [← hzdef, stripZeros_stripZeros]]
    rw [← hsdef]
    split <;> simp_all

/-! ## The normalized literal -/

theorem _root_.Haus.Grammar.NumberLit.length_le {t : Text} (h : NumberLit L t) : t.length ≤ L.maxNumberLength := by
  cases h <;> assumption

/-- Hex and binary literals: their value as an integer. -/
theorem normalize_radix {s ds : Text} {r : Char} (hs : Sign s) (hr : r = 'x' ∨ r = 'b') :
    normalizeNumber (s ++ '0' :: r :: ds) =
      String.ofList (signedText (s == ['-']) (digitsValue (if r = 'x' then 16 else 2) (ds.filter (· != '_')))) := by
  rw [normalizeNumber_sign hs (by simp)]
  unfold normalizeBody
  have hf : ('0' :: r :: ds).filter (· != '_') = '0' :: r :: ds.filter (· != '_') := by
    rcases hr with rfl | rfl <;> simp 
  rw [hf]
  rcases hr with rfl | rfl <;> simp only [↓reduceIte] <;>
    rw [← String.toList_inj, integer_toList, String.toList_ofList] <;> rfl

/--
The normalized literal of a hex or binary integer, a sign and decimal
digits, is a decimal literal within the limits when it is short enough, and
normalizes to itself.
-/
theorem signedLit (neg : Bool) (v : Nat) (hlen : (signedText neg v).length ≤ L.maxNumberLength) :
    NumberLit L (signedText neg v) ∧ normalizeNumber (signedText neg v) = String.ofList (signedText neg v) := by
  have hs : Sign (if neg then ['-'] else []) := by cases neg <;> simp [Sign]
  have := NumberLit.decimal (L := L) _ (Nat.toDigits 10 v) [] [] hs (intPart_toDigits v) (.inl rfl) (.inl rfl)
    (by simp [expMagnitude, digitsValue]) (by simpa [signedText] using hlen)
  refine ⟨by simpa [signedText] using this, ?_⟩
  unfold signedText
  rw [normalizeNumber_sign hs (toDigits_not_minus 10 v (by decide) (by decide)), normalizeBody_digits]
  cases neg <;> rfl

theorem signedText_length (neg : Bool) (v : Nat) :
    (signedText neg v).length = (if neg then 1 else 0) + (Nat.toDigits 10 v).length := by
  unfold signedText; cases neg <;> simp; omega

theorem sign_length {s : Text} (hs : Sign s) : (if (s == ['-']) = true then 1 else 0) = s.length := by
  rcases hs with rfl | rfl <;> rfl

/-- Fewer than `10 ^ k` (`k > 0`): at most `k` decimal digits. -/
theorem decimalLength {v k : Nat} (hk : 0 < k) (h : v < 10 ^ k) : (Nat.toDigits 10 v).length ≤ k :=
  (Nat.length_toDigits_le_iff (by decide) hk).mpr h

theorem isBin_hex {c : Char} (h : isBinDigit c = true) : isHexDigit c = true ∧ hexValue c < 2 := by
  simp [isBinDigit] at h; rcases h with rfl | rfl <;> decide

theorem intPart_filter {i : Text} (h : IntPart i) :
    IntPart (i.filter (· != '_')) ∧ (∀ c ∈ i.filter (· != '_'), isDigit c = true) ∧
      ((i.filter (· != '_')).head? = some '0' → i.filter (· != '_') = ['0']) := by
  cases h with
  | zero => exact ⟨by simpa using IntPart.zero, by simp; decide, by simp⟩
  | nonzero c rest hc h0 hs =>
    have hc_ : c ≠ '_' := by rintro rfl; simp [isDigit] at hc
    have hr : ∀ x ∈ rest.filter (· != '_'), isDigit x = true := by
      intro x hx
      obtain ⟨hx1, hx2⟩ := List.mem_filter.mp hx
      rcases sepTail_chars hs x hx1 with h | rfl
      · exact h
      · simp at hx2
    simp only [List.filter_cons, hc_, bne_iff_ne, ne_eq, not_false_eq_true, ↓reduceIte]
    exact ⟨.nonzero c _ hc h0 (sepTail_all hr), List.forall_mem_cons.mpr ⟨hc, hr⟩, by simp [h0]⟩

theorem frac_filter {f : Text} (h : f = [] ∨ Frac f) :
    f.filter (· != '_') = [] ∨ Frac (f.filter (· != '_')) := by
  rcases h with rfl | ⟨ds, rfl, hds⟩
  · exact .inl rfl
  · right
    obtain ⟨d, r, rfl, hd, hr⟩ := hds
    have hd_ : d ≠ '_' := by rintro rfl; simp [isDigit] at hd
    have hr' : ∀ x ∈ r.filter (· != '_'), isDigit x = true := by
      intro x hx
      obtain ⟨hx1, hx2⟩ := List.mem_filter.mp hx
      rcases sepTail_chars hr x hx1 with h | rfl
      · exact h
      · simp at hx2
    refine ⟨d :: r.filter (· != '_'), by simp [hd_], d, _, rfl, hd, sepTail_all hr'⟩

theorem filter_idem (l : Text) : (l.filter (· != '_')).filter (· != '_') = l.filter (· != '_') := by
  rw [List.filter_filter]; congr 1; funext c; simp

/-- A radix literal's digits, `_` removed: at least one. -/
theorem digits_filter_pos {p : Char → Bool} (hp : p '_' = false) {ds : Text} (hds : Digits p ds) :
    0 < (ds.filter (· != '_')).length := by
  obtain ⟨d, r, rfl, hd, -⟩ := hds
  have : d ≠ '_' := by rintro rfl; rw [hp] at hd; exact absurd hd (by decide)
  simp [this]

/-- The value of a radix literal's digits, `_` removed: fewer than `b ^ k` for `k` digits. -/
theorem digits_value_lt {p : Char → Bool} {b : Nat} (hp : ∀ c, p c = true → hexValue c < b) {ds : Text}
    (hds : Digits p ds) : digitsValue b (ds.filter (· != '_')) < b ^ (ds.filter (· != '_')).length :=
  digitsValue_lt fun c hc => by
    obtain ⟨h1, h2⟩ := List.mem_filter.mp hc
    rcases digits_chars hds c h1 with h | rfl
    · exact hp c h
    · simp at h2

/--
**A number's normalized literal is a literal within the same limits**, and
normalizes to itself. For a hex literal this is what `maxHexDigits` is for
(§7): at most `maxHexDigits` hex digits are less than `10 ^ (n - 1)`, so at
most `n - 1` decimal digits and a sign.
-/
theorem normalized_lit {t : Text} (h : NumberLit L t) :
    NumberLit L (normalizeNumber t).toList ∧ normalizeNumber (normalizeNumber t).toList = normalizeNumber t := by
  cases h with
  | hex s ds hs hds hlen hhex =>
    rw [normalize_radix (ds := ds) hs (.inl rfl)]
    simp only [↓reduceIte, String.toList_ofList]
    refine signedLit _ _ ?_
    -- at most `maxHexDigits` hex digits: less than `10 ^ (n - 1)`
    have hv := Nat.lt_of_lt_of_le (digits_value_lt (fun _ => hexValue_hex) hds)
      (Nat.le_trans (Nat.pow_le_pow_right (by decide) hhex) ((L.maxHexDigits_iff _).mp (Nat.le_refl _)))
    have hn : 0 < L.maxNumberLength - 1 := by
      rcases hs with rfl | rfl <;> simp only [List.length_append, List.length_cons] at hlen <;> omega
    have := decimalLength hn hv
    have : s.length ≤ 1 := by rcases hs with rfl | rfl <;> simp
    rw [signedText_length, sign_length hs]
    simp only [List.length_append, List.length_cons] at hlen
    omega
  | binary s ds hs hds hlen =>
    rw [normalize_radix (ds := ds) hs (.inr rfl)]
    simp only [show ('b' = 'x') = False by decide, ite_false, String.toList_ofList]
    refine signedLit _ _ ?_
    -- `k` binary digits: less than `2 ^ k ≤ 10 ^ k`, so at most `k` decimal digits
    have hk := digits_filter_pos (by decide) hds
    have hv := Nat.lt_of_lt_of_le (digits_value_lt (fun _ h => (isBin_hex h).2) hds)
      (Nat.pow_le_pow_left (show 2 ≤ 10 by decide) _)
    have := decimalLength hk hv
    have := List.length_filter_le (· != '_') ds
    rw [signedText_length, sign_length hs]
    simp only [List.length_append, List.length_cons] at hlen
    omega
  | decimal s i f e hs hi hf he hexp hlen =>
    rw [normalize_decimal hs hi hf he, String.toList_ofList]
    obtain ⟨hi', -, -⟩ := intPart_filter hi
    have hf' := frac_filter hf
    have he' : (normE e = [] ∨ Exp (normE e)) ∧ expMagnitude (normE e) = expMagnitude e ∧
        (normE e).length ≤ e.length ∧ normE (normE e) = normE e := by
      rcases he with rfl | he
      · exact ⟨.inl rfl, rfl, by simp [normE], rfl⟩
      · obtain ⟨h1, h2, h3, -, h5⟩ := normE_exp he
        exact ⟨.inr h1, h2, h3, h5⟩
    have hl : (s ++ i.filter (· != '_') ++ f.filter (· != '_') ++ normE e).length ≤ (s ++ i ++ f ++ e).length := by
      have := List.length_filter_le (· != '_') i
      have := List.length_filter_le (· != '_') f
      simp only [List.length_append]; omega
    refine ⟨.decimal _ _ _ _ hs hi' hf' he'.1 (by rw [he'.2.1]; exact hexp) (Nat.le_trans hl hlen), ?_⟩
    rw [normalize_decimal hs hi' hf' he'.1, filter_idem, filter_idem, he'.2.2.2]

/--
**Every number a literal can hold fits the number limit in normalized
form** (§7): the normalized literal of a number parsed within `L`, which is
its canonical text (§12), always decimal, has at most `L.maxNumberLength`
characters. This is what the hex limit `maxHexDigits` buys.
-/
theorem _root_.Haus.Grammar.NumberLit.normalize_fits {t : Text} (h : NumberLit L t) :
    (normalizeNumber t).length ≤ L.maxNumberLength := by
  rw [← String.length_toList]; exact (normalized_lit h).1.length_le

/-! ## Writing a number -/

/-- **A number, written canonically**, is the same number, within the same limits. -/
theorem number_canonical {t : Text} (h : NumberLit L t) (n : Nat) :
    Val L n (Canonical.number (normalizeNumber t)) (.num (normalizeNumber t)) := by
  obtain ⟨hl, hn⟩ := normalized_lit h
  have := Val.number n _ hl
  rwa [hn] at this

end Haus.RoundTrip
