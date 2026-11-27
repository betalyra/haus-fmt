import Haus.Json.WellFormed
import Haus.Props.Values
import Haus.Layout.Pretty

/-!
# Values: checked when built, total afterwards (spec §7, §11, §12)

A binding's value type holds haus values only (§11). Beyond its shape, a
haus value is **valid** (`Value.Valid`): every number is a normalized
literal and every tag a tag (`Value.wf`, §2, §4), and every record, at any
depth, has unique keys (`UniqueKeys`, §1). Strings are valid Unicode by
Lean's `Char` (A5).

`Built` is a value as a binding holds it: valid, with its size (§7, the
values it is written as) and its depth (§7, counted as for values built in
code) recorded when it was built. Building is the only step that can fail:

* the constructors (`Built.num`, `Built.str`, `Built.bytes`, `Built.arr`,
  `Built.record`, `Built.variant`) check what they add against the limits
  of §7, so that a value that exists is within them: a literal
  (`invalid-number`, and on its normalized literal `number-too-long`,
  `exponent-too-large`), a string or byte string (`string-too-long`), a
  tag (`invalid-tag`, `tag-too-long`), the keys of one record
  (`duplicate-key`, `key-too-long`), and a container's depth and size
  (`nesting-too-deep`, `too-many-nodes`). The order of these checks is not
  part of the specification (§17). `container_within` and its uses
  (`arr_within`, `record_within`, `variant_within`): a built container is
  within the depth and node limits; `num_fits`, `str_fits`, `bytes_fits`:
  a built leaf is within the limits.
* parsing builds valid values directly (`parse_valid`, from `parse_wf` and
  A3), within the parser's limits (A4) but for the node limit, which it
  doesn't apply (§7): a parsed value is held as it is (`Built.ofParsed`).
  A container built from parts counts their depths and sizes; their lengths
  were checked when they were built.

On a built value the canonical form, the input of its hash, equality,
order and the layouts are functions, total by their types, with no error
to report (§11, §12). Equality is defined by the canonical form
(`equals`), and equal values (§2) are `equals` (`equals_of_equiv`). Writer
options are checked when they are made: `Layout.Options` holds natural
numbers, so nothing is left to check when writing.

The model computes a container's depth from its value; a binding computes
it from its parts' recorded depths, one `max` per part, as it does the size.
Lean's values are trees whose parts are never shared, so a value's size is
also its size in memory, and nothing can change a value after it is built:
the safety net of §11 (`value-changed`) has nothing to catch here.
-/

namespace Haus
open Canonical

namespace Value

/-- **A valid value** (§1, §2, §4, §11): numbers normalized, tags tags, keys unique, at any depth. -/
def Valid (v : Value) : Prop := v.wf = true ∧ UniqueKeys v

end Value

/-- **Every value the reference parser returns is valid** (§11: parsing builds valid values). -/
theorem parse_valid {L : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs) :
    ∀ v ∈ vs, v.Valid :=
  fun v hv => ⟨parse_wf h v hv, Grammar.File.uniqueKeys (Sound.parse_sound L input vs h) v hv⟩

/--
**A value as a binding holds it** (§11): valid, with its size and depth
(§7) recorded when it was built.
-/
structure Built where
  value : Value
  size : Nat
  depth : Nat
  valid : value.Valid
  size_eq : size = value.nodes
  depth_eq : depth = value.depth

namespace Built

/-- A parsed value, held as it is: valid (`parse_valid`), within the parser's limits, and not counted against the node limit (§7). -/
def ofParsed (v : Value) (hv : v.Valid) : Built := ⟨v, v.nodes, v.depth, hv, rfl, rfl⟩

/-! ## The constructors: the only step that can fail -/

theorem wfList_map (xs : List Built) : Value.wfList (xs.map Built.value) = true :=
  wfList_of (by intro x hx; obtain ⟨b, _, rfl⟩ := List.mem_map.mp hx; exact b.valid.1)

theorem wfFields_map (fs : List (String × Built)) :
    Value.wfFields (fs.map fun kb => (kb.1, kb.2.value)) = true :=
  wfFields_of (by intro kv hkv; obtain ⟨⟨k, b⟩, _, rfl⟩ := List.mem_map.mp hkv; exact b.valid.1)

theorem uniqueKeys_map (xs : List Built) : ∀ x ∈ xs.map Built.value, UniqueKeys x := by
  intro x hx; obtain ⟨b, _, rfl⟩ := List.mem_map.mp hx; exact b.valid.2

