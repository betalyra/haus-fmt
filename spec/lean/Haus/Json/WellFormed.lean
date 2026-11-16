import Haus.Json.Normal
import Haus.Json.SelfDescribing
import Haus.RoundTrip.File
import Haus.Sound.Values

/-!
# Parsed values are well formed

`Value.wf` (normalized numbers, tags) is what the JSON round trips assume
of a value. Every value the grammar derives has it (`Val.wf`), so every
value the reference parser returns does (`parse_wf`): numbers are the
normalized literals of §2 (`normalLit_number`), tags are tags.
-/

namespace Haus
open Grammar RoundTrip

/-! ## Numbers -/

theorem isIntDigits_of {ds : Text} (hne : ds ≠ []) (hd : ∀ c ∈ ds, isDigit c = true)
    (h0 : ds.head? = some '0' → ds = ['0']) : isIntDigits ds = true := by
  match ds, hne with
  | c :: cs, _ =>
    by_cases hc : c = '0'
    · subst hc; rw [h0 rfl]; rfl
    · unfold isIntDigits
      split
      · rename_i heq; cases heq
      · rename_i heq; cases heq; exact absurd rfl hc
      · rename_i heq
        cases heq
        simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.all_eq_true]
        exact ⟨⟨hd _ (by simp), hc⟩, fun d hdm => hd d (by simp [hdm])⟩

theorem isIntDigits_stripZeros {ds : Text} (hd : ∀ c ∈ ds, isDigit c = true) : isIntDigits (stripZeros ds) = true := by
  apply isIntDigits_of (stripZeros_ne_nil ds) (stripZeros_chars hd) (stripZeros_head ds)

theorem isIntDigits_toDigits (v : Nat) : isIntDigits (Nat.toDigits 10 v) = true := by
  apply isIntDigits_of Nat.toDigits_ne_nil toDigits_decimal
  intro h
  rcases Nat.eq_zero_or_pos v with rfl | hv
  · rfl
  · obtain ⟨c, rest, he, hc⟩ := toDigits_head hv
    rw [he] at h; simp at h; exact absurd h hc

theorem dropMinus_digit {c : Char} {cs : Text} (h : isDigit c = true) : dropMinus (c :: cs) = c :: cs := by
  unfold dropMinus
  split
  · rename_i r he; cases he; simp [isDigit] at h
  · rfl

theorem takeWhile_all {p : Char → Bool} {l : Text} (h : ∀ c ∈ l, p c = true) : l.takeWhile p = l := by
  simpa using takeWhile_append_of_all (l₂ := []) h

theorem dropWhile_all {p : Char → Bool} {l : Text} (h : ∀ c ∈ l, p c = true) : l.dropWhile p = [] := by
  simpa using dropWhile_append_of_all (l₂ := []) h

/-- An integer's literal is a normalized literal. -/
theorem normalLit_intText (neg : Bool) (v : Nat) : isNormalLit (intText neg v) = true := by
  have hd := toDigits_decimal (n := v)
  obtain ⟨c, rest, he⟩ : ∃ c rest, Nat.toDigits 10 v = c :: rest :=
    match Nat.toDigits 10 v, Nat.toDigits_ne_nil (b := 10) (n := v) with
    | c :: rest, _ => ⟨c, rest, rfl⟩
  have hc : isDigit c = true := hd c (by simp [he])
  have hall : ∀ x ∈ Nat.toDigits 10 v, isDigit x = true := hd
  have hdrop : dropMinus (intText neg v) = Nat.toDigits 10 v := by
    unfold intText
    split
    · rfl
    · simp only [List.nil_append]; rw [he]; exact dropMinus_digit hc
  unfold isNormalLit
  simp only [hdrop, takeWhile_all hall, dropWhile_all hall, isIntDigits_toDigits, Bool.true_and]
  rfl

