import Haus.Json.SchemaBased
import Haus.Json.Normal
import Haus.Schema.RoundTrip

/-!
# Schema-based JSON round trip (spec §16.3)

For every type of an environment and every value it decodes (§15):

- `schemaBased_round_trip`: reading the schema-based JSON of a decoded value gives the
  value back;
- `schemaBased_injective`: two decoded values with the same schema-based JSON are the
  same;
- `toJson_error`: writing a decoded value fails only for a record payload
  with a field named `_tag` or `_args`, which §16.3 says has no
  schema-based form.

The value must be well formed (`Value.wf`: normalized numbers, tags), as
every value the parser returns is: a `Decimal` is written as its literal and
an `Any` as its self-describing form. Floats rest on `floatLaw`: the spelling of a
decoded float rounds back to it. A `Maybe` that writes `null` never has an
argument whose JSON is `null` (`nullArg?_next`), whatever `chainNull`
computes.
-/

namespace Haus.Schema
open Haus

/-! ## The spelling of a float is a JSON number without `E` or `+` -/

theorem mem_stripTrailing {ds : Text} {c : Char} (h : c ∈ stripTrailing ds) : c ∈ ds := by
  unfold stripTrailing at h
  exact List.mem_reverse.mp ((List.dropWhile_sublist _).subset (List.mem_reverse.mp h))

/-- Characters a float's spelling is made of. -/
def SpellChar (c : Char) : Prop := isDigit c = true ∨ c = '.' ∨ c = 'e' ∨ c = '-'

theorem intText_chars (neg : Bool) (v : Nat) : ∀ c ∈ intText neg v, SpellChar c := by
  intro c hc
  unfold intText at hc
  rcases List.mem_append.mp hc with h | h
  · split at h
    · simp only [List.mem_singleton] at h; exact .inr (.inr (.inr h))
    · simp at h
  · exact .inl (RoundTrip.toDigits_decimal c h)

theorem layout_chars {ds : Text} (hd : ∀ c ∈ ds, isDigit c = true) (n : Int) :
    ∀ c ∈ layout ds n, SpellChar c := by
  intro c hc
  have zero : ∀ k, ∀ c ∈ List.replicate k '0', SpellChar c := fun k c h => by
    rw [List.eq_of_mem_replicate h]; exact .inl rfl
  unfold layout at hc
  simp only at hc
  split at hc
  · rcases List.mem_append.mp hc with h | h
    · exact .inl (hd c h)
    · exact zero _ c h
  split at hc
  · rcases List.mem_append.mp hc with h | h
    · exact .inl (hd c (List.mem_of_mem_take h))
    · rcases List.mem_cons.mp h with h | h
      · exact .inr (.inl h)
      · exact .inl (hd c (List.mem_of_mem_drop h))
  split at hc
  · rcases List.mem_cons.mp hc with h | h
    · rw [h]; exact .inl rfl
    rcases List.mem_cons.mp h with h | h
    · exact .inr (.inl h)
    rcases List.mem_append.mp h with h | h
    · exact zero _ c h
    · exact .inl (hd c h)
  · rcases List.mem_append.mp hc with h | h
    · rcases List.mem_append.mp h with h | h
      · exact .inl (hd c (List.mem_of_mem_take h))
      · split at h
        · rcases List.mem_cons.mp h with h | h
          · exact .inr (.inl h)
          · exact .inl (hd c (List.mem_of_mem_drop h))
        · simp at h
    · rcases List.mem_cons.mp h with h | h
      · exact .inr (.inr (.inl h))
      · exact intText_chars _ _ c h

/-- Strings made of `SpellChar`s. -/
def Spelled (s : String) : Prop := ∀ c ∈ s.toList, SpellChar c

theorem Spelled.append {a b : String} (ha : Spelled a) (hb : Spelled b) : Spelled (a ++ b) := by
  intro c hc
  simp only [String.toList_append, List.mem_append] at hc
  exact hc.elim (ha c) (hb c)

theorem spelled_zero : Spelled "0" := by intro c h; simp at h; rw [h]; exact .inl rfl
theorem spelled_minus : Spelled "-" := by intro c h; simp at h; exact .inr (.inr (.inr h))
theorem spelled_empty : Spelled "" := by intro c h; simp at h

theorem spell_chars (k : FloatType) (x : Flt) : Spelled (spell k x) := by
  unfold spell
  split
  · rename_i neg m q
    have hs : Spelled (if neg = true then "-" else "") := by
      cases neg
      · exact spelled_empty
      · exact spelled_minus
    simp only
    split
    · exact hs.append spelled_zero
    · split
      · refine hs.append ?_
        intro c hc
        rw [String.toList_ofList] at hc
        refine layout_chars ?_ _ c hc
        intro d hd
        exact RoundTrip.toDigits_decimal d (mem_stripTrailing hd)
      · exact hs.append spelled_zero
  · exact spelled_zero

theorem jsonToLit_self {t : Text} (h : ∀ c ∈ t, c ≠ '+' ∧ c ≠ 'E') : jsonToLit t = t := by
  unfold jsonToLit
  induction t with
  | nil => rfl
  | cons c cs ih =>
    have hc := h c (by simp)
    simp only [List.filterMap_cons, hc.1, hc.2, ↓reduceIte]
    rw [ih fun d hd => h d (by simp [hd])]

theorem jsonToLit_spell (k : FloatType) (x : Flt) : jsonToLit (spell k x).toList = (spell k x).toList := by
  apply jsonToLit_self
  intro c hc
  rcases spell_chars k x c hc with h | h | h | h
  · constructor <;> (intro e; subst e; simp [isDigit] at h)
  all_goals (subst h; decide)

/-! ## `null` -/

theorem maybeOf?_some {c a : Ty} (h : maybeOf? c = some a) :
    c = .variant true [.bare "None", .positional "Some" [a]] := by
  unfold maybeOf? at h
  split at h
  · cases h; rfl
  · cases h

theorem maybeAt?_some {o : String} {c a : Ty} (h : maybeAt? o c = some a) : maybeOf? c = some a := by
  unfold maybeAt? at h
  split at h
  · exact h
  · cases h

theorem maybeAt?_none {o : String} {c : Ty} (h : maybeOf? c = none) : maybeAt? o c = none := by
  unfold maybeAt?; split <;> simp [h]

