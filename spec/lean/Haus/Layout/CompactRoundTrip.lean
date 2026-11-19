import Haus.Layout.Compact
import Haus.RoundTrip.File
import Haus.Pretty.BlockString

/-!
# The compact and minimised layouts parse back (L3)

For every value the grammar derives within the limits `L`, its compact and
its minimised layout are derived too, with the same value: fields in the
same order, nothing sorted. By induction on the derivation, like the
canonical form's round trip (`Haus.RoundTrip.Values`), whose leaves
(strings, keys, bytes, numbers) they share; the only difference is the
whitespace between tokens, which any blank `Spacing` may add.

* `parse_compact`, `parse_minimised`: for every value a parser returns,
  its layout parses back to exactly that value;
* `parse_compactAll`, `parse_minimisedAll`: a parsed file or stream, written
  in either layout, parses back to the same values in the same order.
-/

namespace Haus.Layout
open Haus Grammar Canonical RoundTrip

variable {L : Limits}

/-- The spacing writes spaces and tabs only. -/
def Spacing.Blank (sp : Spacing) : Prop :=
  (∀ c ∈ sp.comma, isBlank c = true) ∧ (∀ c ∈ sp.colon, isBlank c = true) ∧
    (∀ c ∈ sp.inner, isBlank c = true) ∧ (∀ c ∈ sp.tag, isBlank c = true)

theorem Spacing.spaced_blank : Spacing.spaced.Blank := by simp [Spacing.Blank, Spacing.spaced, isBlank]
theorem Spacing.tight_blank : Spacing.tight.Blank := by simp [Spacing.Blank, Spacing.tight]

/-- Spaces and tabs are whitespace. -/
theorem ws_blanks : ∀ {w : Text}, (∀ c ∈ w, isBlank c = true) → WS w
  | [], _ => .nil
  | c :: w, h => .blank c w (h c (by simp)) (ws_blanks fun x hx => h x (by simp [hx]))

/-! ## Building the layout from its parts -/

section
variable (sp : Spacing) (hsp : sp.Blank)
include hsp

/-- Values separated by `,` and the spacing, followed by whitespace `e`. -/
theorem itemsFrom_line {n : Nat} : ∀ (x : Value) (xs : List Value) {e : Text}, WS e →
    (∀ y ∈ x :: xs, Val L n (line sp y) y) → ItemsFrom L n (lineList sp (x :: xs) ++ e) (x :: xs)
  | x, [], e, he, h => by simpa [lineList] using ItemsFrom.last n (line sp x) e x (h x (by simp)) he
  | x, y :: ys, e, he, h => by
    have := ItemsFrom.cons n (line sp x) [] sp.comma _ x (y :: ys) (h x (by simp)) .nil (ws_blanks hsp.1)
      (itemsFrom_line y ys he fun z hz => h z (by simp_all))
    simpa [lineList] using this

theorem items_line {n : Nat} : ∀ xs : List Value, (∀ y ∈ xs, Val L n (line sp y) y) →
    Items L n (lineList sp xs) xs
  | [], _ => by simpa [lineList] using Items.empty n [] .nil
  | x :: xs, h => by simpa using Items.some n [] _ _ .nil (by simpa using itemsFrom_line sp hsp x xs .nil h)

/-- A field `key: value`, by its parts. -/
def LineOk (L : Limits) (n : Nat) (sp : Spacing) (kv : String × Value) : Prop :=
  Key L (Canonical.key kv.1) kv.1 ∧ Val L n (line sp kv.2) kv.2

theorem field_line {n : Nat} {kv : String × Value} (h : LineOk L n sp kv) :
    Field L n (Canonical.key kv.1 ++ ':' :: sp.colon ++ line sp kv.2) kv := by
  simpa using Field.mk n _ [] sp.colon _ kv.1 kv.2 h.1 .nil (ws_blanks hsp.2.1) h.2