theorem isNormalLit_intText_string (neg : Bool) (v : Nat) : isNormalLit (String.ofList (intText neg v)).toList = true := by
  rw [String.toList_ofList]; exact normalLit_intText neg v

/-- The normalized exponent part is one a normalized literal has. -/
theorem normalExp_normE {e : Text} (he : Exp e) : normalTail.normalExp (normE e) = true := by
  obtain ⟨m, sgn, ds, rfl, hm, hsg, hds⟩ := he
  have hdc := digits_chars hds
  have hdf : ∀ c ∈ ds.filter (· != '_'), isDigit c = true := by
    intro c hc
    obtain ⟨hc1, hc2⟩ := List.mem_filter.mp hc
    rcases hdc c hc1 with h | rfl
    · exact h
    · simp at hc2
  have hm' : m ≠ '_' := by rcases hm with rfl | rfl <;> decide
  have hfe : (m :: sgn ++ ds).filter (· != '_') = m :: sgn ++ ds.filter (· != '_') := by
    rcases hsg with rfl | rfl | rfl <;> simp [hm']
  have hz := isIntDigits_stripZeros hdf
  have hzd := stripZeros_chars hdf
  unfold normE
  rw [hfe]
  show normalTail.normalExp ('e' :: normalizeExponent (sgn ++ ds.filter (· != '_'))) = true
  rw [normalizeExponent_eq hsg fun c hc => hdf c (List.mem_of_head? hc)]
  generalize hZ : stripZeros (ds.filter (· != '_')) = z at hz hzd
  have hz0 : ∀ cs, z ≠ '-' :: cs := by
    intro cs h; subst h; simp [isDigit] at hzd
  by_cases hneg : (sgn == ['-'] && z != ['0']) = true
  · simp only [hneg, ↓reduceIte, List.cons_append, List.nil_append]
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at hneg
    unfold normalTail.normalExp
    split
    · rename_i heq; cases heq
    · rename_i heq; cases heq; exact absurd rfl hneg.2
    · rename_i ds' _ heq; cases heq; exact hz
    · rename_i ds' _ hno heq; cases heq; exact absurd rfl (hno z)
    · rename_i heq; exact absurd rfl (heq _)
  · simp only [Bool.not_eq_true] at hneg
    simp only [hneg, Bool.false_eq_true, ↓reduceIte, List.nil_append]
    unfold normalTail.normalExp
    split
    · rename_i heq; cases heq
    · rename_i heq; cases heq; exact absurd rfl (hz0 ['0'])
    · rename_i ds' _ heq; cases heq; exact absurd rfl (hz0 ds')
    · rename_i ds' _ _ heq; cases heq; exact hz
    · rename_i heq; exact absurd rfl (heq _)

