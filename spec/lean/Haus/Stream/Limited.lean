import Haus.Stream.Correct

/-!
# Streams: the value limit and strict mode (spec §6, §7) — design review C4

Two things a stream reader adds to `read` (`Haus.Stream`):

* **The value limit** (§7, default 64 Mi). A stream reader holds one value
  at a time, and counts its characters from the previous top-level comma (or
  the start of the stream, after a byte order mark) up to the next one:
  whitespace and comments before the value count, the commas don't. The
  text after the last comma counts too, as the reader holds it as well. A
  value of exactly the limit is accepted. The limit applies to stream
  readers only: `parse`, which is given the whole text, doesn't apply it, so
  a file with one larger value parses whole and fails streamed, by design.
* **Strict mode** (§6): the stream must end with a comma after its last
  value (whitespace and comments may follow); otherwise the last value may
  have been cut off, and the reader reports `stream-truncated` instead of
  returning it. A stream without values is not truncated.

The reader checks a value's length before parsing it (it can't hold more),
so the first error in the stream wins: a syntax error in an earlier value,
or the value limit at the first value over it. Strict mode adds an error
only at the end, after the last value has parsed.

Proven:

* `readWith_chunks`: any split gives the same values and error.
* `readWith_cases`: for any text, the reader gives what `read` gives (so, by
  `read_correct`, the values of the whole-text parse), or stops with
  `value-too-long` or, in strict mode, `stream-truncated`, after some of
  `read`'s values.
* `readWith_valid`: for a text `parse` accepts, the error is
  `value-too-long` exactly when some value's characters exceed the limit
  (`Fits`), else `stream-truncated` exactly when in strict mode the text
  after the last top-level comma holds a value (`Terminated`), else none;
  the values returned are the first values of the whole text, all of them
  when there is no error.
* `readWith_correct`: the reader returns `vs` without an error exactly when
  `parse` accepts the whole text with `vs`, every value fits the limit, and,
  in strict mode, the stream is terminated.
* `readWith_eq_read`: within the limit and not strict, it is `read`.
-/

namespace Haus.Stream
open Haus Parser

/-- What a stream reader adds to the parser's limits (§6, §7). -/
structure Options where
  /-- Characters in one top-level value (§7). -/
  maxValueLength : Nat := 64 * 1024 * 1024
  /-- Require a comma after the last value (§6). -/
  strict : Bool := false
  deriving Repr, Inhabited

/-- A value's text without the byte order mark at the start of the stream. -/
def dropBom : Text → Text
  | '﻿' :: t => t
  | t => t

/-- The characters of a value as §7 counts them: the first without a byte order mark at the start of the stream. -/
def valueChars (first : Bool) (p : Text) : Nat := (if first then dropBom p else p).length

/-- The text after the last top-level comma (or up to an unbalanced bracket). -/
def restOf : Res → Text
  | .ok _ cur buf => cur ++ buf
  | .unbalanced t => t

def tooLongError (o : Options) (p : Text) : Error :=
  .at .valueTooLong s!"value longer than {o.maxValueLength} characters" p

/-- At the end of the input. -/
def truncatedError : Error := ⟨.streamTruncated, "stream ended without ',' after the last value (truncated?)", 0⟩

/--
`decode` with the value limit and strict mode: each value's length is
checked before it is parsed; in strict mode, a value after the last comma
is an error.
-/
def decodeWith (o : Options) (L : Limits) : Bool → List Text → Res → List Value × Option Error
  | first, p :: ps, res =>
    if o.maxValueLength < valueChars first p then ([], some (tooLongError o p)) else
    match parsePiece L first p with
    | .ok [v] => let x := decodeWith o L false ps res; (v :: x.1, x.2)
    | .ok _ => ([], some (.at .expectedValue "expected a value before ','" p))
    | .error e => ([], some e)
  | first, [], res =>
    if o.maxValueLength < valueChars first (restOf res) then ([], some (tooLongError o (restOf res))) else
    let x := decode L first [] res
    if o.strict && x.2.isNone && !x.1.isEmpty then ([], some truncatedError) else x

/--
**The stream reader with the value limit and strict mode**: the values of
the text arriving as `chunks`, and the error that ended it, if any.
-/
def readWith (o : Options) (L : Limits) (chunks : List Text) : List Value × Option Error :=
  let rd := split chunks
  decodeWith o L true rd.pieces rd.res

