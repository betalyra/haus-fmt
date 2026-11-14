import Haus.Json.Text

/-!
# JSON without a schema (spec §16.1) and lossless JSON (§16.2)

- `JSON.toValue`: any JSON reads as a haus value (§16.1).
- `lossless v`: the lossless form of a haus value; `fromLossless` reads it.

What is proven, about `JSON` as data:

| Theorem | Says |
|---|---|
| `fromLossless_lossless` | Reading the lossless form of a value gives the value back |
| `lossless_read_write` | The same, up to `Value.Equiv`, as §16.2 states it |
| `lossless_unique` | Every JSON the reader accepts is the lossless form of the value it reads, as data (`JSON.Equiv`) |
| `lossless_equiv_iff` | Two values have the same lossless form, as data, exactly when they are equal (§2) |
| `fromLossless_wf` | What the reader returns is well formed: normalized numbers, tags |

The round trip needs the value to be well formed (`Value.wf`): its
numbers are normalized literals and its tags are tags, as for every value
the parser returns. A `Value` built by hand can hold any string as a
number. `lossless_equiv_iff` needs nothing.

The limits (§7) are checked separately, on the value read (`Value.fits`):
`readLossless` reads text, maps it and checks them.
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
/-- Every number, string and byte string within the limits. -/
def leaves (L : Limits) : Value → Bool
  | .num s => JSON.numberFits L s.toList
  | .str s => s.length ≤ L.maxStringLength
  | .bytes bs => 2 * bs.length ≤ L.maxStringLength
  | .arr xs => leavesList L xs
  | .record fs => leavesFields L fs
  | .variant _ xs => leavesList L xs

def leavesList (L : Limits) : List Value → Bool
  | [] => true
  | x :: xs => leaves L x && leavesList L xs

def leavesFields (L : Limits) : List (String × Value) → Bool
  | [] => true
  | (_, x) :: fs => leaves L x && leavesFields L fs
end

/--
**Within the limits** (§7): a haus text could write the value within them.
Numbers as in `JSON.numberFits`; a byte string takes two hex digits a byte.
-/
def fits (L : Limits) (v : Value) : Bool := v.depth ≤ L.maxDepth && leaves L v

end Value

namespace JSON

/-! ## §16.1: JSON without a schema -/

mutual
/--
**JSON as a haus value** (§16.1): an object as a record, an array as an
array, a string as a string, a number as a number with its literal
normalized (§2), `true` and `false` as `True` and `False`, `null` as `None`.
-/
def toValue : JSON → Except String Value
  | .null => .ok (.variant "None" [])
  | .bool b => .ok (.variant (if b then "True" else "False") [])
  | .num t => if isJsonNumber t.toList then .ok (.num (normalizeNumber t.toList)) else .error "not a JSON number"
  | .str s => .ok (.str s)
  | .arr xs => (toValueList xs).map .arr
  | .obj ms => (toValueMembers ms).map .record

def toValueList : List JSON → Except String (List Value)
  | [] => .ok []
  | x :: xs => do return (← toValue x) :: (← toValueList xs)

def toValueMembers : List (String × JSON) → Except String (List (String × Value))
  | [] => .ok []
  | (k, x) :: ms => do return (k, ← toValue x) :: (← toValueMembers ms)
end

/-! ## §16.2: lossless -/

/-- `{"tag": T}` without arguments, `{"tag": T, "args": […]}` with them. -/
def tagged (t : String) (args : List JSON) : JSON :=
  .obj (("tag", .str t) :: if args.isEmpty then [] else [("args", .arr args)])

mutual
/-- **The lossless form** of a haus value (§16.2). -/
def lossless : Value → JSON
  | .num s => .obj [("num", .str s)]
  | .str s => .str s
  | .bytes bs => .obj [("bytes", .str (String.ofList (Bytes.hex bs)))]
  | .arr xs => .arr (losslessList xs)
  | .record fs => .obj [("rec", .obj (losslessFields fs))]
  | .variant t xs => tagged t (losslessList xs)

def losslessList : List Value → List JSON
  | [] => []
  | x :: xs => lossless x :: losslessList xs