/-- **A parsed number is a normalized literal** (§2). -/
theorem normalLit_number {L : Limits} {t : Text} (h : NumberLit L t) :
    isNormalLit (normalizeNumber t).toList = true := by
  cases h with
  | hex s ds hs _ _ => rw [normalize_radix hs (.inl rfl)]; exact isNormalLit_intText_string _ _
  | binary s ds hs _ _ => rw [normalize_radix hs (.inr rfl)]; exact isNormalLit_intText_string _ _
  | decimal sg i f e hs hi hf he _ _ =>
    rw [normalize_decimal hs hi hf he, String.toList_ofList]
    obtain ⟨hIP, hid, hi0⟩ := intPart_filter hi
    have hine : i.filter (· != '_') ≠ [] := by
      cases hi with
      | zero => simp
      | nonzero c rest hc _ _ =>
        have : c ≠ '_' := by rintro rfl; simp [isDigit] at hc
        simp [this]
    -- After the integer part: `.` and the fraction, or `e` and the exponent, or nothing.
    have htail : ∀ c, ((f.filter (· != '_')) ++ normE e).head? = some c → isDigit c = false := by
      intro c hc
      rcases hf with rfl | ⟨ds, rfl, -⟩
      · rcases he with rfl | he
        · simp [normE] at hc
        · obtain ⟨m, sgn, ds, rfl, hm, hsg, -⟩ := he
          have hm' : m ≠ '_' := by rcases hm with rfl | rfl <;> decide
          have : (m :: sgn ++ ds).filter (· != '_') = m :: (sgn ++ ds).filter (· != '_') := by simp [hm']
          simp only [List.filter_nil, List.nil_append, normE, this, List.head?_cons, Option.some.injEq] at hc
          subst hc; rfl
      · simp at hc; subst hc; rfl
    have hsplit : ∀ {r : Text}, (∀ c, r.head? = some c → isDigit c = false) →
        (i.filter (· != '_') ++ r).takeWhile isDigit = i.filter (· != '_') ∧
        (i.filter (· != '_') ++ r).dropWhile isDigit = r := by
      intro r hr
      rw [takeWhile_append_of_all hid, dropWhile_append_of_all hid]
      cases r with
      | nil => simp
      | cons c cs => simp [hr c rfl]
    obtain ⟨htw, hdw⟩ := hsplit htail
    have hdm : dropMinus (sg ++ i.filter (· != '_') ++ f.filter (· != '_') ++ normE e) =
        i.filter (· != '_') ++ (f.filter (· != '_') ++ normE e) := by
      obtain ⟨c, cs, hcs⟩ : ∃ c cs, i.filter (· != '_') = c :: cs :=
        match i.filter (· != '_'), hine with
        | c :: cs, _ => ⟨c, cs, rfl⟩
      rcases hs with rfl | rfl
      · simp only [List.nil_append, List.append_assoc, hcs, List.cons_append]
        exact dropMinus_digit (hid c (by simp [hcs]))
      · simp [dropMinus]
    unfold isNormalLit
    simp only [hdm, htw, hdw, isIntDigits_of hine hid hi0, Bool.true_and]
    -- The tail: a fraction and an exponent, each optional.
    have hexp : normalTail.normalExp (normE e) = true := by
      rcases he with rfl | he
      · rfl
      · exact normalExp_normE he
    rcases hf with rfl | ⟨ds, rfl, hds⟩
    · simp only [List.filter_nil, List.nil_append]
      unfold normalTail
      split
      · rename_i r heq
        rcases he with rfl | ⟨m, sgn, ds, rfl, hm, -, -⟩
        · simp [normE] at heq
        · have hm' : m ≠ '_' := by rcases hm with rfl | rfl <;> decide
          simp [normE, hm'] at heq
      · exact hexp
    · have hdc := digits_chars hds
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
      have hetail : ∀ c, (normE e).head? = some c → isDigit c = false := by
        intro c hc
        rcases he with rfl | ⟨m, sgn, ds', rfl, hm, -, -⟩
        · simp [normE] at hc
        · have hm' : m ≠ '_' := by rcases hm with rfl | rfl <;> decide
          simp [normE, hm'] at hc; subst hc; rfl
      have h2 : (ds.filter (· != '_') ++ normE e).takeWhile isDigit = ds.filter (· != '_') ∧
          (ds.filter (· != '_') ++ normE e).dropWhile isDigit = normE e := by
        rw [takeWhile_append_of_all hdf, dropWhile_append_of_all hdf]
        cases hN : normE e with
        | nil => simp
        | cons c cs => simp [hetail c (by rw [hN]; rfl)]
      simp only [List.filter_cons, show ('.' != '_') = true by decide, ↓reduceIte, List.cons_append]
      unfold normalTail
      simp only [h2.1, h2.2, hexp, Bool.and_true, bne_iff_ne, ne_eq, hne, not_false_eq_true]

/-! ## Values -/

theorem tag_isTag {t : Text} (h : Tag t) : isTag t = true := by
  obtain ⟨c, cs, rfl, hc, hcs⟩ := h
  simp [isTag, hc, List.all_eq_true.mpr hcs]

theorem wfList_of {xs : List Value} (h : ∀ x ∈ xs, x.wf = true) : Value.wfList xs = true := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp only [Value.wfList, h x (by simp), ih fun y hy => h y (by simp [hy]), Bool.and_self]

theorem wfFields_of {fs : List (String × Value)} (h : ∀ kv ∈ fs, kv.2.wf = true) : Value.wfFields fs = true := by
  induction fs with
  | nil => rfl
  | cons kv fs ih =>
    obtain ⟨k, x⟩ := kv
    simp only [Value.wfFields, h (k, x) (by simp), ih fun y hy => h y (by simp [hy]), Bool.and_self]

variable {L : Limits}

mutual
/-- **Every value the grammar derives is well formed.** -/
theorem _root_.Haus.Grammar.Val.wf {n : Nat} {t : Text} {v : Value} : Val L n t v → v.wf = true
  | .number _ _ h => by simp only [Value.wf]; exact normalLit_number h
  | .string _ _ _ _ | .blockString _ _ _ _ | .bytes _ _ _ _ _ => rfl
  | .array _ _ _ h => by simp only [Value.wf]; exact h.wf
  | .record _ _ _ h => by simp only [Value.wf]; exact h.wf
  | .tag _ _ h _ => by simp [Value.wf, Value.wfList, tag_isTag h]
  | .payload _ _ _ _ _ h _ _ hi _ => by simp [Value.wf, tag_isTag h, hi.wf]
  | .recordPayload _ _ _ _ _ h _ _ hr => by simp [Value.wf, Value.wfList, tag_isTag h, hr.wf]

theorem _root_.Haus.Grammar.Items.wf {n : Nat} {t : Text} {xs : List Value} : Items L n t xs → Value.wfList xs = true
  | .empty _ _ _ => rfl
  | .some _ _ _ _ _ h => h.wf

theorem _root_.Haus.Grammar.ItemsFrom.wf {n : Nat} {t : Text} {xs : List Value} :
    ItemsFrom L n t xs → Value.wfList xs = true
  | .last _ _ _ _ hv _ => by simp [Value.wfList, hv.wf]
  | .lastComma _ _ _ _ _ hv _ _ => by simp [Value.wfList, hv.wf]
  | .cons _ _ _ _ _ _ _ hv _ _ hs => by simp [Value.wfList, hv.wf, hs.wf]

theorem _root_.Haus.Grammar.Record.wf {n : Nat} {t : Text} {fs : List (String × Value)} :
    Record L n t fs → Value.wfFields fs = true
  | .mk _ _ _ h _ => h.wf

theorem _root_.Haus.Grammar.Fields.wf {n : Nat} {t : Text} {fs : List (String × Value)} :
    Fields L n t fs → Value.wfFields fs = true
  | .empty _ _ _ => rfl
  | .some _ _ _ _ _ h => h.wf

theorem _root_.Haus.Grammar.FieldsFrom.wf {n : Nat} {t : Text} {fs : List (String × Value)} :
    FieldsFrom L n t fs → Value.wfFields fs = true
  | .last _ _ _ _ hf _ => by simp [Value.wfFields, hf.wf]
  | .lastComma _ _ _ _ _ hf _ _ => by simp [Value.wfFields, hf.wf]
  | .cons _ _ _ _ _ _ _ hf _ _ hs => by simp [Value.wfFields, hf.wf, hs.wf]

theorem _root_.Haus.Grammar.Field.wf {n : Nat} {t : Text} {f : String × Value} : Field L n t f → f.2.wf = true
  | .mk _ _ _ _ _ _ _ _ _ _ hv => hv.wf
end

/-- **Every value the reference parser returns is well formed**, so the JSON round trips hold for it. -/
theorem parse_wf {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) : ∀ v ∈ vs, v.wf = true := by
  intro v hv
  obtain ⟨s, hs⟩ := File.vals (Sound.parse_sound L input vs h) v hv
  exact hs.wf

end Haus
