import Haus.Json.SchemaBasedWellFormed
import Haus.Json.Fits

/-!
# Schema-based JSON within the limits (spec §7, §16.3)

`toJson_fits`: the schema-based JSON of a decoded value whose encoding (§15) is
within the haus limits (`Value.fits`) is within the JSON limits (`Fits`,
nested at most `jsonDepth L = 4 · maxDepth + 1`), so the JSON text reader
reads it back.

It needs more of the limits than the self-describing form (`Limits.SchemaBasedOk`,
true of the defaults), each for a reason:

- **member names**: schema-based JSON's own (`_tag`, `_args`, `value`,
  `values`, and the self-describing form's inside an `Any`) have at most 6
  characters;
- **numbers in strings**: an `Int`, `Int64`, `UInt64` or `Decimal` is a
  string holding its literal, and a haus number within the limits has at
  most `maxNumberLength · 6/5 + 4` characters (an integer's hex form may fit
  when its decimal form doesn't);
- **number tokens**: an integer of at most 32 bits and a float are JSON
  numbers, which the JSON limits count as written, with no hex form to fall
  back on. A float's spelling can be an integer of up to 21 digits
  (`1e20` is `100000000000000000000`), whose hex form is shorter: with
  `maxNumberLength` 19 to 21 the haus value fits and its schema-based JSON doesn't.
  So `maxNumberLength` must be at least 22 (an integer of at most 32 bits
  has at most 11 characters).

`Bytes` are base64, `4 · ⌈n / 3⌉` characters, at most the `2 · n` of their
hex (as `Value.fits` counts them) or 4. Nesting: schema-based JSON uses at most two
levels for a haus level (`{"_tag", "values": […]}`), and an `Any` its
self-describing form, four.
-/

namespace Haus

/-- What `toJson_fits` needs of the limits, besides `SelfDescribingOk`. -/
def Limits.SchemaBasedOk (L : Limits) : Prop :=
  6 ≤ L.maxStringLength ∧ L.maxNumberLength * 6 / 5 + 4 ≤ L.maxStringLength ∧ 22 ≤ L.maxNumberLength

theorem Limits.schemaBasedOk_default : Limits.SchemaBasedOk {} := by unfold Limits.SchemaBasedOk; decide

theorem Limits.SchemaBasedOk.selfDescribing {L : Limits} (h : L.SchemaBasedOk) : L.SelfDescribingOk := ⟨h.1, h.2.1, by have := h.2.2; omega⟩

theorem Bytes.base64_length : ∀ bs : List UInt8, (Bytes.base64 bs).length = 4 * ((bs.length + 2) / 3)
  | [] => rfl
  | [_] => by simp [Bytes.base64]
  | [_, _] => by simp [Bytes.base64]
  | _ :: _ :: _ :: rest => by simp [Bytes.base64, Bytes.base64_length rest]; omega

namespace Schema
open JSON

/-! ## Number tokens -/

theorem hexForm_digits {lit h : Text} (hh : hexForm lit = some h) : ∀ c ∈ dropMinus lit, isDigit c = true := by
  by_cases hc : ∃ r, lit = '-' :: r
  · obtain ⟨r, rfl⟩ := hc
    simp only [hexForm, Bool.and_eq_true, bne_iff_ne, ne_eq, List.all_eq_true] at hh
    split at hh
    · rename_i hall; exact hall.2
    · cases hh
  · have hd : dropMinus lit = lit := by
      unfold dropMinus; split
      · exact absurd ⟨_, rfl⟩ hc
      · rfl
    rw [hd]
    unfold hexForm at hh
    split at hh
    rename_i sign ds heq
    have hds : ds = lit := by
      split at heq
      · rename_i r; exact absurd ⟨r, rfl⟩ hc
      · cases heq; rfl
    subst hds
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.all_eq_true] at hh
    split at hh
    · rename_i hall; exact hall.2
    · cases hh

