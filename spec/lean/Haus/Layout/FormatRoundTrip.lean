import Haus.Layout.Format
import Haus.Layout.CompactRoundTrip
import Haus.Sound.Values

/-!
# The formatter keeps the values: compact and minimised (spec §11)

`format L .compact o input` and `format L .minimised o input`, when they
give a text, give one that parses to exactly the values of the input, in
the same order (`parse_format_compact`, `parse_format_minimised`): keys,
numbers, strings and byte strings as spelled in the input (§11: spellings
kept), comments dropped.

The proof is the compact round trip of values (`Haus.Layout.CompactRoundTrip`)
with the tree's leaves in place of the canonical ones: by induction on the
grammar's derivation of each value of the input (which holds the limits:
nesting, unique keys, tags), the line of the tree is derived too. A leaf's
spelling is derived for its value because `read` checked it (`Node.ok`: the
spelling read again alone by the parser's reader for its kind), and the
reader for it is sound (`Haus.Sound`); a `"…"` string with a raw U+2028 or
U+2029, written with them escaped (`escapeSeps`), is still that string.
-/

namespace Haus.Format
open Haus Grammar Layout RoundTrip Parser Sound

variable {L : Limits}

/-! ## Equality -/

mutual
theorem valueEq_sound : ∀ (a b : Value), valueEq a b = true → a = b
  | .num x, b, h => by cases b <;> simp_all [valueEq]
  | .str x, b, h => by cases b <;> simp_all [valueEq]
  | .bytes x, b, h => by cases b <;> simp_all [valueEq]
  | .arr xs, b, h => by
    cases b with
    | arr ys => rw [valuesEq_sound xs ys (by simpa [valueEq] using h)]
    | _ => simp [valueEq] at h
  | .record fs, b, h => by
    cases b with
    | record gs => rw [fieldsEq_sound fs gs (by simpa [valueEq] using h)]
    | _ => simp [valueEq] at h
  | .variant t xs, b, h => by
    cases b with
    | variant u ys =>
      simp only [valueEq, Bool.and_eq_true, beq_iff_eq] at h
      rw [h.1, valuesEq_sound xs ys h.2]
    | _ => simp [valueEq] at h

theorem valuesEq_sound : ∀ (xs ys : List Value), valuesEq xs ys = true → xs = ys
  | [], ys, h => by cases ys <;> simp_all [valuesEq]
  | x :: xs, ys, h => by
    cases ys with
    | nil => simp [valuesEq] at h
    | cons y ys =>
      simp only [valuesEq, Bool.and_eq_true] at h
      rw [valueEq_sound x y h.1, valuesEq_sound xs ys h.2]

theorem fieldsEq_sound : ∀ (fs gs : List (String × Value)), fieldsEq fs gs = true → fs = gs
  | [], gs, h => by cases gs <;> simp_all [fieldsEq]
  | (k, x) :: fs, gs, h => by
    cases gs with
    | nil => simp [fieldsEq] at h
    | cons g gs =>
      obtain ⟨l, y⟩ := g
      simp only [fieldsEq, Bool.and_eq_true, beq_iff_eq] at h
      rw [h.1.1, valueEq_sound x y h.1.2, fieldsEq_sound fs gs h.2]
end

/-! ## Leaves -/

theorem run_map_ok {α β : Type} {f : α → β} {p : P α} {s r : Text} {v : β} (h : (f <$> p).run s = .ok (v, r)) :
    ∃ a, p.run s = .ok (a, r) ∧ v = f a := by
  rw [run_map] at h
  cases hp : p.run s with
  | error e => simp [hp, Except.map] at h
  | ok ar =>
    obtain ⟨a, r'⟩ := ar
    simp only [hp, Except.map, Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨a, rfl, rfl⟩

theorem readsAs_ok {p : P Value} {s : Text} {v : Value} (h : readsAs p s v = true) : p.run s = .ok (v, []) := by
  unfold readsAs at h
  split at h
  · rename_i w heq; rw [heq, valueEq_sound w v h]
  · simp at h

/-- No character of an escape is a line or paragraph separator: they are ASCII. -/
theorem escape_noSep {e : Text} {c : Char} (h : Escape e c) : ∀ x ∈ e, isLineSep x = false := by
  cases h with
  | unicode ds _ _ hds _ =>
    intro x hx
    simp only [List.mem_append, List.mem_cons, List.mem_nil_iff, or_false] at hx
    rcases hx with ((rfl | rfl | rfl) | hx) | rfl
    · decide
    · decide
    · decide
    · have hx := hds x hx
      have hle : x.toNat ≤ 102 := by
        simp only [isHexDigit, isDigit, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hx
        rcases hx with (⟨-, h⟩ | ⟨-, h⟩) | ⟨-, h⟩ <;>
          (have := Char.le_def.mp h; simp [UInt32.le_iff_toNat_le] at this; omega)
      simp only [isLineSep, Bool.and_eq_false_iff, decide_eq_false_iff_not]
      omega
    · decide
  | _ => decide

theorem escapeSeps_append (a b : Text) : escapeSeps (a ++ b) = escapeSeps a ++ escapeSeps b := by
  simp [escapeSeps]

theorem escapeSeps_id {t : Text} (h : ∀ x ∈ t, isLineSep x = false) : escapeSeps t = t := by
  induction t with
  | nil => rfl
  | cons c t ih =>
    simp only [escapeSeps, List.flatMap_cons] at ih ⊢
    rw [ih fun x hx => h x (by simp [hx]), ite_eq_right_iff.mpr (by simp [h c (by simp)])]
    rfl

/-- Escaping the separators of a `"…"` string's text keeps what it denotes. -/
theorem chars_escapeSeps {raw s : Text} (h : Chars BasicChar raw s) : Chars BasicChar (escapeSeps raw) s := by
  induction h with
  | nil => exact .nil
  | char c raw s hc _ ih =>
    rw [show c :: raw = [c] ++ raw from rfl, escapeSeps_append]
    by_cases hsep : isLineSep c = true
    · simpa [escapeSeps, hsep] using Chars.escape _ c _ _ (Pretty.unicode_escape c) ih
    · simpa [escapeSeps, hsep] using Chars.char c _ _ hc ih
  | escape e c raw s he _ ih =>
    rw [escapeSeps_append, escapeSeps_id (escape_noSep he)]
    exact .escape e c _ _ he ih

theorem basicString_escapeSeps {s : Text} {x : String} (h : BasicString L s x) : BasicString L (escapeSeps s) x := by
  cases h with
  | mk raw s' hc hl =>
    have : escapeSeps ('"' :: raw ++ ['"']) = '"' :: escapeSeps raw ++ ['"'] := by
      simp [escapeSeps, isLineSep]
    rw [this]
    exact .mk _ _ (chars_escapeSeps hc) hl

/-- A `"…"` string doesn't start with three quotes. -/
theorem basicString_take3 {s : Text} {x : String} (h : BasicString L s x) : s.take 3 ≠ ['"', '"', '"'] := by
  cases h with
  | mk raw s' hc _ =>
    cases hc with
    | nil => simp
    | char c raw s hc' _ =>
      intro h
      simp only [List.cons_append, List.take_succ_cons, List.cons.injEq] at h
      exact hc'.1 h.2.1
    | escape e c raw s he _ =>
      cases he <;> simp

/-- **A leaf as `read` checked it is derived for its value**, on one line, at any depth. -/
theorem leafOk_val {s : Text} {v : Value} (h : leafOk L s v = true) (n : Nat) : Val L n (leafLine s v) v := by
  cases v with
  | num x =>
    obtain ⟨lit, hs, hn, hv⟩ := number_sound L s [] _ (readsAs_ok h)
    simp only [List.append_nil] at hs; subst hs
    rw [hv]; exact .number n _ hn
  | str x =>
    simp only [leafOk] at h
    split at h
    · rename_i t0
      obtain ⟨y, heq, hv⟩ := run_map_ok (readsAs_ok h)
      injection hv with hv; subst hv
      obtain ⟨raw, hs, hb⟩ := blockString_sound L t0 [] _ heq
      have : leafLine ('"' :: '"' :: '"' :: t0) (.str x) = Canonical.string x := by
        simp [leafLine, basic]
      rw [this]
      cases hb with
      | mk _ _ _ _ ss _ _ _ _ _ hl => exact string_canonical _ hl n
    · rename_i t0 hnot
      obtain ⟨y, heq, hv⟩ := run_map_ok (readsAs_ok h)
      injection hv with hv; subst hv
      obtain ⟨raw, hs, hb⟩ := basicString_sound L t0 [] _ heq
      simp only [List.append_nil] at hs
      rw [← hs] at hb
      have : leafLine ('"' :: t0) (.str x) = escapeSeps ('"' :: t0) := by
        simp only [leafLine, basic, basicString_take3 hb, ite_false]
      rw [this]
      exact .string n _ _ (basicString_escapeSeps hb)
    · simp at h
  | bytes bs =>
    simp only [leafOk] at h
    split at h
    · rename_i t0
      obtain ⟨raw, bs', hs, hb, hl, hv⟩ := bytes_sound L t0 [] _ (readsAs_ok h)
      simp only [List.append_nil] at hs
      rw [hs, hv]
      simpa [leafLine] using Val.bytes n raw bs' hb hl
    · simp at h
  | _ => simp [leafOk] at h

/-! ## The parts of the tree -/

def Item.node : Item → Node
  | .mk v _ => v

def Field.key : Field → String
  | .mk k _ _ _ _ => k

def Field.node : Field → Node
  | .mk _ _ _ v _ => v

@[simp] theorem Item.node_mk (v : Node) (g : Gap) : (Item.mk v g).node = v := rfl
@[simp] theorem Field.key_mk (k : String) (g₁ g₂ : Gap) (v : Node) (g : Gap) : (Field.mk k g₁ g₂ v g).key = k := rfl
@[simp] theorem Field.node_mk (k : String) (g₁ g₂ : Gap) (v : Node) (g : Gap) : (Field.mk k g₁ g₂ v g).node = v := rfl

theorem Item.values_eq : ∀ xs : List Item, Item.values xs = xs.map fun x => x.node.value
  | [] => rfl
  | .mk _ _ :: xs => by simp [Item.values, Item.values_eq xs, Item.node]

theorem Field.values_eq : ∀ fs : List Field, Field.values fs = fs.map fun f => (f.key, f.node.value)
  | [] => rfl
  | .mk _ _ _ _ _ :: fs => by simp [Field.values, Field.values_eq fs, Field.key, Field.node]

theorem Item.ok_mem {xs : List Item} (h : Item.ok L xs = true) : ∀ x ∈ xs, x.node.ok L = true := by
  induction xs with
  | nil => simp
  | cons x xs ih =>
    obtain ⟨v, g⟩ := x
    simp only [Item.ok, Bool.and_eq_true] at h
    simp only [List.mem_cons, forall_eq_or_imp]
    exact ⟨h.1, ih h.2⟩

theorem Field.ok_mem {fs : List Field} (h : Field.ok L fs = true) : ∀ f ∈ fs, f.node.ok L = true := by
  induction fs with
  | nil => simp
  | cons f fs ih =>
    obtain ⟨k, g₁, g₂, v, g⟩ := f
    simp only [Field.ok, Bool.and_eq_true] at h
    simp only [List.mem_cons, forall_eq_or_imp]
    exact ⟨h.1, ih h.2⟩

theorem Item.sizeOf_node {x : Item} {xs : List Item} (h : x ∈ xs) : sizeOf x.node < sizeOf xs := by
  have := List.sizeOf_lt_of_mem h
  obtain ⟨v, g⟩ := x
  simp only [Item.node, Item.mk.sizeOf_spec] at this ⊢
  omega

theorem Field.sizeOf_node {f : Field} {fs : List Field} (h : f ∈ fs) : sizeOf f.node < sizeOf fs := by
  have := List.sizeOf_lt_of_mem h
  obtain ⟨k, g₁, g₂, v, g⟩ := f
  simp only [Field.node, Field.mk.sizeOf_spec] at this ⊢
  omega

/-! ## Derivations of the parts -/

theorem _root_.Haus.Grammar.ItemsFrom.vals {n : Nat} {t : Text} {xs : List Value} :
    ItemsFrom L n t xs → ∀ x ∈ xs, ∃ s, Val L n s x
  | .last _ _ _ _ hv _ => List.forall_mem_singleton.mpr ⟨_, hv⟩
  | .lastComma _ _ _ _ _ hv _ _ => List.forall_mem_singleton.mpr ⟨_, hv⟩
  | .cons _ _ _ _ _ _ _ hv _ _ hi => List.forall_mem_cons.mpr ⟨⟨_, hv⟩, hi.vals⟩

theorem _root_.Haus.Grammar.Items.vals {n : Nat} {t : Text} {xs : List Value} :
    Items L n t xs → ∀ x ∈ xs, ∃ s, Val L n s x
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hi => hi.vals

/-- A field's key, derived as a key, and a derivation of its value. -/
def FieldDerived (L : Limits) (n : Nat) (kv : String × Value) : Prop :=
  (∃ k, Key L k kv.1) ∧ ∃ s, Val L n s kv.2

theorem _root_.Haus.Grammar.Field.derived {n : Nat} {t : Text} {f : String × Value} :
    Grammar.Field L n t f → FieldDerived L n f
  | .mk _ _ _ _ _ _ _ hk _ _ hv => ⟨⟨_, hk⟩, ⟨_, hv⟩⟩

theorem _root_.Haus.Grammar.FieldsFrom.derived {n : Nat} {t : Text} {fs : List (String × Value)} :
    FieldsFrom L n t fs → ∀ g ∈ fs, FieldDerived L n g
  | .last _ _ _ _ hf _ => List.forall_mem_singleton.mpr hf.derived
  | .lastComma _ _ _ _ _ hf _ _ => List.forall_mem_singleton.mpr hf.derived
  | .cons _ _ _ _ _ _ _ hf _ _ hi => List.forall_mem_cons.mpr ⟨hf.derived, hi.derived⟩

theorem _root_.Haus.Grammar.Fields.derived {n : Nat} {t : Text} {fs : List (String × Value)} :
    Fields L n t fs → ∀ g ∈ fs, FieldDerived L n g
  | .empty _ _ _ => by simp
  | .some _ _ _ _ _ hf => hf.derived

/-! ## Building the line from its parts -/

section
variable (sp : Spacing) (hsp : sp.Blank)
include hsp

theorem itemsFrom_build {n : Nat} : ∀ (x : Item) (xs : List Item),
    (∀ y ∈ x :: xs, Val L n (line sp y.node) y.node.value) →
    ItemsFrom L n (lineItems sp (x :: xs)) (Item.values (x :: xs))
  | .mk v g, [], h => by
    simpa [lineItems, Item.values] using ItemsFrom.last n (line sp v) [] _ (h (.mk v g) (by simp)) .nil
  | .mk v g, y :: ys, h => by
    have := ItemsFrom.cons n (line sp v) [] sp.comma _ _ _ (h (.mk v g) (by simp)) .nil (ws_blanks hsp.1)
      (itemsFrom_build y ys fun z hz => h z (by simp_all))
    simpa [lineItems, Item.values] using this

theorem items_build {n : Nat} : ∀ xs : List Item, (∀ y ∈ xs, Val L n (line sp y.node) y.node.value) →
    Items L n (lineItems sp xs) (Item.values xs)
  | [], _ => by simpa [lineItems, Item.values] using Items.empty (L := L) n [] .nil
  | x :: xs, h => by simpa using Items.some n [] _ _ .nil (itemsFrom_build sp hsp x xs h)

/-- A field `key: value` of the line, by its parts. -/
def FieldLine (L : Limits) (n : Nat) (sp : Spacing) (f : Field) : Prop :=
  Key L (Canonical.key f.key) f.key ∧ Val L n (line sp f.node) f.node.value

theorem fieldsFrom_build {n : Nat} : ∀ (f : Field) (fs : List Field) {e : Text}, WS e →
    (∀ g ∈ f :: fs, FieldLine L n sp g) → FieldsFrom L n (lineFields sp (f :: fs) ++ e) (Field.values (f :: fs))
  | .mk k g₁ g₂ v g, [], e, he, h => by
    obtain ⟨hk, hv⟩ := h (.mk k g₁ g₂ v g) (by simp)
    have := FieldsFrom.last n _ e (k, v.value)
      (Grammar.Field.mk n _ [] sp.colon _ k v.value hk .nil (ws_blanks hsp.2.1) hv) he
    simpa [lineFields, Field.values] using this
  | .mk k g₁ g₂ v g, f :: fs, e, he, h => by
    obtain ⟨hk, hv⟩ := h (.mk k g₁ g₂ v g) (by simp)
    have := FieldsFrom.cons n _ [] sp.comma _ (k, v.value) _
      (Grammar.Field.mk n _ [] sp.colon _ k v.value hk .nil (ws_blanks hsp.2.1) hv) .nil (ws_blanks hsp.1)
      (fieldsFrom_build f fs he fun z hz => h z (by simp_all))
    simpa [lineFields, Field.values] using this

theorem record_build {n : Nat} (fs : List Field) (hnd : ((Field.values fs).map Prod.fst).Nodup)
    (h : ∀ g ∈ fs, FieldLine L n sp g) : Record L n (lineRecord sp fs) (Field.values fs) := by
  cases fs with
  | nil =>
    simpa [lineRecord, lineFields, Field.values] using Record.mk (L := L) n [] [] (Fields.empty n [] .nil) hnd
  | cons f fs =>
    have := Record.mk n _ _ (Fields.some n sp.inner _ _ (ws_blanks hsp.2.2.1)
      (fieldsFrom_build sp hsp f fs (ws_blanks hsp.2.2.1) h)) hnd
    simpa [lineRecord] using this

/--
A record's fields written on a line, given that each field's value, derived
at some depth, is derived on its line too (the induction hypothesis).
-/
theorem record_of_fields {m : Nat} {r : Text} (fs : List Field)
    (ih : ∀ f ∈ fs, ∀ {n : Nat} {t : Text}, Val L n t f.node.value → Val L n (line sp f.node) f.node.value)
    (hr : Record L m r (Field.values fs)) : Record L m (lineRecord sp fs) (Field.values fs) := by
  cases hr with
  | mk _ inner _ hf hnd =>
    refine record_build sp hsp fs hnd fun f hf' => ?_
    have hmem : (f.key, f.node.value) ∈ Field.values fs := by
      rw [Field.values_eq]; exact List.mem_map.mpr ⟨f, hf', rfl⟩
    obtain ⟨⟨k, hk⟩, ⟨s, hv⟩⟩ := hf.derived _ hmem
    exact ⟨key_canonical hk, ih f hf' hv⟩

theorem items_of_items {m : Nat} {r : Text} (xs : List Item)
    (ih : ∀ x ∈ xs, ∀ {n : Nat} {t : Text}, Val L n t x.node.value → Val L n (line sp x.node) x.node.value)
    (hi : Items L m r (Item.values xs)) : Items L m (lineItems sp xs) (Item.values xs) := by
  refine items_build sp hsp xs fun x hx => ?_
  have hmem : x.node.value ∈ Item.values xs := by
    rw [Item.values_eq]; exact List.mem_map.mpr ⟨x, hx, rfl⟩
  obtain ⟨s, hv⟩ := hi.vals _ hmem
  exact ih x hx hv

end

/-! ## The induction -/

theorem val_record' {n : Nat} {t : Text} {fs : List (String × Value)} (h : Val L n t (.record fs)) :
    ∃ m, n = m + 1 ∧ Record L m t fs := by
  cases h with
  | record m _ _ hr => exact ⟨m, rfl, hr⟩

/-- **The line of a tree is derived for its value** wherever the value is (at the same depth). -/
theorem Node.line_val (sp : Spacing) (hsp : sp.Blank) :
    ∀ (node : Node), node.ok L = true → ∀ {n : Nat} {t : Text}, Val L n t node.value → Val L n (line sp node) node.value
  | .leaf s v, hok, n, _, _ => by simpa [line, Node.value] using leafOk_val hok n
  | .bare tag, _, n, t, hv => by
    generalize hw : (Node.bare tag).value = w at hv
    cases hv with
    | tag _ t' ht hl =>
      simp only [Node.value, Value.variant.injEq] at hw
      obtain ⟨rfl, -⟩ := hw
      simpa [line, Node.value] using Val.tag n _ ht hl
    | payload _ _ _ _ _ _ _ _ _ hxs =>
      simp only [Node.value, Value.variant.injEq] at hw
      exact absurd hw.2.symm hxs
    | recordPayload => simp [Node.value] at hw
    | _ => simp [Node.value] at hw
  | .arr g xs, hok, n, t, hv => by
    have ih : ∀ x ∈ xs, ∀ {n : Nat} {t : Text}, Val L n t x.node.value → Val L n (line sp x.node) x.node.value :=
      fun x hx _ _ h =>
        have : sizeOf x.node < sizeOf (Node.arr g xs) := by have := Item.sizeOf_node hx; simp only [Node.arr.sizeOf_spec]; omega
        Node.line_val sp hsp x.node (Item.ok_mem hok x hx) h
    generalize hw : (Node.arr g xs).value = w at hv
    cases hv with
    | array m inner ys hi =>
      simp only [Node.value, Value.arr.injEq] at hw
      subst hw
      simpa [line, Node.value] using Val.array m _ _ (items_of_items sp hsp xs ih hi)
    | _ => simp [Node.value] at hw
  | .record g fs, hok, n, t, hv => by
    have ih : ∀ f ∈ fs, ∀ {n : Nat} {t : Text}, Val L n t f.node.value → Val L n (line sp f.node) f.node.value :=
      fun f hf _ _ h =>
        have : sizeOf f.node < sizeOf (Node.record g fs) := by have := Field.sizeOf_node hf; simp only [Node.record.sizeOf_spec]; omega
        Node.line_val sp hsp f.node (Field.ok_mem hok f hf) h
    generalize hw : (Node.record g fs).value = w at hv
    cases hv with
    | record m r gs hr =>
      simp only [Node.value, Value.record.injEq] at hw
      subst hw
      simpa [line, Node.value] using Val.record m _ _ (record_of_fields sp hsp fs ih hr)
    | _ => simp [Node.value] at hw
  | .braces tag g fs, hok, n, t, hv => by
    have ih : ∀ f ∈ fs, ∀ {n : Nat} {t : Text}, Val L n t f.node.value → Val L n (line sp f.node) f.node.value :=
      fun f hf _ _ h =>
        have : sizeOf f.node < sizeOf (Node.braces tag g fs) := by have := Field.sizeOf_node hf; simp only [Node.braces.sizeOf_spec]; omega
        Node.line_val sp hsp f.node (Field.ok_mem hok f hf) h
    generalize hw : (Node.braces tag g fs).value = w at hv
    cases hv with
    | payload m t' sp' inner xs ht hl _ hi _ =>
      simp only [Node.value, Value.variant.injEq] at hw
      obtain ⟨rfl, rfl⟩ := hw
      obtain ⟨s, hs⟩ := hi.vals (.record (Field.values fs)) (by simp)
      obtain ⟨k, rfl, hr⟩ := val_record' hs
      have := Val.recordPayload (k + 1) t' sp.tag _ _ ht hl hsp.2.2.2
        ((record_of_fields sp hsp fs ih hr).mono (k + 1) (by omega))
      simpa [line, Node.value] using this
    | recordPayload m t' sp' r gs ht hl _ hr =>
      simp only [Node.value, Value.variant.injEq, List.cons.injEq, Value.record.injEq, and_true] at hw
      obtain ⟨rfl, rfl⟩ := hw
      simpa [line, Node.value] using
        Val.recordPayload m t' sp.tag _ _ ht hl hsp.2.2.2 (record_of_fields sp hsp fs ih hr)
    | _ => simp [Node.value] at hw
  | .args tag g xs, hok, n, t, hv => by
    have hok' : Item.ok L xs = true := by simp [Node.ok] at hok; exact hok.2
    have hne : xs ≠ [] := by simp [Node.ok] at hok; exact hok.1
    have ih : ∀ x ∈ xs, ∀ {n : Nat} {t : Text}, Val L n t x.node.value → Val L n (line sp x.node) x.node.value :=
      fun x hx _ _ h =>
        have : sizeOf x.node < sizeOf (Node.args tag g xs) := by have := Item.sizeOf_node hx; simp only [Node.args.sizeOf_spec]; omega
        Node.line_val sp hsp x.node (Item.ok_mem hok' x hx) h
    generalize hw : (Node.args tag g xs).value = w at hv
    by_cases hrec : ∃ g' fs after, xs = [.mk (.record g' fs) after]
    · -- `Tag({ … })` is written `Tag { … }`
      obtain ⟨g', fs, after, hxs⟩ := hrec
      have hokfs : Field.ok L fs = true := by subst hxs; simpa [Item.ok, Node.ok] using hok'
      have ihf : ∀ f ∈ fs, ∀ {n : Nat} {t : Text}, Val L n t f.node.value → Val L n (line sp f.node) f.node.value :=
        fun f hf _ _ h =>
          have : sizeOf f.node < sizeOf (Node.args tag g xs) := by
            have := Field.sizeOf_node hf
            subst hxs
            simp only [Node.args.sizeOf_spec, List.cons.sizeOf_spec, List.nil.sizeOf_spec, Item.mk.sizeOf_spec,
              Node.record.sizeOf_spec]
            omega
          Node.line_val sp hsp f.node (Field.ok_mem hokfs f hf) h
      subst hxs
      cases hv with
      | payload m t' sp' inner ys ht hl _ hi _ =>
        simp only [Node.value, Item.values, Value.variant.injEq] at hw
        obtain ⟨rfl, rfl⟩ := hw
        obtain ⟨s, hs⟩ := hi.vals (.record (Field.values fs)) (by simp)
        obtain ⟨k, rfl, hr⟩ := val_record' hs
        have := Val.recordPayload (k + 1) t' sp.tag _ _ ht hl hsp.2.2.2
          ((record_of_fields sp hsp fs ihf hr).mono (k + 1) (by omega))
        simpa [line, Node.value, Item.values] using this
      | recordPayload m t' sp' r gs ht hl _ hr =>
        simp only [Node.value, Item.values, Value.variant.injEq, List.cons.injEq, Value.record.injEq, and_true] at hw
        obtain ⟨rfl, rfl⟩ := hw
        simpa [line, Node.value, Item.values] using
          Val.recordPayload m t' sp.tag _ _ ht hl hsp.2.2.2 (record_of_fields sp hsp fs ihf hr)
      | _ => simp [Node.value, Item.values] at hw
    · have hline : line sp (.args tag g xs) = tag.toList ++ '(' :: lineItems sp xs ++ [')'] := by
        rcases xs with _ | ⟨⟨v, a⟩, _ | ⟨y, ys⟩⟩
        · exact absurd rfl hne
        · cases v with
          | record g' fs => exact absurd ⟨g', fs, a, rfl⟩ hrec
          | _ => simp [line]
        · simp [line]
      cases hv with
      | payload m t' sp' inner ys ht hl _ hi hys =>
        simp only [Node.value, Value.variant.injEq] at hw
        obtain ⟨rfl, rfl⟩ := hw
        rw [hline]
        simpa [Node.value] using Val.payload m t' [] _ _ ht hl (by simp) (items_of_items sp hsp xs ih hi) hys
      | recordPayload m t' sp' r gs ht hl _ hr =>
        simp only [Node.value, Value.variant.injEq] at hw
        obtain ⟨-, hvs⟩ := hw
        rcases xs with _ | ⟨⟨v, a⟩, _ | ⟨⟨w, b⟩, ys⟩⟩
        · simp [Item.values] at hvs
        · simp only [Item.values, List.cons.injEq, and_true] at hvs
          cases v with
          | record g' fs => exact absurd ⟨g', fs, a, rfl⟩ hrec
          | leaf s w =>
            simp only [Node.value] at hvs
            subst hvs
            simp [Item.ok, Node.ok, leafOk] at hok'
          | _ => simp [Node.value] at hvs
        · simp [Item.values] at hvs
      | tag _ _ _ _ =>
        simp only [Node.value, Value.variant.injEq] at hw
        rcases xs with _ | ⟨⟨v, a⟩, ys⟩
        · exact absurd rfl hne
        · simp [Item.values] at hw
      | _ => simp [Node.value] at hw
termination_by node => sizeOf node
decreasing_by
  all_goals
    simp only [Node.arr.sizeOf_spec, Node.record.sizeOf_spec, Node.braces.sizeOf_spec, Node.args.sizeOf_spec] at *
    omega

/-! ## Files -/

theorem fileItems_build (sp : Spacing) : ∀ (x : Item) (xs : List Item),
    (∀ y ∈ x :: xs, Val L L.maxDepth (line sp y.node) y.node.value) →
      FileItems L ((x :: xs).flatMap (streamLine sp)) (Item.values (x :: xs))
  | .mk v g, [], h => by
    simpa [Item.values, streamLine] using FileItems.lastComma _ [] ['\n'] _ (h (.mk v g) (by simp)) .nil wsEnd_lf
  | .mk v g, y :: ys, h => by
    have := FileItems.cons _ [] ['\n'] _ _ _ (h (.mk v g) (by simp)) .nil (by simpa using WS.newline ['\n'] [] .lf .nil)
      (fileItems_build sp y ys fun z hz => h z (by simp_all))
    simpa [Item.values, streamLine] using this

/-- Top-level items one per line, each derived on its line, are a file with exactly their values. -/
theorem file_build (sp : Spacing) (stream : Bool) : ∀ {xs : List Item},
    (∀ y ∈ xs, Val L L.maxDepth (line sp y.node) y.node.value) →
    Grammar.File L (lineItemsFile sp stream xs) (Item.values xs)
  | [], _ => by simpa [lineItemsFile, Item.values] using Grammar.File.empty (L := L) [] [] (.inl rfl) (.ws [] .nil)
  | [.mk v g], h => by
    cases stream
    · simpa [lineItemsFile, Item.values] using
        Grammar.File.values [] [] _ _ (.inl rfl) .nil (FileItems.last _ ['\n'] _ (h (.mk v g) (by simp)) wsEnd_lf)
    · simpa [lineItemsFile] using Grammar.File.values [] [] _ _ (.inl rfl) .nil (fileItems_build sp (.mk v g) [] h)
  | x :: y :: ys, h => by
    simpa [lineItemsFile] using Grammar.File.values [] [] _ _ (.inl rfl) .nil (fileItems_build sp x (y :: ys) h)

/-- What `read` gives: the parser's values, and leaves that read as their values. -/
theorem read_ok {input : Text} {f : File} (h : read L input = .ok f) :
    Parser.parse L input = .ok f.values ∧ Item.ok L f.items = true := by
  unfold read at h
  split at h
  · simp at h
  · rename_i vs hp
    split at h
    · rename_i f' _
      split at h
      · rename_i hc
        simp only [Except.ok.injEq] at h
        subst h
        simp only [Bool.and_eq_true] at hc
        rw [valuesEq_sound _ _ hc.1]
        exact ⟨hp, hc.2⟩
      · simp at h
    · simp at h

/-- **A document written in a one-line layout parses to the values it was read with.** -/
theorem parse_lineFile (sp : Spacing) (hsp : sp.Blank) (stream : Bool) {input : Text} {f : File}
    (h : read L input = .ok f) : Parser.parse L (lineFile sp stream f) = Parser.parse L input := by
  obtain ⟨hp, hok⟩ := read_ok h
  rw [hp]
  have hvals := File.vals ((parse_correct L input f.values).mp hp)
  refine (parse_correct L _ _).mpr (file_build sp stream fun y hy => ?_)
  have hmem : y.node.value ∈ f.values := by
    simp only [File.values, Item.values_eq]; exact List.mem_map.mpr ⟨y, hy, rfl⟩
  obtain ⟨s, hs⟩ := hvals _ hmem
  exact Node.line_val sp hsp y.node (Item.ok_mem hok y hy) hs

/--
**Compact keeps the values** (§11): when the formatter writes a text in the
compact layout, it parses to the values of the input, in the same order.
-/
theorem parse_format_compact {o : Options} {input out : Text} (h : format L .compact o input = .ok out) :
    Parser.parse L out = Parser.parse L input := by
  unfold format at h
  cases hr : read L input with
  | error e => simp [hr, Except.map] at h
  | ok f =>
    simp only [hr, Except.map, Except.ok.injEq, File.format] at h
    subst h
    exact parse_lineFile _ Spacing.spaced_blank _ hr

/-- **Minimised keeps the values** (§11), as compact does. -/
theorem parse_format_minimised {o : Options} {input out : Text} (h : format L .minimised o input = .ok out) :
    Parser.parse L out = Parser.parse L input := by
  unfold format at h
  cases hr : read L input with
  | error e => simp [hr, Except.map] at h
  | ok f =>
    simp only [hr, Except.map, Except.ok.injEq, File.format] at h
    subst h
    exact parse_lineFile _ Spacing.tight_blank _ hr

end Haus.Format
