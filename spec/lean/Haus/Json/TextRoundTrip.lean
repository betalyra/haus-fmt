import Haus.Json.Text

/-!
# Reading back JSON text (spec §16)

`JSON.parse` reads back what `JSON.write` writes (`parse_write`), for every
JSON value the reader can return: well formed (`WellFormed`: numbers are
JSON number tokens, no object has two members with the same name) and within
the limits (`Fits`: strings, member names, number tokens and nesting). Strings
need no condition of their own: a Lean `String` holds Unicode scalar values,
so it has no unpaired surrogates.

These are exactly the values `parse` returns (`parse_sound`), so
`parse_write_iff`: the text of `j` reads back as `j` exactly when `j` is well
formed and within the limits.

`parseLines_writeLines` and `parseLines_sound` do the same for JSON Lines
(§16, "Streams"): the compact writer writes nothing below U+0020
(`write_chars`), so no line break, and each value is one line. It writes
no DEL, C1 or bidi control either (`write_clean`): every one is escaped.
-/

namespace Haus.JSON
open Haus

/-! ## What the reader accepts -/

/--
**Well-formed JSON** (I-JSON, §16): every number is a JSON number token
(RFC 8259) and no object has two members with the same name.
-/
inductive WellFormed : JSON → Prop
  | null : WellFormed .null
  | bool (b : Bool) : WellFormed (.bool b)
  | num (t : String) : isJsonNumber t.toList = true → WellFormed (.num t)
  | str (s : String) : WellFormed (.str s)
  | arr (xs : List JSON) : (∀ x ∈ xs, WellFormed x) → WellFormed (.arr xs)
  | obj (ms : List (String × JSON)) : (ms.map (·.1)).Nodup → (∀ m ∈ ms, WellFormed m.2) →
      WellFormed (.obj ms)

/--
**JSON within the limits** (§16, "Limits"), nested at most `d`: strings and
member names at most `maxStringLength` characters, number tokens as written
within `tokenFits`.
-/
inductive Fits (L : Limits) : Nat → JSON → Prop
  | null (d : Nat) : Fits L d .null
  | bool (d : Nat) (b : Bool) : Fits L d (.bool b)
  | num (d : Nat) (t : String) : tokenFits L t.toList = true → Fits L d (.num t)
  | str (d : Nat) (s : String) : s.length ≤ L.maxStringLength → Fits L d (.str s)
  | arr (d : Nat) (xs : List JSON) : (∀ x ∈ xs, Fits L d x) → Fits L (d + 1) (.arr xs)
  | obj (d : Nat) (ms : List (String × JSON)) :
      (∀ m ∈ ms, m.1.length ≤ L.maxStringLength) → (∀ m ∈ ms, Fits L d m.2) → Fits L (d + 1) (.obj ms)

/-- **JSON Lines** (§16, "Streams"): each value compactly, followed by a line feed. -/
def writeLines (js : List JSON) : Text := js.flatMap fun j => write j ++ ['\n']

/-! ## Numbers -/

theorem isNumberChar_digit {c : Char} (h : isDigit c = true) : isNumberChar c = true := by
  simp [isNumberChar, h]

theorem jsonExp_chars : ∀ r : Text, jsonTail.jsonExp r = true → ∀ c ∈ r, isNumberChar c = true
  | [], _ => by simp
  | c :: r, h => by
    unfold jsonTail.jsonExp at h
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at h
    obtain ⟨hc, hds⟩ := h
    have hd : ∀ ds : Text, (ds != []) = true ∧ ds.all isDigit = true → ∀ x ∈ ds, isNumberChar x = true := by
      intro ds h x hx
      simp only [List.all_eq_true] at h
      exact isNumberChar_digit (h.2 x hx)
    intro x hx
    rcases List.mem_cons.mp hx with rfl | hx
    · rcases hc with rfl | rfl <;> rfl
    · split at hds
      · rcases List.mem_cons.mp hx with rfl | hx
        · rfl
        · exact hd _ hds x hx
      · rcases List.mem_cons.mp hx with rfl | hx
        · rfl
        · exact hd _ hds x hx
      · exact hd _ hds x hx

theorem mem_takeWhile {p : Char → Bool} : ∀ {l : Text} {c : Char}, c ∈ l.takeWhile p → p c = true
  | [], _, h => by simp at h
  | x :: l, c, h => by
    rw [List.takeWhile_cons] at h
    split at h
    · rcases List.mem_cons.mp h with rfl | h
      · assumption
      · exact mem_takeWhile h
    · simp at h

theorem mem_split {p : Char → Bool} {l : Text} {c : Char} (h : c ∈ l) :
    c ∈ l.takeWhile p ∨ c ∈ l.dropWhile p := by
  rw [← List.takeWhile_append_dropWhile (p := p) (l := l)] at h
  exact List.mem_append.mp h

theorem jsonTail_chars {r : Text} (h : jsonTail r = true) : ∀ c ∈ r, isNumberChar c = true := by
  unfold jsonTail at h
  split at h
  · rename_i r
    simp only [Bool.and_eq_true] at h
    intro c hc
    rcases List.mem_cons.mp hc with rfl | hc
    · rfl
    · rcases mem_split (p := isDigit) hc with hc | hc
      · exact isNumberChar_digit (mem_takeWhile hc)
      · exact jsonExp_chars _ h.2 c hc
  · exact jsonExp_chars _ h

/-- A JSON number token is made of number characters only. -/
theorem isJsonNumber_chars {t : Text} (h : isJsonNumber t = true) : ∀ c ∈ t, isNumberChar c = true := by
  unfold isJsonNumber at h
  simp only [Bool.and_eq_true] at h
  have hu : ∀ c ∈ dropMinus t, isNumberChar c = true := by
    intro c hc
    rcases mem_split (p := isDigit) hc with hc | hc
    · exact isNumberChar_digit (mem_takeWhile hc)
    · exact jsonTail_chars h.2 c hc
  match t with
  | [] => simp
  | c :: r =>
    by_cases hm : c = '-'
    · subst hm
      intro x hx
      rcases List.mem_cons.mp hx with rfl | hx
      · rfl
      · exact hu x hx
    · have : dropMinus (c :: r) = c :: r := by
        unfold dropMinus; split
        · rename_i heq; cases heq; exact absurd rfl hm
        · rfl
      rwa [this] at hu

