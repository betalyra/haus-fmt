import Haus.Json.Text

/-!
# JSON import (spec §16.1) and self-describing JSON (§16.2)

- `JSON.toValue`: any JSON reads as a haus value, the import (§16.1).
- `selfDescribing v`: the self-describing form of a haus value, as it
  appears inside schema-based JSON (`Any`, unknown values);
  `fromSelfDescribing` reads it.
- `hausJson v`: a self-describing JSON text's JSON, the envelope
  `{"_haus": 1, "_value": …}` around `selfDescribing v`; `fromHausJson`
  reads it, and only it.

What is proven, about `JSON` as data:

| Theorem | Says |
|---|---|
| `fromHausJson_hausJson`, `fromSelfDescribing_selfDescribing` | Reading the self-describing JSON of a value gives the value back, with the envelope and without |
| `hausJson_read_write`, `selfDescribing_read_write` | The same, up to `Value.Equiv`, as §16.2 states it |
| `hausJson_unique`, `selfDescribing_unique` | Every JSON the reader accepts is the self-describing JSON of the value it reads, as data (`JSON.Equiv`) |
| `hausJson_equiv_iff`, `selfDescribing_equiv_iff` | Two values have the same self-describing JSON, as data, exactly when they are equal (§2) |
| `fromHausJson_wf`, `fromSelfDescribing_wf` | What the reader returns is well formed: normalized numbers, tags |

The round trip needs the value to be well formed (`Value.wf`): its
numbers are normalized literals and its tags are tags, as for every value
the parser returns. A `Value` built by hand can hold any string as a
number. `hausJson_equiv_iff` needs nothing.

The limits (§7) are checked separately, on the value read (`Value.fits`):
`readHausJson` reads text with the JSON reader in strict mode, which
rejects a raw DEL, C1 or bidi control in a string or member name where it
meets it (`control-character`, `bidi-control`), maps it and checks the
limits; `readImport` does the same for the import, which accepts those
characters raw.
-/

namespace Haus
open Haus

/-! ## Well-formed values and the limits -/

namespace Value

mutual
/-- Numbers are normalized literals (§2), tags are tags. True of every value the parser returns. -/
def wf : Value → Bool
  | .num s => isNormalLit s.toList
  | .str _ => true
  | .bytes _ => true
  | .arr xs => wfList xs
  | .record fs => wfFields fs
  | .variant t xs => isTag t.toList && wfList xs

def wfList : List Value → Bool
  | [] => true
  | x :: xs => wf x && wfList xs

def wfFields : List (String × Value) → Bool
  | [] => true
  | (_, x) :: fs => wf x && wfFields fs
end

mutual
/--
Nesting depth (§7): records, arrays and payloads are one level each, and
`Tag { … }` is one level, as in the grammar (its shortest spelling).
-/
def depth : Value → Nat
  | .arr xs => depthList xs + 1
  | .record fs => depthFields fs + 1
  | .variant _ [] => 0
  | .variant _ [.record fs] => depthFields fs + 1
  | .variant _ xs => depthList xs + 1
  | _ => 0

def depthList : List Value → Nat
  | [] => 0
  | x :: xs => max (depth x) (depthList xs)

def depthFields : List (String × Value) → Nat
  | [] => 0
  | (_, x) :: fs => max (depth x) (depthFields fs)
end

mutual
/--
The values written for a value (§7, the node limit): the value itself and,
inside it, every element, field value and argument, each as often as it is
written. A value built in code whose parts share each other writes each
shared part once for every place it is in.
-/
def nodes : Value → Nat
  | .arr xs => nodesList xs + 1
  | .record fs => nodesFields fs + 1
  | .variant _ xs => nodesList xs + 1
  | _ => 1

def nodesList : List Value → Nat
  | [] => 0
  | x :: xs => nodes x + nodesList xs

def nodesFields : List (String × Value) → Nat
  | [] => 0
  | (_, x) :: fs => nodes x + nodesFields fs
end

mutual
/-- Every number, string, byte string, record key and tag within the limits. -/
def leaves (L : Limits) : Value → Bool
  | .num s => JSON.numberFits L s.toList
  | .str s => s.length ≤ L.maxStringLength
  | .bytes bs => 2 * bs.length ≤ L.maxStringLength
  | .arr xs => leavesList L xs
  | .record fs => leavesFields L fs
  | .variant t xs => t.length ≤ L.maxStringLength && leavesList L xs

def leavesList (L : Limits) : List Value → Bool
  | [] => true
  | x :: xs => leaves L x && leavesList L xs

def leavesFields (L : Limits) : List (String × Value) → Bool
  | [] => true
  | (k, x) :: fs => k.length ≤ L.maxStringLength && leaves L x && leavesFields L fs
end

/--
**Within the limits** (§7): a haus text could write the value within them.
Numbers as in `JSON.numberFits`; a byte string takes two hex digits a byte;
a record key or tag counts like a string.
-/
def fits (L : Limits) (v : Value) : Bool := v.depth ≤ L.maxDepth && leaves L v

mutual
/--
The code (spec §17) of the first number, string, byte string, record key or
tag outside the limits, in the order of the text; none if they all fit.
-/
def leafCode (L : Limits) : Value → Option Code
  -- As the haus parser checks: the literal's length, then its exponent.
  | .num s => if JSON.numberFits L s.toList then none else some (JSON.tokenCode L s.toList)
  | .str s => if s.length ≤ L.maxStringLength then none else some .stringTooLong
  | .bytes bs => if 2 * bs.length ≤ L.maxStringLength then none else some .stringTooLong
  | .arr xs => leafCodeList L xs
  | .record fs => leafCodeFields L fs
  | .variant t xs => if t.length ≤ L.maxStringLength then leafCodeList L xs else some .tagTooLong

def leafCodeList (L : Limits) : List Value → Option Code
  | [] => none
  | x :: xs =>
    match leafCode L x with
    | some c => some c
    | none => leafCodeList L xs

def leafCodeFields (L : Limits) : List (String × Value) → Option Code
  | [] => none
  | (k, x) :: fs =>
    if k.length > L.maxStringLength then some .keyTooLong else
    match leafCode L x with
    | some c => some c
    | none => leafCodeFields L fs
end

/-- The code (spec §17) of a value that doesn't `fit`: nested too deeply, or a leaf too large. -/
def limitCode (L : Limits) (v : Value) : Code :=
  if v.depth > L.maxDepth then .nestingTooDeep else (leafCode L v).getD .nestingTooDeep

end Value

namespace JSON

/-! ## §16.1: JSON import -/

mutual
/--
**JSON as a haus value**, the import (§16.1): an object as a record, an
array as an array, a string as a string, a number as a number with its
literal normalized (§2), `true` and `false` as `True` and `False`, `null` as
`None`. Nothing in the data is special: `{"_tag": "Circle"}` and an envelope
are records.
-/
def toValue : JSON → Except Error Value
  | .null => .ok (.variant "None" [])
  | .bool b => .ok (.variant (if b then "True" else "False") [])
  | .num t => if isJsonNumber t.toList then .ok (.num (normalizeNumber t.toList)) else .error ⟨.jsonSyntax, "not a JSON number"⟩
  | .str s => .ok (.str s)
  | .arr xs => (toValueList xs).map .arr
  | .obj ms => (toValueMembers ms).map .record

