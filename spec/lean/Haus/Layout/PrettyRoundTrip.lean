import Haus.Layout.Pretty
import Haus.Layout.CompactRoundTrip

/-!
# The pretty layout parses back (L5)

For every value the grammar derives within the limits `L`, its pretty
layout (without comments) is derived too, with the same value, at every
indent of spaces and tabs, with any number of columns taken, and for any
options: the width only decides whether a positional payload stays on its
line, and both choices parse back. By induction on the derivation, like the
canonical form's round trip; strings with a line feed are block strings,
which parse back by L4 (`Pretty.blockString_val`), and a payload that stays
on its line is its compact layout, which parses back by L3 (`Val.line`).

* `parse_pretty`: for every value a parser returns, its pretty layout parses
  back to exactly that value;
* `parse_prettyAll`: a parsed file or stream in the pretty layout parses
  back to the same values, in the same order.
-/

namespace Haus.Layout
open Haus Grammar Canonical RoundTrip

variable {L : Limits}

/-- Spaces and tabs only. -/
def Blank (w : Text) : Prop := ∀ c ∈ w, isBlank c = true

theorem deeper_blank (o : Options) {ind : Text} (h : Blank ind) : Blank (deeper o ind) := by
  intro c hc
  simp only [deeper, List.mem_append, List.mem_replicate] at hc
  rcases hc with hc | ⟨_, rfl⟩
  · exact h c hc
  · rfl

/-- A line break and an indent are whitespace. -/
theorem ws_nl {w : Text} (h : Blank w) : WS ('\n' :: w) := by
  simpa using WS.newline ['\n'] w .lf (ws_blanks h)

/-- The pretty layout of a value, at every indent and with any columns taken, is derived with the value. -/
def PrettyOk (L : Limits) (n : Nat) (o : Options) (v : Value) : Prop :=
  ∀ ind, Blank ind → ∀ used, Val L n (pretty o ind used v) v

/-- A field: its key, and its value's pretty layout. -/
def FieldPrettyOk (L : Limits) (n : Nat) (o : Options) (kv : String × Value) : Prop :=
  Key L (Canonical.key kv.1) kv.1 ∧ PrettyOk L n o kv.2

/-! ## Building the layout from its parts -/