theorem fieldsFrom_line {n : Nat} : ∀ (f : String × Value) (fs : List (String × Value)) {e : Text}, WS e →
    (∀ g ∈ f :: fs, LineOk L n sp g) → FieldsFrom L n (lineFields sp (f :: fs) ++ e) (f :: fs)
  | (k, v), [], e, he, h => by
    simpa [lineFields] using FieldsFrom.last n _ e (k, v) (field_line sp hsp (h (k, v) (by simp))) he
  | (k, v), g :: gs, e, he, h => by
    have := FieldsFrom.cons n _ [] sp.comma _ (k, v) (g :: gs) (field_line sp hsp (h (k, v) (by simp))) .nil
      (ws_blanks hsp.1) (fieldsFrom_line g gs he fun z hz => h z (by simp_all))
    simpa [lineFields] using this

theorem record_line {n : Nat} (fs : List (String × Value)) (hnd : (fs.map Prod.fst).Nodup)
    (h : ∀ g ∈ fs, LineOk L n sp g) : Record L n (braces sp fs (lineFields sp fs)) fs := by
  cases fs with
  | nil => simpa [braces, lineFields] using Record.mk (L := L) n [] [] (Fields.empty n [] .nil) hnd
  | cons f fs =>
    have := Record.mk n _ _ (Fields.some n sp.inner _ _ (ws_blanks hsp.2.2.1)
      (fieldsFrom_line sp hsp f fs (ws_blanks hsp.2.2.1) h)) hnd
    simpa [braces] using this

end

/-! ## The induction -/

mutual
theorem _root_.Haus.Grammar.Val.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text} {v : Value} :
    Val L n t v → Val L n (line sp v) v
  | .number _ t hn => by simpa [Layout.line] using number_canonical hn n
  | .string _ t s hs => by
    cases hs with
    | mk raw s' _ hl => simpa [Layout.line] using string_canonical (L := L) (String.ofList s') (by simpa using hl) n
  | .blockString _ t s hs => by
    cases hs with
    | mk _ _ _ _ ss _ _ _ _ _ hl => simpa [Layout.line] using string_canonical (L := L) (blockText ss) hl n
  | .bytes _ raw bs hb hl => by simpa [Layout.line] using bytes_canonical hb hl n
  | .array m inner xs hi => by
    simpa [Layout.line] using Val.array m _ _ (items_line sp hsp xs (hi.line sp hsp))
  | .record m t fs hr => by
    simpa [Layout.line] using Val.record m _ _ (hr.line sp hsp)
  | .tag _ t ht hl => by simpa [Layout.line] using Val.tag n t ht hl
  | .payload m t sp' inner xs ht hl hsp' hi hxs => by
    have hall := hi.line sp hsp
    rcases xs with _ | ⟨x, xs⟩
    · exact absurd rfl hxs
    rcases positional_shape x xs with ⟨fs, rfl, rfl⟩ | hp
    · -- `Tag({…})` is written `Tag {…}`, one level less deep
      have hv := hall (.record fs) (by simp)
      obtain ⟨k, rfl, hr⟩ := val_record hv
      have hr' : Record L k (braces sp fs (lineFields sp fs)) fs := by simpa [Layout.line] using hr
      have := Val.recordPayload (k + 1) t sp.tag _ _ ht hl hsp.2.2.2 (hr'.mono (k + 1) (by omega))
      simpa [Layout.line] using this
    · rw [line_args _ _ hp]
      simpa using Val.payload m t [] _ _ ht hl (by simp) (items_line sp hsp _ hall) hxs
  | .recordPayload m t sp' r fs ht hl hsp' hr => by
    simpa [Layout.line] using Val.recordPayload m t sp.tag _ _ ht hl hsp.2.2.2 (hr.line sp hsp)

theorem _root_.Haus.Grammar.Items.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text} {xs : List Value} :
    Items L n t xs → ∀ x ∈ xs, Val L n (line sp x) x
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hi => hi.line sp hsp