theorem uniqueKeys_fields (fs : List (String × Built)) :
    ∀ kv ∈ fs.map (fun kb => (kb.1, kb.2.value)), UniqueKeys kv.2 := by
  intro kv hkv; obtain ⟨⟨k, b⟩, _, rfl⟩ := List.mem_map.mp hkv; exact b.valid.2

/-- The parts' sizes add up: the size of a container is one more than its parts' (§7). -/
theorem nodesList_map : ∀ xs : List Built, Value.nodesList (xs.map Built.value) = (xs.map Built.size).sum
  | [] => rfl
  | b :: bs => by simp [Value.nodesList, nodesList_map bs, b.size_eq]

theorem nodesFields_map : ∀ fs : List (String × Built),
    Value.nodesFields (fs.map fun kb => (kb.1, kb.2.value)) = (fs.map fun kb => kb.2.size).sum
  | [] => rfl
  | (_, b) :: fs => by simp [Value.nodesFields, nodesFields_map fs, b.size_eq]

/-- A value without parts: size 1, depth 0. -/
def leaf (L : Limits) (v : Value) (hv : v.Valid) (h1 : v.nodes = 1) : Except Code Built :=
  if 1 ≤ L.maxNodes then .ok ⟨v, 1, v.depth, hv, h1.symm, rfl⟩ else .error .tooManyNodes

/--
A number from a literal in any spelling (§11), normalized as the parser
does: `1E+05` is `1e5`, `0xFF` is `255`. Text that isn't one number literal
(`01`, `NaN`, empty) is `invalid-number`. The number limits (§7) are
measured on the normalized literal, as it is written: `number-too-long`,
`exponent-too-large` (§11).
-/
def num (L : Limits) (lit : String) : Except Code Built :=
  match Parser.lexNumber lit.toList with
  | some n =>
    if n.rest = [] then
      if hs : isNormalLit (normalizeNumber n.literal).toList = true then
        if JSON.numberFits L (normalizeNumber n.literal).toList then
          leaf L (.num (normalizeNumber n.literal)) ⟨by simp [Value.wf, hs], .num _⟩ (by simp [Value.nodes])
        else .error (JSON.tokenCode L (normalizeNumber n.literal).toList)
      else .error .invalidNumber
    else .error .invalidNumber
  | none => .error .invalidNumber

/-- A string: every Lean string is valid Unicode (A5); at most `maxStringLength` characters. -/
def str (L : Limits) (s : String) : Except Code Built :=
  if s.length ≤ L.maxStringLength then leaf L (.str s) ⟨by simp [Value.wf], .str s⟩ (by simp [Value.nodes])
  else .error .stringTooLong

/-- A byte string: two hex digits a byte within `maxStringLength`, as the parser counts them. -/
def bytes (L : Limits) (bs : List UInt8) : Except Code Built :=
  if 2 * bs.length ≤ L.maxStringLength then leaf L (.bytes bs) ⟨by simp [Value.wf], .bytes bs⟩ (by simp [Value.nodes])
  else .error .stringTooLong

/-- A container: its depth within `maxDepth` (`nesting-too-deep`), its size within `maxNodes` (`too-many-nodes`). -/
def container (L : Limits) (v : Value) (hv : v.Valid) (size : Nat) (hs : size = v.nodes) : Except Code Built :=
  if v.depth ≤ L.maxDepth then
    if size ≤ L.maxNodes then .ok ⟨v, size, v.depth, hv, hs, rfl⟩ else .error .tooManyNodes
  else .error .nestingTooDeep

/-- An array of built values: one addition per part for its size (§7). -/
def arr (L : Limits) (xs : List Built) : Except Code Built :=
  container L (.arr (xs.map Built.value)) ⟨by simp [Value.wf, wfList_map], .arr _ (uniqueKeys_map xs)⟩
    ((xs.map Built.size).sum + 1) (by simp [Value.nodes, nodesList_map])

/-- A record: its keys unique (`duplicate-key`) and within the string limit (`key-too-long`). -/
def record (L : Limits) (fs : List (String × Built)) : Except Code Built :=
  if hk : (fs.map Prod.fst).Nodup then
    if fs.all fun kb => kb.1.length ≤ L.maxStringLength then
      container L (.record (fs.map fun kb => (kb.1, kb.2.value)))
        ⟨by simp [Value.wf, wfFields_map],
          .record _ (by simpa [List.map_map, Function.comp_def] using hk) (uniqueKeys_fields fs)⟩
        ((fs.map fun kb => kb.2.size).sum + 1) (by simp [Value.nodes, nodesFields_map])
    else .error .keyTooLong
  else .error .duplicateKey