def losslessFields : List (String × Value) → List (String × JSON)
  | [] => []
  | (k, x) :: fs => (k, lossless x) :: losslessFields fs
end

/-- `{"num": "…"}`: a normalized literal. -/
def numOf : JSON → Except String Value
  | .str s => if isNormalLit s.toList then .ok (.num s) else .error "num: not a normalized number literal"
  | _ => .error "num: not a string"

/-- `{"bytes": "…"}`: lowercase hex digits in pairs. -/
def bytesOf : JSON → Except String Value
  | .str h =>
    match Bytes.unhex h.toList with
    | some bs => .ok (.bytes bs)
    | none => .error "bytes: not lowercase hex digits in pairs"
  | _ => .error "bytes: not a string"

/-- `{"tag": "…"}`: a tag. -/
def tagOf : JSON → Except String String
  | .str t => if isTag t.toList then .ok t else .error "tag: not a tag"
  | _ => .error "tag: not a string"

mutual
/--
**Reading lossless JSON** (§16.2): exactly the forms `lossless` writes, in
any member order, and nothing else. A `num` must be a normalized literal,
`bytes` lowercase hex, a `tag` a tag, and `args` not empty.
-/
def fromLossless : JSON → Except String Value
  | .str s => .ok (.str s)
  | .arr xs => (fromLosslessList xs).map .arr
  | .obj [("num", x)] => numOf x
  | .obj [("bytes", x)] => bytesOf x
  | .obj [("rec", .obj ms)] => (fromLosslessMembers ms).map .record
  | .obj [("tag", x)] => (tagOf x).map (.variant · [])
  | .obj [("tag", x), ("args", .arr (y :: ys))] => do
    let t ← tagOf x
    return .variant t (← fromLosslessList (y :: ys))
  | .obj [("args", .arr (y :: ys)), ("tag", x)] => do
    let t ← tagOf x
    return .variant t (← fromLosslessList (y :: ys))
  | _ => .error "not a lossless value"

def fromLosslessList : List JSON → Except String (List Value)
  | [] => .ok []
  | x :: xs => do return (← fromLossless x) :: (← fromLosslessList xs)

def fromLosslessMembers : List (String × JSON) → Except String (List (String × Value))
  | [] => .ok []
  | (k, x) :: ms => do return (k, ← fromLossless x) :: (← fromLosslessMembers ms)
end

/-! ## Reading text -/

def checkFits (L : Limits) (v : Value) : Except String Value :=
  if v.fits L then .ok v else .error "outside the limits"

/-- JSON text without a schema, within the limits (§16.1): JSON nesting at most `d`. -/
def readSchemaless (L : Limits) (t : Text) : Except String Value := do
  checkFits L (← toValue (← parseDepth L L.maxDepth t))

/-- Lossless JSON text, within the limits (§16.2). -/
def readLossless (L : Limits) (t : Text) : Except String Value := do
  checkFits L (← fromLossless (← parse L t))

/-- The text of a value's lossless form. -/
def writeLossless (v : Value) : Text := write (lossless v)

/-! ## Proofs: reading what is written -/

theorem tagged_nil (t : String) : tagged t [] = .obj [("tag", .str t)] := rfl
theorem tagged_cons (t : String) (y : JSON) (ys : List JSON) :
    tagged t (y :: ys) = .obj [("tag", .str t), ("args", .arr (y :: ys))] := rfl

theorem losslessList_eq : ∀ xs : List Value, losslessList xs = xs.map lossless
  | [] => rfl
  | x :: xs => by simp [losslessList, losslessList_eq xs]

theorem losslessFields_eq : ∀ fs : List (String × Value), losslessFields fs = fs.map fun kv => (kv.1, lossless kv.2)
  | [] => rfl
  | (k, x) :: fs => by simp [losslessFields, losslessFields_eq fs]