theorem _root_.Haus.Grammar.ItemsFrom.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {xs : List Value} : ItemsFrom L n t xs → ∀ x ∈ xs, Val L n (line sp x) x
  | .last _ _ _ _ hv _ => List.forall_mem_singleton.mpr (hv.line sp hsp)
  | .lastComma _ _ _ _ _ hv _ _ => List.forall_mem_singleton.mpr (hv.line sp hsp)
  | .cons _ _ _ _ _ _ _ hv _ _ hi => List.forall_mem_cons.mpr ⟨hv.line sp hsp, hi.line sp hsp⟩

theorem _root_.Haus.Grammar.Record.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : Record L n t fs → Record L n (braces sp fs (lineFields sp fs)) fs
  | .mk _ _ fs hf hnd => record_line sp hsp fs hnd (hf.line sp hsp)

theorem _root_.Haus.Grammar.Fields.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : Fields L n t fs → ∀ g ∈ fs, LineOk L n sp g
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hf => hf.line sp hsp

theorem _root_.Haus.Grammar.FieldsFrom.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : FieldsFrom L n t fs → ∀ g ∈ fs, LineOk L n sp g
  | .last _ _ _ _ hf _ => List.forall_mem_singleton.mpr (hf.line sp hsp)
  | .lastComma _ _ _ _ _ hf _ _ => List.forall_mem_singleton.mpr (hf.line sp hsp)
  | .cons _ _ _ _ _ _ _ hf _ _ hi => List.forall_mem_cons.mpr ⟨hf.line sp hsp, hi.line sp hsp⟩