def toValueList : List JSON → Except Error (List Value)
  | [] => .ok []
  | x :: xs => do return (← toValue x) :: (← toValueList xs)

def toValueMembers : List (String × JSON) → Except Error (List (String × Value))
  | [] => .ok []
  | (k, x) :: ms => do return (k, ← toValue x) :: (← toValueMembers ms)
end

/-! ## §16.2: self-describing JSON -/

/-- `{"_tag": T}` without arguments, `{"_tag": T, "_args": […]}` with them. -/
def tagged (t : String) (args : List JSON) : JSON :=
  .obj (("_tag", .str t) :: if args.isEmpty then [] else [("_args", .arr args)])

mutual
/--
**The self-describing form** of a haus value (§16.2), without the envelope:
as it appears inside schema-based JSON (`Any`, unknown values, §16.3).
-/
def selfDescribing : Value → JSON
  | .num s => .obj [("_num", .str s)]
  | .str s => .str s
  | .bytes bs => .obj [("_bytes", .str (String.ofList (Bytes.hex bs)))]
  | .arr xs => .arr (selfDescribingList xs)
  | .record fs => .obj [("_rec", .obj (selfDescribingFields fs))]
  | .variant t xs => tagged t (selfDescribingList xs)

def selfDescribingList : List Value → List JSON
  | [] => []
  | x :: xs => selfDescribing x :: selfDescribingList xs

def selfDescribingFields : List (String × Value) → List (String × JSON)
  | [] => []
  | (k, x) :: fs => (k, selfDescribing x) :: selfDescribingFields fs
end

/-- The envelope (§16.2): `{"_haus": 1, "_value": j}`, the version of the form and the value. -/
def envelope (j : JSON) : JSON := .obj [("_haus", .num "1"), ("_value", j)]

/-- **Self-describing JSON** of a haus value (§16.2): its self-describing form in the envelope. -/
def hausJson (v : Value) : JSON := envelope (selfDescribing v)

/-- `{"_num": "…"}`: a normalized literal. -/
def numOf : JSON → Except Error Value
  | .str s => if isNormalLit s.toList then .ok (.num s) else .error ⟨.hausJsonNumber, "_num: not a normalized number literal"⟩
  | _ => .error ⟨.hausJsonNumber, "_num: not a string"⟩

/-- `{"_bytes": "…"}`: lowercase hex digits in pairs. -/
def bytesOf : JSON → Except Error Value
  | .str h =>
    match Bytes.unhex h.toList with
    | some bs => .ok (.bytes bs)
    | none => .error ⟨.hausJsonBytes, "_bytes: not lowercase hex digits in pairs"⟩
  | _ => .error ⟨.hausJsonBytes, "_bytes: not a string"⟩

/-- `{"_tag": "…"}`: a tag. -/
def tagOf : JSON → Except Error String
  | .str t => if isTag t.toList then .ok t else .error ⟨.invalidTag, "_tag: not a tag"⟩
  | _ => .error ⟨.invalidTag, "_tag: not a string"⟩

/--
The code of JSON that is no self-describing form: `invalid-tag` for a
`{"_tag", "_args"}` object whose tag isn't one (the tag is checked before
`_args`), else `haus-json-form`.
-/
def formCode : JSON → Code
  | .obj [("_tag", x), ("_args", _)] | .obj [("_args", _), ("_tag", x)] =>
    if (tagOf x).toOption.isSome then .hausJsonForm else .invalidTag
  | _ => .hausJsonForm

mutual
/--
**Reading a self-describing value** (§16.2), without the envelope: exactly
the forms `selfDescribing` writes, in any member order, and nothing else. A
`_num` must be a normalized literal, `_bytes` lowercase hex, a `_tag` a tag,
and `_args` not empty.
-/
def fromSelfDescribing : JSON → Except Error Value
  | .str s => .ok (.str s)
  | .arr xs => (fromSelfDescribingList xs).map .arr
  | .obj [("_num", x)] => numOf x
  | .obj [("_bytes", x)] => bytesOf x
  | .obj [("_rec", .obj ms)] => (fromSelfDescribingMembers ms).map .record
  | .obj [("_tag", x)] => (tagOf x).map (.variant · [])
  | .obj [("_tag", x), ("_args", .arr (y :: ys))] => do
    let t ← tagOf x
    return .variant t (← fromSelfDescribingList (y :: ys))
  | .obj [("_args", .arr (y :: ys)), ("_tag", x)] => do
    let t ← tagOf x
    return .variant t (← fromSelfDescribingList (y :: ys))
  | j => .error ⟨formCode j, "not a self-describing value"⟩

def fromSelfDescribingList : List JSON → Except Error (List Value)
  | [] => .ok []
  | x :: xs => do return (← fromSelfDescribing x) :: (← fromSelfDescribingList xs)

def fromSelfDescribingMembers : List (String × JSON) → Except Error (List (String × Value))
  | [] => .ok []
  | (k, x) :: ms => do return (k, ← fromSelfDescribing x) :: (← fromSelfDescribingMembers ms)
end

/--
The value in an envelope (§16.2): an object with exactly the members
`_haus` and `_value`, in either order (`haus-json-form` otherwise), whose
`_haus` is the JSON number written `1` (`haus-json-version` otherwise: `2`,
`"1"`, `1.0`).
-/
def unwrap : JSON → Except Error JSON
  | .obj [("_haus", h), ("_value", j)] | .obj [("_value", j), ("_haus", h)] =>
    match h with
    | .num "1" => .ok j
    | _ => .error ⟨.hausJsonVersion, "_haus: not 1, the only version of self-describing JSON"⟩
  | _ => .error ⟨.hausJsonForm, "not an envelope {\"_haus\": 1, \"_value\": …}"⟩

/--
**Reading self-describing JSON** (§16.2): the envelope, and in it a
self-describing value. Its errors are placed by `hausJsonPlace`, from the
envelope: `$._value._args[1]._num`.
-/
def fromHausJson (j : JSON) : Except Error Value := do fromSelfDescribing (← unwrap j)

/-! ## Reading text -/

def checkFits (L : Limits) (v : Value) : Except Error Value :=
  if v.fits L then .ok v else .error ⟨v.limitCode L, "outside the limits"⟩

/-- The JSON import of a text, within the limits (§16.1): JSON nesting at most `d`. -/
def readImport (L : Limits) (t : Text) : Except Error Value := do
  checkFits L (← toValue (← parseDepth (textLimits L t) L.maxDepth t))

/--
One self-describing JSON text without a byte order mark, within the limits
(§16.2): nesting `4 · d + 2`, and strict: no raw DEL, C1 or bidi control in
a string or member name (§16). Only haus writes this form, and it escapes
them.
-/
def readHausJsonText (L : Limits) (t : Text) : Except Error Value := do
  let j ← parseText (textLimits L t) true (hausJsonDepth L) t
  checkFits L (← fromHausJson j)

/-- **Self-describing JSON text** (§16.2), within the limits, after an optional byte order mark. -/
def readHausJson (L : Limits) (t : Text) : Except Error Value := readHausJsonText L (dropBom t)

/--
**Self-describing JSON Lines** (§16, "Streams"): one envelope per line, as
`parseLines` reads lines.
-/
def readHausJsonLines (L : Limits) (t : Text) : Except Error (List Value) :=
  (lines (dropBom t)).mapM fun l =>
    if l.isEmpty then .error ⟨.jsonSyntax, "empty line"⟩ else readHausJsonText L l