section
variable {n : Nat} (o : Options) {ind ind' : Text} (hind : Blank ind) (hind' : Blank ind')
include hind hind'

/-- Items one per line at `ind'`, each followed by `,`, then the closing indent `ind`. -/
theorem itemsFrom_pretty : ∀ (x : Value) (xs : List Value), (∀ y ∈ x :: xs, PrettyOk L n o y) →
    ItemsFrom L n (pretty o ind' (ind'.length + 1) x ++ ',' :: '\n' :: prettyItems o ind' xs ++ ind) (x :: xs)
  | x, [], h => by
    simpa [prettyItems] using
      ItemsFrom.lastComma n _ [] ('\n' :: ind) x (h x (by simp) ind' hind' _) .nil (ws_nl hind)
  | x, y :: ys, h => by
    have := ItemsFrom.cons n _ [] ('\n' :: ind') _ x (y :: ys) (h x (by simp) ind' hind' (ind'.length + 1)) .nil
      (ws_nl hind')
      (itemsFrom_pretty y ys fun z hz => h z (by simp_all))
    simpa [prettyItems] using this

omit hind in
theorem field_pretty {kv : String × Value} (h : FieldPrettyOk L n o kv) :
    Field L n (Canonical.key kv.1 ++ ':' :: ' ' :: pretty o ind' (ind'.length + (Canonical.key kv.1).length + 3) kv.2)
      kv := by
  simpa using Field.mk n _ [] [' '] _ kv.1 kv.2 h.1 .nil (ws_blanks (by decide))
    (h.2 ind' hind' (ind'.length + (Canonical.key kv.1).length + 3))

/-- Fields one per line at `ind'`, each followed by `,`, then the closing indent `ind`. -/
theorem fieldsFrom_pretty : ∀ (f : String × Value) (fs : List (String × Value)), (∀ g ∈ f :: fs, FieldPrettyOk L n o g) →
    FieldsFrom L n (Canonical.key f.1 ++ ':' :: ' ' :: pretty o ind' (ind'.length + (Canonical.key f.1).length + 3) f.2 ++
      ',' :: '\n' :: prettyFields o ind' fs ++ ind) (f :: fs)
  | f, [], h => by
    simpa [prettyFields] using
      FieldsFrom.lastComma n _ [] ('\n' :: ind) f (field_pretty o hind' (h f (by simp))) .nil (ws_nl hind)
  | f, g :: gs, h => by
    have := FieldsFrom.cons n _ [] ('\n' :: ind') _ f (g :: gs) (field_pretty o hind' (h f (by simp))) .nil
      (ws_nl hind') (fieldsFrom_pretty g gs fun z hz => h z (by simp_all))
    simpa [prettyFields] using this
end

theorem block_items {n : Nat} (o : Options) {ind : Text} (hind : Blank ind) (op cl : Char) :
    ∀ xs : List Value, (∀ y ∈ xs, PrettyOk L n o y) →
      ∃ inner, block ind op cl xs (prettyItems o (deeper o ind) xs) = op :: inner ++ [cl] ∧ Items L n inner xs
  | [], _ => ⟨[], by simp [block], .empty n [] .nil⟩
  | x :: xs, h => by
    have hd := deeper_blank o hind
    refine ⟨'\n' :: deeper o ind ++ (pretty o (deeper o ind) ((deeper o ind).length + 1) x ++ ',' :: '\n' ::
      prettyItems o (deeper o ind) xs ++ ind), by simp [block, prettyItems], ?_⟩
    simpa using Items.some n _ _ _ (ws_nl hd) (itemsFrom_pretty o hind hd x xs h)

theorem block_fields {n : Nat} (o : Options) {ind : Text} (hind : Blank ind) :
    ∀ fs : List (String × Value), (∀ g ∈ fs, FieldPrettyOk L n o g) →
      ∃ inner, block ind '{' '}' fs (prettyFields o (deeper o ind) fs) = '{' :: inner ++ ['}'] ∧ Fields L n inner fs
  | [], _ => ⟨[], by simp [block], .empty n [] .nil⟩
  | f :: fs, h => by
    have hd := deeper_blank o hind
    refine ⟨'\n' :: deeper o ind ++ (Canonical.key f.1 ++ ':' :: ' ' ::
      pretty o (deeper o ind) ((deeper o ind).length + (Canonical.key f.1).length + 3) f.2 ++
      ',' :: '\n' :: prettyFields o (deeper o ind) fs ++ ind), by simp [block, prettyFields], ?_⟩
    simpa using Fields.some n _ _ _ (ws_nl hd) (fieldsFrom_pretty o hind hd f fs h)

theorem pretty_record (o : Options) (ind : Text) (used : Nat) (fs : List (String × Value)) :
    pretty o ind used (.record fs) = block ind '{' '}' fs (prettyFields o (deeper o ind) fs) := by
  simp [pretty]

/-! ## The induction -/

mutual
theorem _root_.Haus.Grammar.Val.pretty (o : Options) {n : Nat} {t : Text} {v : Value} :
    Val L n t v → PrettyOk L n o v
  | .number _ t hn => fun _ _ _ => by simpa [Layout.pretty] using number_canonical hn n
  | .string _ t s hs => fun ind hind _ => by
    cases hs with
    | mk raw s' _ hl =>
      have hl' : (String.ofList s').length ≤ L.maxStringLength := by simpa using hl
      simp only [Layout.pretty]
      split
      · exact Pretty.blockString_val (deeper_blank o hind) hl' n
      · exact string_canonical _ hl' n
  | .blockString _ t s hs => fun ind hind _ => by
    cases hs with
    | mk _ _ _ _ ss _ _ _ _ _ hl =>
      simp only [Layout.pretty]
      split
      · exact Pretty.blockString_val (deeper_blank o hind) hl n
      · exact string_canonical _ hl n
  | .bytes _ raw bs hb hl => fun _ _ _ => by simpa [Layout.pretty] using bytes_canonical hb hl n
  | .array m inner xs hi => fun ind hind _ => by
    obtain ⟨inner', he, hi'⟩ := block_items o hind '[' ']' xs (hi.pretty o)
    simp only [Layout.pretty, he]
    exact .array m _ _ hi'
  | .record m t fs hr => fun ind hind _ => by
    rw [pretty_record]; exact .record m _ _ (hr.pretty o ind hind)
  | .tag _ t ht hl => fun _ _ _ => by simpa [Layout.pretty] using Val.tag n t ht hl
  | .payload m t sp inner xs ht hl hsp hi hxs => fun ind hind used => by
    have hall := hi.pretty o
    rcases xs with _ | ⟨x, xs⟩
    · exact absurd rfl hxs
    rcases positional_shape x xs with ⟨fs, rfl, rfl⟩ | hp
    · -- `Tag({…})` is written `Tag {…}`, one level less deep
      have hv := hall (.record fs) (by simp) ind hind 0
      rw [pretty_record] at hv
      obtain ⟨k, rfl, hr⟩ := val_record hv
      have := Val.recordPayload (k + 1) t [' '] _ _ ht hl (by decide) (hr.mono (k + 1) (by omega))
      simpa [Layout.pretty] using this
    · rw [pretty.eq_8 o ind used _ x xs hp]
      split
      · -- on its line: the compact layout (L3)
        simpa [compact] using (Val.payload m t sp inner _ ht hl hsp hi hxs).line .spaced Spacing.spaced_blank
      · obtain ⟨inner', he, hi'⟩ := block_items o hind '(' ')' (x :: xs) hall
        rw [he]
        simpa using Val.payload m t [] inner' _ ht hl (by simp) hi' hxs
  | .recordPayload m t sp r fs ht hl hsp hr => fun ind hind _ => by
    simpa [Layout.pretty] using Val.recordPayload m t [' '] _ _ ht hl (by decide) (hr.pretty o ind hind)

theorem _root_.Haus.Grammar.Items.pretty (o : Options) {n : Nat} {t : Text} {xs : List Value} :
    Items L n t xs → ∀ x ∈ xs, PrettyOk L n o x
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hi => hi.pretty o

theorem _root_.Haus.Grammar.ItemsFrom.pretty (o : Options) {n : Nat} {t : Text} {xs : List Value} :
    ItemsFrom L n t xs → ∀ x ∈ xs, PrettyOk L n o x
  | .last _ _ _ _ hv _ => List.forall_mem_singleton.mpr (hv.pretty o)
  | .lastComma _ _ _ _ _ hv _ _ => List.forall_mem_singleton.mpr (hv.pretty o)
  | .cons _ _ _ _ _ _ _ hv _ _ hi => List.forall_mem_cons.mpr ⟨hv.pretty o, hi.pretty o⟩

theorem _root_.Haus.Grammar.Record.pretty (o : Options) {n : Nat} {t : Text} {fs : List (String × Value)} :
    Record L n t fs → ∀ ind, Blank ind → Record L n (block ind '{' '}' fs (prettyFields o (deeper o ind) fs)) fs
  | .mk _ _ fs hf hnd, ind, hind => by
    obtain ⟨inner, he, hf'⟩ := block_fields o hind fs (hf.pretty o)
    rw [he]; exact .mk n _ _ hf' hnd

theorem _root_.Haus.Grammar.Fields.pretty (o : Options) {n : Nat} {t : Text} {fs : List (String × Value)} :
    Fields L n t fs → ∀ g ∈ fs, FieldPrettyOk L n o g
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hf => hf.pretty o

theorem _root_.Haus.Grammar.FieldsFrom.pretty (o : Options) {n : Nat} {t : Text} {fs : List (String × Value)} :
    FieldsFrom L n t fs → ∀ g ∈ fs, FieldPrettyOk L n o g
  | .last _ _ _ _ hf _ => List.forall_mem_singleton.mpr (hf.pretty o)
  | .lastComma _ _ _ _ _ hf _ _ => List.forall_mem_singleton.mpr (hf.pretty o)
  | .cons _ _ _ _ _ _ _ hf _ _ hi => List.forall_mem_cons.mpr ⟨hf.pretty o, hi.pretty o⟩

theorem _root_.Haus.Grammar.Field.pretty (o : Options) {n : Nat} {t : Text} {f : String × Value} :
    Field L n t f → FieldPrettyOk L n o f
  | .mk _ _ _ _ _ _ _ hk _ _ hv => ⟨key_canonical hk, hv.pretty o⟩
end

/-! ## Files and streams -/

theorem blank_nil' : Blank [] := by simp [Blank]

theorem fileItems_prettyStream (o : Options) :
    ∀ (v : Value) (vs : List Value), (∀ x ∈ v :: vs, PrettyOk L L.maxDepth o x) →
      FileItems L (prettyStream o (v :: vs)) (v :: vs)
  | v, [], h => by
    simpa [prettyStream] using FileItems.lastComma _ [] ['\n'] v (h v (by simp) [] blank_nil' 1) .nil wsEnd_lf
  | v, w :: ws, h => by
    have hsep : WS ('\n' :: (if (pretty o [] 1 v).contains '\n' && !(w :: ws).isEmpty then ['\n'] else [])) := by
      split
      · simpa using WS.newline ['\n'] ['\n'] .lf (by simpa using WS.newline ['\n'] [] .lf .nil)
      · exact ws_nl blank_nil'
    have := FileItems.cons _ [] _ _ v (w :: ws) (h v (by simp) [] blank_nil' 1) .nil hsep
      (fileItems_prettyStream o w ws fun x hx => h x (by simp_all))
    simpa [prettyStream] using this

/-- Values in the pretty layout are a file with exactly those values. -/
theorem file_prettyAll (o : Options) : ∀ {vs : List Value}, (∀ v ∈ vs, PrettyOk L L.maxDepth o v) →
    File L (prettyAll o vs) vs
  | [], _ => by simpa [prettyAll] using File.empty (L := L) [] [] (.inl rfl) (.ws [] .nil)
  | [v], h => by
    simpa [prettyAll] using
      File.values [] [] _ _ (.inl rfl) .nil (FileItems.last _ ['\n'] v (h v (by simp) [] blank_nil' 0) wsEnd_lf)
  | v :: w :: ws, h => by
    simpa [prettyAll] using File.values [] [] _ _ (.inl rfl) .nil (fileItems_prettyStream o v (w :: ws) h)

/--
**L5. The pretty layout of a parsed value parses back to it,** fields in the
same order, at every indent of spaces and tabs, with any columns taken, for
any options.
-/
theorem parse_pretty (o : Options) {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {ind : Text} (hind : Blank ind) (used : Nat) :
    Parser.parse L (pretty o ind used v) = .ok [v] := by
  obtain ⟨s, hs⟩ := File.vals ((parse_correct L input vs).mp h) v hv
  exact (parse_correct L _ _).mpr (file_single (hs.pretty o ind hind used))

/-- **L5. A parsed file or stream in the pretty layout parses back** to the same values, in order. -/
theorem parse_prettyAll (o : Options) {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    Parser.parse L (prettyAll o vs) = .ok vs := by
  have hvs := File.vals ((parse_correct L input vs).mp h)
  exact (parse_correct L _ _).mpr (file_prettyAll o fun v hv => by
    obtain ⟨s, hs⟩ := hvs v hv; exact hs.pretty o)

end Haus.Layout
