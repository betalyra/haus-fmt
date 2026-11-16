import Haus.Json.SchemaBasedRoundTrip
import Haus.Json.TextRoundTrip
import Haus.Json.WellFormed
import Haus.Props.Values

/-!
# Schema-based JSON is well formed (spec §16.3)

`toJson_wellFormed`: the schema-based JSON of a value decoded from a value without
duplicate keys is well formed (`JSON.WellFormed`), so the JSON text reader
reads its text back (`readJson_write`).

- **Numbers.** Schema-based JSON writes a number only for an integer of at most 32
  bits (`intLit`, a normalized literal) and a finite float (`spell`, laid out
  like JavaScript, `spell_json`). Wider integers, `Decimal`s, `NaN` and the
  infinities are strings, and the self-describing form (of `Any` and of an unknown
  tag's arguments) writes numbers as strings too.
- **Member names.** A record's members are the value's fields that the type
  lists, in order, so distinct when the value's keys are (`UniqueKeys`); a
  `Map`'s are the value's keys. A tagged object has `_tag` and then `value`,
  `values`, `_args` or the payload's fields, and a payload with a field named
  `_tag` (or `_args`) is the one thing writing refuses (`toJson_error`).
-/

namespace Haus.JSON

/-- The self-describing form of a value without duplicate keys is well-formed JSON. -/
theorem selfDescribing_wellFormed {v : Value} (h : UniqueKeys v) : WellFormed (selfDescribing v) := by
  induction h with
  | num s => exact .obj _ (by simp) (by simpa using .str _)
  | str s => exact .str _
  | bytes bs => exact .obj _ (by simp) (by simpa using .str _)
  | arr xs _ ih =>
    rw [selfDescribing, selfDescribingList_eq]
    exact .arr _ (by simpa using ih)
  | record fs hnd _ ih =>
    rw [selfDescribing, selfDescribingFields_eq]
    have hin : WellFormed (.obj (fs.map fun kv => (kv.1, selfDescribing kv.2))) := by
      refine .obj _ (by rw [List.map_map]; exact hnd) ?_
      intro m hm
      obtain ⟨kv, hkv, rfl⟩ := List.mem_map.mp hm
      exact ih kv hkv
    exact .obj _ (by simp) (by simpa using hin)
  | variant t xs _ ih =>
    rw [selfDescribing, selfDescribingList_eq]
    cases xs with
    | nil => exact .obj _ (by simp) (by simpa using .str _)
    | cons x xs =>
      exact .obj _ (by simp) (by simpa using ⟨.str _, .arr _ (by simpa using ih)⟩)

/-- The self-describing JSON of a value without duplicate keys, its envelope included, is well-formed JSON. -/
theorem hausJson_wellFormed {v : Value} (h : UniqueKeys v) : WellFormed (hausJson v) :=
  .obj _ (by simp) (by simpa using ⟨.num _ (by decide), selfDescribing_wellFormed h⟩)

end Haus.JSON

namespace Haus.Schema
open Haus

/-! ## Numbers -/

theorem isJsonNumber_append {i rest : Text} (hi : i ≠ []) (hd : ∀ c ∈ i, isDigit c = true)
    (hint : isIntDigits i = true) (hr : ∀ c r', rest = c :: r' → isDigit c = false) :
    isJsonNumber (i ++ rest) = jsonTail rest := by
  obtain ⟨c, cs, rfl⟩ : ∃ c cs, i = c :: cs :=
    match i, hi with
    | c :: cs, _ => ⟨c, cs, rfl⟩
  have hdm : dropMinus ((c :: cs) ++ rest) = (c :: cs) ++ rest := dropMinus_digit (hd c (by simp))
  unfold isJsonNumber
  simp only [hdm, takeWhile_append_of_all hd, dropWhile_append_of_all hd]
  cases rest with
  | nil => simp [hint]
  | cons d r => simp [hr d r rfl, hint]

theorem isJsonNumber_minus {t : Text} {c : Char} {r : Text} (ht : t = c :: r) (hc : isDigit c = true) :
    isJsonNumber ('-' :: t) = isJsonNumber t := by
  subst ht
  unfold isJsonNumber
  rw [dropMinus_digit hc]
  rfl

theorem jsonExp_intText (neg : Bool) (v : Nat) : jsonTail.jsonExp ('e' :: intText neg v) = true := by
  have hd := RoundTrip.toDigits_decimal (n := v)
  obtain ⟨c, rest, he⟩ : ∃ c rest, Nat.toDigits 10 v = c :: rest :=
    match Nat.toDigits 10 v, Nat.toDigits_ne_nil (b := 10) (n := v) with
    | c :: rest, _ => ⟨c, rest, rfl⟩
  have hc : isDigit c = true := hd c (by simp [he])
  have hall : (c :: rest).all isDigit = true := List.all_eq_true.mpr (he ▸ hd)
  unfold intText
  split
  · simp only [List.cons_append, List.nil_append, he]
    simp [jsonTail.jsonExp, hall]
  · simp only [List.nil_append, he]
    have h1 : c ≠ '+' := by rintro rfl; simp [isDigit] at hc
    have h2 : c ≠ '-' := by rintro rfl; simp [isDigit] at hc
    simp [jsonTail.jsonExp, h1, h2, hall]

theorem jsonTail_frac {f : Text} (hne : f ≠ []) (hd : ∀ c ∈ f, isDigit c = true) : jsonTail ('.' :: f) = true := by
  simp [jsonTail, takeWhile_all hd, dropWhile_all hd, hne, jsonTail.jsonExp]

/-- **The layout of a float's digits is a JSON number.** -/
theorem layout_json {ds : Text} (hne : ds ≠ []) (hd : ∀ c ∈ ds, isDigit c = true) (h0 : ds.head? ≠ some '0')
    (n : Int) : isJsonNumber (layout ds n) = true := by
  have htake : ∀ j, ∀ c ∈ ds.take j, isDigit c = true := fun j c hc => hd c (List.mem_of_mem_take hc)
  have hdrop : ∀ j, ∀ c ∈ ds.drop j, isDigit c = true := fun j c hc => hd c (List.mem_of_mem_drop hc)
  have hhead : ∀ j, 0 < j → (ds.take j).head? = ds.head? := by
    intro j hj
    cases ds with
    | nil => simp
    | cons c cs => cases j with
      | zero => omega
      | succ j => rfl
  have hint : ∀ j, 0 < j → isIntDigits (ds.take j) = true := by
    intro j hj
    apply isIntDigits_of (by simp [hne]; omega) (htake j)
    intro h; rw [hhead j hj] at h; exact absurd h h0
  have dot : ∀ (r : Text) c r', '.' :: r = c :: r' → isDigit c = false := by
    intro r c r' h; cases h; rfl
  have nil : ∀ c r', ([] : Text) = c :: r' → isDigit c = false := by intro c r' h; cases h
  simp only [layout]
  by_cases h1 : (ds.length : Int) ≤ n ∧ n ≤ 21
  · have hb : (decide ((ds.length : Int) ≤ n) && decide (n ≤ 21)) = true := by simp [h1]
    simp only [hb, ↓reduceIte]
    have hall : ∀ c ∈ ds ++ List.replicate (n - ds.length).toNat '0', isDigit c = true :=
      fun c hc => (List.mem_append.mp hc).elim (hd c) (fun h => by rw [List.eq_of_mem_replicate h]; rfl)
    rw [← List.append_nil (ds ++ _), isJsonNumber_append (by simp [hne]) hall ?_ nil]
    · rfl
    · apply isIntDigits_of (by simp [hne]) hall
      intro h
      cases ds with
      | nil => exact absurd rfl hne
      | cons c cs => simp at h; simp [h] at h0
  · have hb : (decide ((ds.length : Int) ≤ n) && decide (n ≤ 21)) = false := by simp; omega
    simp only [hb, Bool.false_eq_true, ↓reduceIte]
    by_cases h2 : 0 < n ∧ n ≤ 21
    · have hb2 : (decide (0 < n) && decide (n ≤ 21)) = true := by simp [h2]
      simp only [hb2, ↓reduceIte]
      have hlt : n.toNat < ds.length := by omega
      rw [isJsonNumber_append (by simp [hne]; omega) (htake _) (hint _ (by omega)) (dot _)]
      exact jsonTail_frac (by simp; omega) (hdrop _)
    · have hb2 : (decide (0 < n) && decide (n ≤ 21)) = false := by simp; omega
      simp only [hb2, Bool.false_eq_true, ↓reduceIte]
      by_cases h3 : -6 < n ∧ n ≤ 0
      · have hb3 : (decide (-6 < n) && decide (n ≤ 0)) = true := by simp [h3]
        simp only [hb3, ↓reduceIte]
        rw [show ('0' :: '.' :: List.replicate (-n).toNat '0') ++ ds =
          ['0'] ++ '.' :: (List.replicate (-n).toNat '0' ++ ds) by simp]
        rw [isJsonNumber_append (by simp) (by simp; rfl) rfl (dot _)]
        exact jsonTail_frac (by simp [hne])
          (fun c hc => (List.mem_append.mp hc).elim (fun h => by rw [List.eq_of_mem_replicate h]; rfl) (hd c))
      · have hb3 : (decide (-6 < n) && decide (n ≤ 0)) = false := by simp; omega
        simp only [hb3, Bool.false_eq_true, ↓reduceIte]
        have he : ∀ (r : Text) c r', 'e' :: r = c :: r' → isDigit c = false := by
          intro r c r' h; cases h; rfl
        by_cases h4 : ds.length > 1
        · simp only [h4, ↓reduceIte, List.append_assoc, List.cons_append]
          rw [isJsonNumber_append (by simp [hne]) (htake _) (hint 1 (by omega)) (dot _)]
          have hne' : ds.drop 1 ≠ [] := by rw [ne_eq, List.drop_eq_nil_iff]; omega
          have hE : ∀ E : Text, List.takeWhile isDigit ('e' :: E) = [] ∧ List.dropWhile isDigit ('e' :: E) = 'e' :: E :=
            fun E => ⟨by simp [List.takeWhile, not_digit_e], by simp [List.dropWhile, not_digit_e]⟩
          simp only [jsonTail, takeWhile_append_of_all (hdrop 1), dropWhile_append_of_all (hdrop 1), (hE _).1,
            (hE _).2, List.append_nil, jsonExp_intText, Bool.and_true, bne_iff_ne, ne_eq, hne', not_false_eq_true]
        · simp only [h4, ↓reduceIte, List.append_nil]
          rw [isJsonNumber_append (by simp [hne]) (htake _) (hint 1 (by omega)) (he _)]
          simp [jsonTail, jsonExp_intText]

theorem isJsonNumber_sign (neg : Bool) {t : Text} (h : isJsonNumber t = true) {c : Char} {r : Text}
    (ht : t = c :: r) (hc : isDigit c = true) :
    isJsonNumber ((if neg then "-" else "").toList ++ t) = true := by
  cases neg
  · simpa using h
  · simpa [isJsonNumber_minus ht hc] using h

/-- **A float's spelling is a JSON number** (§15): `0`, `-0`, or its digits laid out like JavaScript. -/
theorem spell_json (k : FloatType) (x : Flt) : isJsonNumber (spell k x).toList = true := by
  cases x with
  | nan => simp only [spell]; decide
  | inf => simp only [spell]; decide
  | fin neg m q =>
    have zero : isJsonNumber ((if neg then "-" else "") ++ "0").toList = true := by cases neg <;> rfl
    unfold spell
    simp only
    by_cases hm : m = 0
    · simp only [hm, ↓reduceIte]; exact zero
    · simp only [hm, ↓reduceIte]
      split
      · rename_i d k' hs
        have hr := digitsAt_some (shortest_some hs)
        simp only [roundsTo, beq_iff_eq] at hr
        generalize decimalExponent _ _ = n at hr ⊢
        have hd0 : d ≠ 0 := by
          rintro rfl
          rw [fraction_zero, roundRat, roundMag_zero] at hr
          simp only [Option.map_some, Option.some.injEq, Flt.fin.injEq] at hr
          omega
        obtain ⟨c0, rest0, hds, hc0⟩ := RoundTrip.toDigits_head (Nat.pos_of_ne_zero hd0)
        obtain ⟨z, hz⟩ := stripTrailing_zeros (Nat.toDigits 10 d)
        generalize stripTrailing (Nat.toDigits 10 d) = s at hz ⊢
        have hV : d = digitsValue 10 s * 10 ^ z := by
          rw [← digitsValue_zeros, ← hz, RoundTrip.digitsValue_toDigits (by decide) (by decide)]
        have hsne : s ≠ [] := by rintro rfl; simp [digitsValue] at hV; omega
        have hsd : ∀ c ∈ s, isDigit c = true := fun c hc =>
          RoundTrip.toDigits_decimal c (by rw [hz]; exact List.mem_append_left _ hc)
        have hs0 : s.head? ≠ some '0' := by
          obtain ⟨c, s', rfl⟩ : ∃ c s', s = c :: s' :=
            match s, hsne with
            | c :: s', _ => ⟨c, s', rfl⟩
          rw [hds] at hz
          simp only [List.cons_append, List.cons.injEq] at hz
          simp [← hz.1, hc0]
        have hlay := layout_json hsne hsd hs0 (n - k' + (Nat.toDigits 10 d).length)
        obtain ⟨D, E, hdec, -⟩ := decBody_layout neg hsne hsd (n - k' + (Nat.toDigits 10 d).length)
        obtain ⟨c, t', ht, hc⟩ := decBody_head hdec
        rw [String.toList_append, String.toList_ofList]
        exact isJsonNumber_sign neg hlay ht hc
      · exact zero

theorem intJson_wf (k : IntType) (n : Int) : JSON.WellFormed (intJson k n) := by
  unfold intJson
  split
  · exact .str _
  · exact .num _ (isNormalLit_json (isNormalLit_intText_string _ _))

theorem floatJson_wf (k : FloatType) (f : Flt) : JSON.WellFormed (floatJson k f) := by
  unfold floatJson
  split
  · exact .str _
  · exact .str _
  · exact .str _
  · exact .num _ (spell_json _ _)

/-! ## Member names -/

/-- An object with `_tag` first and then other members. -/
theorem wf_tagged {tag : String} {ms : List (String × JSON)} (hk : "_tag" ∉ ms.map (·.1))
    (hnd : (ms.map (·.1)).Nodup) (hw : ∀ m ∈ ms, JSON.WellFormed m.2) :
    JSON.WellFormed (.obj (("_tag", .str tag) :: ms)) := by
  refine .obj _ (by simp only [List.map_cons, List.nodup_cons]; exact ⟨hk, hnd⟩) ?_
  intro m hm
  rcases List.mem_cons.mp hm with rfl | hm
  · exact .str _
  · exact hw m hm

theorem wf_tag (tag : String) : JSON.WellFormed (.obj [("_tag", .str tag)]) :=
  wf_tagged (ms := []) (by simp) .nil (by simp)

theorem wf_tag_one (tag k : String) (hk : k ≠ "_tag") {j : JSON} (h : JSON.WellFormed j) :
    JSON.WellFormed (.obj [("_tag", .str tag), (k, j)]) :=
  wf_tagged (ms := [(k, j)]) (by simpa using hk.symm) (by simp) (by simpa using h)

theorem toJsonEntries_keys {env : Env} {F : Nat} {o : String} {t : Ty} :
    ∀ {ys : List (String × Typed)} {ms : List (String × JSON)}, toJsonEntries env F o t ys = .ok ms →
      ms.map (·.1) = ys.map (·.1)
  | [], ms, h => by simp only [toJsonEntries, Except.ok.injEq] at h; subst h; rfl
  | (k, y) :: ys, ms, h => by
    rw [toJsonEntries_cons] at h
    obtain ⟨j, -, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    simp [toJsonEntries_keys hms]

theorem Entries.keys {env : Env} {t : Ty} {fs : List (String × Value)} {ys : List (String × Typed)} :
    Entries env t fs ys → ys.map (·.1) = fs.map (·.1)
  | .nil => rfl
  | .cons _ h => by simp [h.keys]

/-- A record's decoded fields are some of the value's, in order. -/
theorem Fields.keys_sublist {env : Env} {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} : Fields env closed fields fs ys → (ys.map (·.1)).Sublist (fs.map (·.1))
  | .nil => .slnil
  | .keep _ _ h => by simpa using h.keys_sublist
  | .skip _ h => by simpa using h.keys_sublist.cons _

/-- A record's decoded fields are fields the type lists. -/
theorem Fields.keys_listed {env : Env} {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} : Fields env closed fields fs ys → ∀ k ∈ ys.map (·.1), (fieldOf? fields k).isSome
  | .nil => by simp
  | .keep hf _ h => by
    intro k hk
    rcases List.mem_cons.mp hk with rfl | hk
    · simp [hf]
    · exact h.keys_listed k hk
  | .skip _ h => h.keys_listed

theorem tag_not_listed {fields : List Field} {ks : List String} (ht : hasReservedField fields = false)
    (h : ∀ k ∈ ks, (fieldOf? fields k).isSome) : "_tag" ∉ ks := by
  intro hk
  have := h _ hk
  simp only [fieldOf?, Option.isSome_iff_exists] at this
  obtain ⟨f, hf⟩ := this
  have hm := List.mem_of_find?_eq_some hf
  have he := List.find?_some hf
  simp only [hasReservedField, List.any_eq_false] at ht
  exact ht f hm (by simp [show f.key = "_tag" by simpa using he])

/-! ## Tagged objects -/

/-- What `Tag { … }` writes: `_tag` and fields the type lists, so never a second `_tag`. -/
def PayloadWF (env : Env) (F : Nat) (o : String) (fields : List Field) (y : Typed) : Prop :=
  ∃ ys, y = .record ys ∧ (ys.map (·.1)).Nodup ∧ (∀ k ∈ ys.map (·.1), (fieldOf? fields k).isSome) ∧
    ∀ ms, toJsonFields env F o fields ys = .ok ms → ∀ m ∈ ms, JSON.WellFormed m.2

theorem recordCase_wf {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {cl : Bool} {fields : List Field} {y : Typed} {b : Bool} {j : JSON}
    (hc : caseOf? cases tag = some (.record tag' cl fields)) (IH : PayloadWF env F o fields y)
    (h : toJsonC env F b o (.variant closed cases) (.case tag [y]) = .ok j) : JSON.WellFormed j := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    cases hn : nullArg? env F o (.variant closed cases) with
    | some a' =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨-, h2⟩ <;> cases h2
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      obtain ⟨ys, rfl, hnd, hl, hys⟩ := IH
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      by_cases ht : hasReservedField fields = true
      · simp [ht] at h
      · simp only [ht, Bool.false_eq_true, ↓reduceIte] at h
        obtain ⟨ms, hms, rfl⟩ := map_ok.mp h
        have hms' := under_ok.mp hms
        have hk := toJsonFields_keys hms'
        exact wf_tagged (by rw [hk]; exact tag_not_listed (by simpa using ht) hl) (hk ▸ hnd) (hys ms hms')

theorem positional_wf {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {ts : List Ty} {ys : List Typed} {b : Bool} {j : JSON}
    (hc : caseOf? cases tag = some (.positional tag' ts))
    (IHargs : ∀ js, toJsonArgs env F o tag 0 ts ys = .ok js → ∀ j ∈ js, JSON.WellFormed j)
    (IHone : ∀ t1, ts = [t1] → ∃ y, ys = [y] ∧ ∀ j, toJsonF env F o t1 y = .ok j → JSON.WellFormed j)
    (h : toJsonC env F b o (.variant closed cases) (.case tag ys) = .ok j) : JSON.WellFormed j := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    cases hn : nullArg? env F o (.variant closed cases) with
    | some a =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨rfl, h2⟩
      · cases h2
      · injection h2 with _ hts
        obtain ⟨y, rfl, hy⟩ := IHone a hts
        simp only [hn] at h
        exact hy j h
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      match ts, IHone, IHargs, h with
      | [], _, _, h => simp only [Except.ok.injEq] at h; subst h; exact wf_tag _
      | [t1], IHone, _, h =>
        obtain ⟨y, rfl, hy⟩ := IHone t1 rfl
        obtain ⟨j1, hj1, rfl⟩ := map_ok.mp h
        exact wf_tag_one _ _ (by decide) (hy j1 (under_ok.mp hj1))
      | t1 :: t2 :: rest, _, IHargs, h =>
        obtain ⟨js, hjs, rfl⟩ := map_ok.mp h
        exact wf_tag_one _ _ (by decide) (.arr _ (IHargs js hjs))

variable {env : Env} {F : Nat}

mutual
/-- **Schema-based JSON is well formed**, by the rules of decoding. -/
theorem Dec.wellFormed {t : Ty} {v : Value} {x : Typed} {j : JSON} :
    Dec env t v x → UniqueKeys v → toJsonF env F o t x = .ok j → JSON.WellFormed j
  | .intro hw hc, hu, h => by
    rw [toJsonF_eq _ hw, toJsonC_hide] at h
    exact hc.wellFormed hu h

theorem Core.wellFormed {c : Ty} {v : Value} {x : Typed} {b : Bool} {j : JSON} :
    Core env c v x → UniqueKeys v → toJsonC env F b o c x = .ok j → JSON.WellFormed j
  | .string _, _, h | .bytes _, _, h | .decimal _, _, h | .time _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h; exact .str _
  | .int _ _, _, h => by simp only [toJsonC, Except.ok.injEq] at h; subst h; exact intJson_wf _ _
  | .float _, _, h | .floatTag _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h; exact floatJson_wf _ _
  | .any _, hu, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h; exact JSON.selfDescribing_wellFormed hu
  | .array hi, hu, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨js, hjs, rfl⟩ := h
    cases hu with
    | arr _ hx => exact .arr _ (hi.wellFormed hx hjs)
  | .map he, hu, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    cases hu with
    | record _ hnd hx =>
      exact .obj _ (by rw [toJsonEntries_keys hms, he.keys]; exact hnd) (he.wellFormed hx hms)
  | .record _ hf, hu, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    cases hu with
    | record _ hnd hx =>
      exact .obj _ (by rw [toJsonFields_keys hms]; exact hnd.sublist hf.keys_sublist) (hf.wellFormed hx hms)
  | .bare (closed := closed) (cases := cases) (tag := tag) hc, _, h => by
    rw [toJsonC.eq_def] at h
    simp only at h
    cases b with
    | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h
      cases hn : nullArg? env F o (.variant closed cases) with
      | some a => simp only [hn, Except.ok.injEq] at h; subst h; exact .null
      | none =>
        simp only [hn] at h
        split at h
        · simp only [Except.ok.injEq] at h; subst h; exact .str _
        · simp only [hc, Except.ok.injEq] at h; subst h; exact wf_tag _
  | .recordCase hc hd, hu, h => by
    cases hu with
    | variant _ _ hx => exact recordCase_wf hc (hd.payloadWF rfl (hx _ (by simp))) h
  | .positional hc ha, hu, h => by
    cases hu with
    | variant _ _ hx =>
      exact positional_wf hc (fun js h => ha.wellFormed hx h) (fun t1 hts => ha.oneWF hts hx) h
  | .unknown (args := args) _, hu, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    cases hu with
    | variant _ _ hx =>
      cases args with
      | nil => exact wf_tag _
      | cons w ws =>
        refine wf_tag_one _ _ (by decide) (.arr _ ?_)
        rw [JSON.selfDescribingList_eq]
        intro j hj
        obtain ⟨v, hv, rfl⟩ := List.mem_map.mp hj
        exact JSON.selfDescribing_wellFormed (hx v hv)

theorem Items.wellFormed {t : Ty} {xs : List Value} {ys : List Typed} {i : Nat} {js : List JSON} :
    Items env t xs ys → (∀ x ∈ xs, UniqueKeys x) → toJsonItems env F o t i ys = .ok js →
      ∀ j ∈ js, JSON.WellFormed j
  | .nil, _, h => by simp only [toJsonItems, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hu, h => by
    rw [toJsonItems_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro j' hj'
    rcases List.mem_cons.mp hj' with rfl | hj'
    · exact hx.wellFormed (hu _ (by simp)) (under_ok.mp hj)
    · exact hs.wellFormed (fun x hx => hu x (by simp [hx])) hjs j' hj'

theorem Entries.wellFormed {t : Ty} {fs : List (String × Value)} {ys : List (String × Typed)}
    {ms : List (String × JSON)} :
    Entries env t fs ys → (∀ kv ∈ fs, UniqueKeys kv.2) → toJsonEntries env F o t ys = .ok ms →
      ∀ m ∈ ms, JSON.WellFormed m.2
  | .nil, _, h => by simp only [toJsonEntries, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hu, h => by
    rw [toJsonEntries_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact hx.wellFormed (hu _ (List.mem_cons.mpr (.inl rfl))) (under_ok.mp hj)
    · exact hs.wellFormed (fun kv hkv => hu kv (by simp [hkv])) hms m hm

theorem Fields.wellFormed {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} {ms : List (String × JSON)} :
    Fields env closed fields fs ys → (∀ kv ∈ fs, UniqueKeys kv.2) → toJsonFields env F o fields ys = .ok ms →
      ∀ m ∈ ms, JSON.WellFormed m.2
  | .nil, _, h => by simp only [toJsonFields, Except.ok.injEq] at h; subst h; simp
  | .keep hf hx hs, hu, h => by
    rw [toJsonFields_cons hf] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact hx.wellFormed (hu _ (List.mem_cons.mpr (.inl rfl))) (under_ok.mp hj)
    · exact hs.wellFormed (fun kv hkv => hu kv (by simp [hkv])) hms m hm
  | .skip _ hs, hu, h => hs.wellFormed (fun kv hkv => hu kv (by simp [hkv])) h

theorem Args.wellFormed {ts : List Ty} {xs : List Value} {ys : List Typed} {tag : String} {i : Nat}
    {js : List JSON} :
    Args env ts xs ys → (∀ x ∈ xs, UniqueKeys x) → toJsonArgs env F o tag i ts ys = .ok js →
      ∀ j ∈ js, JSON.WellFormed j
  | .nil, _, h => by simp only [toJsonArgs, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hu, h => by
    rw [toJsonArgs_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro j' hj'
    rcases List.mem_cons.mp hj' with rfl | hj'
    · exact hx.wellFormed (hu _ (by simp)) (under_ok.mp hj)
    · exact hs.wellFormed (fun x hx => hu x (by simp [hx])) hjs j' hj'

theorem Args.oneWF {ts : List Ty} {xs : List Value} {ys : List Typed} {t : Ty} :
    Args env ts xs ys → ts = [t] → (∀ x ∈ xs, UniqueKeys x) →
      ∃ y, ys = [y] ∧ ∀ j, toJsonF env F o t y = .ok j → JSON.WellFormed j
  | .nil, hts, _ => by cases hts
  | .cons hx .nil, hts, hu => by
    simp only [List.cons.injEq, and_true] at hts
    exact ⟨_, rfl, fun j h => hx.wellFormed (hu _ (by simp)) (hts ▸ h)⟩
  | .cons _ (.cons _ _), hts, _ => by simp at hts

theorem Dec.payloadWF {t : Ty} {cl : Bool} {fields : List Field} {a : Value} {y : Typed} :
    Dec env t a y → t = .record cl fields → UniqueKeys a → PayloadWF env F o fields y
  | .intro hw hcore, ht0, hu => hcore.payloadWF (ht0 ▸ hw) hu

theorem Core.payloadWF {cl : Bool} {fields : List Field} {c : Ty} {s : Nat} {a : Value} {y : Typed} :
    Core env c a y → whnf env env.fuel (.record cl fields) = .ok (s, c) → UniqueKeys a →
      PayloadWF env F o fields (y.hide s)
  | .record (closed := cl') (fields := fields') (ys := ys) _ hf, hw, hu => by
    rw [whnf_record] at hw
    have e := Prod.mk.inj (Except.ok.inj hw)
    have e2 : Ty.record cl fields = Ty.record cl' fields' := e.2
    injection e2 with ec ef
    cases hu with
    | record _ hnd hx =>
      have IH : ∀ ms, toJsonFields env F o fields' ys = .ok ms → ∀ m ∈ ms, JSON.WellFormed m.2 :=
        fun ms h => hf.wellFormed hx h
      subst ec ef
      rw [← e.1]
      exact ⟨ys, rfl, hnd.sublist hf.keys_sublist, hf.keys_listed, IH⟩
  | .string _, hw, _ | .bytes _, hw, _ | .int _ _, hw, _ | .float _, hw, _
  | .floatTag _, hw, _ | .decimal _, hw, _ | .any _, hw, _ | .time _, hw, _
  | .array _, hw, _ | .map _, hw, _ | .bare _, hw, _ | .recordCase _ _, hw, _
  | .positional _ _, hw, _ | .unknown _, hw, _ => by
    rw [whnf_record] at hw; cases hw
end

/-! ## The theorem -/

/--
**Schema-based JSON is well formed** (§16.3): the schema-based JSON of a value decoded from
a value without duplicate keys has JSON numbers and distinct member names,
so the JSON text reader reads its text back.
-/
theorem toJson_wellFormed {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hu : UniqueKeys v) (hj : toJson env t x = .ok j) : JSON.WellFormed j :=
  (decode_sound h).wellFormed hu hj

end Haus.Schema