mutual
/-- **Lossless reads back**: reading the lossless form of a well-formed value gives the value. -/
theorem fromLossless_lossless : ∀ v : Value, v.wf = true → fromLossless (lossless v) = .ok v
  | .num s, h => by
    simp only [Value.wf] at h
    simp [lossless, fromLossless, numOf, h]
  | .str s, _ => rfl
  | .bytes bs, _ => by
    simp [lossless, fromLossless, bytesOf, Bytes.hex_decode_encode]
  | .arr xs, h => by
    simp only [Value.wf] at h
    simp [lossless, fromLossless, fromLosslessList_losslessList xs h, Except.map]
  | .record fs, h => by
    simp only [Value.wf] at h
    simp [lossless, fromLossless, fromLosslessMembers_losslessFields fs h, Except.map]
  | .variant t [], h => by
    simp only [Value.wf, Bool.and_eq_true] at h
    simp [lossless, losslessList, tagged_nil, fromLossless, tagOf, h.1, Except.map]
  | .variant t (x :: xs), h => by
    simp only [Value.wf, Bool.and_eq_true] at h
    have ih := fromLosslessList_losslessList (x :: xs) h.2
    simp only [losslessList] at ih
    simp [lossless, losslessList, tagged_cons, fromLossless, tagOf, h.1, ih]
    rfl

theorem fromLosslessList_losslessList : ∀ xs : List Value, Value.wfList xs = true →
    fromLosslessList (losslessList xs) = .ok xs
  | [], _ => rfl
  | x :: xs, h => by
    simp only [Value.wfList, Bool.and_eq_true] at h
    simp only [losslessList, fromLosslessList, fromLossless_lossless x h.1,
      fromLosslessList_losslessList xs h.2]
    rfl

theorem fromLosslessMembers_losslessFields : ∀ fs : List (String × Value), Value.wfFields fs = true →
    fromLosslessMembers (losslessFields fs) = .ok fs
  | [], _ => rfl
  | (k, x) :: fs, h => by
    simp only [Value.wfFields, Bool.and_eq_true] at h
    simp only [losslessFields, fromLosslessMembers, fromLossless_lossless x h.1,
      fromLosslessMembers_losslessFields fs h.2]
    rfl
end

/--
**Lossless round trip** (§16.2): for every well-formed value `v`, reading
its lossless JSON gives a value equal to `v` (§2). (In fact `v` itself.)
-/
theorem lossless_read_write (v : Value) (h : v.wf = true) :
    ∃ w, fromLossless (lossless v) = .ok w ∧ Value.Equiv w v :=
  ⟨v, fromLossless_lossless v h, rfl⟩

/-! ## Proofs: only lossless forms are read -/

theorem bind_ok {α β ε : Type} {r : Except ε α} {f : α → Except ε β} {y : β} :
    (r >>= f) = .ok y ↔ ∃ x, r = .ok x ∧ f x = .ok y := by
  cases r <;> simp [bind, Except.bind]

theorem map_ok {α β ε : Type} {r : Except ε α} {f : α → β} {y : β} :
    r.map f = .ok y ↔ ∃ x, r = .ok x ∧ f x = y := by
  cases r <;> simp [Except.map]

theorem pure_ok {α ε : Type} {x y : α} : (pure x : Except ε α) = .ok y ↔ x = y := by
  simp [pure, Except.pure]

/-- Two members, sorted: `args` before `tag`. -/
theorem sort_tag_args (a b : JSON) :
    [("tag", a), ("args", b)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("args", b), ("tag", a)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("tag" ≤ "args") = false by decide, Bool.false_eq_true, ↓reduceIte]

theorem sort_args_tag (a b : JSON) :
    [("args", b), ("tag", a)].mergeSort (fun p q => decide (p.1 ≤ q.1)) = [("args", b), ("tag", a)] := by
  rw [List.mergeSort_pair]
  simp only [show decide ("args" ≤ "tag") = true by decide, ↓reduceIte]

theorem canon_tagged (t : String) (y : JSON) (ys : List JSON) :
    (tagged t (y :: ys)).canon = .obj [("args", .arr (canonList (y :: ys))), ("tag", .str t)] := by
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
      let vs ← fromLosslessList (y :: ys)
      pure (Value.variant t vs)) = .ok v) :
    ∃ t vs, x = .str t ∧ isTag t.toList = true ∧ fromLosslessList (y :: ys) = .ok vs ∧ v = .variant t vs := by
  obtain ⟨t, ht, h⟩ := bind_ok.mp h
  obtain ⟨vs, hvs, h⟩ := bind_ok.mp h
  obtain ⟨hx, hs⟩ := tagOf_ok.mp ht
  exact ⟨t, vs, hx, hs, hvs, (pure_ok.mp h).symm⟩