/-- A variant: its tag a tag (`invalid-tag`, §4) within the string limit (`tag-too-long`). -/
def variant (L : Limits) (t : String) (xs : List Built) : Except Code Built :=
  if ht : isTag t.toList = true then
    if t.length ≤ L.maxStringLength then
      container L (.variant t (xs.map Built.value))
        ⟨by simp [Value.wf, ht, wfList_map], .variant _ _ (uniqueKeys_map xs)⟩
        ((xs.map Built.size).sum + 1) (by simp [Value.nodes, nodesList_map])
    else .error .tagTooLong
  else .error .invalidTag

/-! ## What exists is within the limits (§7) -/

theorem container_within {L : Limits} {v : Value} {hv : v.Valid} {s : Nat} {hs : s = v.nodes} {b : Built}
    (h : container L v hv s hs = .ok b) : b.depth ≤ L.maxDepth ∧ b.size ≤ L.maxNodes := by
  unfold container at h
  split at h
  · split at h
    · cases h; exact ⟨by assumption, by assumption⟩
    · cases h
  · cases h

theorem arr_within {L : Limits} {xs : List Built} {b : Built} (h : arr L xs = .ok b) :
    b.depth ≤ L.maxDepth ∧ b.size ≤ L.maxNodes :=
  container_within h

theorem record_within {L : Limits} {fs : List (String × Built)} {b : Built} (h : record L fs = .ok b) :
    b.depth ≤ L.maxDepth ∧ b.size ≤ L.maxNodes := by
  unfold record at h
  split at h
  · split at h
    · exact container_within h
    · cases h
  · cases h

theorem variant_within {L : Limits} {t : String} {xs : List Built} {b : Built} (h : variant L t xs = .ok b) :
    b.depth ≤ L.maxDepth ∧ b.size ≤ L.maxNodes := by
  unfold variant at h
  split at h
  · split at h
    · exact container_within h
    · cases h
  · cases h

theorem leaf_value {L : Limits} {v : Value} {hv : v.Valid} {h1 : v.nodes = 1} {b : Built}
    (h : leaf L v hv h1 = .ok b) : b.value = v := by
  unfold leaf at h
  split at h
  · cases h; rfl
  · cases h

theorem str_fits {L : Limits} {s : String} {b : Built} (h : str L s = .ok b) : b.value.fits L = true := by
  unfold str at h
  split at h
  · rw [leaf_value h]; simp_all [Value.fits, Value.depth, Value.leaves]
  · cases h

theorem bytes_fits {L : Limits} {bs : List UInt8} {b : Built} (h : bytes L bs = .ok b) : b.value.fits L = true := by
  unfold bytes at h
  split at h
  · rw [leaf_value h]; simp_all [Value.fits, Value.depth, Value.leaves]
  · cases h

theorem num_fits {L : Limits} {lit : String} {b : Built} (h : num L lit = .ok b) : b.value.fits L = true := by
  unfold num at h
  split at h
  · split at h
    · split at h
      · split at h
        · rw [leaf_value h]; simp_all [Value.fits, Value.depth, Value.leaves]
        · cases h
      · cases h
    · cases h
  · cases h

/-! ## Total afterwards (§11, §12)

Each of these is a function of the built value: it gives a result for every
value, and has no error to report. -/

/-- **The canonical form** (§12). -/
def canonical (v : Built) : Text := Canonical.canonical v.value

/-- **The input of `hash`** (§12): the UTF-8 bytes of the canonical form. The digest itself is not modelled. -/
def hashInput (v : Built) : List UInt8 := (String.ofList v.canonical).toUTF8.toList

/-- **Equality** (§2), defined by the canonical form (§12). -/
def equals (a b : Built) : Bool := a.canonical == b.canonical

/-- The order of two byte strings, a prefix first. -/
def bytesOrder : List UInt8 → List UInt8 → Ordering
  | [], [] => .eq
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt
  | x :: xs, y :: ys => if x < y then .lt else if y < x then .gt else bytesOrder xs ys

/-- **Order** (§12): by the UTF-8 bytes of the canonical forms, a prefix first. -/
def compare (a b : Built) : Ordering := bytesOrder a.hashInput b.hashInput

/-- The layouts (§11), for one value; a file of several with `Layout.compactAll`, `minimisedAll`, `prettyAll`. -/
def compact (v : Built) : Text := Layout.compact v.value
def minimised (v : Built) : Text := Layout.minimised v.value
def pretty (o : Layout.Options) (vs : List Built) : Text := Layout.prettyAll o (vs.map Built.value)