/-- A JSON number token starts with `-` or a digit. -/
theorem isJsonNumber_head {t : Text} (h : isJsonNumber t = true) :
    ∃ c r, t = c :: r ∧ (c = '-' ∨ isDigit c = true) := by
  match t, h with
  | [], h => simp [isJsonNumber, dropMinus, isIntDigits] at h
  | c :: r, h =>
    refine ⟨c, r, rfl, ?_⟩
    by_cases hm : c = '-'
    · exact .inl hm
    · right
      have hd : dropMinus (c :: r) = c :: r := by
        unfold dropMinus; split
        · rename_i heq; cases heq; exact absurd rfl hm
        · rfl
      unfold isJsonNumber at h
      rw [hd] at h
      cases hc : isDigit c
      · simp [hc, isIntDigits] at h
      · rfl

theorem isNumberChar_toNat {c : Char} (h : isNumberChar c = true) : 0x20 ≤ c.toNat := by
  simp only [isNumberChar, isDigit, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
  rcases h with ((((⟨h, _⟩ | rfl) | rfl) | rfl) | rfl) | rfl
  · exact Nat.le_trans (by decide) (Char.le_def.mp h)
  all_goals decide

/-- Nothing that can continue a number: a number written before it ends where it should. -/
def NumStop (r : Text) : Prop := ∀ c, r.head? = some c → isNumberChar c = false

theorem numStop_nil : NumStop [] := by intro c h; cases h

theorem numStop_cons {c : Char} {r : Text} (h : isNumberChar c = false) : NumStop (c :: r) := by
  intro c' h'; cases h'; exact h

theorem number_write {L : Limits} {t : String} {rest : Text} (hn : isJsonNumber t.toList = true)
    (hf : tokenFits L t.toList = true) (hr : NumStop rest) :
    number L (t.toList ++ rest) = .ok (.num t, rest) := by
  have hall := isJsonNumber_chars hn
  have ht : (t.toList ++ rest).takeWhile isNumberChar = t.toList := by
    rw [List.takeWhile_append_of_pos hall]
    cases rest with
    | nil => simp
    | cons c r => simp [hr c rfl]
  have hd : (t.toList ++ rest).dropWhile isNumberChar = rest := by
    rw [List.dropWhile_append_of_pos hall]
    cases rest with
    | nil => simp
    | cons c r => simp [hr c rfl]
  simp [number, ht, hd, hn, hf, String.ofList_toList]

/-! ## Strings -/

theorem hexChar_spec : ∀ k < 16, isHexDigit (Bytes.hexChar k) = true ∧ hexValue (Bytes.hexChar k) = k := by decide

theorem hexChar_toNat : ∀ n < 16, 0x20 ≤ (Bytes.hexChar n).toNat := by decide

theorem hexChar_clean : ∀ n < 16, mustEscape (Bytes.hexChar n) = false := by decide

/-- Four hex digits read back as the number they write. -/
theorem hex4_hex4Of {n : Nat} (h : n < 0x10000) (r : Text) : hex4 (hex4Of n ++ r) = some (n, r) := by
  obtain ⟨h1, v1⟩ := hexChar_spec (n / 4096 % 16) (Nat.mod_lt _ (by decide))
  obtain ⟨h2, v2⟩ := hexChar_spec (n / 256 % 16) (Nat.mod_lt _ (by decide))
  obtain ⟨h3, v3⟩ := hexChar_spec (n / 16 % 16) (Nat.mod_lt _ (by decide))
  obtain ⟨h4, v4⟩ := hexChar_spec (n % 16) (Nat.mod_lt _ (by decide))
  simp only [hex4Of, List.cons_append, List.nil_append, hex4, List.all_cons, List.all_nil, h1, h2, h3, h4,
    Bool.and_self, ↓reduceIte, digitsValue, List.foldl, v1, v2, v3, v4, Option.some.injEq, Prod.mk.injEq, and_true]
  omega

/-- A character that `mustEscape`s is below U+10000 and no surrogate. -/
theorem mustEscape_lt {c : Char} (h : mustEscape c = true) : c.toNat < 0x2070 := by
  simp only [mustEscape, isRawControl, isBidi, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at h
  omega

/-- How `escape` writes a character other than `"`, `\`, LF, CR and tab. -/
theorem escape_other {c : Char} (h1 : c ≠ '"') (h2 : c ≠ '\\') (h3 : c ≠ '\n') (h4 : c ≠ '\r')
    (h5 : c ≠ '\t') : escape c = if mustEscape c then '\\' :: 'u' :: hex4Of c.toNat else [c] := by
  unfold escape; split <;> simp_all

/-- An escaped character reads back as itself. -/
theorem strChars_escape {L : Limits} {strict : Bool} (c : Char) (f : Nat) (acc : List Char) (n : Nat) (r : Text)
    (hn : n ≤ L.maxStringLength) :
    strChars L strict (f + 1) (escape c ++ r) acc n = strChars L strict f r (c :: acc) (n + 1) := by
  have hn' : ¬ n > L.maxStringLength := by omega
  by_cases h1 : c = '"'
  · subst h1; simp [escape, strChars, hn']
  by_cases h2 : c = '\\'
  · subst h2; simp [escape, strChars, hn']
  by_cases h3 : c = '\n'
  · subst h3; simp [escape, strChars, hn']
  by_cases h4 : c = '\r'
  · subst h4; simp [escape, strChars, hn']
  by_cases h5 : c = '\t'
  · subst h5; simp [escape, strChars, hn']
  rw [escape_other h1 h2 h3 h4 h5]
  split
  · rename_i hc
    have hlt := mustEscape_lt hc
    have hx := hex4_hex4Of (n := c.toNat) (by omega) r
    have hhi : isHigh c.toNat = false := by simp [isHigh]; omega
    have hlo : isLow c.toNat = false := by simp [isLow]; omega
    simp only [List.cons_append, strChars, hn', ↓reduceIte, hx, hhi, hlo, Bool.false_eq_true, Char.ofNat_toNat]
  · rename_i hc
    have hlt : ¬ c.toNat < 0x20 := by
      simp only [mustEscape, isRawControl, Bool.or_eq_true, decide_eq_true_eq, not_or] at hc
      exact hc.1.1
    simp [strChars, hn', h2, hlt, hc]

/-- A string's escaped characters read back as the string. -/
theorem strChars_write {L : Limits} {strict : Bool} : ∀ (cs : List Char) (fuel : Nat) (acc : List Char) (n : Nat) (rest : Text),
    n + cs.length ≤ L.maxStringLength → cs.length < fuel →
    strChars L strict fuel (cs.flatMap escape ++ '"' :: rest) acc n = .ok (String.ofList (acc.reverse ++ cs), rest)
  | [], fuel + 1, acc, n, rest, hl, _ => by
    have hn' : ¬ n > L.maxStringLength := by simp at hl; omega
    simp [strChars, hn']
  | c :: cs, fuel + 1, acc, n, rest, hl, hf => by
    simp only [List.length_cons] at hl hf
    rw [List.flatMap_cons, List.append_assoc, strChars_escape c fuel acc n _ (by omega),
      strChars_write cs fuel (c :: acc) (n + 1) rest (by omega) (by omega)]
    simp

theorem strChars_writeString {L : Limits} {strict : Bool} (s : String) (rest : Text) (h : s.length ≤ L.maxStringLength) :
    strChars L strict ((s.toList.flatMap escape ++ '"' :: rest).length + 1) (s.toList.flatMap escape ++ '"' :: rest) [] 0 =
      .ok (s, rest) := by
  have hle : ∀ cs : List Char, cs.length ≤ (cs.flatMap escape).length := by
    intro cs
    induction cs with
    | nil => simp
    | cons c cs ih =>
      have : 1 ≤ (escape c).length := by
        unfold escape; split <;> try simp
        split <;> simp [hex4Of]
      simp only [List.flatMap_cons, List.length_append, List.length_cons]
      omega
  have := hle s.toList
  rw [strChars_write s.toList _ [] 0 rest (by simp [String.length_toList, h])
    (by simp only [List.length_append, List.length_cons]; omega)]
  simp [String.ofList_toList]

/-- What `escape` writes needs no escape. -/
theorem escape_clean (c : Char) : ∀ e ∈ escape c, mustEscape e = false := by
  by_cases h1 : c = '"'
  · subst h1; decide
  by_cases h2 : c = '\\'
  · subst h2; decide
  by_cases h3 : c = '\n'
  · subst h3; decide
  by_cases h4 : c = '\r'
  · subst h4; decide
  by_cases h5 : c = '\t'
  · subst h5; decide
  rw [escape_other h1 h2 h3 h4 h5]
  split
  · intro e he
    simp only [hex4Of, List.mem_cons, List.not_mem_nil, or_false] at he
    rcases he with rfl | rfl | rfl | rfl | rfl | rfl
    any_goals decide
    all_goals exact hexChar_clean _ (Nat.mod_lt _ (by decide))
  · rename_i hc
    intro e he
    simp only [List.mem_singleton] at he
    subst he; simpa using hc

theorem writeString_clean (s : String) : ∀ e ∈ writeString s, mustEscape e = false := by
  intro e he
  simp only [writeString, List.cons_append, List.mem_cons, List.mem_append, List.mem_flatMap,
    List.not_mem_nil, or_false] at he
  rcases he with rfl | ⟨c, _, hc⟩ | rfl
  · decide
  · exact escape_clean c e hc
  · decide

/-! ## What the writer writes -/

theorem digit_ne {c : Char} (h : isDigit c = true) {d : Char} (hd : isDigit d = false) : c ≠ d := by
  rintro rfl; simp_all

theorem writeItems_mem {c : Char} : ∀ {xs : List JSON}, c ∈ writeItems xs → c = ',' ∨ ∃ x ∈ xs, c ∈ write x
  | [], h => by simp [writeItems] at h
  | [x], h => .inr ⟨x, by simp, by simpa [writeItems] using h⟩
  | x :: y :: ys, h => by
    simp only [writeItems, List.mem_append, List.mem_cons] at h
    rcases h with h | rfl | h
    · exact .inr ⟨x, by simp, h⟩
    · exact .inl rfl
    · rcases writeItems_mem h with h | ⟨z, hz, h⟩
      · exact .inl h
      · exact .inr ⟨z, List.mem_cons_of_mem _ hz, h⟩

theorem writeMembers_mem {c : Char} : ∀ {ms : List (String × JSON)}, c ∈ writeMembers ms →
    c = ',' ∨ c = ':' ∨ ∃ m ∈ ms, c ∈ writeString m.1 ∨ c ∈ write m.2
  | [], h => by simp [writeMembers] at h
  | [(k, x)], h => by
    simp only [writeMembers, List.mem_append, List.mem_cons] at h
    rcases h with h | rfl | h
    · exact .inr (.inr ⟨(k, x), by simp, .inl h⟩)
    · exact .inr (.inl rfl)
    · exact .inr (.inr ⟨(k, x), by simp, .inr h⟩)
  | (k, x) :: m :: ms, h => by
    simp only [writeMembers, List.mem_append, List.mem_cons] at h
    rcases h with (h | rfl | h) | rfl | h
    · exact .inr (.inr ⟨(k, x), by simp, .inl h⟩)
    · exact .inr (.inl rfl)
    · exact .inr (.inr ⟨(k, x), by simp, .inr h⟩)
    · exact .inl rfl
    · rcases writeMembers_mem h with h | h | ⟨z, hz, h⟩
      · exact .inl h
      · exact .inr (.inl h)
      · exact .inr (.inr ⟨z, List.mem_cons_of_mem _ hz, h⟩)

theorem isDigit_toNat {c : Char} (h : isDigit c = true) : 48 ≤ c.toNat ∧ c.toNat ≤ 57 := by
  simp only [isDigit, Bool.and_eq_true, decide_eq_true_eq] at h
  have h1 := Char.le_def.mp h.1
  have h2 := Char.le_def.mp h.2
  simp only [UInt32.le_iff_toNat_le] at h1 h2
  exact ⟨h1, h2⟩

theorem isNumberChar_clean {c : Char} (h : isNumberChar c = true) : mustEscape c = false := by
  simp only [isNumberChar, Bool.or_eq_true, beq_iff_eq] at h
  rcases h with ((((h | rfl) | rfl) | rfl) | rfl) | rfl
  · have := isDigit_toNat h
    simp only [mustEscape, isRawControl, isBidi, Bool.or_eq_false_iff, Bool.and_eq_false_imp, decide_eq_true_eq,
      decide_eq_false_iff_not]
    omega
  all_goals decide

/--
**The writer writes no character that must be escaped** (§16): no control
character (below U+0020, DEL, C1) and no bidi control, raw, anywhere in
`write j`. So the self-describing reader, which rejects them raw, reads what
any writer writes.
-/
theorem write_clean {j : JSON} (h : WellFormed j) : ∀ c ∈ write j, mustEscape c = false := by
  induction h with
  | null => decide
  | bool b => cases b <;> decide
  | num t ht => exact fun c hc => isNumberChar_clean (isJsonNumber_chars ht c hc)
  | str s => exact writeString_clean s
  | arr xs _ ih =>
    intro c hc
    simp only [write, List.cons_append, List.mem_cons, List.mem_append, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | hc | rfl
    · decide
    · rcases writeItems_mem hc with rfl | ⟨x, hx, hc⟩
      · decide
      · exact ih x hx c hc
    · decide
  | obj ms _ _ ih =>
    intro c hc
    simp only [write, List.cons_append, List.mem_cons, List.mem_append, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | hc | rfl
    · decide
    · rcases writeMembers_mem hc with rfl | rfl | ⟨m, hm, hc | hc⟩
      · decide
      · decide
      · exact writeString_clean _ c hc
      · exact ih m hm c hc
    · decide

/--
**The writer writes no control character**: every character of `write j`
is U+0020 or above. In particular no line break, so in JSON Lines each value
is one line.
-/
theorem write_chars {j : JSON} (h : WellFormed j) : ∀ c ∈ write j, 0x20 ≤ c.toNat := by
  intro c hc
  have := write_clean h c hc
  simp only [mustEscape, isRawControl, Bool.or_eq_false_iff, decide_eq_false_iff_not] at this
  omega

/-- What a value's text starts with: not whitespace, not `]`, not a byte order mark. -/
def Start (c : Char) : Prop := isWs c = false ∧ c ≠ ']' ∧ c ≠ '﻿'

theorem write_head {j : JSON} (h : WellFormed j) : ∃ c r, write j = c :: r ∧ Start c := by
  cases h with
  | null => exact ⟨'n', ['u', 'l', 'l'], by simp [write], by unfold Start; decide⟩
  | bool b =>
    cases b
    · exact ⟨'f', ['a', 'l', 's', 'e'], by simp [write], by unfold Start; decide⟩
    · exact ⟨'t', ['r', 'u', 'e'], by simp [write], by unfold Start; decide⟩
  | str s => exact ⟨_, _, rfl, by unfold Start; decide⟩
  | arr xs _ => exact ⟨_, _, rfl, by unfold Start; decide⟩
  | obj ms _ _ => exact ⟨_, _, rfl, by unfold Start; decide⟩
  | num t ht =>
    obtain ⟨c, r, he, hc⟩ := isJsonNumber_head ht
    refine ⟨c, r, he, ?_⟩
    rcases hc with rfl | hc
    · unfold Start; decide
    · refine ⟨?_, digit_ne hc rfl, digit_ne hc rfl⟩
      simp [isWs, digit_ne hc (d := ' ') rfl, digit_ne hc (d := '\t') rfl, digit_ne hc (d := '\n') rfl,
        digit_ne hc (d := '\r') rfl]

theorem writeItems_head {xs : List JSON} (hne : xs ≠ []) (h : ∀ x ∈ xs, WellFormed x) :
    ∃ c r, writeItems xs = c :: r ∧ Start c := by
  match xs, hne with
  | [x], _ => simpa [writeItems] using write_head (h x (by simp))
  | x :: y :: ys, _ =>
    obtain ⟨c, r, he, hc⟩ := write_head (h x (by simp))
    exact ⟨c, r ++ ',' :: writeItems (y :: ys), by simp [writeItems, he], hc⟩

theorem skipWs_cons {c : Char} {r : Text} (h : isWs c = false) : skipWs (c :: r) = c :: r :=
  List.dropWhile_cons_of_neg (by simp [h])

theorem skipWs_start {c : Char} {r : Text} (h : Start c) : skipWs (c :: r) = c :: r := skipWs_cons h.1

theorem skipWs_close {r : Text} : skipWs (']' :: r) = ']' :: r := skipWs_cons rfl
theorem skipWs_brace {r : Text} : skipWs ('}' :: r) = '}' :: r := skipWs_cons rfl
theorem skipWs_comma {r : Text} : skipWs (',' :: r) = ',' :: r := skipWs_cons rfl
theorem skipWs_colon {r : Text} : skipWs (':' :: r) = ':' :: r := skipWs_cons rfl
theorem skipWs_quote {r : Text} : skipWs ('"' :: r) = '"' :: r := skipWs_cons rfl
theorem skipWs_nil : skipWs [] = [] := rfl

theorem write_ne_nil {j : JSON} (h : WellFormed j) : write j ≠ [] := by
  obtain ⟨c, r, he, _⟩ := write_head h
  simp [he]

/-! ## Reading what is written -/

section
variable {L : Limits} {strict : Bool}

theorem value_number {f d : Nat} {c : Char} {r : Text} (h : c = '-' ∨ isDigit c = true) :
    value L strict (f + 1) d (c :: r) = number L (c :: r) := by
  rcases h with rfl | h
  · simp [value]
  · simp [value, h, digit_ne h (d := '{') rfl, digit_ne h (d := '[') rfl, digit_ne h (d := '"') rfl,
      digit_ne h (d := 't') rfl, digit_ne h (d := 'f') rfl, digit_ne h (d := 'n') rfl]

theorem numStop_close : NumStop (']' :: r) := numStop_cons rfl
theorem numStop_brace : NumStop ('}' :: r) := numStop_cons rfl
theorem numStop_comma : NumStop (',' :: r) := numStop_cons rfl

theorem not_contains {keys : List String} {k : String} (h : k ∉ keys) : keys.contains k = false := by
  simpa using h

/--
The reader's three functions read back what the writer writes, given enough
fuel: a value (`value`), array items after the first `[` (`items`) and object
members after the first `{` (`members`). By induction on the fuel.
-/
theorem read_write : ∀ fuel : Nat,
    (∀ (j : JSON) (d : Nat) (rest : Text), WellFormed j → Fits L d j → (write j).length ≤ fuel →
      NumStop rest → value L strict fuel d (write j ++ rest) = .ok (j, rest)) ∧
    (∀ (xs : List JSON) (d : Nat) (rest : Text) (acc : List JSON), xs ≠ [] → (∀ x ∈ xs, WellFormed x) →
      (∀ x ∈ xs, Fits L d x) → (writeItems xs).length < fuel →
      items L strict fuel d (writeItems xs ++ ']' :: rest) acc = .ok (.arr (acc.reverse ++ xs), rest)) ∧
    (∀ (ms : List (String × JSON)) (d : Nat) (rest : Text) (acc : List (String × JSON)) (keys : List String),
      ms ≠ [] → (ms.map (·.1)).Nodup → (∀ m ∈ ms, m.1 ∉ keys) → (∀ m ∈ ms, WellFormed m.2) →
      (∀ m ∈ ms, m.1.length ≤ L.maxStringLength) → (∀ m ∈ ms, Fits L d m.2) →
      (writeMembers ms).length < fuel →
      members L strict fuel d (writeMembers ms ++ '}' :: rest) acc keys = .ok (.obj (acc.reverse ++ ms), rest))
  | 0 => by
    refine ⟨fun j _ _ hw _ hl _ => ?_, fun _ _ _ _ _ _ _ hl => absurd hl (Nat.not_lt_zero _),
      fun _ _ _ _ _ _ _ _ _ _ _ hl => absurd hl (Nat.not_lt_zero _)⟩
    obtain ⟨c, r, he, _⟩ := write_head hw
    rw [he] at hl; simp at hl
  | f + 1 => by
    obtain ⟨hv, hi, hm⟩ := read_write f
    refine ⟨?_, ?_, ?_⟩
    · intro j d rest hw hf hl hr
      cases hw with
      | null => simp [write, value, word, List.isPrefixOf]; rfl
      | bool b => cases b <;> (simp [write, value, word, List.isPrefixOf]; rfl)
      | num t ht =>
        cases hf with
        | num _ _ htf =>
          obtain ⟨c, r, he, hc⟩ := isJsonNumber_head ht
          simp only [write]
          rw [he, List.cons_append, value_number hc, ← List.cons_append, ← he, number_write ht htf hr]
      | str s =>
        cases hf with
        | str _ _ hs =>
          simp only [write, writeString, List.cons_append, List.append_assoc, List.nil_append]
          simp only [value]
          rw [strChars_writeString s rest hs]
          rfl
      | arr xs hxs =>
        cases hf with
        | arr d xs hfx =>
          simp only [write, List.cons_append, List.append_assoc, List.length_cons, List.length_append] at hl ⊢
          match xs, hxs, hfx with
          | [], _, _ => simp [value, writeItems, skipWs_close]
          | x :: xs, hxs, hfx =>
            obtain ⟨c, r, he, hc⟩ := writeItems_head (List.cons_ne_nil x xs) hxs
            have hc' : c ≠ ']' := hc.2.1
            have := hi (x :: xs) d rest [] (List.cons_ne_nil x xs) hxs hfx (by omega)
            rw [he] at this hl ⊢
            simp only [List.cons_append, List.reverse_nil, List.nil_append] at this
            simp [value, skipWs_start hc, hc', this]
      | obj ms hnd hms =>
        cases hf with
        | obj d ms hks hfm =>
          simp only [write, List.cons_append, List.append_assoc, List.length_cons, List.length_append] at hl ⊢
          match ms, hnd, hms, hks, hfm with
          | [], _, _, _, _ => simp [value, writeMembers, skipWs_brace]
          | (k, x) :: ms, hnd, hms, hks, hfm =>
            have := hm ((k, x) :: ms) d rest [] [] (List.cons_ne_nil _ _) hnd (by simp) hms hks hfm (by omega)
            have he : writeMembers ((k, x) :: ms) = '"' :: (writeMembers ((k, x) :: ms)).tail := by
              cases ms <;> simp [writeMembers, writeString]
            rw [he] at this ⊢
            simp only [List.cons_append, List.reverse_nil, List.nil_append] at this
            simp [value, skipWs_quote, this]
    · intro xs d rest acc hne hw hf hl
      match xs, hne, hw, hf with
      | [x], _, hw, hf =>
        simp only [writeItems] at hl ⊢
        have := hv x d (']' :: rest) (hw x (by simp)) (hf x (by simp)) (by omega) numStop_close
        simp [items, this, skipWs_close, bind, Except.bind]
      | x :: y :: ys, _, hw, hf =>
        simp only [writeItems, List.length_append, List.length_cons] at hl ⊢
        have h1 := hv x d (',' :: (writeItems (y :: ys) ++ ']' :: rest)) (hw x (by simp)) (hf x (by simp))
          (by omega) numStop_comma
        obtain ⟨c, r, he, hc⟩ := writeItems_head (List.cons_ne_nil y ys) (fun z hz => hw z (by simp [hz]))
        have h2 := hi (y :: ys) d rest (x :: acc) (List.cons_ne_nil y ys) (fun z hz => hw z (by simp [hz]))
          (fun z hz => hf z (by simp [hz])) (by omega)
        rw [he] at h2
        simp only [List.cons_append, List.reverse_cons, List.append_assoc] at h2
        rw [List.append_assoc, List.cons_append, items, h1]
        simp [skipWs_comma, he, skipWs_start hc, h2, bind, Except.bind]
    · intro ms d rest acc keys hne hnd hk hw hs hf hl
      match ms, hne, hnd, hk, hw, hs, hf with
      | [(k, x)], _, _, hk, hw, hs, hf =>
        simp only [writeMembers, writeString, List.length_append, List.length_cons] at hl ⊢
        obtain ⟨c, r, he, hc⟩ := write_head (hw (k, x) (by simp))
        simp only at he
        have hx := hv x d ('}' :: rest) (hw (k, x) (by simp)) (hf (k, x) (by simp)) (by omega) numStop_brace
        rw [he, List.cons_append] at hx
        have hsk := strChars_writeString (L := L) (strict := strict) k (':' :: c :: (r ++ '}' :: rest)) (hs (k, x) (by simp))
        simp only [List.cons_append, List.append_assoc, List.nil_append, he]
        rw [members, hsk]
        simp [hk (k, x) (by simp), skipWs_colon, skipWs_start hc, hx, skipWs_brace, bind, Except.bind]
      | (k, x) :: m :: ms, _, hnd, hk, hw, hs, hf =>
        simp only [writeMembers, writeString, List.length_append, List.length_cons] at hl ⊢
        obtain ⟨c, r, he, hc⟩ := write_head (hw (k, x) (by simp))
        simp only at he
        have hm' : writeMembers (m :: ms) = '"' :: (writeMembers (m :: ms)).tail := by
          cases ms <;> simp [writeMembers, writeString]
        have hx := hv x d (',' :: ('"' :: (writeMembers (m :: ms)).tail ++ '}' :: rest)) (hw (k, x) (by simp))
          (hf (k, x) (by simp)) (by omega) numStop_comma
        rw [he] at hx
        simp only [List.cons_append] at hx
        have hnd' := List.nodup_cons.mp hnd
        have h2 := hm (m :: ms) d rest ((k, x) :: acc) (k :: keys) (List.cons_ne_nil _ _) hnd'.2
          (by
            intro m' hm' hmk
            rcases List.mem_cons.mp hmk with h | h
            · exact hnd'.1 (List.mem_map.mpr ⟨m', hm', h⟩)
            · exact hk m' (List.mem_cons_of_mem _ hm') h)
          (fun z hz => hw z (by simp [hz])) (fun z hz => hs z (by simp [hz]))
          (fun z hz => hf z (by simp [hz])) (by omega)
        rw [hm', List.cons_append] at h2
        have hsk := strChars_writeString (L := L) (strict := strict) k
          (':' :: c :: (r ++ ',' :: '"' :: ((writeMembers (m :: ms)).tail ++ '}' :: rest))) (hs (k, x) (by simp))
        rw [hm']
        simp only [List.cons_append, List.append_assoc, List.nil_append, he]
        rw [members, hsk]
        simp [hk (k, x) (by simp), skipWs_colon, skipWs_start hc, hx, skipWs_comma, skipWs_quote, h2, bind,
          Except.bind]

theorem value_write {j : JSON} {d fuel : Nat} {rest : Text} (hw : WellFormed j) (hf : Fits L d j)
    (hl : (write j).length ≤ fuel) (hr : NumStop rest) : value L strict fuel d (write j ++ rest) = .ok (j, rest) :=
  (read_write fuel).1 j d rest hw hf hl hr

theorem dropBom_start {c : Char} {r : Text} (h : Start c) : dropBom (c :: r) = c :: r := by
  unfold dropBom; split
  · rename_i heq; cases heq; exact absurd rfl h.2.2
  · rfl

/-- One JSON text, nested at most `d`, without a byte order mark. -/
theorem parseText_write {j : JSON} {d : Nat} (hw : WellFormed j) (hf : Fits L d j) :
    parseText L strict d (write j) = .ok j := by
  obtain ⟨c, r, he, hc⟩ := write_head hw
  have hv := value_write (strict := strict) (fuel := 2 * (write j).length + 4) (rest := []) hw hf (by omega) numStop_nil
  rw [List.append_nil, he] at hv
  unfold parseText
  rw [he, skipWs_start hc, hv]
  rfl

theorem parseDepth_write {j : JSON} {d : Nat} (hw : WellFormed j) (hf : Fits L d j) :
    parseDepth L d (write j) = .ok j := by
  obtain ⟨c, r, he, hc⟩ := write_head hw
  unfold parseDepth
  rw [he, dropBom_start hc, ← he, parseText_write hw hf]

/--
**JSON text reads back** (§16): reading what the writer writes gives the same
JSON, for every well-formed value within the limits. Exactly the same value:
members in the same order, numbers with the same text.
-/
theorem parse_write {j : JSON} (hw : WellFormed j) (hf : Fits L (jsonDepth L) j) :
    parse L (write j) = .ok j :=
  parseDepth_write hw hf

/-! ## JSON Lines -/

theorem splitOn_newline : ∀ (a b : Text), (∀ c ∈ a, c ≠ '\n') →
    (a ++ '\n' :: b).splitOn '\n' = a :: b.splitOn '\n'
  | [], b, _ => by simp [List.splitOn, List.splitOnP_cons_eq_ite_modifyHead]
  | c :: a, b, h => by
    have ih := splitOn_newline a b (fun x hx => h x (List.mem_cons_of_mem _ hx))
    simp only [List.splitOn] at ih ⊢
    rw [List.cons_append, List.splitOnP_cons_eq_ite_modifyHead, ih]
    simp [h c (by simp)]

theorem write_no_newline {j : JSON} (h : WellFormed j) : ∀ c ∈ write j, c ≠ '\n' := by
  intro c hc he
  have := write_chars h c hc
  subst he
  exact absurd this (by decide)

theorem write_last {j : JSON} (h : WellFormed j) : (write j).getLast? ≠ some '\r' := by
  intro he
  have := write_chars h _ (List.mem_of_getLast? he)
  exact absurd this (by decide)

theorem writeLines_splitOn : ∀ {js : List JSON}, (∀ j ∈ js, WellFormed j) →
    (writeLines js).splitOn '\n' = js.map write ++ [[]]
  | [], _ => by simp [writeLines, List.splitOn]
  | j :: js, h => by
    have ih := writeLines_splitOn (js := js) (fun x hx => h x (List.mem_cons_of_mem _ hx))
    simp only [writeLines, List.flatMap_cons, List.append_assoc, List.singleton_append] at ih ⊢
    rw [splitOn_newline _ _ (write_no_newline (h j (by simp))), ih]
    simp

/-- The lines of written JSON Lines are the values' texts. -/
theorem lines_writeLines {js : List JSON} (h : ∀ j ∈ js, WellFormed j) : lines (writeLines js) = js.map write := by
  unfold lines
  rw [writeLines_splitOn h]
  have hcr : (js.map write).map (fun l : Text => if l.getLast? = some '\r' then l.dropLast else l) = js.map write := by
    rw [List.map_map]
    apply List.map_congr_left
    intro j hj
    simp [write_last (h j hj)]
  simp [hcr]

/--
**JSON Lines read back** (§16, "Streams"): reading the lines written for a
list of values gives the same values, each well formed and within the limits.
-/
theorem parseLines_writeLines {js : List JSON} (hw : ∀ j ∈ js, WellFormed j)
    (hf : ∀ j ∈ js, Fits L (jsonDepth L) j) : parseLines L (writeLines js) = .ok js := by
  have hb : dropBom (writeLines js) = writeLines js := by
    cases js with
    | nil => rfl
    | cons j js =>
      obtain ⟨c, r, he, hc⟩ := write_head (hw j (by simp))
      simp only [writeLines, List.flatMap_cons, he, List.cons_append]
      exact dropBom_start hc
  unfold parseLines
  rw [hb, lines_writeLines hw]
  clear hb
  induction js with
  | nil => rfl
  | cons j js ih =>
    have h1 : (write j).isEmpty = false := by
      cases h : write j with
      | nil => exact absurd h (write_ne_nil (hw j (by simp)))
      | cons _ _ => rfl
    have ih := ih (fun x hx => hw x (List.mem_cons_of_mem _ hx)) (fun x hx => hf x (List.mem_cons_of_mem _ hx))
    simp only [List.map_cons, List.mapM_cons, h1, parseText_write (hw j (by simp)) (hf j (by simp)), ih]
    rfl

/-! ## Only such values are read -/

/-- A string read is within the length limit. -/
theorem strChars_length : ∀ (fuel : Nat) (t : Text) (acc : List Char) (n : Nat) (s : String) (r : Text),
    strChars L strict fuel t acc n = .ok (s, r) → acc.length = n → s.length ≤ L.maxStringLength
  | 0, _, _, _, _, _, h, _ => by simp [strChars] at h
  | f + 1, t, acc, n, s, r, h, hn => by
    have ih := strChars_length f
    simp only [strChars] at h
    split at h
    · cases h
    · rename_i hle
      split at h
      · cases h
      · cases h; simp [String.length_ofList, hn]; omega
      · rename_i c r'
        split at h
        all_goals first
          | cases h
          | exact ih _ _ _ _ _ h (by simp [hn])
          | ((repeat' split at h) <;> first | cases h | exact ih _ _ _ _ _ h (by simp [hn]))
      · cases h
      · split at h
        · cases h
        · split at h
          · split at h <;> cases h
          · exact ih _ _ _ _ _ h (by simp [hn])

theorem number_sound {d : Nat} {t : Text} {j : JSON} {r : Text} (h : number L t = .ok (j, r)) :
    WellFormed j ∧ Fits L d j := by
  unfold number at h
  dsimp only at h
  split at h
  · cases h
  split at h
  · cases h
  cases h
  rename_i h1 h2
  simp only [Bool.not_eq_true', Bool.not_eq_false] at h1 h2
  exact ⟨.num _ (by rwa [String.toList_ofList]), .num _ _ (by rwa [String.toList_ofList])⟩

theorem word_sound {w : String} {j0 j : JSON} {t r : Text} (h : word w j0 t = .ok (j, r)) : j = j0 := by
  unfold word at h; split at h <;> cases h; rfl

/--
What the reader's three functions return is well formed and within the
limits. By induction on the fuel.
-/
theorem read_sound : ∀ fuel : Nat,
    (∀ d t j r, value L strict fuel d t = .ok (j, r) → WellFormed j ∧ Fits L d j) ∧
    (∀ d t acc j r, (∀ x ∈ acc, WellFormed x ∧ Fits L d x) → items L strict fuel d t acc = .ok (j, r) →
      ∃ xs, j = .arr xs ∧ ∀ x ∈ xs, WellFormed x ∧ Fits L d x) ∧
    (∀ d t acc keys j r, keys = acc.map (·.1) → (acc.map (·.1)).Nodup →
      (∀ m ∈ acc, m.1.length ≤ L.maxStringLength ∧ WellFormed m.2 ∧ Fits L d m.2) →
      members L strict fuel d t acc keys = .ok (j, r) →
      ∃ ms, j = .obj ms ∧ (ms.map (·.1)).Nodup ∧
        ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ WellFormed m.2 ∧ Fits L d m.2)
  | 0 => by
    refine ⟨?_, ?_, ?_⟩
    · intro _ _ _ _ h; simp [value] at h
    · intro _ _ _ _ _ _ h; simp [items] at h
    · intro _ _ _ _ _ _ _ _ _ h; simp [members] at h
  | f + 1 => by
    obtain ⟨hv, hi, hm⟩ := read_sound f
    refine ⟨?_, ?_, ?_⟩
    · intro d t j r h
      simp only [value] at h
      split at h
      · split at h
        · cases h
        obtain ⟨d', rfl⟩ : ∃ d', d = d' + 1 := ⟨d - 1, by omega⟩
        simp only [Nat.add_sub_cancel] at h
        split at h
        · cases h; exact ⟨.obj [] (by simp) (by simp), .obj _ _ (by simp) (by simp)⟩
        · obtain ⟨ms, rfl, hnd, hms⟩ := hm _ _ _ _ _ _ rfl (by simp) (by simp) h
          exact ⟨.obj _ hnd (fun m hm => (hms m hm).2.1),
            .obj _ _ (fun m hm => (hms m hm).1) (fun m hm => (hms m hm).2.2)⟩
      · split at h
        · cases h
        obtain ⟨d', rfl⟩ : ∃ d', d = d' + 1 := ⟨d - 1, by omega⟩
        simp only [Nat.add_sub_cancel] at h
        split at h
        · cases h; exact ⟨.arr [] (by simp), .arr _ _ (by simp)⟩
        · obtain ⟨xs, rfl, hxs⟩ := hi _ _ _ _ _ (by simp) h
          exact ⟨.arr _ (fun x hx => (hxs x hx).1), .arr _ _ (fun x hx => (hxs x hx).2)⟩
      · rename_i r0
        cases hs : strChars L strict (r0.length + 1) r0 [] 0 with
        | error e => rw [hs] at h; cases h
        | ok p =>
          rw [hs] at h
          cases h
          exact ⟨.str _, .str _ _ (strChars_length _ _ _ _ _ _ hs rfl)⟩
      · rw [word_sound h]; exact ⟨.bool _, .bool _ _⟩
      · rw [word_sound h]; exact ⟨.bool _, .bool _ _⟩
      · rw [word_sound h]; exact ⟨.null, .null _⟩
      · split at h
        · exact number_sound h
        · cases h
      · cases h
    · intro d t acc j r hacc h
      simp only [items, bind, Except.bind] at h
      split at h
      · cases h
      rename_i p hp
      obtain ⟨hpw, hpf⟩ := hv _ _ _ _ hp
      split at h
      · exact hi _ _ _ _ _ (by
          intro x hx
          rcases List.mem_cons.mp hx with rfl | hx
          · exact ⟨hpw, hpf⟩
          · exact hacc x hx) h
      · cases h
        refine ⟨_, rfl, fun x hx => ?_⟩
        rcases List.mem_cons.mp (List.mem_reverse.mp hx) with rfl | hx
        · exact ⟨hpw, hpf⟩
        · exact hacc x hx
      · cases h
    · intro d t acc keys j r hk hnd hacc h
      simp only [members, bind, Except.bind] at h
      split at h
      · rename_i r0
        split at h
        · cases h
        rename_i p hp
        have hlen := strChars_length _ _ _ _ _ _ hp rfl
        split at h
        · cases h
        rename_i hnk
        split at h
        · split at h
          · cases h
          rename_i q hq
          obtain ⟨hqw, hqf⟩ := hv _ _ _ _ hq
          have hnk' : p.1 ∉ acc.map (·.1) := by subst hk; simpa using hnk
          have hacc' : ∀ m ∈ (p.1, q.1) :: acc, m.1.length ≤ L.maxStringLength ∧ WellFormed m.2 ∧ Fits L d m.2 := by
            intro m hm
            rcases List.mem_cons.mp hm with rfl | hm
            · exact ⟨hlen, hqw, hqf⟩
            · exact hacc m hm
          split at h
          · exact hm _ _ ((p.1, q.1) :: acc) _ _ _ (by simp [hk])
              (show (((p.1, q.1) :: acc).map (·.1)).Nodup from List.nodup_cons.mpr ⟨hnk', hnd⟩) hacc' h
          · cases h
            refine ⟨_, rfl, ?_, fun m hm => hacc' m (List.mem_reverse.mp hm)⟩
            rw [List.map_reverse]
            exact (List.reverse_perm _).nodup_iff.mpr (List.nodup_cons.mpr ⟨hnk', hnd⟩)
          · cases h
        · cases h
      · cases h

/-- What `parseText` reads is well formed and nested at most `d`. -/
theorem parseText_sound {d : Nat} {t : Text} {j : JSON} (h : parseText L strict d t = .ok j) :
    WellFormed j ∧ Fits L d j := by
  simp only [parseText, bind, Except.bind] at h
  split at h
  · cases h
  rename_i p hp
  split at h
  · cases h; exact (read_sound _).1 _ _ _ _ hp
  · cases h

/--
**What JSON text reads is well formed and within the limits**: so the
conditions of `parse_write` are exactly those of the values `parse` returns.
-/
theorem parse_sound {t : Text} {j : JSON} (h : parse L t = .ok j) : WellFormed j ∧ Fits L (jsonDepth L) j :=
  parseText_sound h

/-- **The written text reads back exactly when** the value is well formed and within the limits. -/
theorem parse_write_iff {j : JSON} : parse L (write j) = .ok j ↔ WellFormed j ∧ Fits L (jsonDepth L) j :=
  ⟨parse_sound, fun ⟨hw, hf⟩ => parse_write hw hf⟩

theorem mapM_sound {α ε : Type} {f : α → Except ε JSON} {P : JSON → Prop} (hf : ∀ a j, f a = .ok j → P j) :
    ∀ {l : List α} {js : List JSON}, l.mapM f = .ok js → ∀ j ∈ js, P j
  | [], js, h => by cases h; simp
  | a :: l, js, h => by
    simp only [List.mapM_cons, bind, Except.bind] at h
    split at h
    · cases h
    rename_i x hx
    split at h
    · cases h
    rename_i ys hys
    cases h
    intro j hj
    rcases List.mem_cons.mp hj with rfl | hj
    · exact hf _ _ hx
    · exact mapM_sound hf hys j hj

/-- What JSON Lines reads is well formed and within the limits, value by value. -/
theorem parseLines_sound {t : Text} {js : List JSON} (h : parseLines L t = .ok js) :
    ∀ j ∈ js, WellFormed j ∧ Fits L (jsonDepth L) j := by
  refine mapM_sound (fun l j hl => ?_) h
  split at hl
  · cases hl
  · exact parseText_sound hl

end

end Haus.JSON