theorem nullArg?_none {env : Env} {F : Nat} {o : String} {c : Ty} (h : maybeOf? c = none) :
    nullArg? env F o c = none := by
  simp [nullArg?, maybeAt?_none h]

theorem nullArg?_some {env : Env} {F : Nat} {o : String} {c a : Ty} (h : nullArg? env F o c = some a) :
    maybeOf? c = some a ∧ maybeAt? o c = some a ∧ usesNull env F o c = true := by
  unfold nullArg? at h
  split at h
  · rename_i a' ha
    by_cases hu : usesNull env F o c = true
    · simp only [hu, ↓reduceIte, Option.some.injEq] at h
      subst h; exact ⟨maybeAt?_some ha, ha, hu⟩
    · simp [hu] at h
  · cases h

/--
**A `Maybe` that writes `null` has an argument whose JSON is never `null`**:
the argument's type is not itself a `Maybe` that writes `null`.
-/
theorem nullArg?_next {env : Env} {F : Nat} {o : String} {c a c' : Ty} {s : Nat} (h : nullArg? env F o c = some a)
    (hw : whnf env env.fuel a = .ok (s, c')) : nullArg? env F (origin env o a) c' = none := by
  obtain ⟨-, hm, hu⟩ := nullArg?_some h
  have hn : nextMaybe env (o, c) = some (origin env o a, c') := by simp [nextMaybe, hm, hw]
  simp only [usesNull, hn, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true, Bool.and_eq_false_iff] at hu
  unfold nullArg?
  split
  · rename_i a' ha'
    rcases hu.2 with h1 | h1
    · simp [ha'] at h1
    · have : usesNull env F (origin env o a) c' = false := by simp [usesNull, h1]
      simp [this]
  · rfl

theorem nullArg?_isBool {env : Env} {F : Nat} {o : String} {c : Ty} (h : isBool c = true) : nullArg? env F o c = none := by
  unfold isBool at h
  split at h
  · exact nullArg?_none rfl
  · cases h

theorem nullArg?_open {env : Env} {F : Nat} {o : String} {cases : List Case} : nullArg? env F o (.variant false cases) = none :=
  nullArg?_none rfl

theorem nullArg?_notVariant {env : Env} {F : Nat} {o : String} {c : Ty} (h : ∀ cl cs, c ≠ .variant cl cs) : nullArg? env F o c = none := by
  apply nullArg?_none
  unfold maybeOf?
  split
  · exact absurd rfl (h _ _)
  · rfl

theorem boolTy_isBool {env : Env} {t c : Ty} {s : Nat} (h : boolTy env t = true)
    (hw : whnf env env.fuel t = .ok (s, c)) : isBool c = true := by
  simp only [boolTy, hw, Bool.and_eq_true] at h
  exact h.2

theorem selfDescribing_ne_null (v : Value) : JSON.selfDescribing v ≠ .null := by
  cases v <;> simp [JSON.selfDescribing, JSON.tagged]

/-! ## Unfolding -/

theorem isBool_eq {c : Ty} (h : isBool c = true) : c = .variant true [.bare "False", .bare "True"] := by
  unfold isBool at h
  split at h
  · rfl
  · cases h

theorem caseOf?_mem {cases : List Case} {tag : String} {cs : Case} (h : caseOf? cases tag = some cs) :
    cs ∈ cases ∧ cs.tag = tag := by
  unfold caseOf? at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

theorem caseOf?_bool {tag : String} {cs : Case} (h : caseOf? [.bare "False", .bare "True"] tag = some cs) :
    tag = "False" ∨ tag = "True" := by
  obtain ⟨hm, ht⟩ := caseOf?_mem h
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl <;> simp [Case.tag] at ht <;> simp [← ht]

theorem caseOf?_maybe {a : Ty} {tag : String} {cs : Case}
    (h : caseOf? [.bare "None", .positional "Some" [a]] tag = some cs) :
    (tag = "None" ∧ cs = .bare "None") ∨ (tag = "Some" ∧ cs = .positional "Some" [a]) := by
  obtain ⟨hm, ht⟩ := caseOf?_mem h
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hm
  rcases hm with rfl | rfl <;> simp [Case.tag] at ht <;> simp [← ht]

theorem isEnum_bare {closed : Bool} {cases : List Case} {tag : String} {cs : Case}
    (he : isEnum (.variant closed cases) = true) (h : caseOf? cases tag = some cs) : cs.isBare = true := by
  unfold isEnum at he
  split at he
  · rename_i heq
    cases heq
    exact List.all_eq_true.mp he cs (caseOf?_mem h).1
  · cases he

theorem toJsonF_eq {env : Env} {F : Nat} {o : String} {t c : Ty} {s : Nat} (x : Typed) (hw : whnf env env.fuel t = .ok (s, c)) :
    toJsonF env F o t x = toJsonC env F (boolTy env t) (origin env o t) c x := by
  simp [toJsonF, hw]

theorem toJsonC_hide (env : Env) (F : Nat) (b : Bool) (o : String) (c : Ty) (x : Typed) :
    ∀ s, toJsonC env F b o c (x.hide s) = toJsonC env F b o c x
  | 0 => rfl
  | s + 1 => by simp only [Typed.hide, toJsonC]; exact toJsonC_hide env F b o c x s

theorem fromJsonF_eq {env : Env} {F : Nat} {o : String} {t c : Ty} {s : Nat} (j : JSON) (hw : whnf env env.fuel t = .ok (s, c)) :
    fromJsonF env F o t j = hidden s c (fromJsonC env F (boolTy env t) (origin env o t) c j) := by
  rw [fromJsonF.eq_def]; simp [hw]

theorem fromJsonC_none {env : Env} {F : Nat} {o : String} {b : Bool} {c : Ty} (j : JSON) (h : nullArg? env F o c = none) :
    fromJsonC env F b o c j = readCore env F b o c j := by
  rw [fromJsonC.eq_def]; simp [h]

theorem fromJsonC_null {env : Env} {F : Nat} {o : String} {b : Bool} {c a : Ty} (h : nullArg? env F o c = some a) :
    fromJsonC env F b o c .null = .ok (.case "None" []) := by
  rw [fromJsonC.eq_def]; simp [h]

theorem fromJsonC_some {env : Env} {F : Nat} {o : String} {b : Bool} {c a c' : Ty} {s' : Nat} {j : JSON}
    (h : nullArg? env F o c = some a) (hj : j ≠ .null) (hw : whnf env env.fuel a = .ok (s', c')) :
    fromJsonC env F b o c j = (fromJsonF env F o a j).map fun y => .case "Some" [y] := by
  rw [fromJsonF_eq j hw, fromJsonC_none j (nullArg?_next h hw), fromJsonC.eq_def]
  cases j with
  | null => exact absurd rfl hj
  | _ => simp [h, hw]

theorem toJsonItems_cons {env : Env} {F : Nat} {o : String} {t : Ty} {i : Nat} {x : Typed} {xs : List Typed} :
    toJsonItems env F o t i (x :: xs) = (do
      let j ← under (.index i) (toJsonF env F o t x)
      let js ← toJsonItems env F o t (i + 1) xs
      return j :: js) := by
  rw [toJsonItems]; rfl

theorem toJsonEntries_cons {env : Env} {F : Nat} {o : String} {t : Ty} {k : String} {x : Typed} {fs : List (String × Typed)} :
    toJsonEntries env F o t ((k, x) :: fs) = (do
      let j ← under (.key k) (toJsonF env F o t x)
      let js ← toJsonEntries env F o t fs
      return (k, j) :: js) := by
  rw [toJsonEntries]; rfl

theorem toJsonFields_cons {env : Env} {F : Nat} {o : String} {fields : List Field} {k : String} {x : Typed}
    {fs : List (String × Typed)} {f : Field} (hf : fieldOf? fields k = some f) :
    toJsonFields env F o fields ((k, x) :: fs) = (do
      let j ← under (.key k) (toJsonF env F o f.ty x)
      let js ← toJsonFields env F o fields fs
      return (k, j) :: js) := by
  rw [toJsonFields]; simp only [hf]; rfl

theorem toJsonArgs_cons {env : Env} {F : Nat} {o : String} {tag : String} {i : Nat} {t : Ty} {ts : List Ty} {x : Typed}
    {xs : List Typed} :
    toJsonArgs env F o tag i (t :: ts) (x :: xs) = (do
      let j ← under (.arg tag i) (toJsonF env F o t x)
      let js ← toJsonArgs env F o tag (i + 1) ts xs
      return j :: js) := by
  rw [toJsonArgs]; rfl

theorem encodeFields_keys : ∀ ys : List (String × Typed), (encodeFields ys).map (·.1) = ys.map (·.1)
  | [] => rfl
  | (k, y) :: ys => by simp [encodeFields, encodeFields_keys ys]

theorem toJsonFields_keys {env : Env} {F : Nat} {o : String} {fields : List Field} :
    ∀ {ys : List (String × Typed)} {ms : List (String × JSON)}, toJsonFields env F o fields ys = .ok ms →
      ms.map (·.1) = ys.map (·.1)
  | [], ms, h => by simp only [toJsonFields, Except.ok.injEq] at h; subst h; rfl
  | (k, y) :: ys, ms, h => by
    unfold toJsonFields at h
    split at h
    · obtain ⟨j, -, h⟩ := bind_ok.mp h
      obtain ⟨ms', hms, h⟩ := bind_ok.mp h
      simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
      simp [toJsonFields_keys hms]
    · cases h

/-! ## The round trip -/

theorem notVariant_string : ∀ cl cs, Ty.string ≠ .variant cl cs := by intros; simp
theorem missingJ?_eq {fields : List Field} {ms : List (String × JSON)} {fs : List (String × Value)}
    (h : ms.map (·.1) = fs.map (·.1)) : missingJ? fields ms = missing? fields fs := by
  unfold missingJ? missing?
  congr 2
  funext f
  have : ms.any (·.1 == f.key) = fs.any (·.1 == f.key) := by
    rw [show ms.any (·.1 == f.key) = (ms.map (·.1)).any (· == f.key) by simp [List.any_map, Function.comp_def],
      show fs.any (·.1 == f.key) = (fs.map (·.1)).any (· == f.key) by simp [List.any_map, Function.comp_def], h]
  rw [this]

theorem missingJ?_cons {fields : List Field} {ms : List (String × JSON)} (m : String × JSON)
    (h : missingJ? fields ms = none) : missingJ? fields (m :: ms) = none := by
  simp only [missingJ?, Option.map_eq_none_iff, List.find?_eq_none, Bool.and_eq_true, Bool.not_eq_true',
    List.any_cons, Bool.or_eq_false_iff, not_and, Bool.not_eq_false] at h ⊢
  intro f hf ho _
  exact h f hf ho

theorem Args.length_ys {env : Env} {ts : List Ty} {xs : List Value} {ys : List Typed} :
    Args env ts xs ys → ys.length = ts.length
  | .nil => rfl
  | .cons _ h => by simp [h.length_ys]

theorem toJsonArgs_length {env : Env} {F : Nat} {o : String} {tag : String} :
    ∀ {i : Nat} {ts : List Ty} {ys : List Typed} {js : List JSON}, ys.length = ts.length →
      toJsonArgs env F o tag i ts ys = .ok js → js.length = ys.length
  | _, [], [], js, _, h => by simp only [toJsonArgs, Except.ok.injEq] at h; subst h; rfl
  | _, _ :: _, [], _, hl, _ | _, [], _ :: _, _, hl, _ => by simp at hl
  | i, t :: ts, y :: ys, js, hl, h => by
    rw [toJsonArgs_cons] at h
    obtain ⟨j, -, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    simp [toJsonArgs_length (by simpa using hl) hjs]

theorem map_ne_null {α : Type} {r : Except Error α} {f : α → JSON} (hf : ∀ a, f a ≠ .null) : r.map f ≠ .ok .null := by
  cases r <;> simp [Except.map, hf]

theorem under_map_ne_null {α : Type} {s : Seg} {r : Except Error α} {f : α → JSON} (hf : ∀ a, f a ≠ .null) :
    (under s r).map f ≠ .ok .null := map_ne_null hf

/-- **Only a `Maybe` that writes `null` writes `null`.** -/
theorem toJsonC_null {env : Env} {F : Nat} {o : String} {b : Bool} {c : Ty} (hn : nullArg? env F o c = none) :
    ∀ x : Typed, toJsonC env F b o c x ≠ .ok .null
  | .secret x => by simp only [toJsonC]; exact toJsonC_null hn x
  | .str _ | .bytes _ | .int _ | .float _ _ | .decimal _ | .time _ _ => by
    cases c <;> simp [toJsonC, mismatch, fail, intJson] <;> (try split) <;> (try simp [floatJson]) <;>
      (try split <;> simp)
  | .any v => by cases c <;> simp [toJsonC, mismatch, fail, selfDescribing_ne_null]
  | .arr _ | .map _ | .record _ => by
    cases c <;> simp only [toJsonC, mismatch, fail, ne_eq, reduceCtorEq, not_false_eq_true] <;>
      exact map_ne_null (by simp)
  | .unknown _ _ => by cases c <;> simp [toJsonC, mismatch, fail, unknownJson]
  | .case tag args => by
    rw [toJsonC.eq_def]
    cases c <;> simp only [mismatch, fail, ne_eq, reduceCtorEq, not_false_eq_true]
    rename_i closed cases
    cases b
    · simp only [Bool.false_eq_true, ↓reduceIte, hn]
      split
      · simp
      · split <;> (try split) <;> first | simp | exact map_ne_null (by simp)
    · simp

theorem readFields_tag {env : Env} {F : Nat} {o : String} {closed : Bool} {fields : List Field} {x : JSON}
    {ms : List (String × JSON)} :
    readFields env F o closed fields true (("_tag", x) :: ms) = readFields env F o closed fields true ms := by
  rw [readFields.eq_def]; simp

theorem whnf_record {env : Env} {cl : Bool} {fields : List Field} :
    whnf env env.fuel (.record cl fields) = .ok (0, .record cl fields) := by
  simp [whnf, peel]

theorem isEnum_bool : isEnum (.variant true [.bare "False", .bare "True"]) = true := rfl

theorem isEnum_false {closed : Bool} {cases : List Case} {tag : String} {cs : Case}
    (hc : caseOf? cases tag = some cs) (hb : cs.isBare = false) : isEnum (.variant closed cases) = false := by
  cases h : isEnum (.variant closed cases)
  · rfl
  · rw [isEnum_bare h hc] at hb; cases hb

/-- `Tag { … }`, given the round trip of its fields. -/
theorem recordCase_roundTrip {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {cl : Bool} {fields : List Field} {y : Typed} {b : Bool} {j : JSON}
    (hc : caseOf? cases tag = some (.record tag' cl fields))
    (hb : b = true → isBool (.variant closed cases) = true)
    (IH : hasReservedField fields = false → ∃ ys, y = .record ys ∧ ∀ ms, toJsonFields env F o fields ys = .ok ms →
      missingJ? fields ms = none ∧ readFields env F o cl fields true ms = .ok ys)
    (h : toJsonC env F b o (.variant closed cases) (.case tag [y]) = .ok j) :
    fromJsonC env F b o (.variant closed cases) j = .ok (.case tag [y]) := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    cases isBool_eq (hb rfl)
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h
    cases hn : nullArg? env F o (.variant closed cases) with
    | some a' =>
      obtain ⟨hm', -, -⟩ := nullArg?_some hn
      cases maybeOf?_some hm'
      rcases caseOf?_maybe hc with ⟨-, h2⟩ | ⟨-, h2⟩ <;> cases h2
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      by_cases ht : hasReservedField fields = true
      · cases y <;> simp [hn, he, hc, ht, mismatch, fail] at h
      · obtain ⟨ys, rfl, hys⟩ := IH (by simpa using ht)
        simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc, ht] at h
        obtain ⟨ms, hms, rfl⟩ := map_ok.mp h
        obtain ⟨hk, hr⟩ := hys ms (under_ok.mp hms)
        rw [fromJsonC_none _ hn, readCore.eq_def]
        simp only [Bool.false_eq_true, ↓reduceIte, he, List.lookup, beq_self_eq_true, hc, ht,
          missingJ?_cons _ hk, readFields_tag, hr, under, Except.map]

/-- `Tag T1 … Tn`, `Some` of a `Maybe` that uses `null` included, given the round trip of the arguments. -/
theorem positional_roundTrip {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {ts : List Ty} {ys : List Typed} {b : Bool} {j : JSON}
    (hc : caseOf? cases tag = some (.positional tag' ts))
    (hb : b = true → isBool (.variant closed cases) = true) (hl : ys.length = ts.length)
    (IHargs : ∀ js, toJsonArgs env F o tag 0 ts ys = .ok js → readArgs env F o tag 0 ts js = .ok ys)
    (IHone : ∀ t1, ts = [t1] → ∃ y, ys = [y] ∧ ∀ j, toJsonF env F o t1 y = .ok j → fromJsonF env F o t1 j = .ok y)
    (h : toJsonC env F b o (.variant closed cases) (.case tag ys) = .ok j) :
    fromJsonC env F b o (.variant closed cases) j = .ok (.case tag ys) := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    cases isBool_eq (hb rfl)
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
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
        cases hw : whnf env env.fuel a with
        | error r => simp [hw, fail] at h
        | ok p =>
          obtain ⟨s', c'⟩ := p
          simp only [hw] at h
          have hj : j ≠ .null := fun e => toJsonC_null (nullArg?_next hn hw) y (e ▸ h)
          rw [fromJsonC_some hn hj hw, hy j (by rw [toJsonF_eq _ hw]; exact h)]
          rfl
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      rw [fromJsonC_none _ hn, readCore.eq_def]
      match ts, hl, IHone, IHargs, h with
      | [], hl, _, _, h =>
        cases ys with
        | cons _ _ => simp at hl
        | nil =>
          simp only [Except.ok.injEq] at h; subst h
          simp [he, hc, List.lookup]
      | [t1], _, IHone, _, h =>
        obtain ⟨y, rfl, hy⟩ := IHone t1 rfl
        obtain ⟨j1, hj1, rfl⟩ := map_ok.mp h
        have hj1' : toJsonF env F o t1 y = .ok j1 := under_ok.mp hj1
        simp only [Bool.false_eq_true, ↓reduceIte, he, List.lookup, beq_self_eq_true, hc, List.length_cons,
          List.length_nil]
        rw [memberValue.eq_def]
        simp only [show ("_tag" = "value") = False by decide, ↓reduceIte]
        rw [memberValue.eq_def]
        simp [hy j1 hj1', under, Except.map]
      | t1 :: t2 :: rest, hl, _, IHargs, h =>
        obtain ⟨js, hjs, rfl⟩ := map_ok.mp h
        have hlen : js.length = (t1 :: t2 :: rest).length := (toJsonArgs_length hl hjs).trans hl
        simp only [Bool.false_eq_true, ↓reduceIte, he, List.lookup, beq_self_eq_true, hc, List.length_cons,
          List.length_nil]
        rw [memberValues.eq_def]
        simp only [show ("_tag" = "values") = False by decide, ↓reduceIte]
        rw [memberValues.eq_def]
        simp [hlen, IHargs js hjs, Except.map]

variable {env : Env} {F : Nat}

mutual
/-- **Schema-based round trip**, by the rules of decoding: the schema-based JSON of a decoded value reads back as it. -/
theorem Dec.roundTrip {t : Ty} {v : Value} {x : Typed} {j : JSON} :
    Dec env t v x → v.wf = true → toJsonF env F o t x = .ok j → fromJsonF env F o t j = .ok x
  | .intro hw hc, hv, h => by
    rw [toJsonF_eq _ hw, toJsonC_hide] at h
    rw [fromJsonF_eq _ hw]
    exact hidden_of (hc.roundTrip hv (fun hb => boolTy_isBool hb hw) h)

theorem Core.roundTrip {c : Ty} {v : Value} {x : Typed} {b : Bool} {j : JSON} :
    Core env c v x → v.wf = true → (b = true → isBool c = true) → toJsonC env F b o c x = .ok j →
      fromJsonC env F b o c j = .ok x
  | .string s, _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
  | .bytes bs, _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [Bytes.base64_decode_encode]
  | .int (k := k) (n := n) _ hr, _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [intOfJson, intJson]
    cases k.asString <;> simp [wholeLit_intLit, hr]
  | .float (k := k) (a := a) (x := f) hx, _, _, h => by
    obtain ⟨n, m, q, rfl⟩ := roundLit_fin hx
    simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [floatOfJson, jsonToLit_spell, String.ofList_toList, floatLaw k a _ hx]
  | .floatTag (k := k) (tag := tag) hx, _, _, h => by
    unfold floatTag? at hx
    split at hx <;> cases hx <;>
    · simp only [toJsonC, floatJson, Except.ok.injEq] at h; subst h
      rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
      simp [floatOfJson]
  | .decimal a, hv, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp only [Value.wf] at hv
    simp [decimalOf, isNormalLit_json hv, normalizeNumber_normal hv]
  | .any v, hv, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [JSON.fromSelfDescribing_selfDescribing v hv]
  | .time (k := k) (s := s) hc, _, _, h => by
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [hc]
  | .array (t := t) (xs := xs) (ys := ys) hi, hv, _, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨js, hjs, rfl⟩ := h
    simp only [Value.wf] at hv
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [hi.roundTrip hv hjs, Except.map]
  | .map (t := t) (fs := fs) (ys := ys) he, hv, _, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [Value.wf] at hv
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    simp [he.roundTrip hv hms, Except.map]
  | .record (closed := closed) (fields := fields) (fs := fs) (ys := ys) hm hf, hv, _, h => by
    simp only [toJsonC, map_ok] at h
    obtain ⟨ms, hms, rfl⟩ := h
    simp only [Value.wf] at hv
    rw [fromJsonC_none _ (nullArg?_notVariant (by simp)), readCore.eq_def]
    have hk : missingJ? fields ms = none := by
      rw [missingJ?_eq ((toJsonFields_keys hms).trans (encodeFields_keys ys).symm)]
      exact hf.missing hm
    simp [hk, hf.roundTrip hv false (by simp) hms, Except.map]
  | .bare (closed := closed) (cases := cases) (tag := tag) hc, hv, hb, h => by
    rw [toJsonC.eq_def] at h
    simp only at h
    cases b with
    | true =>
      have hB := hb rfl
      cases isBool_eq hB
      simp only [↓reduceIte, Except.ok.injEq] at h; subst h
      rw [fromJsonC_none _ (nullArg?_isBool hB), readCore.eq_def]
      rcases caseOf?_bool hc with rfl | rfl <;> simp
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h
      cases hn : nullArg? env F o (.variant closed cases) with
      | some a =>
        simp only [hn] at h
        obtain ⟨hm, -, -⟩ := nullArg?_some hn
        cases maybeOf?_some hm
        rcases caseOf?_maybe hc with ⟨rfl, -⟩ | ⟨-, h2⟩
        · simp only [Except.ok.injEq] at h; subst h
          rw [fromJsonC_null hn]
        · cases h2
      | none =>
        simp only [hn] at h
        rw [fromJsonC_none _ hn, readCore.eq_def]
        by_cases he : isEnum (.variant closed cases) = true
        · simp only [he, ↓reduceIte, Except.ok.injEq] at h; subst h
          simp [he, hc]
        · simp only [he, Bool.false_eq_true, ↓reduceIte, hc, Except.ok.injEq] at h; subst h
          simp [he, hc]
  | .recordCase hc hd, hv, hb, h => by
    simp only [Value.wf, Value.wfList, Bool.and_eq_true, and_true] at hv
    exact recordCase_roundTrip hc hb (fun ht => hd.payload rfl hv.2 ht) h
  | .positional hc ha, hv, hb, h => by
    simp only [Value.wf, Bool.and_eq_true] at hv
    exact positional_roundTrip hc hb ha.length_ys (fun js h => ha.roundTrip hv.2 h) (fun t1 hts => ha.one hts hv.2) h
  | .unknown (cases := cases) (tag := tag) (args := args) hc, hv, hb, h => by
    simp only [Value.wf, Bool.and_eq_true] at hv
    have hbf : b = false := by
      cases b
      · rfl
      · exact absurd (hb rfl) (by simp [isBool])
    subst hbf
    simp only [toJsonC, Except.ok.injEq] at h; subst h
    rw [fromJsonC_none _ nullArg?_open, readCore.eq_def]
    have he : isEnum (.variant false cases) = false := rfl
    cases args with
    | nil => simp [unknownJson, he, hc, hv.1, List.lookup]
    | cons w ws =>
      have hl := JSON.fromSelfDescribingList_selfDescribingList (w :: ws) hv.2
      simp only [JSON.selfDescribingList] at hl
      simp [unknownJson, he, hc, hv.1, List.lookup, JSON.selfDescribingList, hl]

theorem Items.roundTrip {t : Ty} {xs : List Value} {ys : List Typed} {i : Nat} {js : List JSON} :
    Items env t xs ys → Value.wfList xs = true → toJsonItems env F o t i ys = .ok js →
      readItems env F o t i js = .ok ys
  | .nil, _, h => by
    simp only [toJsonItems, Except.ok.injEq] at h; subst h
    rw [readItems.eq_def]
  | .cons hx hs, hv, h => by
    simp only [Value.wfList, Bool.and_eq_true] at hv
    rw [toJsonItems_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    rw [readItems.eq_def]
    simp [hx.roundTrip hv.1 (under_ok.mp hj), hs.roundTrip hv.2 hjs, under, bind, Except.bind, pure, Except.pure]

theorem Entries.roundTrip {t : Ty} {fs : List (String × Value)} {ys : List (String × Typed)}
    {ms : List (String × JSON)} :
    Entries env t fs ys → Value.wfFields fs = true → toJsonEntries env F o t ys = .ok ms →
      readEntries env F o t ms = .ok ys
  | .nil, _, h => by
    simp only [toJsonEntries, Except.ok.injEq] at h; subst h
    rw [readEntries.eq_def]
  | .cons hx hs, hv, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    rw [toJsonEntries_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    rw [readEntries.eq_def]
    simp [hx.roundTrip hv.1 (under_ok.mp hj), hs.roundTrip hv.2 hms, under, bind, Except.bind, pure, Except.pure]

theorem Fields.roundTrip {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} {ms : List (String × JSON)} :
    Fields env closed fields fs ys → Value.wfFields fs = true → ∀ skip : Bool,
      (skip = true → hasReservedField fields = false) → toJsonFields env F o fields ys = .ok ms →
      readFields env F o closed fields skip ms = .ok ys
  | .nil, _, _, _, h => by
    simp only [toJsonFields, Except.ok.injEq] at h; subst h
    rw [readFields.eq_def]
  | .keep (k := k) hf hx hs, hv, skip, hsk, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    rw [toJsonFields_cons hf] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨ms', hms, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    have hs' : (skip && k == "_tag") = false := by
      cases skip
      · rfl
      · have hk := (List.find?_some hf)
        have hm := List.mem_of_find?_eq_some hf
        simp only [beq_iff_eq] at hk
        have := hsk rfl
        simp only [hasReservedField, List.any_eq_false] at this
        simp only [Bool.true_and, beq_eq_false_iff_ne, ne_eq]
        intro he; exact this _ hm (by simp [hk, he])
    rw [readFields.eq_def]
    simp [hs', hf, hx.roundTrip hv.1 (under_ok.mp hj), hs.roundTrip hv.2 skip hsk hms, under, bind, Except.bind,
      pure, Except.pure]
  | .skip _ hs, hv, skip, hsk, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at hv
    exact hs.roundTrip hv.2 skip hsk h

theorem Args.roundTrip {ts : List Ty} {xs : List Value} {ys : List Typed} {tag : String} {i : Nat}
    {js : List JSON} :
    Args env ts xs ys → Value.wfList xs = true → toJsonArgs env F o tag i ts ys = .ok js →
      readArgs env F o tag i ts js = .ok ys
  | .nil, _, h => by
    simp only [toJsonArgs, Except.ok.injEq] at h; subst h
    rw [readArgs.eq_def]
  | .cons hx hs, hv, h => by
    simp only [Value.wfList, Bool.and_eq_true] at hv
    rw [toJsonArgs_cons] at h
    obtain ⟨j, hj, h⟩ := bind_ok.mp h
    obtain ⟨js', hjs, h⟩ := bind_ok.mp h
    simp only [pure, Except.pure, Except.ok.injEq] at h; subst h
    rw [readArgs.eq_def]
    simp [hx.roundTrip hv.1 (under_ok.mp hj), hs.roundTrip hv.2 hjs, under, bind, Except.bind, pure, Except.pure]

/-- One positional argument: its round trip. -/
theorem Args.one {ts : List Ty} {xs : List Value} {ys : List Typed} {t : Ty} :
    Args env ts xs ys → ts = [t] → Value.wfList xs = true →
      ∃ y, ys = [y] ∧ ∀ j, toJsonF env F o t y = .ok j → fromJsonF env F o t j = .ok y
  | .nil, hts, _ => by cases hts
  | .cons hx .nil, hts, hv => by
    simp only [List.cons.injEq, and_true] at hts
    simp only [Value.wfList, Bool.and_eq_true, and_true] at hv
    exact ⟨_, rfl, fun j h => hts ▸ hx.roundTrip hv (hts ▸ h)⟩
  | .cons _ (.cons _ _), hts, _ => by simp at hts

/-- A record payload: what `Tag { … }` decodes its record to, and its fields' round trip. -/
theorem Dec.payload {t : Ty} {cl : Bool} {fields : List Field} {a : Value} {y : Typed} :
    Dec env t a y → t = .record cl fields → a.wf = true → hasReservedField fields = false →
      ∃ ys, y = .record ys ∧ ∀ ms, toJsonFields env F o fields ys = .ok ms →
        missingJ? fields ms = none ∧ readFields env F o cl fields true ms = .ok ys
  | .intro hw hcore, ht0, ha, ht => hcore.payload (ht0 ▸ hw) ha ht

theorem Core.payload {cl : Bool} {fields : List Field} {c : Ty} {s : Nat} {a : Value} {y : Typed} :
    Core env c a y → whnf env env.fuel (.record cl fields) = .ok (s, c) → a.wf = true →
      hasReservedField fields = false →
      ∃ ys, y.hide s = .record ys ∧ ∀ ms, toJsonFields env F o fields ys = .ok ms →
        missingJ? fields ms = none ∧ readFields env F o cl fields true ms = .ok ys
  | .record (closed := cl') (fields := fields') (ys := ys) hm hf, hw, ha, ht => by
    rw [whnf_record] at hw
    have e := Prod.mk.inj (Except.ok.inj hw)
    have e2 : Ty.record cl fields = Ty.record cl' fields' := e.2
    injection e2 with ec ef
    simp only [Value.wf] at ha
    have IH : ∀ ms, toJsonFields env F o fields' ys = .ok ms → readFields env F o cl' fields' true ms = .ok ys :=
      fun ms h => hf.roundTrip ha true (fun _ => ef ▸ ht) h
    subst ec ef
    rw [← e.1]
    refine ⟨ys, rfl, fun ms h => ⟨?_, IH ms h⟩⟩
    rw [missingJ?_eq ((toJsonFields_keys h).trans (encodeFields_keys _).symm)]
    exact hf.missing hm
  | .string _, hw, _, _ | .bytes _, hw, _, _ | .int _ _, hw, _, _ | .float _, hw, _, _
  | .floatTag _, hw, _, _ | .decimal _, hw, _, _ | .any _, hw, _, _ | .time _, hw, _, _
  | .array _, hw, _, _ | .map _, hw, _, _ | .bare _, hw, _, _ | .recordCase _ _, hw, _, _
  | .positional _ _, hw, _, _ | .unknown _, hw, _, _ => by
    rw [whnf_record] at hw; cases hw
end

/-! ## Writing fails only for `_tag` and `_args` fields -/

theorem under_error {α : Type} {sg : Seg} {r : Except Error α} {e : Error} (h : under sg r = .error e) :
    ∃ e', r = .error e' ∧ e.reason = e'.reason := by
  cases r with
  | error e' => simp only [under, Except.error.injEq] at h; subst h; exact ⟨e', rfl, rfl⟩
  | ok _ => simp [under] at h

theorem map_error {α β : Type} {r : Except Error α} {f : α → β} {e : Error} (h : r.map f = .error e) :
    r = .error e := by
  cases r <;> simp_all [Except.map]

theorem bind_error {α β : Type} {r : Except Error α} {f : α → Except Error β} {e : Error}
    (h : (r >>= f) = .error e) : r = .error e ∨ ∃ x, r = .ok x ∧ f x = .error e := by
  cases r <;> simp_all [bind, Except.bind]

/-- The only error writing can give: a record payload with a field named `_tag` or `_args`. -/
def TagErr (e : Error) : Prop := e.reason = reservedFieldReason

theorem recordCase_err {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {cl : Bool} {fields : List Field} {y : Typed} {b : Bool} {e : Error}
    (hc : caseOf? cases tag = some (.record tag' cl fields))
    (hb : b = true → isBool (.variant closed cases) = true)
    (IH : ∃ ys, y = .record ys ∧ ∀ e, toJsonFields env F o fields ys = .error e → TagErr e)
    (h : toJsonC env F b o (.variant closed cases) (.case tag [y]) = .error e) : TagErr e := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    cases isBool_eq (hb rfl)
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
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
      · simp only [ht, ↓reduceIte, Except.error.injEq] at h; subst h; rfl
      · simp only [ht, Bool.false_eq_true, ↓reduceIte] at h
        obtain ⟨e', he', hr⟩ := under_error (map_error h)
        exact hr.trans (hys e' he')

theorem positional_err {env : Env} {F : Nat} {o : String} {closed : Bool} {cases : List Case} {tag tag' : String}
    {ts : List Ty} {ys : List Typed} {b : Bool} {e : Error}
    (hc : caseOf? cases tag = some (.positional tag' ts))
    (hb : b = true → isBool (.variant closed cases) = true)
    (IHargs : ∀ e, toJsonArgs env F o tag 0 ts ys = .error e → TagErr e)
    (IHone : ∀ t1, ts = [t1] → ∃ y, ys = [y] ∧ ∀ e, toJsonF env F o t1 y = .error e → TagErr e)
    (h : toJsonC env F b o (.variant closed cases) (.case tag ys) = .error e) : TagErr e := by
  rw [toJsonC.eq_def] at h
  simp only at h
  cases b with
  | true =>
    cases isBool_eq (hb rfl)
    have := isEnum_bare isEnum_bool hc
    simp [Case.isBare] at this
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
        exact hy e h
    | none =>
      have he := isEnum_false (closed := closed) hc rfl
      simp only [hn, he, Bool.false_eq_true, ↓reduceIte, hc] at h
      match ts, IHone, IHargs, h with
      | [], _, _, h => simp at h
      | [t1], IHone, _, h =>
        obtain ⟨y, rfl, hy⟩ := IHone t1 rfl
        obtain ⟨e', he', hr⟩ := under_error (map_error h)
        exact hr.trans (hy e' he')
      | t1 :: t2 :: rest, _, IHargs, h => exact IHargs e (map_error h)

variable {env : Env} {F : Nat}

mutual
theorem Dec.writeErr {t : Ty} {v : Value} {x : Typed} {e : Error} :
    Dec env t v x → toJsonF env F o t x = .error e → TagErr e
  | .intro hw hc, h => by
    rw [toJsonF_eq _ hw, toJsonC_hide] at h
    exact hc.writeErr (fun hb => boolTy_isBool hb hw) h

theorem Core.writeErr {c : Ty} {v : Value} {x : Typed} {b : Bool} {e : Error} :
    Core env c v x → (b = true → isBool c = true) → toJsonC env F b o c x = .error e → TagErr e
  | .string _, _, h | .bytes _, _, h | .int _ _, _, h | .decimal _, _, h | .any _, _, h
  | .time _, _, h => by simp [toJsonC] at h
  | .float _, _, h | .floatTag _, _, h => by simp [toJsonC] at h
  | .array hi, _, h => by simp only [toJsonC] at h; exact hi.writeErr (map_error h)
  | .map he, _, h => by simp only [toJsonC] at h; exact he.writeErr (map_error h)
  | .record _ hf, _, h => by simp only [toJsonC] at h; exact hf.writeErr (map_error h)
  | .bare (closed := closed) (cases := cases) (tag := tag) hc, hb, h => by
    rw [toJsonC.eq_def] at h
    simp only at h
    cases b with
    | true => simp at h
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h
      cases hn : nullArg? env F o (.variant closed cases) with
      | some a => simp [hn] at h
      | none =>
        simp only [hn] at h
        split at h
        · cases h
        · simp [hc] at h
  | .recordCase hc hd, hb, h => recordCase_err hc hb (hd.payloadErr rfl) h
  | .positional hc ha, hb, h =>
    positional_err hc hb (fun e h => ha.writeErr h) (fun t1 hts => ha.oneErr hts) h
  | .unknown _, _, h => by simp [toJsonC] at h

theorem Items.writeErr {t : Ty} {xs : List Value} {ys : List Typed} {i : Nat} {e : Error} :
    Items env t xs ys → toJsonItems env F o t i ys = .error e → TagErr e
  | .nil, h => by simp [toJsonItems] at h
  | .cons hx hs, h => by
    rw [toJsonItems_cons] at h
    rcases bind_error h with h | ⟨j, -, h⟩
    · obtain ⟨e', he', hr⟩ := under_error h
      exact hr.trans (hx.writeErr he')
    · rcases bind_error h with h | ⟨_, -, h⟩
      · exact hs.writeErr h
      · cases h

theorem Entries.writeErr {t : Ty} {fs : List (String × Value)} {ys : List (String × Typed)} {e : Error} :
    Entries env t fs ys → toJsonEntries env F o t ys = .error e → TagErr e
  | .nil, h => by simp [toJsonEntries] at h
  | .cons hx hs, h => by
    rw [toJsonEntries_cons] at h
    rcases bind_error h with h | ⟨j, -, h⟩
    · obtain ⟨e', he', hr⟩ := under_error h
      exact hr.trans (hx.writeErr he')
    · rcases bind_error h with h | ⟨_, -, h⟩
      · exact hs.writeErr h
      · cases h

theorem Fields.writeErr {closed : Bool} {fields : List Field} {fs : List (String × Value)}
    {ys : List (String × Typed)} {e : Error} :
    Fields env closed fields fs ys → toJsonFields env F o fields ys = .error e → TagErr e
  | .nil, h => by simp [toJsonFields] at h
  | .keep hf hx hs, h => by
    rw [toJsonFields_cons hf] at h
    rcases bind_error h with h | ⟨j, -, h⟩
    · obtain ⟨e', he', hr⟩ := under_error h
      exact hr.trans (hx.writeErr he')
    · rcases bind_error h with h | ⟨_, -, h⟩
      · exact hs.writeErr h
      · cases h
  | .skip _ hs, h => hs.writeErr h

theorem Args.writeErr {ts : List Ty} {xs : List Value} {ys : List Typed} {tag : String} {i : Nat}
    {e : Error} : Args env ts xs ys → toJsonArgs env F o tag i ts ys = .error e → TagErr e
  | .nil, h => by simp [toJsonArgs] at h
  | .cons hx hs, h => by
    rw [toJsonArgs_cons] at h
    rcases bind_error h with h | ⟨j, -, h⟩
    · obtain ⟨e', he', hr⟩ := under_error h
      exact hr.trans (hx.writeErr he')
    · rcases bind_error h with h | ⟨_, -, h⟩
      · exact hs.writeErr h
      · cases h

theorem Args.oneErr {ts : List Ty} {xs : List Value} {ys : List Typed} {t : Ty} :
    Args env ts xs ys → ts = [t] → ∃ y, ys = [y] ∧ ∀ e, toJsonF env F o t y = .error e → TagErr e
  | .nil, hts => by cases hts
  | .cons hx .nil, hts => by
    simp only [List.cons.injEq, and_true] at hts
    exact ⟨_, rfl, fun e h => hx.writeErr (hts ▸ h)⟩
  | .cons _ (.cons _ _), hts => by simp at hts

theorem Dec.payloadErr {t : Ty} {cl : Bool} {fields : List Field} {a : Value} {y : Typed} :
    Dec env t a y → t = .record cl fields →
      ∃ ys, y = .record ys ∧ ∀ e, toJsonFields env F o fields ys = .error e → TagErr e
  | .intro hw hcore, ht0 => hcore.payloadErr (ht0 ▸ hw)

theorem Core.payloadErr {cl : Bool} {fields : List Field} {c : Ty} {s : Nat} {a : Value} {y : Typed} :
    Core env c a y → whnf env env.fuel (.record cl fields) = .ok (s, c) →
      ∃ ys, y.hide s = .record ys ∧ ∀ e, toJsonFields env F o fields ys = .error e → TagErr e
  | .record (closed := cl') (fields := fields') (ys := ys) _ hf, hw => by
    rw [whnf_record] at hw
    have e := Prod.mk.inj (Except.ok.inj hw)
    have e2 : Ty.record cl fields = Ty.record cl' fields' := e.2
    injection e2 with ec ef
    have IH : ∀ er, toJsonFields env F o fields' ys = .error er → TagErr er := fun er h => hf.writeErr h
    subst ec ef
    rw [← e.1]
    exact ⟨ys, rfl, IH⟩
  | .string _, hw | .bytes _, hw | .int _ _, hw | .float _, hw
  | .floatTag _, hw | .decimal _, hw | .any _, hw | .time _, hw
  | .array _, hw | .map _, hw | .bare _, hw | .recordCase _ _, hw
  | .positional _ _, hw | .unknown _, hw => by
    rw [whnf_record] at hw; cases hw
end

/-! ## The theorems -/

/-- The round trip for any fuel, as long as writing and reading use the same. -/
theorem schemaBased_round_trip_fuel {env : Env} {F : Nat} {o : String} {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hv : v.wf = true) (hj : toJsonF env F o t x = .ok j) :
    fromJsonF env F o t j = .ok x :=
  (decode_sound h).roundTrip hv hj

/--
**Schema-based round trip** (§16.3): for every well-formed value `v` that the type
`t` decodes to `x`, reading the schema-based JSON of `x` gives `x` back.
-/
theorem schemaBased_round_trip {env : Env} {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hv : v.wf = true) (hj : toJson env t x = .ok j) :
    fromJson env t j = .ok x :=
  schemaBased_round_trip_fuel h hv hj

/--
**Writing fails only where §16.3 says**: the only error writing a decoded
value can give is a record payload with a field named `_tag` or `_args`,
which has no schema-based form. So the round trip is not vacuous.
-/
theorem toJson_error {env : Env} {t : Ty} {v : Value} {x : Typed} {e : Error}
    (h : decode env t v = .ok x) (he : toJson env t x = .error e) : e.reason = reservedFieldReason :=
  (decode_sound h).writeErr he

/--
**Schema-based JSON is injective** (§16.3): two values decoded with the type `t`
(from well-formed values) that have the same schema-based JSON are the same.
-/
theorem schemaBased_injective {env : Env} {t : Ty} {v w : Value} {x y : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hy : decode env t w = .ok y) (hv : v.wf = true) (hw : w.wf = true)
    (hjx : toJson env t x = .ok j) (hjy : toJson env t y = .ok j) : x = y := by
  have h := schemaBased_round_trip hx hv hjx
  rw [schemaBased_round_trip hy hw hjy] at h
  exact (Except.ok.inj h).symm

end Haus.Schema