/-! ## What the reader counts and checks -/

/-- The characters of each value, as §7 counts them: the pieces, then the rest. -/
def lengths : Bool → List Text → Res → List Nat
  | first, [], res => [valueChars first (restOf res)]
  | first, p :: ps, res => valueChars first p :: lengths false ps res

/-- The values of the text after the last top-level comma. -/
def restValues (L : Limits) : Bool → List Text → Res → List Value
  | first, [], res => (decode L first [] res).1
  | _, _ :: ps, res => restValues L false ps res

/-- The characters of each top-level value of `t`, as §7 counts them (the text after the last comma included). -/
def valueLengths (t : Text) : List Nat := lengths true (split [t]).pieces (split [t]).res

/-- Every value of `t` fits the value limit `n`. -/
def Fits (n : Nat) (t : Text) : Prop := ∀ k ∈ valueLengths t, k ≤ n

instance (n : Nat) (t : Text) : Decidable (Fits n t) := by unfold Fits; infer_instance

/-- No value follows the last top-level comma of `t`: a stream that strict mode accepts. -/
def Terminated (L : Limits) (t : Text) : Prop := restValues L true (split [t]).pieces (split [t]).res = []

/-! ## Proofs -/

theorem readWith_chunks (o : Options) (L : Limits) (cs : List Text) : readWith o L cs = readWith o L [cs.flatten] := by
  unfold readWith; rw [split_chunks]

/-- Any pieces: `decode`'s result, or a stop with one of the two new errors after some of its values. -/
theorem decodeWith_cases (o : Options) (L : Limits) : ∀ (first : Bool) (ps : List Text) (res : Res),
    decodeWith o L first ps res = decode L first ps res ∨
    ∃ e vs, decodeWith o L first ps res = (vs, some e) ∧
      (e.code = .valueTooLong ∨ (e.code = .streamTruncated ∧ o.strict = true)) ∧ vs <+: (decode L first ps res).1
  | first, [], res => by
    simp only [decodeWith]
    split
    · exact .inr ⟨_, [], rfl, .inl rfl, List.nil_prefix⟩
    · split
      · rename_i h
        simp only [Bool.and_eq_true] at h
        exact .inr ⟨_, [], rfl, .inr ⟨rfl, h.1.1⟩, List.nil_prefix⟩
      · exact .inl rfl
  | first, p :: ps, res => by
    simp only [decodeWith, decode]
    split
    · exact .inr ⟨_, [], rfl, .inl rfl, List.nil_prefix⟩
    · rcases hpp : parsePiece L first p with e | (_ | ⟨v, _ | ⟨w, ws⟩⟩)
      · exact .inl rfl
      · exact .inl rfl
      · rcases decodeWith_cases o L false ps res with h | ⟨e, vs, h, hc, hp⟩
        · exact .inl (by simp only [h])
        · exact .inr ⟨e, _, by simp only [h], hc, List.cons_prefix_cons.mpr ⟨rfl, hp⟩⟩
      · exact .inl rfl

/-- Every value fits and not strict: `decode`. -/
theorem decodeWith_eq_decode {o : Options} {L : Limits} (hs : o.strict = false) :
    ∀ (first : Bool) (ps : List Text) (res : Res), (∀ k ∈ lengths first ps res, k ≤ o.maxValueLength) →
      decodeWith o L first ps res = decode L first ps res
  | first, [], res, h => by
    simp only [lengths, List.mem_singleton, forall_eq] at h
    simp [decodeWith, hs, Nat.not_lt.mpr h]
  | first, p :: ps, res, h => by
    simp only [lengths, List.mem_cons, forall_eq_or_imp] at h
    simp only [decodeWith, decode, Nat.not_lt.mpr h.1, ↓reduceIte]
    rcases hpp : parsePiece L first p with e | (_ | ⟨v, _ | ⟨w, ws⟩⟩)
    · rfl
    · rfl
    · simp only [decodeWith_eq_decode hs false ps res h.2]
    · rfl