theorem equals_iff (a b : Built) : a.equals b = true ↔ a.canonical = b.canonical := by
  simp [equals]

/-- Equal values (§2) are `equals`: the canonical form is a function of the value up to §2. -/
theorem equals_of_equiv {a b : Built} (h : Value.Equiv a.value b.value) : a.equals b = true :=
  (equals_iff a b).mpr (RoundTrip.canonical_of_equiv h)

theorem bytesOrder_self : ∀ l : List UInt8, bytesOrder l l = .eq
  | [] => rfl
  | x :: xs => by simp [bytesOrder, bytesOrder_self xs]

theorem compare_self (a : Built) : a.compare a = .eq := bytesOrder_self _

/-! ## Examples -/

private def D : Limits := {}

-- Numbers from another spelling are normalized; text that isn't a literal is refused.
#guard ((num D "1E+05").toOption.map (·.value)) == some (.num "1e5")
#guard ((num D "0xFF").toOption.map (·.value)) == some (.num "255")
#guard num D "01" matches .error .invalidNumber
#guard num D "NaN" matches .error .invalidNumber
#guard num D "" matches .error .invalidNumber
-- The number limits, on the normalized literal: 1000 digits fit, 1001 don't; nor does `1e6145`.
#guard ((num D (toString (10 ^ 999))).toOption.map (·.value)) == some (.num (toString (10 ^ 999)))
#guard num D (toString (10 ^ 1000)) matches .error .numberTooLong
#guard num D "1e6145" matches .error .exponentTooLarge
-- A hex literal is measured as its decimal form: 830 hex digits of `f` are more than 1000 decimal digits.
#guard num D ("0x" ++ String.ofList (List.replicate 840 'f')) matches .error .numberTooLong
-- 600 digits with a `_` between each two: 1199 characters as written, 600 as normalized.
#guard (num D ("_".intercalate (List.replicate 600 "1"))).toOption.isSome
-- Lengths of strings, byte strings, keys and tags.
private def L3 : Limits := { maxStringLength := 3 }
#guard (str L3 "abc").toOption.isSome && str L3 "abcd" matches .error .stringTooLong
#guard bytes L3 [1, 2] matches .error .stringTooLong
#guard (do let a ← num L3 "1"; record L3 [("abcd", a)]) matches .error .keyTooLong
#guard variant L3 "Abcd" [] matches .error .tagTooLong
-- Tags and keys.
#guard variant D "lower" [] matches .error .invalidTag
#guard ((variant D "None" []).toOption.map (·.value)) == some (.variant "None" [])
#guard (do let a ← num D "1"; record D [("a", a), ("a", a)]) matches .error .duplicateKey
#guard ((do let a ← num D "1"; let b ← num D "2"; record D [("a", a), ("b", b)]).toOption.map Built.size) == some 3
-- The depth, counted as for values built in code: `T { a: [] }` is 2 levels, `T([])` too.
private def L1 : Limits := { maxDepth := 1 }
#guard ((do let e ← arr D []; let r ← record D [("a", e)]; variant D "T" [r]).toOption.map Built.depth) == some 2
#guard (do let e ← arr L1 []; arr L1 [e]) matches .error .nestingTooDeep
#guard ((do let one ← num L1 "1"; let r ← record L1 [("a", one)]; variant L1 "T" [r]).toOption.map Built.depth) == some 1
-- The node limit, where a value is built: x₀ = [], xₙ₊₁ = [xₙ, xₙ]. With a limit of 6, x₂ (size 7) is refused.
private def L6 : Limits := { maxNodes := 6 }
#guard ((do let x0 ← arr L6 []; arr L6 [x0, x0]).toOption.map Built.size) == some 3
#guard (do let x0 ← arr L6 []; let x1 ← arr L6 [x0, x0]; arr L6 [x1, x1]) matches .error .tooManyNodes
-- `T { a: 1 }` has size 3.
#guard ((do let one ← num D "1"; let r ← record D [("a", one)]; variant D "T" [r]).toOption.map Built.size) == some 3
-- Total afterwards: equality by the canonical form, whatever the key order.
#guard (do
    let one ← num D "1"; let two ← num D "2"
    let a ← record D [("a", one), ("b", two)]; let b ← record D [("b", two), ("a", one)]
    return (a.equals b, a.compare b)) matches .ok (true, .eq)

end Built
end Haus