/-- What the lossless reader accepts in an object: one of the forms `lossless` writes. -/
theorem fromLossless_obj {ms : List (String × JSON)} {v : Value} (h : fromLossless (.obj ms) = .ok v) :
    (∃ s, ms = [("num", .str s)] ∧ isNormalLit s.toList = true ∧ v = .num s) ∨
    (∃ hx bs, ms = [("bytes", .str hx)] ∧ Bytes.unhex hx.toList = some bs ∧ v = .bytes bs) ∨
    (∃ ms' fs, ms = [("rec", .obj ms')] ∧ fromLosslessMembers ms' = .ok fs ∧ v = .record fs) ∨
    (∃ t, ms = [("tag", .str t)] ∧ isTag t.toList = true ∧ v = .variant t []) ∨
    (∃ t y ys vs, (ms = [("tag", .str t), ("args", .arr (y :: ys))] ∨
      ms = [("args", .arr (y :: ys)), ("tag", .str t)]) ∧
      isTag t.toList = true ∧ fromLosslessList (y :: ys) = .ok vs ∧ v = .variant t vs) := by
  unfold fromLossless at h
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
**Only lossless forms are read** (§16.2): a JSON value the lossless reader
accepts is, as data, the lossless form of the value it reads.
-/
theorem lossless_unique : ∀ (j : JSON) (v : Value), fromLossless j = .ok v → Equiv (lossless v) j
  | .null, _, h | .bool _, _, h | .num _, _, h => by simp [fromLossless] at h
  | .str s, v, h => by
    simp only [fromLossless, Except.ok.injEq] at h
    subst h; rfl
  | .arr xs, v, h => by
    simp only [fromLossless, map_ok] at h
    obtain ⟨vs, hvs, rfl⟩ := h
    have := losslessList_unique xs vs hvs
    simp only [Equiv, lossless, canon, this]
  | .obj ms, v, h => by
    rcases fromLossless_obj h with ⟨s, rfl, -, rfl⟩ | ⟨hx, bs, rfl, hu, rfl⟩ | ⟨ms', fs, rfl, hfs, rfl⟩ |
      ⟨t, rfl, -, rfl⟩ | ⟨t, y, ys, vs, hms, -, hvs, rfl⟩
    · rfl
    · simp only [Equiv, lossless, Bytes.hex_encode_decode _ _ hu, String.ofList_toList]
    · have := losslessMembers_unique ms' fs hfs
      simp only [Equiv, lossless, canon, canonMembers, this]
    · rfl
    · have := losslessList_unique (y :: ys) vs hvs
      obtain ⟨w, ws, rfl⟩ : ∃ w ws, vs = w :: ws := by
        cases vs with
        | nil => simp [losslessList, canonList] at this
        | cons w ws => exact ⟨w, ws, rfl⟩
      have e : losslessList (w :: ws) = lossless w :: losslessList ws := rfl
      rw [e] at this
      rcases hms with rfl | rfl
      · simp only [Equiv, lossless, e, canon_tagged, this, canon, canonMembers, sort_tag_args]
      · simp only [Equiv, lossless, e, canon_tagged, this, canon, canonMembers, sort_args_tag]