/-- The outcome on pieces `decode` reads without an error. -/
theorem decodeWith_of_ok (o : Options) (L : Limits) : ∀ (first : Bool) (ps : List Text) (res : Res) (vs : List Value),
    decode L first ps res = (vs, none) →
    (decodeWith o L first ps res).2.map Error.code =
      if (lengths first ps res).all (· ≤ o.maxValueLength) then
        (if o.strict && !(restValues L first ps res).isEmpty then some .streamTruncated else none)
      else some .valueTooLong
  | first, [], res, vs, h => by
    simp only [decodeWith, lengths, restValues, List.all_cons, List.all_nil, Bool.and_true, h]
    by_cases hl : o.maxValueLength < valueChars first (restOf res)
    · simp [hl, tooLongError, Error.at]
    · simp only [hl, ↓reduceIte, decide_eq_true (Nat.not_lt.mp hl), Option.isNone_none, Bool.and_true]
      split <;> simp [truncatedError]
  | first, p :: ps, res, vs, h => by
    obtain ⟨v, vs', hp, hd, rfl⟩ := decode_cons h
    simp only [decodeWith, lengths, restValues, List.all_cons]
    by_cases hl : o.maxValueLength < valueChars first p
    · simp [hl, Nat.not_le.mpr hl, tooLongError, Error.at]
    · simp only [hl, ↓reduceIte, decide_eq_true (Nat.not_lt.mp hl), Bool.true_and, hp]
      exact decodeWith_of_ok o L false ps res vs' hd

/-- On pieces `decode` reads without an error, the values returned are its first ones, all of them without an error. -/
theorem decodeWith_values {o : Options} {L : Limits} {first : Bool} {ps : List Text} {res : Res} {vs : List Value}
    (h : decode L first ps res = (vs, none)) :
    (decodeWith o L first ps res).1 <+: vs ∧ ((decodeWith o L first ps res).2 = none → (decodeWith o L first ps res).1 = vs) := by
  rcases decodeWith_cases o L first ps res with he | ⟨e, vs', he, -, hp⟩
  · rw [he, h]; exact ⟨List.prefix_refl _, fun _ => rfl⟩
  · rw [he]; rw [h] at hp; exact ⟨hp, fun h => by cases h⟩

/--
**Any text**: the reader gives what `read` gives (by `read_correct`, the
values of the whole-text parse when it accepts), or stops with
`value-too-long`, or in strict mode `stream-truncated`, after some of the
values `read` gives.
-/
theorem readWith_cases (o : Options) (L : Limits) (cs : List Text) :
    readWith o L cs = read L cs ∨
    ∃ e vs, readWith o L cs = (vs, some e) ∧
      (e.code = .valueTooLong ∨ (e.code = .streamTruncated ∧ o.strict = true)) ∧ vs <+: (read L cs).1 :=
  decodeWith_cases o L true _ _

/-- **Within the limit and not strict, it is `read`.** -/
theorem readWith_eq_read {o : Options} (L : Limits) (cs : List Text) (hs : o.strict = false)
    (hf : Fits o.maxValueLength cs.flatten) : readWith o L cs = read L cs := by
  rw [readWith_chunks, read_chunks]
  exact decodeWith_eq_decode hs _ _ _ hf

theorem all_iff_fits (n : Nat) (t : Text) : (valueLengths t).all (· ≤ n) = true ↔ Fits n t := by
  simp [Fits, List.all_eq_true]

theorem isEmpty_iff_terminated (L : Limits) (t : Text) :
    (restValues L true (split [t]).pieces (split [t]).res).isEmpty = true ↔ Terminated L t := by
  simp [Terminated]

open Classical in
/--
**A text `parse` accepts, read as a stream.** The reader fails with
`value-too-long` exactly when some value's characters exceed the limit;
otherwise with `stream-truncated` exactly when in strict mode a value
follows the last top-level comma; otherwise not at all. The values it
returns are the first values of the whole text, and all of them when there
is no error.
-/
theorem readWith_valid (o : Options) (L : Limits) (cs : List Text) {vs : List Value}
    (h : parse L cs.flatten = .ok vs) :
    (readWith o L cs).2.map Error.code =
      (if Fits o.maxValueLength cs.flatten then
        (if o.strict = true ∧ ¬Terminated L cs.flatten then some .streamTruncated else none)
      else some .valueTooLong) ∧
    (readWith o L cs).1 <+: vs ∧ ((readWith o L cs).2 = none → (readWith o L cs).1 = vs) := by
  have hr := (read_correct L [cs.flatten] vs).mpr (by simpa using h)
  rw [readWith_chunks]
  unfold read at hr
  refine ⟨?_, decodeWith_values hr⟩
  unfold readWith
  rw [decodeWith_of_ok o L true _ _ vs hr]
  have h1 := all_iff_fits o.maxValueLength cs.flatten
  have h2 := isEmpty_iff_terminated L cs.flatten
  unfold valueLengths at h1
  by_cases hf : Fits o.maxValueLength cs.flatten
  · simp only [h1.mpr hf, hf, ↓reduceIte]
    by_cases ht : Terminated L cs.flatten
    · simp [h2.mpr ht, ht]
    · have : (restValues L true (split [cs.flatten]).pieces (split [cs.flatten]).res).isEmpty = false := by
        cases hh : (restValues L true (split [cs.flatten]).pieces (split [cs.flatten]).res).isEmpty
        · rfl
        · exact absurd (h2.mp hh) ht
      cases hs : o.strict <;> simp [this, ht]
  · have : (valueLengths cs.flatten).all (· ≤ o.maxValueLength) = false := by
      cases hh : (valueLengths cs.flatten).all (· ≤ o.maxValueLength)
      · rfl
      · exact absurd ((all_iff_fits _ _).mp hh) hf
    unfold valueLengths at this
    simp [this, hf]

