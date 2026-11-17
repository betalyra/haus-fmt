import Haus.Json.SchemaBasedWellFormed
import Haus.Json.Fits

/-!
# Schema-based JSON within the limits (spec §7, §16.3)

`toJson_fits`: the schema-based JSON of a decoded value whose encoding (§15) is
within the haus limits (`Value.fits`) is within the JSON limits (`Fits`,
nested at most `jsonDepth L = 4 · maxDepth + 1`), so the JSON text reader
reads it back.

It needs of the limits what the self-describing form does
(`Limits.SchemaBasedOk`, true of the defaults):

- **member names**: schema-based JSON's own (`_tag`, `_args`, `value`,
  `values`, and the self-describing form's inside an `Any`) have at most 6
  characters;
- **numbers in strings**: an `Int`, `Int64`, `UInt64` or `Decimal` is a
  string holding its literal, of at most `maxNumberLength` characters;
- **number tokens**: an integer of at most 32 bits and a float are JSON
  numbers, which the JSON limits count as written, as the haus limits count
  their literal (`numberFits` and `tokenFits` agree): an integer's literal is
  decimal, and every integer a haus literal can hold has a decimal form
  within the number limit (§7).

`Bytes` are base64, `4 · ⌈n / 3⌉` characters, at most the `2 · n` of their
hex (as `Value.fits` counts them) or 4. Nesting: schema-based JSON uses at most two
levels for a haus level (`{"_tag", "values": […]}`), and an `Any` its
self-describing form, four.
-/

namespace Haus

/-- What `toJson_fits` needs of the limits: what the self-describing form needs. -/
def Limits.SchemaBasedOk (L : Limits) : Prop := L.SelfDescribingOk

theorem Limits.schemaBasedOk_default : Limits.SchemaBasedOk {} := Limits.selfDescribingOk_default

theorem Limits.SchemaBasedOk.selfDescribing {L : Limits} (h : L.SchemaBasedOk) : L.SelfDescribingOk := h

theorem Bytes.base64_length : ∀ bs : List UInt8, (Bytes.base64 bs).length = 4 * ((bs.length + 2) / 3)
  | [] => rfl
  | [_] => by simp [Bytes.base64]
  | [_, _] => by simp [Bytes.base64]
  | _ :: _ :: _ :: rest => by simp [Bytes.base64, Bytes.base64_length rest]; omega

namespace Schema
open JSON

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
    (hc : caseOf? env cases tag = some (.record tag' cl fields)) (IH : PayloadFits L env F o fields y)
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
    (hc : caseOf? env cases tag = some (.positional tag' ts)) (hlen : ys.length = ts.length)
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
    · exact .num _ _ (numberFits_tokenFits hl)
  | .float (k := k) (x := f) hx, hl, _, h => by
    obtain ⟨n, m, q, rfl⟩ := roundLit_fin hx
    simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
    simp only [encode, encodeFloat, Value.leaves] at hl
    exact .num _ _ (numberFits_tokenFits hl)
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