theorem layout_digits_length {ds : Text} (n : Int) (h : ∀ c ∈ layout ds n, isDigit c = true) :
    (layout ds n).length ≤ 21 := by
  simp only [layout] at h ⊢
  by_cases h1 : (ds.length : Int) ≤ n ∧ n ≤ 21
  · have hb : (decide ((ds.length : Int) ≤ n) && decide (n ≤ 21)) = true := by simp [h1]
    simp only [hb, ↓reduceIte, List.length_append, List.length_replicate]
    omega
  · have hb : (decide ((ds.length : Int) ≤ n) && decide (n ≤ 21)) = false := by simp; omega
    simp only [hb, Bool.false_eq_true, ↓reduceIte] at h ⊢
    exfalso
    split at h
    · exact absurd (h '.' (by simp)) (by decide)
    split at h
    · exact absurd (h '.' (by simp)) (by decide)
    · exact absurd (h 'e' (by simp)) (by decide)

/-- A float's spelling: a sign, then `0` or digits laid out like JavaScript. -/
theorem spell_cases (k : FloatType) (x : Flt) :
    ∃ (neg : Bool) (t : Text), (spell k x).toList = (if neg then "-" else "").toList ++ t ∧
      (∃ c r, t = c :: r ∧ isDigit c = true) ∧
      (t = ['0'] ∨ ∃ ds n, t = layout ds n ∧ ds ≠ [] ∧ (∀ c ∈ ds, isDigit c = true)) := by
  cases x with
  | nan => exact ⟨false, ['0'], by simp [spell], ⟨_, _, rfl, rfl⟩, .inl rfl⟩
  | inf => exact ⟨false, ['0'], by simp [spell], ⟨_, _, rfl, rfl⟩, .inl rfl⟩
  | fin neg m q =>
    unfold spell
    simp only
    by_cases hm : m = 0
    · simp only [hm, ↓reduceIte]
      exact ⟨neg, ['0'], by simp, ⟨_, _, rfl, rfl⟩, .inl rfl⟩
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
        obtain ⟨z, hz⟩ := stripTrailing_zeros (Nat.toDigits 10 d)
        generalize stripTrailing (Nat.toDigits 10 d) = s at hz ⊢
        have hV : d = digitsValue 10 s * 10 ^ z := by
          rw [← digitsValue_zeros, ← hz, RoundTrip.digitsValue_toDigits (by decide) (by decide)]
        have hsne : s ≠ [] := by rintro rfl; simp [digitsValue] at hV; omega
        have hsd : ∀ c ∈ s, isDigit c = true := fun c hc =>
          RoundTrip.toDigits_decimal c (by rw [hz]; exact List.mem_append_left _ hc)
        obtain ⟨D, E, hdec, -⟩ := decBody_layout neg hsne hsd (n - k' + (Nat.toDigits 10 d).length)
        exact ⟨neg, _, by rw [String.toList_append, String.toList_ofList], decBody_head hdec,
          .inr ⟨s, _, rfl, hsne, hsd⟩⟩
      · exact ⟨neg, ['0'], by simp, ⟨_, _, rfl, rfl⟩, .inl rfl⟩

/-- **A float's spelling as a JSON number token** is within the limits whenever it is as a haus number. -/
theorem spell_tokenFits {L : Limits} (hL : 22 ≤ L.maxNumberLength) (k : FloatType) (x : Flt)
    (h : numberFits L (spell k x).toList = true) : tokenFits L (spell k x).toList = true := by
  simp only [numberFits, tokenFits, Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq] at h ⊢
  refine ⟨?_, h.1⟩
  rcases h.2 with h | ⟨-, hh⟩
  · exact h
  · split at hh
    · rename_i hx hform
      have hd := hexForm_digits hform
      obtain ⟨neg, t, he, ⟨c0, r0, hc0, hd0⟩, ht⟩ := spell_cases k x
      rw [he] at hd ⊢
      have hdt : ∀ c ∈ t, isDigit c = true := by
        cases neg
        · simpa [hc0, dropMinus_digit hd0] using hd
        · simpa [dropMinus] using hd
      have hlen : t.length ≤ 21 := by
        rcases ht with rfl | ⟨ds, n, rfl, -, -⟩
        · simp
        · exact layout_digits_length n hdt
      cases neg <;> simp <;> omega
    · simp at hh

/-- An integer of at most 32 bits has at most 11 characters. -/
theorem intLit_length {k : IntType} {n : Int} (hk : k.asString = false) (hr : k.inRange n = true) :
    (intLit n).toList.length ≤ 11 := by
  have hb : n.natAbs < 2 ^ 32 := by
    cases k with
    | int => simp [IntType.asString] at hk
    | signed b =>
      simp only [IntType.asString, decide_eq_false_iff_not, Nat.not_lt] at hk
      simp only [IntType.inRange, Bool.and_eq_true, decide_eq_true_eq] at hr
      have : (2 : Int) ^ (b - 1) ≤ 2 ^ 31 := by
        have := Nat.pow_le_pow_right (n := 2) (by decide) (show b - 1 ≤ 31 by omega)
        exact_mod_cast this
      omega
    | unsigned b =>
      simp only [IntType.asString, decide_eq_false_iff_not, Nat.not_lt] at hk
      simp only [IntType.inRange, Bool.and_eq_true, decide_eq_true_eq] at hr
      have : (2 : Int) ^ b ≤ 2 ^ 32 := by
        have := Nat.pow_le_pow_right (n := 2) (by decide) hk
        exact_mod_cast this
      omega
  have hd : (Nat.toDigits 10 n.natAbs).length ≤ 10 :=
    toDigits_length_le (by decide) (Nat.lt_of_lt_of_le hb (by decide))
  simp only [intLit, String.toList_ofList, RoundTrip.intText, List.length_append]
  split <;> simp <;> omega

/-! ## Nesting -/

/--
The JSON nesting a value's schema-based JSON may use: `4 · depth + 1`, and for a
record two less, so that `{"_tag", "value": {…}}` (two levels) fits where
`Tag {…}` (one) does.
-/
def jsonNeed (w : Value) : Nat :=
  match w with
  | .record _ => 4 * w.depth - 1
  | _ => 4 * w.depth + 1

theorem need_le (w : Value) : jsonNeed w ≤ 4 * w.depth + 1 := by
  unfold jsonNeed; split <;> omega

theorem need_variant (t : String) (xs : List Value) :
    jsonNeed (.variant t xs) = 4 * (Value.variant t xs).depth + 1 := rfl

theorem depthList_ge : ∀ {xs : List Value} {x : Value}, x ∈ xs → x.depth ≤ Value.depthList xs
  | y :: ys, x, h => by
    simp only [Value.depthList]
    rcases List.mem_cons.mp h with rfl | h
    · omega
    · have := depthList_ge h; omega

/-- An argument of a payload has two levels more to spare: `{"_tag", "values": […]}`. -/
theorem need_args {t : String} {xs : List Value} (hne : xs ≠ []) {x : Value} (hx : x ∈ xs) :
    jsonNeed x + 2 ≤ jsonNeed (.variant t xs) := by
  rw [need_variant]
  by_cases hr : ∃ fs, xs = [.record fs]
  · obtain ⟨fs, rfl⟩ := hr
    simp only [List.mem_singleton] at hx; subst hx
    simp [jsonNeed, Value.depth]
    omega
  · have hr' : ∀ fs, xs ≠ [.record fs] := fun fs h => hr ⟨fs, h⟩
    rw [JSON.Value.depth_variant hne hr']
    have := depthList_ge hx
    have := need_le x
    omega

theorem need_nonrecord {w : Value} (h : ∀ fs, w ≠ .record fs) : jsonNeed w = 4 * w.depth + 1 := by
  unfold jsonNeed; split
  · rename_i fs; exact absurd rfl (h fs)
  · rfl

variable {L : Limits}

/-- The self-describing form within the nesting `jsonNeed` allows. -/
theorem selfDescribing_fits_need (hL : L.SelfDescribingOk) (v : Value) {d : Nat} (hd : jsonNeed v ≤ d)
    (hl : v.leaves L = true) : Fits L d (selfDescribing v) := by
  by_cases hr : ∃ fs, v = .record fs
  · obtain ⟨fs, rfl⟩ := hr
    simp only [jsonNeed, Value.depth] at hd
    simp only [Value.leaves] at hl
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    obtain ⟨d'', rfl⟩ := fits_succ (d := d') (by omega)
    simp only [selfDescribing]
    refine .obj _ _ (names_le hL (by simp <;> decide)) ?_
    simp only [List.mem_singleton, forall_eq]
    have h := selfDescribingFields_fitsD hL fs (d := d'') (by omega) hl
    exact .obj _ _ (fun m hm => (h m hm).1) (fun m hm => (h m hm).2)
  · rw [need_nonrecord fun fs h => hr ⟨fs, h⟩] at hd
    exact selfDescribing_fitsD hL v hd hl

/-! ## Tagged objects -/

theorem fits_tagged {d : Nat} (hL : L.SchemaBasedOk) {tag : String} (ht : tag.length ≤ L.maxStringLength)
    {ms : List (String × JSON)} (hms : ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2) :
    Fits L (d + 1) (.obj (("_tag", .str tag) :: ms)) := by
  refine .obj _ _ ?_ ?_
  · intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact Nat.le_trans (show "_tag".length ≤ 6 by decide) hL.1
    · exact (hms m hm).1
  · intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact .str _ _ ht
    · exact (hms m hm).2

theorem fits_tag_one {d : Nat} (hL : L.SchemaBasedOk) {tag k : String} (ht : tag.length ≤ L.maxStringLength)
    (hk : k.length ≤ 6) {j : JSON} (hj : Fits L d j) : Fits L (d + 1) (.obj [("_tag", .str tag), (k, j)]) :=
  fits_tagged (ms := [(k, j)]) hL ht (by simp; exact ⟨by have := hL.1; omega, hj⟩)

theorem fits_tag {d : Nat} (hL : L.SchemaBasedOk) {tag : String} (ht : tag.length ≤ L.maxStringLength) :
    Fits L (d + 1) (.obj [("_tag", .str tag)]) :=
  fits_tagged (ms := []) hL ht (by simp)

/-- What `Tag { … }` writes is within the limits, given its fields are. -/
def PayloadFits (L : Limits) (env : Env) (F : Nat) (o : String) (fields : List Field) (y : Typed) : Prop :=
  ∃ ys, y = .record ys ∧ ∀ d ms, Value.leavesFields L (encodeFields ys) = true →
    4 * Value.depthFields (encodeFields ys) + 1 ≤ d → toJsonFields env F o fields ys = .ok ms →
    ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2

theorem recordCase_fits {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {cl : Bool} {fields : List Field} {y : Typed} {b : Bool} {j : JSON} {d : Nat} (hL : L.SchemaBasedOk)
    (hc : caseOf? cases tag = some (.record tag' cl fields)) (IH : PayloadFits L env F o fields y)
    (hl : (encode (.case tag [y])).leaves L = true) (hd : jsonNeed (encode (.case tag [y])) ≤ d)
    (h : toJsonC env F b o (.variant closed cases) (.case tag [y]) = .ok j) : Fits L d j := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _ _
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    cases hn : nullArg? env F o (.variant closed cases) with
    | some a' =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨-, h2⟩ <;> cases h2
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      obtain ⟨ys, rfl, hys⟩ := IH
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      by_cases ht : hasReservedField fields = true
      · simp [ht] at h
      · simp only [ht, Bool.false_eq_true, ↓reduceIte] at h
        obtain ⟨ms, hms, rfl⟩ := map_ok.mp h
        simp only [encode, encodeList, Value.leaves, Value.leavesList, Bool.and_true, Bool.and_eq_true,
          decide_eq_true_eq] at hl
        simp only [encode, encodeList, need_variant, Value.depth] at hd
        obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
        exact fits_tagged hL hl.1 (hys d' ms hl.2 (by omega) (under_ok.mp hms))

theorem positional_fits {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {ts : List Ty} {ys : List Typed} {b : Bool} {j : JSON} {d : Nat} (hL : L.SchemaBasedOk)
    (hc : caseOf? cases tag = some (.positional tag' ts)) (hlen : ys.length = ts.length)
    (IHargs : ∀ d js, Value.leavesList L (encodeList ys) = true → 4 * Value.depthList (encodeList ys) + 1 ≤ d →
      toJsonArgs env F o tag 0 ts ys = .ok js → ∀ j ∈ js, Fits L d j)
    (IHone : ∀ t1, ts = [t1] → ∃ y, ys = [y] ∧ ∀ d j, (encode y).leaves L = true → jsonNeed (encode y) ≤ d →
      toJsonF env F o t1 y = .ok j → Fits L d j)
    (hl : (encode (.case tag ys)).leaves L = true) (hd : jsonNeed (encode (.case tag ys)) ≤ d)
    (h : toJsonC env F b o (.variant closed cases) (.case tag ys) = .ok j) : Fits L d j := by
  simp only [encode, Value.leaves, Bool.and_eq_true, decide_eq_true_eq] at hl
  simp only [encode] at hd
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _ _
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
        simp only [encodeList, Value.leavesList, Bool.and_true] at hl
        have := need_args (t := "Some") (xs := [encode y]) (by simp) (x := encode y) (by simp)
        simp only [encodeList] at hd
        exact hy d j hl.2 (by omega) h
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      match ts, hlen, IHone, IHargs, h with
      | [], _, _, _, h =>
        simp only [Except.ok.injEq] at h; subst h
        obtain ⟨d', rfl⟩ := fits_succ (d := d) (by rw [need_variant] at hd; omega)
        exact fits_tag hL hl.1
      | [t1], _, IHone, _, h =>
        obtain ⟨y, rfl, hy⟩ := IHone t1 rfl
        obtain ⟨j1, hj1, rfl⟩ := map_ok.mp h
        simp only [encodeList, Value.leavesList, Bool.and_true] at hl
        have := need_args (t := tag) (xs := [encode y]) (by simp) (x := encode y) (by simp)
        simp only [encodeList] at hd
        obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
        exact fits_tag_one hL hl.1 (by decide) (hy d' j1 hl.2 (by omega) (under_ok.mp hj1))
      | t1 :: t2 :: rest, hlen, _, IHargs, h =>
        obtain ⟨js, hjs, rfl⟩ := map_ok.mp h
        obtain ⟨y1, y2, ys', rfl⟩ : ∃ y1 y2 ys', ys = y1 :: y2 :: ys' := by
          match ys, hlen with
          | y1 :: y2 :: ys', _ => exact ⟨y1, y2, ys', rfl⟩
        have hdep := JSON.Value.depth_variant (t := tag) (xs := encodeList (y1 :: y2 :: ys'))
          (by simp [encodeList]) (by simp [encodeList])
        rw [need_variant, hdep] at hd
        obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
        obtain ⟨d'', rfl⟩ := fits_succ (d := d') (by omega)
        exact fits_tag_one hL hl.1 (by decide) (.arr _ _ (IHargs d'' js hl.2 (by omega) hjs))

theorem need_le_max (w : Value) {n d : Nat} (h : 4 * max w.depth n + 1 ≤ d) : jsonNeed w ≤ d ∧ 4 * n + 1 ≤ d := by
  have := need_le w
  have := Nat.le_max_left w.depth n
  have := Nat.le_max_right w.depth n
  omega

theorem leavesList_mem : ∀ {xs : List Value} {x : Value}, Value.leavesList L xs = true → x ∈ xs → x.leaves L = true
  | y :: ys, x, h, hx => by
    simp only [Value.leavesList, Bool.and_eq_true] at h
    rcases List.mem_cons.mp hx with rfl | hx
    · exact h.1
    · exact leavesList_mem h.2 hx

variable {env : Env} {F : Nat}

mutual
/-- **Schema-based JSON within the limits**, by the rules of decoding. -/
theorem Dec.fits (hL : L.SchemaBasedOk) {t : Ty} {v : Value} {x : Typed} {j : JSON} {d : Nat} :
    Dec env t v x → (encode x).leaves L = true → jsonNeed (encode x) ≤ d → toJsonF env F o t x = .ok j →
      Fits L d j
  | .intro hw hc, hl, hd, h => by
    rw [toJsonF_eq _ hw, toJsonC_hide] at h
    rw [encode_hide] at hl hd
    exact hc.fits hL hl hd h

theorem Core.fits (hL : L.SchemaBasedOk) {c : Ty} {v : Value} {x : Typed} {b : Bool} {j : JSON} {d : Nat} :
    Core env c v x → (encode x).leaves L = true → jsonNeed (encode x) ≤ d → toJsonC env F b o c x = .ok j →
      Fits L d j
  | .string _, hl, _, h | .time _, hl, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode, Value.leaves, Value.leavesList, Bool.and_true, Bool.and_eq_true, decide_eq_true_eq] at hl
    first | exact .str _ _ hl | exact .str _ _ hl.2
  | .bytes _, hl, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode, Value.leaves, decide_eq_true_eq] at hl
    refine .str _ _ ?_
    simp only [String.length_ofList, Bytes.base64_length]
    have := hL.1
    omega
  | .decimal _, hl, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode, Value.leaves] at hl
    have := numberFits_length hl
    have := hL.2.1
    exact .str _ _ (by rw [← String.length_toList]; omega)
  | .int _ hr, hl, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode, Value.leaves] at hl
    unfold intJson
    split
    · have := numberFits_length hl
      have := hL.2.1
      exact .str _ _ (by rw [← String.length_toList]; omega)
    · rename_i hk
      refine .num _ _ ?_
      simp only [numberFits, Bool.and_eq_true, decide_eq_true_eq] at hl
      simp only [tokenFits, Bool.and_eq_true, decide_eq_true_eq]
      have := intLit_length (by simpa using hk) hr
      have := hL.2.2
      exact ⟨by omega, hl.1⟩
  | .float (k := k) (x := f) hx, hl, _, h => by
    obtain ⟨n, m, q, rfl⟩ := roundLit_fin hx
    simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
    simp only [encode, encodeFloat, Value.leaves] at hl
    exact .num _ _ (spell_tokenFits hL.2.2 k _ hl)
  | .floatTag (k := k) (tag := tag) hx, hl, _, h => by
    have he := floatTag?_encode k hx
    simp only [encode, he, Value.leaves, Value.leavesList, Bool.and_true, decide_eq_true_eq] at hl
    unfold floatTag? at hx
    split at hx <;> cases hx <;>
    · simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
      exact .str _ _ (Nat.le_trans (by decide) hl)
  | .any _, hl, hd, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode] at hl hd
    exact selfDescribing_fits_need hL.selfDescribing _ hd hl
  | .array hi, hl, hd, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨js, hjs, rfl⟩ := h
    simp only [encode, Value.leaves] at hl
    simp only [encode, jsonNeed, Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    exact .arr _ _ (hi.fits hL hl (by omega) hjs)
  | .map he, hl, hd, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [encode, Value.leaves] at hl
    simp only [encode, jsonNeed, Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    have := he.fits hL hl (d := d') (by omega) hms
    exact .obj _ _ (fun m hm => (this m hm).1) (fun m hm => (this m hm).2)
  | .record _ hf, hl, hd, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [encode, Value.leaves] at hl
    simp only [encode, jsonNeed, Value.depth] at hd
    obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
    have := hf.fits hL hl (d := d') (by omega) hms
    exact .obj _ _ (fun m hm => (this m hm).1) (fun m hm => (this m hm).2)
  | .bare (closed := closed) (cases := cases) (tag := tag) hc, hl, hd, h => by
    simp only [encode, encodeList, Value.leaves, Value.leavesList, Bool.and_true, decide_eq_true_eq] at hl
    rw [toJsonC.eq_def] at h
    simp only at h
    cases b with
    | true => simp only [↓reduceIte, Except.ok.injEq] at h; subst h; exact .bool _ _
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h
      cases hn : nullArg? env F o (.variant closed cases) with
      | some a => simp only [hn, Except.ok.injEq] at h; subst h; exact .null _
      | none =>
        simp only [hn] at h
        split at h
        · simp only [Except.ok.injEq] at h; subst h; exact .str _ _ hl
        · simp only [hc, Except.ok.injEq] at h; subst h
          simp only [encode, encodeList, need_variant] at hd
          obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
          exact fits_tag hL hl
  | .recordCase hc hd', hl, hd, h => recordCase_fits hL hc (hd'.payloadFits hL rfl) hl hd h
  | .positional hc ha, hl, hd, h =>
    positional_fits hL hc ha.length_ys (fun d js hl hd h => ha.fits hL hl hd h) (fun t1 hts => ha.oneFits hL hts) hl hd h
  | .unknown (tag := tag) (args := args) _, hl, hd, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    simp only [encode, Value.leaves, Bool.and_eq_true, decide_eq_true_eq] at hl
    simp only [encode] at hd
    cases args with
    | nil =>
      rw [need_variant] at hd
      obtain ⟨d', rfl⟩ := fits_succ (d := d) (by omega)
      exact fits_tag hL hl.1
    | cons w ws =>
      have hne : (w :: ws) ≠ [] := by simp
      obtain ⟨d', rfl⟩ := fits_succ (d := d) (by have := need_args (t := tag) hne (List.mem_cons_self ..); omega)
      obtain ⟨d'', rfl⟩ := fits_succ (d := d') (by have := need_args (t := tag) hne (List.mem_cons_self ..); omega)
      refine fits_tag_one hL hl.1 (by decide) (.arr _ _ ?_)
      rw [JSON.selfDescribingList_eq]
      intro j hj
      obtain ⟨v, hv, rfl⟩ := List.mem_map.mp hj
      have hlv : v.leaves L = true := leavesList_mem hl.2 hv
      exact selfDescribing_fits_need hL.selfDescribing v (by have := need_args (t := tag) hne hv; omega) hlv

theorem Items.fits (hL : L.SchemaBasedOk) {t : Ty} {xs : List Value} {ys : List Typed} {i : Nat} {js : List JSON} {d : Nat} :
    Items env t xs ys → Value.leavesList L (encodeList ys) = true → 4 * Value.depthList (encodeList ys) + 1 ≤ d →
      toJsonItems env F o t i ys = .ok js → ∀ j ∈ js, Fits L d j
  | .nil, _, _, h => by simp only [toJsonItems, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hl, hd, h => by
    simp only [encodeList, Value.leavesList, Bool.and_eq_true] at hl
    simp only [encodeList, Value.depthList] at hd
    rw [toJsonItems_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro j' hj'
    rcases List.mem_cons.mp hj' with rfl | hj'
    · exact hx.fits hL hl.1 (need_le_max _ hd).1 (under_ok.mp hj)
    · exact hs.fits hL hl.2 (need_le_max _ hd).2 hjs j' hj'

theorem Entries.fits (hL : L.SchemaBasedOk) {t : Ty} {fs : List (String × Value)} {ys : List (String × Typed)}
    {ms : List (String × JSON)} {d : Nat} :
    Entries env t fs ys → Value.leavesFields L (encodeFields ys) = true →
      4 * Value.depthFields (encodeFields ys) + 1 ≤ d → toJsonEntries env F o t ys = .ok ms →
      ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2
  | .nil, _, _, h => by simp only [toJsonEntries, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hl, hd, h => by
    simp only [encodeFields, Value.leavesFields, Bool.and_eq_true, decide_eq_true_eq] at hl
    simp only [encodeFields, Value.depthFields] at hd
    rw [toJsonEntries_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact ⟨hl.1.1, hx.fits hL hl.1.2 (need_le_max _ hd).1 (under_ok.mp hj)⟩
    · exact hs.fits hL hl.2 (need_le_max _ hd).2 hms m hm

theorem Fields.fits (hL : L.SchemaBasedOk) {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} {ms : List (String × JSON)} {d : Nat} :
    Fields env closed fields fs ys → Value.leavesFields L (encodeFields ys) = true →
      4 * Value.depthFields (encodeFields ys) + 1 ≤ d → toJsonFields env F o fields ys = .ok ms →
      ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2
  | .nil, _, _, h => by simp only [toJsonFields, Except.ok.injEq] at h; subst h; simp
  | .keep hf hx hs, hl, hd, h => by
    simp only [encodeFields, Value.leavesFields, Bool.and_eq_true, decide_eq_true_eq] at hl
    simp only [encodeFields, Value.depthFields] at hd
    rw [toJsonFields_cons hf] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro m hm
    rcases List.mem_cons.mp hm with rfl | hm
    · exact ⟨hl.1.1, hx.fits hL hl.1.2 (need_le_max _ hd).1 (under_ok.mp hj)⟩
    · exact hs.fits hL hl.2 (need_le_max _ hd).2 hms m hm
  | .skip _ hs, hl, hd, h => hs.fits hL hl hd h

theorem Args.fits (hL : L.SchemaBasedOk) {ts : List Ty} {xs : List Value} {ys : List Typed} {tag : String} {i : Nat}
    {js : List JSON} {d : Nat} :
    Args env ts xs ys → Value.leavesList L (encodeList ys) = true → 4 * Value.depthList (encodeList ys) + 1 ≤ d →
      toJsonArgs env F o tag i ts ys = .ok js → ∀ j ∈ js, Fits L d j
  | .nil, _, _, h => by simp only [toJsonArgs, Except.ok.injEq] at h; subst h; simp
  | .cons hx hs, hl, hd, h => by
    simp only [encodeList, Value.leavesList, Bool.and_eq_true] at hl
    simp only [encodeList, Value.depthList] at hd
    rw [toJsonArgs_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    intro j' hj'
    rcases List.mem_cons.mp hj' with rfl | hj'
    · exact hx.fits hL hl.1 (need_le_max _ hd).1 (under_ok.mp hj)
    · exact hs.fits hL hl.2 (need_le_max _ hd).2 hjs j' hj'

theorem Args.oneFits (hL : L.SchemaBasedOk) {ts : List Ty} {xs : List Value} {ys : List Typed} {t : Ty} :
    Args env ts xs ys → ts = [t] →
      ∃ y, ys = [y] ∧ ∀ d j, (encode y).leaves L = true → jsonNeed (encode y) ≤ d →
        toJsonF env F o t y = .ok j → Fits L d j
  | .nil, hts => by cases hts
  | .cons hx .nil, hts => by
    simp only [List.cons.injEq, and_true] at hts
    exact ⟨_, rfl, fun d j hl hd h => hx.fits hL hl hd (hts ▸ h)⟩
  | .cons _ (.cons _ _), hts => by simp at hts

theorem Dec.payloadFits (hL : L.SchemaBasedOk) {t : Ty} {cl : Bool} {fields : List Field} {a : Value} {y : Typed} :
    Dec env t a y → t = .record cl fields → PayloadFits L env F o fields y
  | .intro hw hcore, ht0 => hcore.payloadFits hL (ht0 ▸ hw)

theorem Core.payloadFits (hL : L.SchemaBasedOk) {cl : Bool} {fields : List Field} {c : Ty} {s : Nat} {a : Value}
    {y : Typed} : Core env c a y → whnf env env.fuel (.record cl fields) = .ok (s, c) →
      PayloadFits L env F o fields (y.hide s)
  | .record (closed := cl') (fields := fields') (ys := ys) _ hf, hw => by
    rw [whnf_record] at hw
    have e := Prod.mk.inj (Except.ok.inj hw)
    have e2 : Ty.record cl fields = Ty.record cl' fields' := e.2
    injection e2 with ec ef
    have IH : ∀ d ms, Value.leavesFields L (encodeFields ys) = true →
        4 * Value.depthFields (encodeFields ys) + 1 ≤ d → toJsonFields env F o fields' ys = .ok ms →
        ∀ m ∈ ms, m.1.length ≤ L.maxStringLength ∧ Fits L d m.2 :=
      fun d ms hl hd h => hf.fits hL hl hd h
    subst ec ef
    rw [← e.1]
    exact ⟨ys, rfl, IH⟩
  | .string _, hw | .bytes _, hw | .int _ _, hw | .float _, hw
  | .floatTag _, hw | .decimal _, hw | .any _, hw | .time _, hw
  | .array _, hw | .map _, hw | .bare _, hw | .recordCase _ _, hw
  | .positional _ _, hw | .unknown _, hw => by
    rw [whnf_record] at hw; cases hw
end

/-! ## The theorem -/

/--
**Schema-based JSON within the limits** (§7, §16.3): the schema-based JSON of a decoded
value whose encoding is within the haus limits is within the JSON limits,
when the limits meet `SchemaBasedOk` (true of the defaults).
-/
theorem toJson_fits (hL : L.SchemaBasedOk) {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hfit : (encode x).fits L = true) (hj : toJson env t x = .ok j) :
    Fits L (jsonDepth L) j := by
  simp only [Value.fits, Bool.and_eq_true, decide_eq_true_eq] at hfit
  exact (decode_sound h).fits hL hfit.2 (by have := need_le (encode x); simp [jsonDepth]; omega) hj

end Schema
end Haus