/-! ## Places (§16.3 "Places")

An error reading JSON names its place in the JSON: member names and array
indexes from the JSON text's root. The readers above say what is wrong; the
functions here say where, as the first part, in reading order, that the
reader rejects. -/

/-- A step of a place in JSON: a member name, or an array index. -/
inductive Step
  | member (k : String)
  | index (i : Nat)
  deriving Repr, DecidableEq

/-- A step as §15 writes it: `.name` for an identifier, `["…"]` for any other name, `[i]` for an index. -/
def Step.text : Step → String
  | .member k => if Canonical.isIdent k then "." ++ k else "[" ++ String.ofList (Canonical.string k) ++ "]"
  | .index i => s!"[{i}]"

/-- A place as text: `$`, then its steps. -/
def placeText (p : List Step) : String := p.foldl (fun s step => s ++ step.text) "$"

mutual
/--
The place of the error of `fromSelfDescribing j`, when it rejects `j`: a
`_num` or `_bytes` that isn't one is at that member, a part of an array, a
`_rec` or an `_args` at the first part rejected, an `_args` that isn't a
non-empty array (with a tag) at that member, and anything else (a tag that
isn't one, JSON that is no form) at the object itself.
-/
def selfDescribingPlace : JSON → List Step
  | .arr xs => selfDescribingListPlaceFrom 0 xs
  | .obj [("_num", _)] => [.member "_num"]
  | .obj [("_bytes", _)] => [.member "_bytes"]
  | .obj [("_rec", .obj ms)] => .member "_rec" :: selfDescribingMembersPlace ms
  | .obj [("_tag", x), ("_args", .arr (y :: ys))] =>
    if (tagOf x).toOption.isSome then .member "_args" :: selfDescribingListPlaceFrom 0 (y :: ys) else []
  | .obj [("_args", .arr (y :: ys)), ("_tag", x)] =>
    if (tagOf x).toOption.isSome then .member "_args" :: selfDescribingListPlaceFrom 0 (y :: ys) else []
  | .obj [("_tag", x), ("_args", _)] | .obj [("_args", _), ("_tag", x)] =>
    if (tagOf x).toOption.isSome then [.member "_args"] else []
  | _ => []

/-- The first item from index `i` on that `fromSelfDescribing` rejects, and the place in it. -/
def selfDescribingListPlaceFrom (i : Nat) : List JSON → List Step
  | [] => []
  | x :: xs =>
    if (fromSelfDescribing x).toOption.isSome then selfDescribingListPlaceFrom (i + 1) xs
    else .index i :: selfDescribingPlace x

/-- The first member that `fromSelfDescribing` rejects, and the place in it. -/
def selfDescribingMembersPlace : List (String × JSON) → List Step
  | [] => []
  | (k, x) :: ms =>
    if (fromSelfDescribing x).toOption.isSome then selfDescribingMembersPlace ms
    else .member k :: selfDescribingPlace x
end

/-- The place of the error of `fromSelfDescribingList xs`: the first item rejected. -/
def selfDescribingListPlace (xs : List JSON) : List Step := selfDescribingListPlaceFrom 0 xs

/--
The place of the error of `fromHausJson j`: `_haus` for a version other than
1, `_value` and the place in it, or else the envelope itself (a text that
isn't one, a member missing).
-/
def hausJsonPlace : JSON → List Step
  | .obj [("_haus", .num "1"), ("_value", j)] => .member "_value" :: selfDescribingPlace j
  | .obj [("_value", j), ("_haus", .num "1")] => .member "_value" :: selfDescribingPlace j
  | .obj [("_haus", _), ("_value", _)] | .obj [("_value", _), ("_haus", _)] => [.member "_haus"]
  | _ => []

/-- The place of an error in one self-describing JSON text without a byte order mark: none for an error in the text. -/
def hausJsonTextPlace (L : Limits) (t : Text) : List Step :=
  match parseText (textLimits L t) true (hausJsonDepth L) t with
  | .ok j => if (fromHausJson j).toOption.isSome then [] else hausJsonPlace j
  | .error _ => []

/-- **Self-describing JSON text** (§16.2) as `readHausJson` reads it, an error with its place. -/
def readHausJsonAt (L : Limits) (t : Text) : Except (List Step × Error) Value :=
  match readHausJson L t with
  | .ok v => .ok v
  | .error e => .error (hausJsonTextPlace L (dropBom t), e)

/--
**Self-describing JSON Lines** as `readHausJsonLines` reads them, an error
with its place: the index of the line, counted from 0, then the place in
its value (`$[3]._value._num`). An empty line, and a byte order mark at the
start of a line after the first, are `json-syntax` at their line (§16,
"Streams").
-/
def readHausJsonLinesAt (L : Limits) (t : Text) : Except (List Step × Error) (List Value) :=
  match readHausJsonLines L t with
  | .ok vs => .ok vs
  | .error e =>
    let ls := lines (dropBom t)
    let rejected (l : Text) : Bool := l.isEmpty || (readHausJsonText L l).toOption.isNone
    let i := (ls.findIdx? rejected).getD 0
    .error (.index i :: hausJsonTextPlace L (ls.getD i []), e)

/-- The text of a value's self-describing JSON. -/
def writeHausJson (v : Value) : Text := write (hausJson v)

/-- Self-describing JSON Lines: each value's envelope, followed by a line feed. -/
def writeHausJsonLines (vs : List Value) : Text := vs.flatMap fun v => writeHausJson v ++ ['\n']

/-! ## Proofs: reading what is written -/

theorem tagged_nil (t : String) : tagged t [] = .obj [("_tag", .str t)] := rfl
theorem tagged_cons (t : String) (y : JSON) (ys : List JSON) :
    tagged t (y :: ys) = .obj [("_tag", .str t), ("_args", .arr (y :: ys))] := rfl

theorem selfDescribingList_eq : ∀ xs : List Value, selfDescribingList xs = xs.map selfDescribing
  | [] => rfl
  | x :: xs => by simp [selfDescribingList, selfDescribingList_eq xs]

theorem selfDescribingFields_eq : ∀ fs : List (String × Value), selfDescribingFields fs = fs.map fun kv => (kv.1, selfDescribing kv.2)
  | [] => rfl
  | (k, x) :: fs => by simp [selfDescribingFields, selfDescribingFields_eq fs]

mutual
/-- **A self-describing value reads back**: reading the self-describing form of a well-formed value gives the value. -/
theorem fromSelfDescribing_selfDescribing : ∀ v : Value, v.wf = true → fromSelfDescribing (selfDescribing v) = .ok v
  | .num s, h => by
    simp only [Value.wf] at h
    simp [selfDescribing, fromSelfDescribing, numOf, h]
  | .str s, _ => rfl
  | .bytes bs, _ => by
    simp [selfDescribing, fromSelfDescribing, bytesOf, Bytes.hex_decode_encode]
  | .arr xs, h => by
    simp only [Value.wf] at h
    simp [selfDescribing, fromSelfDescribing, fromSelfDescribingList_selfDescribingList xs h, Except.map]
  | .record fs, h => by
    simp only [Value.wf] at h
    simp [selfDescribing, fromSelfDescribing, fromSelfDescribingMembers_selfDescribingFields fs h, Except.map]
  | .variant t [], h => by
    simp only [Value.wf, Bool.and_eq_true] at h
    simp [selfDescribing, selfDescribingList, tagged_nil, fromSelfDescribing, tagOf, h.1, Except.map]
  | .variant t (x :: xs), h => by
    simp only [Value.wf, Bool.and_eq_true] at h
    have ih := fromSelfDescribingList_selfDescribingList (x :: xs) h.2
    simp only [selfDescribingList] at ih
    simp [selfDescribing, selfDescribingList, tagged_cons, fromSelfDescribing, tagOf, h.1, ih]
    rfl

theorem fromSelfDescribingList_selfDescribingList : ∀ xs : List Value, Value.wfList xs = true →
    fromSelfDescribingList (selfDescribingList xs) = .ok xs
  | [], _ => rfl
  | x :: xs, h => by
    simp only [Value.wfList, Bool.and_eq_true] at h
    simp only [selfDescribingList, fromSelfDescribingList, fromSelfDescribing_selfDescribing x h.1,
      fromSelfDescribingList_selfDescribingList xs h.2]
    rfl

theorem fromSelfDescribingMembers_selfDescribingFields : ∀ fs : List (String × Value), Value.wfFields fs = true →
    fromSelfDescribingMembers (selfDescribingFields fs) = .ok fs
  | [], _ => rfl
  | (k, x) :: fs, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at h
    simp only [selfDescribingFields, fromSelfDescribingMembers, fromSelfDescribing_selfDescribing x h.1,
      fromSelfDescribingMembers_selfDescribingFields fs h.2]
    rfl
end

/--
**Self-describing round trip without the envelope** (§16.2): for every
well-formed value `v`, reading its self-describing form gives a value equal
to `v` (§2). (In fact `v` itself.)
-/
theorem selfDescribing_read_write (v : Value) (h : v.wf = true) :
    ∃ w, fromSelfDescribing (selfDescribing v) = .ok w ∧ Value.Equiv w v :=
  ⟨v, fromSelfDescribing_selfDescribing v h, rfl⟩

/-! ## Proofs: only self-describing forms are read -/

theorem bind_ok {α β ε : Type} {r : Except ε α} {f : α → Except ε β} {y : β} :
    (r >>= f) = .ok y ↔ ∃ x, r = .ok x ∧ f x = .ok y := by
  cases r <;> simp [bind, Except.bind]

theorem map_ok {α β ε : Type} {r : Except ε α} {f : α → β} {y : β} :
    r.map f = .ok y ↔ ∃ x, r = .ok x ∧ f x = y := by
  cases r <;> simp [Except.map]

theorem pure_ok {α ε : Type} {x y : α} : (pure x : Except ε α) = .ok y ↔ x = y := by
  simp [pure, Except.pure]

/-- Two members, sorted: `_args` before `_tag`. -/
theorem sort_tag_args (a b : JSON) :
    [("_tag", a), ("_args", b)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("_args", b), ("_tag", a)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("_tag" ≤ "_args") = false by decide, Bool.false_eq_true, ↓reduceIte]

theorem sort_args_tag (a b : JSON) :
    [("_args", b), ("_tag", a)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("_args", b), ("_tag", a)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("_args" ≤ "_tag") = true by decide, ↓reduceIte]

theorem canon_tagged (t : String) (y : JSON) (ys : List JSON) :
    (tagged t (y :: ys)).canon = .obj [("_args", .arr (canonList (y :: ys))), ("_tag", .str t)] := by
  simp only [tagged_cons, canon, canonMembers, sort_tag_args]

theorem tagOf_ok {x : JSON} {t : String} : tagOf x = .ok t ↔ x = .str t ∧ isTag t.toList = true := by
  cases x <;> simp only [tagOf, reduceCtorEq, false_and, JSON.str.injEq]
  rename_i t'
  by_cases hs : isTag t'.toList = true
  · simp only [hs, ↓reduceIte, Except.ok.injEq]
    exact ⟨fun h => ⟨h, h ▸ hs⟩, fun h => h.1⟩
  · simp only [hs, Bool.false_eq_true, ↓reduceIte, reduceCtorEq, false_iff, not_and]
    intro he; subst he; exact hs

theorem tagArgs_ok {x y : JSON} {ys : List JSON} {v : Value}
    (h : (do
      let t ← tagOf x
      let vs ← fromSelfDescribingList (y :: ys)
      pure (Value.variant t vs)) = .ok v) :
    ∃ t vs, x = .str t ∧ isTag t.toList = true ∧ fromSelfDescribingList (y :: ys) = .ok vs ∧ v = .variant t vs := by
  obtain ⟨t, ht, h⟩ := bind_ok.mp h
  obtain ⟨vs, hvs, h⟩ := bind_ok.mp h
  obtain ⟨hx, hs⟩ := tagOf_ok.mp ht
  exact ⟨t, vs, hx, hs, hvs, (pure_ok.mp h).symm⟩

/-- What the self-describing reader accepts in an object: one of the forms `selfDescribing` writes. -/
theorem fromSelfDescribing_obj {ms : List (String × JSON)} {v : Value} (h : fromSelfDescribing (.obj ms) = .ok v) :
    (∃ s, ms = [("_num", .str s)] ∧ isNormalLit s.toList = true ∧ v = .num s) ∨
    (∃ hx bs, ms = [("_bytes", .str hx)] ∧ Bytes.unhex hx.toList = some bs ∧ v = .bytes bs) ∨
    (∃ ms' fs, ms = [("_rec", .obj ms')] ∧ fromSelfDescribingMembers ms' = .ok fs ∧ v = .record fs) ∨
    (∃ t, ms = [("_tag", .str t)] ∧ isTag t.toList = true ∧ v = .variant t []) ∨
    (∃ t y ys vs, (ms = [("_tag", .str t), ("_args", .arr (y :: ys))] ∨
      ms = [("_args", .arr (y :: ys)), ("_tag", .str t)]) ∧
      isTag t.toList = true ∧ fromSelfDescribingList (y :: ys) = .ok vs ∧ v = .variant t vs) := by
  unfold fromSelfDescribing at h
  split at h
  · rename_i heq; cases heq
  · rename_i heq; cases heq
  · rename_i x heq; cases heq
    cases x <;> simp only [numOf, reduceCtorEq] at h
    rename_i s
    by_cases hs : isNormalLit s.toList = true
    · simp only [hs, ↓reduceIte, Except.ok.injEq] at h
      exact .inl ⟨s, rfl, hs, h.symm⟩
    · simp [hs] at h
  · rename_i x heq; cases heq
    cases x <;> simp only [bytesOf, reduceCtorEq] at h
    rename_i hx
    cases hu : Bytes.unhex hx.toList with
    | none => simp [hu] at h
    | some bs =>
      simp only [hu, Except.ok.injEq] at h
      exact .inr (.inl ⟨hx, bs, rfl, hu, h.symm⟩)
  · rename_i ms' heq; cases heq
    obtain ⟨fs, hfs, rfl⟩ := map_ok.mp h
    exact .inr (.inr (.inl ⟨ms', fs, rfl, hfs, rfl⟩))
  · rename_i x heq; cases heq
    obtain ⟨t, ht, rfl⟩ := map_ok.mp h
    obtain ⟨rfl, hs⟩ := tagOf_ok.mp ht
    exact .inr (.inr (.inr (.inl ⟨t, rfl, hs, rfl⟩)))
  · rename_i x y ys heq; cases heq
    obtain ⟨t, vs, rfl, hs, hvs, rfl⟩ := tagArgs_ok h
    exact .inr (.inr (.inr (.inr ⟨t, y, ys, vs, .inl rfl, hs, hvs, rfl⟩)))
  · rename_i y ys x heq; cases heq
    obtain ⟨t, vs, rfl, hs, hvs, rfl⟩ := tagArgs_ok h
    exact .inr (.inr (.inr (.inr ⟨t, y, ys, vs, .inr rfl, hs, hvs, rfl⟩)))
  · simp at h

mutual
/--
**Only self-describing forms are read** (§16.2): a JSON value
`fromSelfDescribing` accepts is, as data, the self-describing form of the
value it reads.
-/
theorem selfDescribing_unique : ∀ (j : JSON) (v : Value), fromSelfDescribing j = .ok v → Equiv (selfDescribing v) j
  | .null, _, h | .bool _, _, h | .num _, _, h => by simp [fromSelfDescribing] at h
  | .str s, v, h => by
    simp only [fromSelfDescribing, Except.ok.injEq] at h
    subst h; rfl
  | .arr xs, v, h => by
    simp only [fromSelfDescribing, map_ok] at h
    obtain ⟨vs, hvs, rfl⟩ := h
    have := selfDescribingList_unique xs vs hvs
    simp only [Equiv, selfDescribing, canon, this]
  | .obj ms, v, h => by
    rcases fromSelfDescribing_obj h with ⟨s, rfl, -, rfl⟩ | ⟨hx, bs, rfl, hu, rfl⟩ | ⟨ms', fs, rfl, hfs, rfl⟩ |
      ⟨t, rfl, -, rfl⟩ | ⟨t, y, ys, vs, hms, -, hvs, rfl⟩
    · rfl
    · simp only [Equiv, selfDescribing, Bytes.hex_encode_decode _ _ hu, String.ofList_toList]
    · have := selfDescribingMembers_unique ms' fs hfs
      simp only [Equiv, selfDescribing, canon, canonMembers, this]
    · rfl
    · have := selfDescribingList_unique (y :: ys) vs hvs
      obtain ⟨w, ws, rfl⟩ : ∃ w ws, vs = w :: ws := by
        cases vs with
        | nil => simp [selfDescribingList, canonList] at this
        | cons w ws => exact ⟨w, ws, rfl⟩
      have e : selfDescribingList (w :: ws) = selfDescribing w :: selfDescribingList ws := rfl
      rw [e] at this
      rcases hms with rfl | rfl
      · simp only [Equiv, selfDescribing, e, canon_tagged, this, canon, canonMembers, sort_tag_args]
      · simp only [Equiv, selfDescribing, e, canon_tagged, this, canon, canonMembers, sort_args_tag]

theorem selfDescribingList_unique : ∀ (xs : List JSON) (vs : List Value), fromSelfDescribingList xs = .ok vs →
    canonList (selfDescribingList vs) = canonList xs
  | [], vs, h => by
    simp only [fromSelfDescribingList, Except.ok.injEq] at h; subst h; rfl
  | x :: xs, vs, h => by
    simp only [fromSelfDescribingList, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    have h1 : canon (selfDescribing w) = canon x := selfDescribing_unique x w hw
    simp only [selfDescribingList, canonList, h1, selfDescribingList_unique xs ws hws]

theorem selfDescribingMembers_unique : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    fromSelfDescribingMembers ms = .ok fs → canonMembers (selfDescribingFields fs) = canonMembers ms
  | [], fs, h => by
    simp only [fromSelfDescribingMembers, Except.ok.injEq] at h; subst h; rfl
  | (k, x) :: ms, fs, h => by
    simp only [fromSelfDescribingMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    have h1 : canon (selfDescribing w) = canon x := selfDescribing_unique x w hw
    simp only [selfDescribingFields, canonMembers, h1, selfDescribingMembers_unique ms ws hws]
end

mutual
/-- What the self-describing reader returns is well formed. -/
theorem fromSelfDescribing_wf : ∀ (j : JSON) (v : Value), fromSelfDescribing j = .ok v → v.wf = true
  | .null, _, h | .bool _, _, h | .num _, _, h => by simp [fromSelfDescribing] at h
  | .str s, v, h => by
    simp only [fromSelfDescribing, Except.ok.injEq] at h
    subst h; rfl
  | .arr xs, v, h => by
    simp only [fromSelfDescribing, map_ok] at h
    obtain ⟨vs, hvs, rfl⟩ := h
    simp only [Value.wf, fromSelfDescribingList_wf xs vs hvs]
  | .obj ms, v, h => by
    rcases fromSelfDescribing_obj h with ⟨s, rfl, hs, rfl⟩ | ⟨hx, bs, rfl, hu, rfl⟩ | ⟨ms', fs, rfl, hfs, rfl⟩ |
      ⟨t, rfl, hs, rfl⟩ | ⟨t, y, ys, vs, hms, hs, hvs, rfl⟩
    · simpa [Value.wf] using hs
    · rfl
    · simp only [Value.wf, fromSelfDescribingMembers_wf ms' fs hfs]
    · simp [Value.wf, Value.wfList, hs]
    · simp [Value.wf, hs, fromSelfDescribingList_wf _ vs hvs]

theorem fromSelfDescribingList_wf : ∀ (xs : List JSON) (vs : List Value), fromSelfDescribingList xs = .ok vs →
    Value.wfList vs = true
  | [], vs, h => by
    simp only [fromSelfDescribingList, Except.ok.injEq] at h; subst h; rfl
  | x :: xs, vs, h => by
    simp only [fromSelfDescribingList, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    simp only [Value.wfList, fromSelfDescribing_wf x w hw, fromSelfDescribingList_wf xs ws hws, Bool.and_self]

theorem fromSelfDescribingMembers_wf : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    fromSelfDescribingMembers ms = .ok fs → Value.wfFields fs = true
  | [], fs, h => by
    simp only [fromSelfDescribingMembers, Except.ok.injEq] at h; subst h; rfl
  | (k, x) :: ms, fs, h => by
    simp only [fromSelfDescribingMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    simp only [Value.wfFields, fromSelfDescribing_wf x w hw, fromSelfDescribingMembers_wf ms ws hws, Bool.and_self]
end

/-! ## Proofs: one self-describing form per value -/

mutual
/-- The self-describing form in canonical member order: `canon (selfDescribing v)` for a value in canonical order. -/
def canonSelfDescribing : Value → JSON
  | .num s => .obj [("_num", .str s)]
  | .str s => .str s
  | .bytes bs => .obj [("_bytes", .str (String.ofList (Bytes.hex bs)))]
  | .arr xs => .arr (canonSelfDescribingList xs)
  | .record fs => .obj [("_rec", .obj (canonSelfDescribingFields fs))]
  | .variant t [] => .obj [("_tag", .str t)]
  | .variant t (x :: xs) => .obj [("_args", .arr (canonSelfDescribingList (x :: xs))), ("_tag", .str t)]

def canonSelfDescribingList : List Value → List JSON
  | [] => []
  | x :: xs => canonSelfDescribing x :: canonSelfDescribingList xs

def canonSelfDescribingFields : List (String × Value) → List (String × JSON)
  | [] => []
  | (k, x) :: fs => (k, canonSelfDescribing x) :: canonSelfDescribingFields fs
end

theorem canonSelfDescribingList_eq : ∀ xs : List Value, canonSelfDescribingList xs = xs.map canonSelfDescribing
  | [] => rfl
  | x :: xs => by simp [canonSelfDescribingList, canonSelfDescribingList_eq xs]

theorem canonSelfDescribingFields_eq : ∀ fs : List (String × Value),
    canonSelfDescribingFields fs = fs.map fun kv => (kv.1, canonSelfDescribing kv.2)
  | [] => rfl
  | (k, x) :: fs => by simp [canonSelfDescribingFields, canonSelfDescribingFields_eq fs]

theorem value_canonList_eq : ∀ xs : List Value, Value.canonList xs = xs.map Value.canon
  | [] => rfl
  | x :: xs => by simp [Value.canonList, value_canonList_eq xs]

theorem value_canonFields_eq : ∀ fs : List (String × Value),
    Value.canonFields fs = fs.map fun kv => (kv.1, kv.2.canon)
  | [] => rfl
  | (k, v) :: fs => by simp [Value.canonFields, value_canonFields_eq fs]

mutual
/-- Comparing self-describing forms as data is comparing the values in canonical order. -/
theorem canon_selfDescribing : ∀ v : Value, (selfDescribing v).canon = canonSelfDescribing v.canon
  | .num s => by simp only [selfDescribing, canon, canonMembers, List.mergeSort_singleton, Value.canon, canonSelfDescribing]
  | .str s => rfl
  | .bytes bs => by simp only [selfDescribing, canon, canonMembers, List.mergeSort_singleton, Value.canon, canonSelfDescribing]
  | .arr xs => by
    simp only [selfDescribing, canon, Value.canon, canonSelfDescribing, canonList_selfDescribing xs]
  | .record fs => by
    simp only [selfDescribing, canon, Value.canon, canonSelfDescribing, canonMembers, List.mergeSort_singleton]
    congr 2
    rw [canonMembers_selfDescribingFields fs, canonSelfDescribingFields_eq, value_canonFields_eq,
      List.map_mergeSort (r := fun (a b : String × Value) => decide (a.1 ≤ b.1))
        (s := fun (a b : String × JSON) => decide (a.1 ≤ b.1))
        (f := fun kv => (kv.1, canonSelfDescribing kv.2)) (fun _ _ _ _ => rfl), List.map_map]
    rfl
  | .variant t [] => by
    simp only [selfDescribing, selfDescribingList, tagged_nil, canon, canonMembers, List.mergeSort_singleton, Value.canon,
      Value.canonList, canonSelfDescribing]
  | .variant t (x :: xs) => by
    have := canonList_selfDescribing (x :: xs)
    simp only [selfDescribing, selfDescribingList] at this ⊢
    simp only [canon_tagged, this, Value.canon, Value.canonList, canonSelfDescribing]

theorem canonList_selfDescribing : ∀ xs : List Value,
    canonList (selfDescribingList xs) = canonSelfDescribingList (Value.canonList xs)
  | [] => rfl
  | x :: xs => by
    simp only [selfDescribingList, canonList, Value.canonList, canonSelfDescribingList, canon_selfDescribing x,
      canonList_selfDescribing xs]

theorem canonMembers_selfDescribingFields : ∀ fs : List (String × Value),
    canonMembers (selfDescribingFields fs) = fs.map fun kv => (kv.1, canonSelfDescribing kv.2.canon)
  | [] => rfl
  | (k, x) :: fs => by
    simp only [selfDescribingFields, canonMembers, canon_selfDescribing x, canonMembers_selfDescribingFields fs, List.map_cons]
end

mutual
theorem canonSelfDescribing_inj : ∀ a b : Value, canonSelfDescribing a = canonSelfDescribing b → a = b
  | .num s, b, h => by
    cases b with
    | num s' => simp only [canonSelfDescribing, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h; rw [h.1.2]
    | variant t ys => cases ys <;> simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .str s, b, h => by
    cases b with
    | str s' => simp only [canonSelfDescribing, str.injEq] at h; rw [h]
    | variant t ys => cases ys <;> simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .bytes bs, b, h => by
    cases b with
    | bytes bs' =>
      simp only [canonSelfDescribing, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h
      rw [Bytes.hex_injective (String.ofList_injective h.1.2)]
    | variant t ys => cases ys <;> simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .arr xs, b, h => by
    cases b with
    | arr ys => simp only [canonSelfDescribing, arr.injEq] at h; rw [canonSelfDescribingList_inj xs ys h]
    | variant t ys => cases ys <;> simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .record fs, b, h => by
    cases b with
    | record gs =>
      simp only [canonSelfDescribing, obj.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at h
      rw [canonSelfDescribingFields_inj fs gs h]
    | variant t ys => cases ys <;> simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .variant t [], b, h => by
    cases b with
    | variant t' ys =>
      cases ys with
      | nil => simp only [canonSelfDescribing, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h; rw [h.1.2]
      | cons y ys => simp [canonSelfDescribing] at h
    | _ => simp [canonSelfDescribing] at h
  | .variant t (x :: xs), b, h => by
    cases b with
    | variant t' ys =>
      cases ys with
      | nil => simp [canonSelfDescribing] at h
      | cons y ys =>
        simp only [canonSelfDescribing, obj.injEq, List.cons.injEq, Prod.mk.injEq, arr.injEq, str.injEq, true_and,
          and_true] at h
        rw [h.2, canonSelfDescribingList_inj (x :: xs) (y :: ys) h.1]
    | _ => simp [canonSelfDescribing] at h

theorem canonSelfDescribingList_inj : ∀ xs ys : List Value, canonSelfDescribingList xs = canonSelfDescribingList ys → xs = ys
  | [], [], _ => rfl
  | [], _ :: _, h | _ :: _, [], h => by simp [canonSelfDescribingList] at h
  | x :: xs, y :: ys, h => by
    simp only [canonSelfDescribingList, List.cons.injEq] at h
    rw [canonSelfDescribing_inj x y h.1, canonSelfDescribingList_inj xs ys h.2]

theorem canonSelfDescribingFields_inj : ∀ fs gs : List (String × Value),
    canonSelfDescribingFields fs = canonSelfDescribingFields gs → fs = gs
  | [], [], _ => rfl
  | [], _ :: _, h | _ :: _, [], h => by simp [canonSelfDescribingFields] at h
  | (k, x) :: fs, (k', y) :: gs, h => by
    simp only [canonSelfDescribingFields, List.cons.injEq, Prod.mk.injEq] at h
    rw [h.1.1, canonSelfDescribing_inj x y h.1.2, canonSelfDescribingFields_inj fs gs h.2]
end

/--
**One self-describing form per value** (§16.2): two values have the same
self-describing form, compared as data, exactly when they are equal (§2).
Holds for every value, well formed or not.
-/
theorem selfDescribing_equiv_iff (a b : Value) : Equiv (selfDescribing a) (selfDescribing b) ↔ Value.Equiv a b := by
  unfold Equiv Value.Equiv
  rw [canon_selfDescribing, canon_selfDescribing]
  exact ⟨canonSelfDescribing_inj _ _, fun h => by rw [h]⟩

/-! ## Proofs: the envelope -/

theorem unwrap_envelope (j : JSON) : unwrap (envelope j) = .ok j := rfl

/-- What `unwrap` accepts: the envelope, in either member order. -/
theorem unwrap_ok {j j' : JSON} (h : unwrap j = .ok j') :
    j = envelope j' ∨ j = .obj [("_value", j'), ("_haus", .num "1")] := by
  unfold unwrap at h
  split at h
  · split at h
    · cases h; exact .inl rfl
    · cases h
  · split at h
    · cases h; exact .inr rfl
    · cases h
  · cases h

theorem sort_haus_value (a b : JSON) :
    [("_haus", a), ("_value", b)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("_haus", a), ("_value", b)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("_haus" ≤ "_value") = true by decide, ↓reduceIte]

theorem sort_value_haus (a b : JSON) :
    [("_value", b), ("_haus", a)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("_haus", a), ("_value", b)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("_value" ≤ "_haus") = false by decide, Bool.false_eq_true, ↓reduceIte]

theorem canon_envelope (j : JSON) : (envelope j).canon = .obj [("_haus", .num "1"), ("_value", j.canon)] := by
  simp only [envelope, canon, canonMembers, sort_haus_value]

/-- **Self-describing JSON reads back** (§16.2): with the envelope, for every well-formed value. -/
theorem fromHausJson_hausJson (v : Value) (h : v.wf = true) : fromHausJson (hausJson v) = .ok v := by
  simp only [fromHausJson, hausJson, unwrap_envelope]
  exact fromSelfDescribing_selfDescribing v h

/--
**Self-describing round trip** (§16.2): for every well-formed value `v`,
reading its self-describing JSON gives a value equal to `v` (§2). (In fact
`v` itself.)
-/
theorem hausJson_read_write (v : Value) (h : v.wf = true) :
    ∃ w, fromHausJson (hausJson v) = .ok w ∧ Value.Equiv w v :=
  ⟨v, fromHausJson_hausJson v h, rfl⟩

/--
**Only self-describing JSON is read** (§16.2): a JSON value the reader
accepts is, as data, the self-describing JSON of the value it reads.
-/
theorem hausJson_unique (j : JSON) (v : Value) (h : fromHausJson j = .ok v) : Equiv (hausJson v) j := by
  obtain ⟨j', hu, hv⟩ := bind_ok.mp h
  have hc : canon (selfDescribing v) = canon j' := selfDescribing_unique j' v hv
  unfold Equiv
  rw [hausJson, canon_envelope, hc]
  rcases unwrap_ok hu with rfl | rfl
  · rw [canon_envelope]
  · simp only [canon, canonMembers, sort_value_haus]

/-- What the self-describing reader returns is well formed. -/
theorem fromHausJson_wf (j : JSON) (v : Value) (h : fromHausJson j = .ok v) : v.wf = true := by
  obtain ⟨j', -, hv⟩ := bind_ok.mp h
  exact fromSelfDescribing_wf j' v hv

/--
**One self-describing JSON per value** (§16.2): two values have the same
self-describing JSON, compared as data, exactly when they are equal (§2).
Holds for every value, well formed or not.
-/
theorem hausJson_equiv_iff (a b : Value) : Equiv (hausJson a) (hausJson b) ↔ Value.Equiv a b := by
  rw [← selfDescribing_equiv_iff]
  unfold Equiv hausJson
  rw [canon_envelope, canon_envelope]
  constructor
  · intro h; simp only [obj.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at h; exact h
  · intro h; rw [h]

/-! ## Tests -/

private def hausJsonText (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] => some (String.ofList (writeHausJson v))
  | _ => none

#guard hausJsonText "Order { total: 19.90, id: 0xFF, b: x\"0B34\", t: [None, Some(1)] }" ==
  some "{\"_haus\":1,\"_value\":{\"_tag\":\"Order\",\"_args\":[{\"_rec\":{\"total\":{\"_num\":\"19.90\"},\"id\":{\"_num\":\"255\"},\"b\":{\"_bytes\":\"0b34\"},\"t\":[{\"_tag\":\"None\"},{\"_tag\":\"Some\",\"_args\":[{\"_num\":\"1\"}]}]}}]}}"
#guard hausJsonText "\"a\\u{7F}\\u{85}\\u{202E}b\"" == some "{\"_haus\":1,\"_value\":\"a\\u007f\\u0085\\u202eb\"}"

/-- Reading `{"_haus": 1, "_value": VALUE}`. -/
private def readValue (value : String) : Except Error Value :=
  readHausJson {} ("{\"_haus\": 1, \"_value\": " ++ value ++ "}").toList

private def readsValue (value : String) : Bool := (readValue value).toOption.isSome

#guard readsValue "{\"_args\": [{\"_num\": \"1\"}], \"_tag\": \"Some\"}"
#guard !readsValue "{\"_tag\": \"T\", \"_args\": []}" && !readsValue "{\"_num\": \"1E5\"}"
#guard !readsValue "{\"_num\": \"0xFF\"}" && !readsValue "{\"_bytes\": \"0B34\"}"
#guard !readsValue "{\"_rec\": {\"a\": 1}}" && !readsValue "{\"_num\": \"1\", \"x\": 2}"
#guard !readsValue "{\"_num\": \"1e6145\"}" && readsValue "{\"_num\": \"1e6144\"}"
#guard !readsValue "{\"num\": \"1\"}" && !readsValue "{\"tag\": \"A\"}"
#guard (readHausJson {} "\uFEFF{\"_value\": \"a\", \"_haus\": 1}".toList).toOption.isSome

private def importText (src : String) : Option String :=
  (readImport {} src.toList).toOption.map fun v => String.ofList (Canonical.canonical v)

#guard importText "{\"a\": 1, \"b\": [true, false, null], \"c\": \"x\"}" == some "{a:1,b:[True,False,None],c:\"x\"}"
#guard importText "1E+05" == some "1e5" && importText "-0" == some "-0" && importText "19.90" == some "19.90"
#guard importText "\uFEFF[1]" == some "[1]"
#guard importText "{\"_haus\": 1, \"_value\": \"a\u007F\"}" == some "{_haus:1,_value:\"a\\u{7F}\"}"
#guard (readImport { maxDepth := 2 } "[[1]]".toList).toOption.isSome
#guard (readImport { maxDepth := 2 } "[[[1]]]".toList).toOption.isNone

private def codeOf (r : Except Error Value) : Option Code :=
  match r with
  | .error e => some e.code
  | .ok _ => none

private def hausJsonCode (src : String) : Option Code := codeOf (readHausJson {} src.toList)

-- Error codes (spec §17).
#guard codeOf (readValue "{\"_tag\": \"T\", \"_args\": []}") == some .hausJsonForm
#guard codeOf (readValue "{\"_num\": \"1E5\"}") == some .hausJsonNumber
#guard codeOf (readValue "{\"_bytes\": \"0B34\"}") == some .hausJsonBytes
#guard codeOf (readValue "{\"_tag\": \"t\"}") == some .invalidTag
#guard codeOf (readValue "{\"_num\": \"1e6145\"}") == some .exponentTooLarge
-- `_num` within the number limit (§7): 1000 characters; an integer's hex form doesn't count.
#guard codeOf (readValue ("{\"_num\": \"" ++ toString (10 ^ 999) ++ "\"}")) == none
#guard codeOf (readValue ("{\"_num\": \"" ++ toString (10 ^ 1000) ++ "\"}")) == some .numberTooLong
#guard codeOf (readValue ("{\"_num\": \"-" ++ toString (16 ^ 829 - 1) ++ "\"}")) == none
#guard codeOf (readValue "1") == some .hausJsonForm
#guard codeOf (readValue "{\"_tag\": \"\", \"_args\": \"\"}") == some .invalidTag
#guard codeOf (readValue "{\"_args\": [], \"_tag\": 1}") == some .invalidTag
#guard codeOf (readValue "{\"_tag\": \"T\", \"_args\": \"\"}") == some .hausJsonForm
-- The envelope.
#guard hausJsonCode "{\"_num\": \"1\"}" == some .hausJsonForm && hausJsonCode "\"a\"" == some .hausJsonForm
#guard hausJsonCode "{\"_haus\": 1}" == some .hausJsonForm
#guard hausJsonCode "{\"_haus\": 1, \"_value\": \"a\", \"x\": 1}" == some .hausJsonForm
#guard hausJsonCode "{\"_haus\": 2, \"_value\": \"a\"}" == some .hausJsonVersion
#guard hausJsonCode "{\"_haus\": \"1\", \"_value\": \"a\"}" == some .hausJsonVersion
#guard hausJsonCode "{\"_haus\": 1.0, \"_value\": \"a\"}" == some .hausJsonVersion
-- Raw DEL, C1 and bidi controls; escaped, they are read.
#guard codeOf (readValue "\"a\u007Fb\"") == some .controlCharacter && codeOf (readValue "\"a\u0085b\"") == some .controlCharacter
#guard codeOf (readValue "\"a\u202Eb\"") == some .bidiControl
#guard codeOf (readValue "{\"_rec\": {\"a\u2066\": \"b\"}}") == some .bidiControl
#guard readsValue "\"a\\u007f\\u0085\\u202eb\""
-- Where the string lexer meets them: before a later error, in an unfinished text too.
#guard hausJsonCode "{\"\":1,\"\u009B" == some .controlCharacter && hausJsonCode "{\"_haus\": 1, \"_value\": \"\u0085" == some .controlCharacter
#guard hausJsonCode "{\"\u2067" == some .bidiControl
#guard codeOf (readImport {} "{\"\":1,\"\u009B".toList) == some .unterminatedString
-- A value at the depth limit reads, in `4 · d + 2` JSON levels; one deeper does not.
#guard (readHausJson { maxDepth := 1 } "{\"_haus\": 1, \"_value\": {\"_tag\": \"T\", \"_args\": [{\"_rec\": {\"a\": \"b\"}}]}}".toList).toOption.isSome
#guard (readHausJson { maxDepth := 1 } "{\"_haus\": 1, \"_value\": {\"_tag\": \"T\", \"_args\": [{\"_rec\": {\"a\": []}}]}}".toList).toOption.isNone
-- JSON Lines: one envelope per line.
#guard (readHausJsonLines {} "{\"_haus\": 1, \"_value\": \"a\"}\r\n{\"_haus\": 1, \"_value\": []}".toList).toOption.map (·.length) == some 2
#guard (readHausJsonLines {} "\"a\"\n".toList).toOption.isNone && (readHausJsonLines {} "".toList).toOption == some []
-- An empty line, and a byte order mark at the start of a later line, are `json-syntax`, at their line (§16, "Streams").
private def linesError (s : String) : Option (String × Code) :=
  match readHausJsonLinesAt {} s.toList with
  | .error (p, e) => some (placeText p, e.code)
  | .ok _ => none
private def env1 : String := "{\"_haus\": 1, \"_value\": \"a\"}"
#guard linesError (env1 ++ "\n\n" ++ env1) == some ("$[1]", .jsonSyntax)
#guard linesError (env1 ++ "\r\n\r\n") == some ("$[1]", .jsonSyntax)
#guard linesError (env1 ++ "\n\uFEFF" ++ env1) == some ("$[1]", .jsonSyntax)
#guard (readHausJsonLinesAt {} ("\uFEFF" ++ env1 ++ "\n" ++ env1).toList).toOption.map (·.length) == some 2
-- Places from the JSON text's root, the line's index first in JSON Lines (§16.3 "Places").
#guard linesError (env1 ++ "\n" ++ env1 ++ "\n{\"_haus\": 1, \"_value\": [\"a\", {\"_num\": \"01\"}]}") == some ("$[2]._value[1]._num", .hausJsonNumber)
private def placeOf (s : String) : Option String :=
  match readHausJsonAt {} s.toList with
  | .error (p, _) => some (placeText p)
  | .ok _ => none
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_tag\": \"T\", \"_args\": [\"a\", {\"_bytes\": \"0B\"}]}}" == some "$._value._args[1]._bytes"
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_rec\": {\"a\": \"b\", \"pt-BR\": 1}}}" == some "$._value._rec[\"pt-BR\"]"
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_tag\": 1}}" == some "$._value"
#guard placeOf "{\"_haus\": 2, \"_value\": \"a\"}" == some "$._haus"
#guard placeOf "{\"_value\": \"a\"}" == some "$"
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_tag\": \"T\", \"_args\": []}}" == some "$._value._args"
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_args\": 5, \"_tag\": \"T\"}}" == some "$._value._args"
#guard placeOf "{\"_haus\": 1, \"_value\": {\"_tag\": \"t\", \"_args\": []}}" == some "$._value"
#guard placeOf "{\"_haus\": 1, \"_value\": \"a\"" == some "$"

-- Lengths are counted on the haus value (§16, "Limits"): a member name as a key, a `_tag` as a tag.
private def codeIn (read : Text → Except Error Value) (s : String) : Option Code :=
  match read s.toList with
  | .error e => some e.code
  | .ok _ => none
#guard codeIn (readImport { maxStringLength := 3 }) "{\"abcd\": 1}" == some .keyTooLong
#guard codeIn (readImport { maxStringLength := 3 }) "[\"abcd\"]" == some .stringTooLong
#guard codeIn (readImport { maxStringLength := 4 }) "{\"_tag\": \"Abcde\"}" == some .stringTooLong
#guard codeIn (readImport { maxStringLength := 3 }) "{\"abc\": \"abc\"}" == none
#guard codeIn (readHausJson { maxStringLength := 6 }) "{\"_haus\": 1, \"_value\": {\"_tag\": \"Abcdefg\"}}" == some .tagTooLong
#guard codeIn (readHausJson { maxStringLength := 6 }) "{\"_haus\": 1, \"_value\": {\"_rec\": {\"abcdefg\": \"x\"}}}" == some .keyTooLong
#guard codeIn (readHausJson { maxStringLength := 6 }) "{\"_haus\": 1, \"_value\": [\"abcdefg\"]}" == some .stringTooLong
#guard codeIn (readHausJson { maxStringLength := 6 }) "{\"_haus\": 1, \"_value\": {\"_tag\": \"Abcdef\"}}" == none
-- Bytes count two characters per byte, as in the hex of a haus byte string.
#guard codeIn (readHausJson { maxStringLength := 6 }) "{\"_haus\": 1, \"_value\": {\"_bytes\": \"00112233\"}}" == some .stringTooLong

end JSON
end Haus