theorem losslessList_unique : ∀ (xs : List JSON) (vs : List Value), fromLosslessList xs = .ok vs →
    canonList (losslessList vs) = canonList xs
  | [], vs, h => by
    simp only [fromLosslessList, Except.ok.injEq] at h; subst h; rfl
  | x :: xs, vs, h => by
    simp only [fromLosslessList, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    have h1 : canon (lossless w) = canon x := lossless_unique x w hw
    simp only [losslessList, canonList, h1, losslessList_unique xs ws hws]

theorem losslessMembers_unique : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    fromLosslessMembers ms = .ok fs → canonMembers (losslessFields fs) = canonMembers ms
  | [], fs, h => by
    simp only [fromLosslessMembers, Except.ok.injEq] at h; subst h; rfl
  | (k, x) :: ms, fs, h => by
    simp only [fromLosslessMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    have h1 : canon (lossless w) = canon x := lossless_unique x w hw
    simp only [losslessFields, canonMembers, h1, losslessMembers_unique ms ws hws]
end

mutual
/-- What the lossless reader returns is well formed. -/
theorem fromLossless_wf : ∀ (j : JSON) (v : Value), fromLossless j = .ok v → v.wf = true
  | .null, _, h | .bool _, _, h | .num _, _, h => by simp [fromLossless] at h
  | .str s, v, h => by
    simp only [fromLossless, Except.ok.injEq] at h
    subst h; rfl
  | .arr xs, v, h => by
    simp only [fromLossless, map_ok] at h
    obtain ⟨vs, hvs, rfl⟩ := h
    simp only [Value.wf, fromLosslessList_wf xs vs hvs]
  | .obj ms, v, h => by
    rcases fromLossless_obj h with ⟨s, rfl, hs, rfl⟩ | ⟨hx, bs, rfl, hu, rfl⟩ | ⟨ms', fs, rfl, hfs, rfl⟩ |
      ⟨t, rfl, hs, rfl⟩ | ⟨t, y, ys, vs, hms, hs, hvs, rfl⟩
    · simpa [Value.wf] using hs
    · rfl
    · simp only [Value.wf, fromLosslessMembers_wf ms' fs hfs]
    · simp [Value.wf, Value.wfList, hs]
    · simp [Value.wf, hs, fromLosslessList_wf _ vs hvs]

theorem fromLosslessList_wf : ∀ (xs : List JSON) (vs : List Value), fromLosslessList xs = .ok vs →
    Value.wfList vs = true
  | [], vs, h => by
    simp only [fromLosslessList, Except.ok.injEq] at h; subst h; rfl
  | x :: xs, vs, h => by
    simp only [fromLosslessList, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    simp only [Value.wfList, fromLossless_wf x w hw, fromLosslessList_wf xs ws hws, Bool.and_self]

theorem fromLosslessMembers_wf : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    fromLosslessMembers ms = .ok fs → Value.wfFields fs = true
  | [], fs, h => by
    simp only [fromLosslessMembers, Except.ok.injEq] at h; subst h; rfl
  | (k, x) :: ms, fs, h => by
    simp only [fromLosslessMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    simp only [Value.wfFields, fromLossless_wf x w hw, fromLosslessMembers_wf ms ws hws, Bool.and_self]
end

/-! ## Proofs: one lossless form per value -/

mutual
/-- The lossless form in canonical member order: `canon (lossless v)` for a value in canonical order. -/
def canonLossless : Value → JSON
  | .num s => .obj [("num", .str s)]
  | .str s => .str s
  | .bytes bs => .obj [("bytes", .str (String.ofList (Bytes.hex bs)))]
  | .arr xs => .arr (canonLosslessList xs)
  | .record fs => .obj [("rec", .obj (canonLosslessFields fs))]
  | .variant t [] => .obj [("tag", .str t)]
  | .variant t (x :: xs) => .obj [("args", .arr (canonLosslessList (x :: xs))), ("tag", .str t)]

def canonLosslessList : List Value → List JSON
  | [] => []
  | x :: xs => canonLossless x :: canonLosslessList xs

def canonLosslessFields : List (String × Value) → List (String × JSON)
  | [] => []
  | (k, x) :: fs => (k, canonLossless x) :: canonLosslessFields fs
end

theorem canonLosslessList_eq : ∀ xs : List Value, canonLosslessList xs = xs.map canonLossless
  | [] => rfl
  | x :: xs => by simp [canonLosslessList, canonLosslessList_eq xs]

theorem canonLosslessFields_eq : ∀ fs : List (String × Value),
    canonLosslessFields fs = fs.map fun kv => (kv.1, canonLossless kv.2)
  | [] => rfl
  | (k, x) :: fs => by simp [canonLosslessFields, canonLosslessFields_eq fs]

theorem value_canonList_eq : ∀ xs : List Value, Value.canonList xs = xs.map Value.canon
  | [] => rfl
  | x :: xs => by simp [Value.canonList, value_canonList_eq xs]

theorem value_canonFields_eq : ∀ fs : List (String × Value),
    Value.canonFields fs = fs.map fun kv => (kv.1, kv.2.canon)
  | [] => rfl
  | (k, v) :: fs => by simp [Value.canonFields, value_canonFields_eq fs]

mutual
/-- Comparing lossless forms as data is comparing the values in canonical order. -/
theorem canon_lossless : ∀ v : Value, (lossless v).canon = canonLossless v.canon
  | .num s => by simp only [lossless, canon, canonMembers, List.mergeSort_singleton, Value.canon, canonLossless]
  | .str s => rfl
  | .bytes bs => by simp only [lossless, canon, canonMembers, List.mergeSort_singleton, Value.canon, canonLossless]
  | .arr xs => by
    simp only [lossless, canon, Value.canon, canonLossless, canonList_lossless xs]
  | .record fs => by
    simp only [lossless, canon, Value.canon, canonLossless, canonMembers, List.mergeSort_singleton]
    congr 2
    rw [canonMembers_losslessFields fs, canonLosslessFields_eq, value_canonFields_eq,
      List.map_mergeSort (r := fun (a b : String × Value) => decide (a.1 ≤ b.1))
        (s := fun (a b : String × JSON) => decide (a.1 ≤ b.1))
        (f := fun kv => (kv.1, canonLossless kv.2)) (fun _ _ _ _ => rfl), List.map_map]
    rfl
  | .variant t [] => by
    simp only [lossless, losslessList, tagged_nil, canon, canonMembers, List.mergeSort_singleton, Value.canon,
      Value.canonList, canonLossless]
  | .variant t (x :: xs) => by
    have := canonList_lossless (x :: xs)
    simp only [lossless, losslessList] at this ⊢
    simp only [canon_tagged, this, Value.canon, Value.canonList, canonLossless]

theorem canonList_lossless : ∀ xs : List Value,
    canonList (losslessList xs) = canonLosslessList (Value.canonList xs)
  | [] => rfl
  | x :: xs => by
    simp only [losslessList, canonList, Value.canonList, canonLosslessList, canon_lossless x,
      canonList_lossless xs]

theorem canonMembers_losslessFields : ∀ fs : List (String × Value),
    canonMembers (losslessFields fs) = fs.map fun kv => (kv.1, canonLossless kv.2.canon)
  | [] => rfl
  | (k, x) :: fs => by
    simp only [losslessFields, canonMembers, canon_lossless x, canonMembers_losslessFields fs, List.map_cons]
end

mutual
theorem canonLossless_inj : ∀ a b : Value, canonLossless a = canonLossless b → a = b
  | .num s, b, h => by
    cases b with
    | num s' => simp only [canonLossless, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h; rw [h.1.2]
    | variant t ys => cases ys <;> simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .str s, b, h => by
    cases b with
    | str s' => simp only [canonLossless, str.injEq] at h; rw [h]
    | variant t ys => cases ys <;> simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .bytes bs, b, h => by
    cases b with
    | bytes bs' =>
      simp only [canonLossless, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h
      rw [Bytes.hex_injective (String.ofList_injective h.1.2)]
    | variant t ys => cases ys <;> simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .arr xs, b, h => by
    cases b with
    | arr ys => simp only [canonLossless, arr.injEq] at h; rw [canonLosslessList_inj xs ys h]
    | variant t ys => cases ys <;> simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .record fs, b, h => by
    cases b with
    | record gs =>
      simp only [canonLossless, obj.injEq, List.cons.injEq, Prod.mk.injEq, true_and, and_true] at h
      rw [canonLosslessFields_inj fs gs h]
    | variant t ys => cases ys <;> simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .variant t [], b, h => by
    cases b with
    | variant t' ys =>
      cases ys with
      | nil => simp only [canonLossless, obj.injEq, List.cons.injEq, Prod.mk.injEq, str.injEq] at h; rw [h.1.2]
      | cons y ys => simp [canonLossless] at h
    | _ => simp [canonLossless] at h
  | .variant t (x :: xs), b, h => by
    cases b with
    | variant t' ys =>
      cases ys with
      | nil => simp [canonLossless] at h
      | cons y ys =>
        simp only [canonLossless, obj.injEq, List.cons.injEq, Prod.mk.injEq, arr.injEq, str.injEq, true_and,
          and_true] at h
        rw [h.2, canonLosslessList_inj (x :: xs) (y :: ys) h.1]
    | _ => simp [canonLossless] at h

theorem canonLosslessList_inj : ∀ xs ys : List Value, canonLosslessList xs = canonLosslessList ys → xs = ys
  | [], [], _ => rfl
  | [], _ :: _, h | _ :: _, [], h => by simp [canonLosslessList] at h
  | x :: xs, y :: ys, h => by
    simp only [canonLosslessList, List.cons.injEq] at h
    rw [canonLossless_inj x y h.1, canonLosslessList_inj xs ys h.2]

theorem canonLosslessFields_inj : ∀ fs gs : List (String × Value),
    canonLosslessFields fs = canonLosslessFields gs → fs = gs
  | [], [], _ => rfl
  | [], _ :: _, h | _ :: _, [], h => by simp [canonLosslessFields] at h
  | (k, x) :: fs, (k', y) :: gs, h => by
    simp only [canonLosslessFields, List.cons.injEq, Prod.mk.injEq] at h
    rw [h.1.1, canonLossless_inj x y h.1.2, canonLosslessFields_inj fs gs h.2]
end

/--
**One lossless form per value** (§16.2): two values have the same lossless
JSON, compared as data, exactly when they are equal (§2). Holds for every
value, well formed or not.
-/
theorem lossless_equiv_iff (a b : Value) : Equiv (lossless a) (lossless b) ↔ Value.Equiv a b := by
  unfold Equiv Value.Equiv
  rw [canon_lossless, canon_lossless]
  exact ⟨canonLossless_inj _ _, fun h => by rw [h]⟩

/-! ## Tests -/

private def losslessText (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] => some (String.ofList (writeLossless v))
  | _ => none

#guard losslessText "Order { total: 19.90, id: 0xFF, b: x\"0B34\", t: [None, Some(1)] }" ==
  some "{\"tag\":\"Order\",\"args\":[{\"rec\":{\"total\":{\"num\":\"19.90\"},\"id\":{\"num\":\"255\"},\"b\":{\"bytes\":\"0b34\"},\"t\":[{\"tag\":\"None\"},{\"tag\":\"Some\",\"args\":[{\"num\":\"1\"}]}]}}]}"

private def readsLossless (src : String) : Bool := (readLossless {} src.toList).toOption.isSome

#guard readsLossless "{\"args\": [{\"num\": \"1\"}], \"tag\": \"Some\"}"
#guard !readsLossless "{\"tag\": \"T\", \"args\": []}" && !readsLossless "{\"num\": \"1E5\"}"
#guard !readsLossless "{\"num\": \"0xFF\"}" && !readsLossless "{\"bytes\": \"0B34\"}"
#guard !readsLossless "{\"rec\": {\"a\": 1}}" && !readsLossless "{\"num\": \"1\", \"x\": 2}"
#guard !readsLossless "{\"num\": \"1e6145\"}" && readsLossless "{\"num\": \"1e6144\"}"

private def schemaless (src : String) : Option String :=
  (readSchemaless {} src.toList).toOption.map fun v => String.ofList (Canonical.canonical v)

#guard schemaless "{\"a\": 1, \"b\": [true, false, null], \"c\": \"x\"}" == some "{a:1,b:[True,False,None],c:\"x\"}"
#guard schemaless "1E+05" == some "1e5" && schemaless "-0" == some "-0" && schemaless "19.90" == some "19.90"
#guard schemaless "\uFEFF[1]" == some "[1]"
#guard (readSchemaless { maxDepth := 2 } "[[1]]".toList).toOption.isSome
#guard (readSchemaless { maxDepth := 2 } "[[[1]]]".toList).toOption.isNone

end JSON
end Haus
