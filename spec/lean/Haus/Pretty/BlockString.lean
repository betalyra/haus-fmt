import Haus.RoundTrip.Strings
import Haus.Correct

/-!
# Block strings in the pretty layout (spec §4, §11)

`blockString ind s` is the block string the pretty layout writes for the
string `s`, with its content and closing quotes at the indent `ind` (spaces
or tabs): the opening `"""` and a line break, then each line of `s` (split
at its line feeds), then a line break, `ind` and the closing `"""`. A line
of `s` is written as `ind` and the line with these escapes:

* `\` as `\\`, and a carriage return as `\r`;
* a quote followed by two more quotes as `\"`, so `"""` is `\"""`, and the
  text holds no three quotes in a row;
* raw control characters but tab, bidi controls and U+2028, U+2029 as
  `\u{…}` (uppercase hex, as in the canonical form);
* the last character, if it is a space or a tab, as `\u{20}` or `\t`.

An empty line is written empty, without the indent.

Proven, for every string `s` within the string limit and every indent:

* `blockString_parses`: it is a block string of the grammar with the value
  `s`, so the reference parser reads it back as exactly `s`
  (`parse_blockString`);
* `blockString_noTrailingBlank`: no line of it ends in a space or a tab;
* so trimming the spaces and tabs at the end of every line, as editors do,
  leaves it unchanged (`trimLines_blockString`) and it still parses to `s`
  (`parse_trimLines_blockString`).
-/

namespace Haus.Pretty
open Haus Grammar

variable {L : Limits}

/-! ## Lines -/

/-- `t` split at its line feeds. Every text has at least one line. -/
def splitLF : Text → List Text
  | [] => [[]]
  | c :: r =>
    if c = '\n' then [] :: splitLF r
    else match splitLF r with
      | l :: ls => (c :: l) :: ls
      | [] => [[c]]

theorem splitLF_ne_nil : ∀ t : Text, splitLF t ≠ []
  | [] => by simp [splitLF]
  | c :: r => by
    unfold splitLF
    split
    · simp
    · split <;> simp

/-- Joining the lines with line feeds gives the text back. -/
theorem intercalate_splitLF : ∀ t : Text, List.intercalate ['\n'] (splitLF t) = t
  | [] => by simp [splitLF]
  | c :: r => by
    have ih := intercalate_splitLF r
    unfold splitLF
    split
    · rename_i h
      subst h
      obtain ⟨l, ls, he⟩ : ∃ l ls, splitLF r = l :: ls :=
        match splitLF r, splitLF_ne_nil r with
        | l :: ls, _ => ⟨l, ls, rfl⟩
      rw [he] at ih ⊢
      rw [List.intercalate_cons_cons, ih]
      simp
    · split
      · rename_i l ls he
        rw [he] at ih
        cases ls with
        | nil => simpa using ih
        | cons l' ls => rw [List.intercalate_cons_cons] at ih ⊢; rw [← ih]; simp
      · rename_i he; exact absurd he (splitLF_ne_nil r)

/-- A text without line feeds is one line. -/
theorem splitLF_noLF : ∀ {a : Text}, '\n' ∉ a → splitLF a = [a]
  | [], _ => rfl
  | c :: r, h => by
    have hc : c ≠ '\n' := fun e => h (e ▸ List.mem_cons_self)
    have hr : '\n' ∉ r := fun e => h (List.mem_cons_of_mem _ e)
    simp only [splitLF, hc, ↓reduceIte, splitLF_noLF hr]

/-- A line, its line feed, and the rest. -/
theorem splitLF_line {a : Text} (h : '\n' ∉ a) (b : Text) : splitLF (a ++ '\n' :: b) = a :: splitLF b := by
  induction a with
  | nil => simp [splitLF]
  | cons c r ih =>
    have hc : c ≠ '\n' := fun e => h (e ▸ List.mem_cons_self)
    have hr : '\n' ∉ r := fun e => h (List.mem_cons_of_mem _ e)
    simp only [List.cons_append, splitLF, hc, ↓reduceIte, ih hr]

theorem splitLF_lines (b : Text) : ∀ {ls : List Text}, (∀ l ∈ ls, '\n' ∉ l) →
    splitLF ((ls.flatMap fun l => l ++ ['\n']) ++ b) = ls ++ splitLF b
  | [], _ => by simp
  | l :: ls, h => by
    have := splitLF_lines b (ls := ls) fun x hx => h x (List.mem_cons_of_mem _ hx)
    simp only [List.flatMap_cons, List.append_assoc, List.cons_append, List.nil_append, List.cons_append]
    rw [splitLF_line (h l List.mem_cons_self), this]

/-! ## Writing -/

/-- `\u{…}`, uppercase hex, as in the canonical form. -/
def unicode (c : Char) : Text := ['\\', 'u', '{'] ++ (Nat.toDigits 16 c.toNat).map Char.toUpper ++ ['}']

/-- A character of a line, other than a quote or a blank at its end. -/
def blockChar (c : Char) : Text :=
  if c = '\\' then ['\\', '\\']
  else if c = '\r' then ['\\', 'r']
  else if (isRawControl c && c != '\t') || isBidi c || isLineSep c then unicode c
  else [c]

/-- A character of a line, followed in the line by `r`. -/
def piece (c : Char) (r : Text) : Text :=
  if c = '"' then (if r.take 2 = ['"', '"'] then ['\\', '"'] else ['"'])
  else if r = [] then
    if c = ' ' then ['\\', 'u', '{', '2', '0', '}']
    else if c = '\t' then ['\\', 't']
    else blockChar c
  else blockChar c

/-- A line of the string, escaped. -/
def line : Text → Text
  | [] => []
  | c :: r => piece c r ++ line r

/-- A content line: the indent and the line, or nothing for an empty line. -/
def contentLine (ind l : Text) : Text := if l = [] then [] else ind ++ line l

def tripleQuote : Text := ['"', '"', '"']

/-- **The block string the pretty layout writes** for `s`, at the indent `ind`. -/
def blockString (ind : Text) (s : String) : Text :=
  tripleQuote ++ '\n' :: ((splitLF s.toList).flatMap fun l => contentLine ind l ++ ['\n']) ++ ind ++ tripleQuote

/-! ## Examples -/

private def bs (ind s : String) : String := String.ofList (blockString ind.toList s)

-- The example of spec §11: the last blank of a line is an escape.
#guard bs "  " "Delivery to the back door  \nRing twice" ==
  "\"\"\"\n  Delivery to the back door \\u{20}\n  Ring twice\n  \"\"\""
-- Lines of only blanks, a tab at the end, an empty line (written without the indent).
#guard bs "  " "a\n   \n\t\n\nb\t" == "\"\"\"\n  a\n    \\u{20}\n  \\t\n\n  b\\t\n  \"\"\""
-- Quotes: each one followed by two more is escaped. Backslashes, CR, controls, bidi, separators.
#guard bs "" "\"\"\"\"x\"\"\n\\\r\u001B\u202E\u2028" ==
  "\"\"\"\n\\\"\\\"\"\"x\"\"\n\\\\\\r\\u{1B}\\u{202E}\\u{2028}\n\"\"\""
#guard (Parser.parse {} (blockString "    ".toList "x \n\"\"\"\n\t")).toOption == some [.str "x \n\"\"\"\n\t"]

/-! ## Each line reads back as itself -/

theorem unicode_escape (c : Char) : Escape (unicode c) c := RoundTrip.unicodeEscape c

/-- Every character is written as itself (allowed raw in a block string) or as an escape for it. -/
theorem blockChar_ok (c : Char) : (blockChar c = [c] ∧ BlockChar c) ∨ Escape (blockChar c) c := by
  unfold blockChar
  split
  · rename_i h; subst h; exact .inr .backslash
  split
  · rename_i _ h; subst h; exact .inr .cr
  split
  · exact .inr (unicode_escape c)
  · rename_i h1 _ h
    have hb : isBidi c = false := by cases hb : isBidi c <;> simp_all
    refine .inl ⟨rfl, h1, ?_, hb⟩
    cases hc : isRawControl c
    · exact .inr rfl
    · exact .inl (Classical.byContradiction fun hne => by simp_all)

theorem piece_ok (c : Char) (r : Text) : (piece c r = [c] ∧ BlockChar c) ∨ Escape (piece c r) c := by
  unfold piece
  split
  · rename_i h; subst h
    split
    · exact .inr .quote
    · exact .inl ⟨rfl, by decide, .inr (by decide), by decide⟩
  split
  · split
    · rename_i h; subst h
      right
      have := Escape.unicode ['2', '0'] (by decide) (by decide) (by decide) (by decide)
      exact this
    split
    · rename_i h; subst h; exact .inr .tab
    · exact blockChar_ok c
  · exact blockChar_ok c

/-- A line, escaped, reads back as the line. -/
theorem chars_line : ∀ l : Text, Chars BlockChar (line l) l
  | [] => .nil
  | c :: r => by
    rcases piece_ok c r with ⟨he, hb⟩ | he
    · simp only [line, he, List.cons_append, List.nil_append]; exact .char c _ r hb (chars_line r)
    · exact .escape _ c _ r he (chars_line r)

/-! ## No unescaped `"""` -/

theorem hexUpper_mem {n : Nat} {y : Char} (h : y ∈ (Nat.toDigits 16 n).map Char.toUpper) : isHexDigit y = true := by
  obtain ⟨d', hd', rfl⟩ := List.mem_map.mp h
  obtain ⟨k, hk, rfl⟩ := RoundTrip.mem_toDigits (by decide) hd'
  exact RoundTrip.isHexDigit_toUpper_digitChar k hk

theorem hex_plain {y : Char} (h : isHexDigit y = true) : y ≠ '"' ∧ y ≠ '\\' ∧ y ≠ '\n' := by
  refine ⟨?_, ?_, ?_⟩ <;> rintro rfl <;> revert h <;> decide

/-- Characters that are neither a quote nor a backslash are passed one by one. -/
theorem ntq_plain {t : Text} (h : ∀ x ∈ t, x ≠ '"' ∧ x ≠ '\\') (u : Text) :
    noTripleQuote (t ++ u) = noTripleQuote u := by
  induction t with
  | nil => rfl
  | cons x t ih =>
    have hx := h x List.mem_cons_self
    rw [List.cons_append, Sound.noTripleQuote_cons hx.2 (fun e => hx.1 e.1)]
    exact ih fun y hy => h y (List.mem_cons_of_mem _ hy)

theorem ntq_escape (x : Char) (u : Text) : noTripleQuote ('\\' :: x :: u) = noTripleQuote u := by
  simp [noTripleQuote]

/-- How a piece starts: a raw quote, an escape, or a raw character that is neither. -/
theorem piece_shape (c : Char) (r : Text) :
    (piece c r = ['"'] ∧ c = '"' ∧ r.take 2 ≠ ['"', '"']) ∨
    (∃ x t, piece c r = '\\' :: x :: t ∧ ∀ y ∈ t, y ≠ '"' ∧ y ≠ '\\') ∨
    (piece c r = [c] ∧ c ≠ '"' ∧ c ≠ '\\') := by
  have hu : ∀ c, ∃ x t, unicode c = '\\' :: x :: t ∧ ∀ y ∈ t, y ≠ '"' ∧ y ≠ '\\' := by
    intro c
    refine ⟨'u', '{' :: ((Nat.toDigits 16 c.toNat).map Char.toUpper ++ ['}']), by simp [unicode], ?_⟩
    intro y hy
    simp only [List.mem_cons, List.mem_append, List.not_mem_nil, or_false] at hy
    rcases hy with rfl | hy | rfl
    · decide
    · have := hex_plain (hexUpper_mem hy); exact ⟨this.1, this.2.1⟩
    · decide
  have hb : ∀ c, c ≠ '"' → (∃ x t, blockChar c = '\\' :: x :: t ∧ ∀ y ∈ t, y ≠ '"' ∧ y ≠ '\\') ∨
      (blockChar c = [c] ∧ c ≠ '"' ∧ c ≠ '\\') := by
    intro c hq
    unfold blockChar
    split
    · exact .inl ⟨'\\', [], rfl, by simp⟩
    split
    · exact .inl ⟨'r', [], rfl, by simp⟩
    split
    · exact .inl (hu c)
    · rename_i h1 _ _; exact .inr ⟨rfl, hq, h1⟩
  unfold piece
  split
  · rename_i h; subst h
    split
    · exact .inr (.inl ⟨'"', [], rfl, by simp⟩)
    · rename_i h; exact .inl ⟨rfl, rfl, h⟩
  · rename_i hq
    split
    · split
      · exact .inr (.inl ⟨'u', ['{', '2', '0', '}'], rfl, by decide⟩)
      split
      · exact .inr (.inl ⟨'t', [], rfl, by simp⟩)
      · exact .inr (hb c hq)
    · exact .inr (hb c hq)

/-- A line that doesn't start with a quote is written without one first. -/
theorem line_head {r : Text} (hr : r.head? ≠ some '"') {u : Text} (hu : u.head? ≠ some '"') :
    (line r ++ u).head? ≠ some '"' := by
  cases r with
  | nil => simpa [line] using hu
  | cons c r =>
    have hc : c ≠ '"' := fun e => hr (by simp [e])
    simp only [line, List.append_assoc]
    rcases piece_shape c r with ⟨-, h, -⟩ | ⟨x, t, he, -⟩ | ⟨he, -, -⟩
    · exact absurd h hc
    · rw [he]; simp
    · rw [he]; simpa using hc

theorem take2_of_head {w : Text} (h : w.head? ≠ some '"') : w.take 2 ≠ ['"', '"'] := by
  cases w with
  | nil => simp
  | cons d w => simp_all

theorem take2_of_second {w : Text} (h : w.head? ≠ some '"') : ('"' :: w).take 2 ≠ ['"', '"'] := by
  cases w with
  | nil => simp
  | cons d w => simp_all

/-- **An escaped line holds no unescaped `"""`**, and none starts at its end. -/
theorem ntq_line : ∀ (l : Text) {u : Text}, u.head? ≠ some '"' → noTripleQuote (line l ++ u) = noTripleQuote u
  | [], _, _ => rfl
  | c :: r, u, hu => by
    have ih := ntq_line r hu
    simp only [line, List.append_assoc]
    rcases piece_shape c r with ⟨he, -, hr⟩ | ⟨x, t, he, ht⟩ | ⟨he, hq, hbs⟩
    · -- a raw quote: what follows doesn't start with two quotes
      have hnext : (line r ++ u).take 2 ≠ ['"', '"'] := by
        cases r with
        | nil => exact take2_of_head (by simpa [line] using hu)
        | cons c' r' =>
          by_cases hc' : c' = '"'
          · subst hc'
            have hr' : r'.head? ≠ some '"' := by
              cases r' with
              | nil => simp
              | cons d r'' => simpa using hr
            have hp : piece '"' r' = ['"'] := by simp [piece, take2_of_head hr']
            rw [show line ('"' :: r') ++ u = '"' :: (line r' ++ u) by simp [line, hp]]
            exact take2_of_second (line_head hr' hu)
          · exact take2_of_head (line_head (r := c' :: r') (by simpa using hc') hu)
      rw [he, List.singleton_append, Sound.noTripleQuote_cons (by decide) (fun e => hnext e.2), ih]
    · rw [he, List.cons_append, List.cons_append, ntq_escape, ntq_plain ht, ih]
    · rw [he, List.singleton_append, Sound.noTripleQuote_cons hbs (fun e => hq e.1), ih]

theorem blank_plain {ind : Text} (h : ∀ c ∈ ind, isBlank c = true) : ∀ x ∈ ind, x ≠ '"' ∧ x ≠ '\\' := by
  intro x hx
  have := h x hx
  constructor <;> rintro rfl <;> revert this <;> decide

/-- The content and the indent hold no unescaped `"""`. -/
theorem ntq_content {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) :
    ∀ ls : List Text, noTripleQuote ((ls.flatMap fun l => contentLine ind l ++ ['\n']) ++ ind) = true
  | [] => by
    simpa [noTripleQuote] using ntq_plain (blank_plain hind) []
  | l :: ls => by
    have ih := ntq_content hind ls
    have hlf : ∀ X : Text, noTripleQuote (['\n'] ++ X) = noTripleQuote X := fun X => by
      rw [List.singleton_append, Sound.noTripleQuote_cons (by decide) (fun e => absurd e.1 (by decide))]
    simp only [List.flatMap_cons, List.append_assoc]
    by_cases hl : l = []
    · rw [show contentLine ind l = [] by simp [contentLine, hl], List.nil_append, hlf, ih]
    · rw [show contentLine ind l = ind ++ line l by simp [contentLine, hl], List.append_assoc, ntq_plain (blank_plain hind),
        ntq_line l (by simp), hlf, ih]

/-! ## The block string parses back -/

theorem contentLine_ok {ind : Text} (l : Text) : BlockLine ind (contentLine ind l) l := by
  unfold contentLine
  split
  · rename_i h; subst h
    by_cases hi : ind = []
    · subst hi; exact .indented [] [] .nil
    · exact .blank [] (by simp) (fun hp => hi (List.prefix_nil.mp hp))
  · exact .indented _ _ (chars_line l)

theorem blockLines_ok (ind : Text) : ∀ ls : List Text,
    BlockLines ind (ls.flatMap fun l => contentLine ind l ++ ['\n']) ls
  | [] => .nil
  | l :: ls => by
    simp only [List.flatMap_cons]
    exact .line _ ['\n'] _ l ls (contentLine_ok l) .lf (blockLines_ok ind ls)

/--
**(a) The block string parses back** to exactly `s`: it is a block string of
the grammar (spec §4) with the value `s`, for every string within the
string limit and every indent of spaces and tabs.
-/
theorem blockString_parses {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) {s : String}
    (hs : s.length ≤ L.maxStringLength) : BlockString L (blockString ind s) s := by
  have htext : blockText (splitLF s.toList) = s := by
    simp [blockText, intercalate_splitLF]
  have := BlockString.mk (L := L) [] ['\n'] _ ind (splitLF s.toList) (by simp) .lf hind
    (blockLines_ok ind _) (ntq_content hind _) (by rw [htext]; exact hs)
  rw [htext] at this
  simpa [blockString, tripleQuote] using this

theorem blockString_val {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) {s : String}
    (hs : s.length ≤ L.maxStringLength) (n : Nat) : Val L n (blockString ind s) (.str s) :=
  .blockString n _ s (blockString_parses hind hs)

/-- The reference parser reads the block string as the string `s`. -/
theorem parse_blockString {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) {s : String}
    (hs : s.length ≤ L.maxStringLength) : Parser.parse L (blockString ind s) = .ok [.str s] := by
  apply (parse_correct L _ _).mpr
  have := File.values (L := L) [] [] _ _ (.inl rfl) .nil
    (FileItems.last _ [] _ (blockString_val hind hs L.maxDepth) (.ws [] .nil))
  simpa using this

/-! ## No line ends in a blank -/

theorem unicode_noLF (c : Char) : ∀ x ∈ unicode c, x ≠ '\n' := by
  intro x hx
  simp only [unicode, List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at hx
  rcases hx with ((rfl | rfl | rfl) | hx) | rfl
  any_goals decide
  exact (hex_plain (hexUpper_mem hx)).2.2

theorem piece_noLF (c : Char) (r : Text) : ∀ x ∈ piece c r, x ≠ '\n' := by
  have hb : ∀ x ∈ blockChar c, x ≠ '\n' := by
    unfold blockChar
    split
    · decide
    split
    · decide
    split
    · exact unicode_noLF c
    · rename_i h
      simp only [List.mem_singleton]
      rintro x rfl rfl
      exact h (by decide)
  unfold piece
  split
  · split <;> decide
  split
  · split
    · decide
    split
    · decide
    · exact hb
  · exact hb

theorem line_noLF : ∀ (l : Text), '\n' ∉ line l
  | [] => by simp [line]
  | c :: r => by
    simp only [line, List.mem_append, not_or]
    exact ⟨fun h => piece_noLF c r _ h rfl, line_noLF r⟩

theorem blank_noLF {ind : Text} (h : ∀ c ∈ ind, isBlank c = true) : '\n' ∉ ind := by
  intro hn; have := h _ hn; revert this; decide

theorem contentLine_noLF {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) (l : Text) : '\n' ∉ contentLine ind l := by
  unfold contentLine
  split
  · simp
  · simp only [List.mem_append, not_or]; exact ⟨blank_noLF hind, line_noLF l⟩

/-- The lines of the block string: the opening quotes, the content lines, the indent and the closing quotes. -/
theorem splitLF_blockString {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) (s : String) :
    splitLF (blockString ind s) =
      tripleQuote :: ((splitLF s.toList).map (contentLine ind) ++ [ind ++ tripleQuote]) := by
  have hm : ((splitLF s.toList).flatMap fun l => contentLine ind l ++ ['\n']) =
      ((splitLF s.toList).map (contentLine ind)).flatMap fun l => l ++ ['\n'] := by
    rw [List.flatMap_map]
  have hlast : '\n' ∉ ind ++ tripleQuote := by
    simp only [List.mem_append, not_or]; exact ⟨blank_noLF hind, by decide⟩
  unfold blockString
  simp only [List.append_assoc, List.cons_append]
  rw [splitLF_line (by decide), hm,
    splitLF_lines _ (by simpa using fun l _ => contentLine_noLF hind l), splitLF_noLF hlast]

/-- The last character of a piece at the end of a line is no blank. -/
theorem piece_last (c : Char) : ∀ x, (piece c []).getLast? = some x → isBlank x = false := by
  intro x hx
  unfold piece at hx
  split at hx
  · simp at hx; subst hx; decide
  simp only [↓reduceIte] at hx
  split at hx
  · simp at hx; subst hx; decide
  split at hx
  · simp at hx; subst hx; decide
  unfold blockChar at hx
  split at hx
  · simp at hx; subst hx; decide
  split at hx
  · simp at hx; subst hx; decide
  split at hx
  · rw [unicode, List.getLast?_concat] at hx; cases hx; decide
  · simp at hx; subst hx
    simp_all [isBlank]

theorem getLast?_append_ne {xs ys : Text} (h : ys ≠ []) : (xs ++ ys).getLast? = ys.getLast? := by
  rw [List.getLast?_append]
  cases hy : ys.getLast? with
  | none => exact absurd (List.getLast?_eq_none_iff.mp hy) h
  | some y => rfl

theorem piece_ne_nil (c : Char) (r : Text) : piece c r ≠ [] := by
  rcases piece_shape c r with ⟨he, -⟩ | ⟨x, t, he, -⟩ | ⟨he, -⟩ <;> simp [he]

theorem line_last : ∀ (l : Text), ∀ x, (line l).getLast? = some x → isBlank x = false
  | [], _, h => by simp [line] at h
  | [c], x, h => piece_last c x (by simpa [line] using h)
  | c :: c' :: r, x, h => by
    have hne : line (c' :: r) ≠ [] := by simp [line, piece_ne_nil]
    rw [line, getLast?_append_ne hne] at h
    exact line_last (c' :: r) x h

/--
**(b) No line of the block string ends in a space or a tab** (spec §11): the
text is split at its line feeds, and it holds no carriage return.
-/
theorem blockString_noTrailingBlank {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) (s : String) :
    ∀ l ∈ splitLF (blockString ind s), ∀ x, l.getLast? = some x → isBlank x = false := by
  rw [splitLF_blockString hind]
  intro l hl x hx
  simp only [List.mem_cons, List.mem_append, List.mem_map, List.not_mem_nil, or_false] at hl
  rcases hl with rfl | ⟨l', -, rfl⟩ | rfl
  · simp [tripleQuote] at hx; subst hx; decide
  · unfold contentLine at hx
    split at hx
    · simp at hx
    · rename_i hne
      have : line l' ≠ [] := by
        cases l' with
        | nil => exact absurd rfl hne
        | cons c r => simp [line, piece_ne_nil]
      rw [getLast?_append_ne this] at hx
      exact line_last l' x hx
  · simp [tripleQuote] at hx; subst hx; decide

theorem blockString_noCR {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) (s : String) :
    '\r' ∉ blockString ind s := by
  have hb : ∀ c, ∀ x ∈ blockChar c, x ≠ '\r' := by
    intro c x hx
    unfold blockChar at hx
    split at hx
    · simp at hx; subst hx; decide
    split at hx
    · simp at hx; rcases hx with rfl | rfl <;> decide
    split at hx
    · simp only [unicode, List.mem_append, List.mem_cons, List.not_mem_nil, or_false] at hx
      rcases hx with ((rfl | rfl | rfl) | hx) | rfl
      any_goals decide
      have := hexUpper_mem hx; rintro rfl; revert this; decide
    · rename_i h; simp at hx; subst hx; intro e; subst e; exact h (by decide)
  have hp : ∀ c r, ∀ x ∈ piece c r, x ≠ '\r' := by
    intro c r x hx
    unfold piece at hx
    split at hx
    · split at hx <;> simp at hx <;> (try rcases hx with rfl | rfl) <;> (try subst hx) <;> decide
    split at hx
    · split at hx
      · simp at hx; rcases hx with rfl | rfl | rfl | rfl | rfl | rfl <;> decide
      split at hx
      · simp at hx; rcases hx with rfl | rfl <;> decide
      · exact hb c x hx
    · exact hb c x hx
  have hl : ∀ l, '\r' ∉ line l := by
    intro l
    induction l with
    | nil => simp [line]
    | cons c r ih =>
      simp only [line, List.mem_append, not_or]
      exact ⟨fun h => hp c r _ h rfl, ih⟩
  have hi : '\r' ∉ ind := by intro hn; have := hind _ hn; revert this; decide
  intro h
  simp only [blockString, tripleQuote, List.mem_append, List.mem_cons, List.mem_flatMap, List.not_mem_nil,
    or_false] at h
  rcases h with (((h | h | h) | h | ⟨l, -, h | h⟩) | h) | h | h | h
  all_goals try exact absurd h (by decide)
  · unfold contentLine at h
    split at h
    · simp at h
    · rcases List.mem_append.mp h with h | h
      · exact hi h
      · exact hl l h
  · exact hi h

/-! ## Trimming trailing blanks changes nothing -/

/-- A line without the spaces and tabs at its end. -/
def trimEnd (l : Text) : Text := (l.reverse.dropWhile isBlank).reverse

/-- What an editor that trims trailing whitespace does: every line trimmed. -/
def trimLines (t : Text) : Text := List.intercalate ['\n'] ((splitLF t).map trimEnd)

theorem trimEnd_self {l : Text} (h : ∀ x, l.getLast? = some x → isBlank x = false) : trimEnd l = l := by
  unfold trimEnd
  cases hr : l.reverse with
  | nil => simp at hr; simp [hr]
  | cons c r =>
    have hc : isBlank c = false := h c (by rw [← List.head?_reverse, hr]; rfl)
    rw [List.dropWhile_cons_of_neg (by simp [hc]), ← hr, List.reverse_reverse]

/-- **(c) Trimming trailing blanks leaves the block string unchanged.** -/
theorem trimLines_blockString {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) (s : String) :
    trimLines (blockString ind s) = blockString ind s := by
  have hm : (splitLF (blockString ind s)).map trimEnd = (splitLF (blockString ind s)).map id :=
    List.map_congr_left fun l hl => trimEnd_self (blockString_noTrailingBlank hind s l hl)
  unfold trimLines
  rw [hm, List.map_id, intercalate_splitLF]

/-- So the block string, trimmed, still parses to `s`. -/
theorem parse_trimLines_blockString {ind : Text} (hind : ∀ c ∈ ind, isBlank c = true) {s : String}
    (hs : s.length ≤ L.maxStringLength) : Parser.parse L (trimLines (blockString ind s)) = .ok [.str s] := by
  rw [trimLines_blockString hind]; exact parse_blockString hind hs

end Haus.Pretty