theorem _root_.Haus.Grammar.Field.line (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {f : String × Value} : Field L n t f → LineOk L n sp f
  | .mk _ _ _ _ _ _ _ hk _ _ hv => ⟨key_canonical hk, hv.line sp hsp⟩
end

/-! ## Files and streams -/

/-- A line feed is whitespace at the end of a file. -/
theorem wsEnd_lf : WSEnd ['\n'] := .ws _ (by simpa using WS.newline ['\n'] [] .lf .nil)

theorem fileItems_lines (write : Value → Text) :
    ∀ (x : Value) (xs : List Value), (∀ v ∈ x :: xs, Val L L.maxDepth (write v) v) →
      FileItems L ((x :: xs).flatMap fun v => write v ++ [',', '\n']) (x :: xs)
  | x, [], h => by
    simpa using FileItems.lastComma _ [] ['\n'] x (h x (by simp)) .nil wsEnd_lf
  | x, y :: ys, h => by
    have := FileItems.cons _ [] ['\n'] _ x (y :: ys) (h x (by simp)) .nil (by simpa using WS.newline ['\n'] [] .lf .nil)
      (fileItems_lines write y ys fun v hv => h v (by simp_all))
    simpa using this

/-- Values written one per line, each with `write`, are a file with exactly those values. -/
theorem file_lines (write : Value → Text) :
    ∀ {vs : List Value}, (∀ v ∈ vs, Val L L.maxDepth (write v) v) → File L (lines write vs) vs
  | [], _ => by simpa [lines] using File.empty (L := L) [] [] (.inl rfl) (.ws [] .nil)
  | [v], h => by
    simpa [lines] using File.values [] [] _ _ (.inl rfl) .nil (FileItems.last _ ['\n'] v (h v (by simp)) wsEnd_lf)
  | v :: w :: ws, h => by
    simpa [lines] using File.values [] [] _ _ (.inl rfl) .nil (fileItems_lines write v (w :: ws) h)

/-- A value written alone, with no line break after it, is a file with that value. -/
theorem file_single {t : Text} {v : Value} (h : Val L L.maxDepth t v) : File L t [v] := by
  simpa using File.values [] [] _ _ (.inl rfl) .nil (FileItems.last _ [] _ h (.ws [] .nil))

theorem parse_line (sp : Spacing) (hsp : sp.Blank) {input : Text} {vs : List Value}
    (h : Parser.parse L input = .ok vs) {v : Value} (hv : v ∈ vs) : Parser.parse L (line sp v) = .ok [v] := by
  obtain ⟨s, hs⟩ := File.vals ((parse_correct L input vs).mp h) v hv
  exact (parse_correct L _ _).mpr (file_single (hs.line sp hsp))

theorem parse_lines (sp : Spacing) (hsp : sp.Blank) {input : Text} {vs : List Value}
    (h : Parser.parse L input = .ok vs) : Parser.parse L (lines (line sp) vs) = .ok vs := by
  have hvs := File.vals ((parse_correct L input vs).mp h)
  exact (parse_correct L _ _).mpr (file_lines _ fun v hv => by
    obtain ⟨s, hs⟩ := hvs v hv; exact hs.line sp hsp)

/-- **L3. The compact layout of a parsed value parses back to it,** fields in the same order. -/
theorem parse_compact {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) {v : Value}
    (hv : v ∈ vs) : Parser.parse L (compact v) = .ok [v] :=
  parse_line _ Spacing.spaced_blank h hv

/-- **L3. The minimised layout of a parsed value parses back to it,** fields in the same order. -/
theorem parse_minimised {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) {v : Value}
    (hv : v ∈ vs) : Parser.parse L (minimised v) = .ok [v] :=
  parse_line _ Spacing.tight_blank h hv

/-- **L3. A parsed file or stream in the compact layout parses back** to the same values, in order. -/
theorem parse_compactAll {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    Parser.parse L (compactAll vs) = .ok vs :=
  parse_lines _ Spacing.spaced_blank h

/-- **L3. A parsed file or stream in the minimised layout parses back** to the same values, in order. -/
theorem parse_minimisedAll {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    Parser.parse L (minimisedAll vs) = .ok vs :=
  parse_lines _ Spacing.tight_blank h

/-! ## One line per value -/

theorem sepTail_noLF {p : Char → Bool} (hp : p '\n' = false) {t : Text} (h : SepTail p t) : '\n' ∉ t := by
  induction h with
  | nil => simp
  | digit c _ hc _ ih => simp only [List.mem_cons, not_or]; exact ⟨fun e => by subst e; simp_all, ih⟩
  | sep c _ hc _ ih => simp only [List.mem_cons, not_or]; exact ⟨by decide, fun e => by subst e; simp_all, ih⟩

theorem digits_noLF {p : Char → Bool} (hp : p '\n' = false) {t : Text} (h : Digits p t) : '\n' ∉ t := by
  obtain ⟨c, rest, rfl, hc, hr⟩ := h
  simp only [List.mem_cons, not_or]
  exact ⟨fun e => by subst e; simp_all, sepTail_noLF hp hr⟩

theorem sign_noLF {s : Text} (h : Sign s) : '\n' ∉ s := by rcases h with rfl | rfl <;> decide

/-- A number literal is on one line. -/
theorem numberLit_noLF {t : Text} (h : NumberLit L t) : '\n' ∉ t := by
  have hd : isDigit '\n' = false := by decide
  cases h with
  | decimal s i f e hs hi hf he _ _ =>
    have hi' : '\n' ∉ i := by
      cases hi with
      | zero => decide
      | nonzero c rest hc _ hr =>
        simp only [List.mem_cons, not_or]; exact ⟨fun e => by subst e; simp_all, sepTail_noLF hd hr⟩
    have hf' : '\n' ∉ f := by
      rcases hf with rfl | ⟨ds, rfl, hds⟩
      · simp
      · simp only [List.mem_cons, not_or]; exact ⟨by decide, digits_noLF hd hds⟩
    have he' : '\n' ∉ e := by
      rcases he with rfl | ⟨x, sg, ds, rfl, hx, hsg, hds⟩
      · simp
      · simp only [List.cons_append, List.mem_cons, List.mem_append, not_or]
        refine ⟨by rcases hx with rfl | rfl <;> decide, ?_, digits_noLF hd hds⟩
        rcases hsg with rfl | rfl | rfl <;> decide
    simp only [List.mem_append, not_or]; exact ⟨⟨⟨sign_noLF hs, hi'⟩, hf'⟩, he'⟩
  | hex s ds hs hds _ _ =>
    simp only [List.mem_append, List.mem_cons, not_or]
    exact ⟨sign_noLF hs, by decide, by decide, digits_noLF (by decide) hds⟩
  | binary s ds hs hds _ =>
    simp only [List.mem_append, List.mem_cons, not_or]
    exact ⟨sign_noLF hs, by decide, by decide, digits_noLF (by decide) hds⟩

theorem escape_noLF (c : Char) : '\n' ∉ escape c := by
  unfold escape
  split <;> try decide
  split
  · intro h; exact Pretty.unicode_noLF c _ h rfl
  · simp only [List.mem_singleton]; intro e; subst e; simp_all

theorem string_noLF (s : String) : '\n' ∉ Canonical.string s := by
  have := escape_noLF
  simp [Canonical.string, this]

theorem bytes_noLF (bs : List UInt8) : '\n' ∉ Canonical.bytes bs := by
  have hd : ∀ d < 16, hexDigit d ≠ '\n' := fun d hd => (Pretty.hex_plain (hexDigit_lt d hd).2).2.2
  have hb : ∀ b : UInt8, '\n' ≠ hexDigit (b.toNat / 16) ∧ '\n' ≠ hexDigit (b.toNat % 16) := fun b => by
    have := b.toNat_lt
    exact ⟨fun h => hd _ (by omega) h.symm, fun h => hd _ (by omega) h.symm⟩
  simp [Canonical.bytes, hb]

theorem identChar_noLF {c : Char} (h : isIdentChar c = true) : c ≠ '\n' := by rintro rfl; revert h; decide

theorem key_noLF (k : String) : '\n' ∉ Canonical.key k := by
  unfold Canonical.key
  split
  · rename_i h
    unfold isIdent at h
    split at h
    · rename_i c cs heq
      rw [heq]
      simp only [Bool.and_eq_true, List.all_eq_true] at h
      have hc : c ≠ '\n' := by have := h.1; rintro rfl; revert this; decide
      have hcs : '\n' ∉ cs := fun hm => identChar_noLF (h.2 _ hm) rfl
      simp [hcs, Ne.symm hc]
    · simp at h
  · exact string_noLF k

theorem tag_noLF {t : Text} (h : Tag t) : '\n' ∉ t := by
  obtain ⟨c, cs, rfl, hc, hcs⟩ := h
  simp only [List.mem_cons, not_or]
  exact ⟨fun e => by subst e; revert hc; decide, fun hm => identChar_noLF (hcs _ hm) rfl⟩

theorem blank_noLF' {w : Text} (h : ∀ c ∈ w, isBlank c = true) : '\n' ∉ w := Pretty.blank_noLF h

section
variable (sp : Spacing) (hsp : sp.Blank)
include hsp

theorem lineList_noLF : ∀ xs : List Value, (∀ x ∈ xs, '\n' ∉ line sp x) → '\n' ∉ lineList sp xs
  | [], _ => by simp [lineList]
  | [x], h => by simpa [lineList] using h x (by simp)
  | x :: y :: ys, h => by
    have h1 := lineList_noLF (y :: ys) fun z hz => h z (by simp_all)
    have h2 := h x (by simp)
    have h3 := blank_noLF' hsp.1
    simp [lineList, h1, h2, h3]

theorem lineFields_noLF : ∀ fs : List (String × Value), (∀ g ∈ fs, '\n' ∉ line sp g.2) →
    '\n' ∉ lineFields sp fs
  | [], _ => by simp [lineFields]
  | [(k, v)], h => by
    have h1 := key_noLF k
    have h2 := h (k, v) (by simp)
    have h3 := blank_noLF' hsp.2.1
    simp [lineFields, h1, h2, h3]
  | (k, v) :: g :: gs, h => by
    have h0 := lineFields_noLF (g :: gs) fun z hz => h z (by simp_all)
    have h1 := key_noLF k
    have h2 := h (k, v) (by simp)
    have h3 := blank_noLF' hsp.2.1
    have h4 := blank_noLF' hsp.1
    simp [lineFields, h0, h1, h2, h3, h4]

theorem braces_noLF (fs : List (String × Value)) {inside : Text} (h : '\n' ∉ inside) :
    '\n' ∉ braces sp fs inside := by
  have h1 := blank_noLF' hsp.2.2.1
  cases fs <;> simp [braces, h, h1]
end

mutual
theorem _root_.Haus.Grammar.Val.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text} {v : Value} :
    Val L n t v → '\n' ∉ line sp v
  | .number _ t hn => by simpa [Layout.line, Canonical.number] using numberLit_noLF (normalized_lit hn).1
  | .string _ t s _ => by simpa [Layout.line] using string_noLF s
  | .blockString _ t s _ => by simpa [Layout.line] using string_noLF s
  | .bytes _ raw bs _ _ => by simpa [Layout.line] using bytes_noLF bs
  | .array m inner xs hi => by
    have := lineList_noLF sp hsp xs (hi.line_noLF sp hsp)
    simp [Layout.line, this]
  | .record m t fs hr => by
    simpa [Layout.line] using braces_noLF sp hsp fs (hr.line_noLF sp hsp)
  | .tag _ t ht _ => by simpa [Layout.line] using tag_noLF ht
  | .payload m t sp' inner xs ht hl hsp' hi hxs => by
    have hall := hi.line_noLF sp hsp
    rcases xs with _ | ⟨x, xs⟩
    · exact absurd rfl hxs
    rcases positional_shape x xs with ⟨fs, rfl, rfl⟩ | hp
    · have h := hall (.record fs) (by simp)
      simp only [Layout.line, String.toList_ofList, List.mem_append, not_or] at h ⊢
      exact ⟨⟨tag_noLF ht, blank_noLF' hsp.2.2.2⟩, h⟩
    · rw [line_args _ _ hp]
      have h1 := tag_noLF ht
      have h2 := lineList_noLF sp hsp _ hall
      simp [h1, h2]
  | .recordPayload m t sp' r fs ht hl hsp' hr => by
    simp only [Layout.line, String.toList_ofList, List.mem_append, not_or]
    exact ⟨⟨tag_noLF ht, blank_noLF' hsp.2.2.2⟩, braces_noLF sp hsp fs (hr.line_noLF sp hsp)⟩

theorem _root_.Haus.Grammar.Items.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {xs : List Value} : Items L n t xs → ∀ x ∈ xs, '\n' ∉ line sp x
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hi => hi.line_noLF sp hsp

theorem _root_.Haus.Grammar.ItemsFrom.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {xs : List Value} : ItemsFrom L n t xs → ∀ x ∈ xs, '\n' ∉ line sp x
  | .last _ _ _ _ hv _ => List.forall_mem_singleton.mpr (hv.line_noLF sp hsp)
  | .lastComma _ _ _ _ _ hv _ _ => List.forall_mem_singleton.mpr (hv.line_noLF sp hsp)
  | .cons _ _ _ _ _ _ _ hv _ _ hi => List.forall_mem_cons.mpr ⟨hv.line_noLF sp hsp, hi.line_noLF sp hsp⟩

theorem _root_.Haus.Grammar.Record.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : Record L n t fs → '\n' ∉ lineFields sp fs
  | .mk _ _ fs hf _ => lineFields_noLF sp hsp fs (hf.line_noLF sp hsp)

theorem _root_.Haus.Grammar.Fields.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : Fields L n t fs → ∀ g ∈ fs, '\n' ∉ line sp g.2
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hf => hf.line_noLF sp hsp

theorem _root_.Haus.Grammar.FieldsFrom.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {fs : List (String × Value)} : FieldsFrom L n t fs → ∀ g ∈ fs, '\n' ∉ line sp g.2
  | .last _ _ _ _ hf _ => List.forall_mem_singleton.mpr (hf.line_noLF sp hsp)
  | .lastComma _ _ _ _ _ hf _ _ => List.forall_mem_singleton.mpr (hf.line_noLF sp hsp)
  | .cons _ _ _ _ _ _ _ hf _ _ hi => List.forall_mem_cons.mpr ⟨hf.line_noLF sp hsp, hi.line_noLF sp hsp⟩

theorem _root_.Haus.Grammar.Field.line_noLF (sp : Spacing) (hsp : sp.Blank) {n : Nat} {t : Text}
    {f : String × Value} : Field L n t f → '\n' ∉ line sp f.2
  | .mk _ _ _ _ _ _ _ _ _ _ hv => hv.line_noLF sp hsp
end

/-- One line of text for each value, each parsing, alone, to its value. -/
def LinesOf (L : Limits) (ls : List Text) (vs : List Value) : Prop :=
  ls.length = vs.length ∧ ∀ p ∈ ls.zip vs, Parser.parse L p.1 = .ok [p.2]

theorem mem_zip_map {g : Value → Text} : ∀ {vs : List Value} {p : Text × Value}, p ∈ (vs.map g).zip vs →
    p.1 = g p.2 ∧ p.2 ∈ vs
  | [], _, h => by simp at h
  | v :: vs, p, h => by
    simp only [List.map_cons, List.zip_cons_cons, List.mem_cons] at h
    rcases h with rfl | h
    · simp
    · exact ⟨(mem_zip_map h).1, List.mem_cons_of_mem _ (mem_zip_map h).2⟩

/-- A value followed by a comma, alone, is a file with that value. -/
theorem file_comma {t : Text} {v : Value} (h : Val L L.maxDepth t v) : File L (t ++ [',']) [v] := by
  simpa using File.values [] [] _ _ (.inl rfl) .nil (FileItems.lastComma _ [] [] _ h .nil (.ws [] .nil))

/--
A stream in a one-line layout **splits by lines** (spec §11, like NDJSON):
split at its line feeds, it is one line per value and an empty last line,
and each line, alone, parses to its value.
-/
theorem lines_split (sp : Spacing) (hsp : sp.Blank) {input : Text} {vs : List Value}
    (h : Parser.parse L input = .ok vs) :
    ∃ ls, Pretty.splitLF (lines (line sp) vs) = ls ++ [[]] ∧ LinesOf L ls vs := by
  have hvs := File.vals ((parse_correct L input vs).mp h)
  have hval : ∀ v ∈ vs, Val L L.maxDepth (line sp v) v ∧ '\n' ∉ line sp v := fun v hv => by
    obtain ⟨s, hs⟩ := hvs v hv; exact ⟨hs.line sp hsp, hs.line_noLF sp hsp⟩
  match vs, hval with
  | [], _ => exact ⟨[], by simp [lines, Pretty.splitLF], by simp [LinesOf]⟩
  | [v], hval =>
    obtain ⟨hv, hn⟩ := hval v (by simp)
    refine ⟨[line sp v], ?_, by simpa [LinesOf] using (parse_correct L _ _).mpr (file_single hv)⟩
    simpa [lines, Pretty.splitLF] using Pretty.splitLF_line hn []
  | v :: w :: ws, hval =>
    refine ⟨(v :: w :: ws).map fun x => line sp x ++ [','], ?_, by simp, fun p hp => ?_⟩
    · have := Pretty.splitLF_lines [] (ls := (v :: w :: ws).map fun x => line sp x ++ [','])
        (by
          simp only [List.mem_map]
          rintro l ⟨x, hx, rfl⟩
          simpa using And.intro (hval x hx).2 (by decide : '\n' ∉ [',']))
      simpa [lines, List.flatMap_map, Pretty.splitLF] using this
    · obtain ⟨he, hm⟩ := mem_zip_map hp
      rw [he]; exact (parse_correct L _ _).mpr (file_comma (hval _ hm).1)

/-- **L3. A compact stream splits by lines,** one value per line, each line parsing to its value. -/
theorem compactAll_split {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    ∃ ls, Pretty.splitLF (compactAll vs) = ls ++ [[]] ∧ LinesOf L ls vs :=
  lines_split _ Spacing.spaced_blank h

/-- **L3. A minimised stream splits by lines,** one value per line, each line parsing to its value. -/
theorem minimisedAll_split {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    ∃ ls, Pretty.splitLF (minimisedAll vs) = ls ++ [[]] ∧ LinesOf L ls vs :=
  lines_split _ Spacing.tight_blank h

end Haus.Layout