/--
**The reader is correct**: in any chunks, it returns the values `vs` and no
error exactly when `parse` accepts the whole text with `vs`, every value
fits the value limit, and, in strict mode, the stream is terminated.
-/
theorem readWith_correct (o : Options) (L : Limits) (cs : List Text) (vs : List Value) :
    readWith o L cs = (vs, none) ↔
      parse L cs.flatten = .ok vs ∧ Fits o.maxValueLength cs.flatten ∧ (o.strict = true → Terminated L cs.flatten) := by
  constructor
  · intro h
    have hp : parse L cs.flatten = .ok vs := by
      rcases readWith_cases o L cs with he | ⟨e, vs', he, -, -⟩
      · exact (read_correct L cs vs).mp (he ▸ h)
      · rw [h] at he; cases he
    obtain ⟨hc, -⟩ := readWith_valid o L cs hp
    rw [h] at hc
    refine ⟨hp, ?_⟩
    by_cases hf : Fits o.maxValueLength cs.flatten
    · refine ⟨hf, fun hs => ?_⟩
      by_cases ht : Terminated L cs.flatten
      · exact ht
      · simp [hf, hs, ht] at hc
    · simp [hf] at hc
  · rintro ⟨hp, hf, ht⟩
    obtain ⟨hc, -, hv⟩ := readWith_valid o L cs hp
    have he : (readWith o L cs).2 = none := by
      have : (readWith o L cs).2.map Error.code = none := by
        rw [hc]; simp only [hf, ↓reduceIte]
        split
        · rename_i h; exact absurd (ht h.1) h.2
        · rfl
      simpa using this
    exact Prod.ext (hv he) he

/-! ## Examples -/

private def codeOf (o : Options) (chunks : List String) : Option String :=
  (readWith o {} (chunks.map String.toList)).2.map (·.code.name)

private def countOf (o : Options) (chunks : List String) : Nat :=
  (readWith o {} (chunks.map String.toList)).1.length

-- A value of exactly the limit is accepted; the comma doesn't count, nor a byte order mark at the start.
#guard codeOf { maxValueLength := 3 } ["123,45"] == none
#guard codeOf { maxValueLength := 3 } ["﻿123,", "456"] == none
#guard codeOf { maxValueLength := 3 } ["1,1234"] == some "value-too-long" && countOf { maxValueLength := 3 } ["1,1234"] == 1
-- Whitespace and comments before a value count; the whole-text parse doesn't apply the limit.
#guard codeOf { maxValueLength := 3 } ["1,   2"] == some "value-too-long"
#guard (parse {} "1,   2".toList).toOption.isSome
-- The first error in the stream wins.
#guard codeOf { maxValueLength := 3 } ["1,,1234"] == some "expected-value"
#guard codeOf { maxValueLength := 3 } ["1234,,"] == some "value-too-long"
-- Strict mode: a comma after the last value, whitespace and comments may follow; no values is fine.
#guard codeOf { strict := true } ["1, 2"] == some "stream-truncated" && countOf { strict := true } ["1, 2"] == 1
#guard codeOf { strict := true } ["1, 2, // end", "\n"] == none
#guard codeOf { strict := true } [" "] == none
-- A syntax error in the last value is reported as such.
#guard codeOf { strict := true } ["1, 2]"] == some "unexpected-closer"

end Haus.Stream
