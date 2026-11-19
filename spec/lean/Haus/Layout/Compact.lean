import Haus.Canonical

/-!
# The compact and minimised layouts, from values (spec §11)

`compact v` and `minimised v` write a value on one line, as spec §11's
compact and minimised layouts write it when serializing values with no
source text: numbers as their normalized literal (always decimal), byte
strings as lowercase hex, strings as `"…"` with the minimal escapes (never a
block string, so a line feed is `\n`), keys bare when they can be. Fields
are written in the order given; nothing is sorted.

The two differ only in the whitespace between tokens (`Spacing`): compact
has `, ` and `: `, a space inside the braces of a non-empty record and
between a tag and its `{` (`Tag { a: 1 }`, `[1, 2]`, `Tag(a, b)`); minimised
has none, and is `Canonical.write` (`minimised_eq_write`): the canonical form
is the minimised layout of the value in canonical order
(`canonical_eq_minimised`).

A file or stream (`compactAll`, `minimisedAll`) is one value per line: a
single value without a comma, more than one each followed by `,`, every
line ending with a line feed; no values give the empty text.

The round trip is proven in `Haus.Layout.CompactRoundTrip`.
-/

namespace Haus.Layout
open Haus Canonical

/-- The whitespace a one-line layout writes between tokens. -/
structure Spacing where
  /-- After a `,` between items or fields. -/
  comma : Text
  /-- After the `:` of a field. -/
  colon : Text
  /-- After `{` and before `}` of a non-empty record. -/
  inner : Text
  /-- Between a tag and the `{` of its record payload. -/
  tag : Text

/-- Compact: `{ a: 1, b: [1, 2] }`. -/
def Spacing.spaced : Spacing := ⟨[' '], [' '], [' '], [' ']⟩

/-- Minimised: `{a:1,b:[1,2]}`. -/
def Spacing.tight : Spacing := ⟨[], [], [], []⟩

/-- A record's braces around its fields: `{}` when it has none. -/
def braces (sp : Spacing) (fs : List (String × Value)) (inside : Text) : Text :=
  match fs with
  | [] => ['{', '}']
  | _ :: _ => '{' :: sp.inner ++ inside ++ sp.inner ++ ['}']

mutual
/-- A value on one line, with the spacing `sp`. -/
def line (sp : Spacing) : Value → Text
  | .num s => number s
  | .str s => string s
  | .bytes bs => bytes bs
  | .arr xs => '[' :: lineList sp xs ++ [']']
  | .record fs => braces sp fs (lineFields sp fs)
  | .variant t [] => t.toList
  | .variant t [.record fs] => t.toList ++ sp.tag ++ braces sp fs (lineFields sp fs)
  | .variant t (x :: xs) => t.toList ++ '(' :: lineList sp (x :: xs) ++ [')']

/-- Values separated by `,` and the spacing. -/
def lineList (sp : Spacing) : List Value → Text
  | [] => []
  | [x] => line sp x
  | x :: xs => line sp x ++ ',' :: sp.comma ++ lineList sp xs

/-- `key: value` fields separated by `,` and the spacing. -/
def lineFields (sp : Spacing) : List (String × Value) → Text
  | [] => []
  | [(k, v)] => key k ++ ':' :: sp.colon ++ line sp v
  | (k, v) :: fs => key k ++ ':' :: sp.colon ++ line sp v ++ ',' :: sp.comma ++ lineFields sp fs
end

/-- **The compact layout** of a value (spec §11): `Person { name: "John Doe", age: 30 }`. -/
def compact (v : Value) : Text := line .spaced v

/-- **The minimised layout** of a value (spec §11): `Person{name:"John Doe",age:30}`. -/
def minimised (v : Value) : Text := line .tight v

/--
A file or stream in a one-line layout: nothing for no values, a single value
on its line without a comma, otherwise every value on its line followed by `,`.
-/
def lines (write : Value → Text) : List Value → Text
  | [] => []
  | [v] => write v ++ ['\n']
  | v :: w :: ws => (v :: w :: ws).flatMap fun x => write x ++ [',', '\n']

/-- **A file or stream in the compact layout.** -/
def compactAll (vs : List Value) : Text := lines compact vs

/-- **A file or stream in the minimised layout.** -/
def minimisedAll (vs : List Value) : Text := lines minimised vs

/-! ## Minimised is the canonical writer -/

@[simp] theorem tight_comma : Spacing.tight.comma = [] := rfl
@[simp] theorem tight_colon : Spacing.tight.colon = [] := rfl
@[simp] theorem tight_inner : Spacing.tight.inner = [] := rfl
@[simp] theorem tight_tag : Spacing.tight.tag = [] := rfl

theorem braces_tight (fs : List (String × Value)) (inside : Text) (h : fs = [] → inside = []) :
    braces .tight fs inside = '{' :: inside ++ ['}'] := by
  cases fs <;> simp_all [braces]

/-- Arguments that aren't a single record: `Tag(…)`. -/
def Positional (x : Value) (xs : List Value) : Prop := ∀ fs, x = .record fs → xs = [] → False

theorem line_args (sp : Spacing) (t : String) {x : Value} {xs : List Value} (h : Positional x xs) :
    line sp (.variant t (x :: xs)) = t.toList ++ '(' :: lineList sp (x :: xs) ++ [')'] :=
  line.eq_8 sp t x xs h

theorem write_args (t : String) {x : Value} {xs : List Value} (h : Positional x xs) :
    write (.variant t (x :: xs)) = t.toList ++ '(' :: writeList (x :: xs) ++ [')'] :=
  write.eq_8 t x xs h

theorem positional_shape (x : Value) (xs : List Value) : (∃ fs, x = .record fs ∧ xs = []) ∨ Positional x xs := by
  by_cases h : ∃ fs, x = .record fs ∧ xs = []
  · exact .inl h
  · exact .inr fun fs hx hxs => h ⟨fs, hx, hxs⟩

mutual
theorem line_tight : ∀ v : Value, line .tight v = write v
  | .num _ => rfl
  | .str _ => rfl
  | .bytes _ => rfl
  | .arr xs => by simp only [line, write, lineList_tight xs]
  | .record fs => by
    simp only [line, write, lineFields_tight fs]
    exact braces_tight _ _ fun h => by subst h; rfl
  | .variant _ [] => rfl
  | .variant t (x :: xs) => by
    rcases positional_shape x xs with ⟨fs, rfl, rfl⟩ | h
    · simp only [line, write, lineFields_tight fs, tight_tag]
      rw [braces_tight _ _ fun h => by subst h; rfl]; simp
    · rw [line_args _ _ h, write_args _ h, lineList_tight (x :: xs)]

theorem lineList_tight : ∀ xs : List Value, lineList .tight xs = writeList xs
  | [] => rfl
  | [x] => by simp only [lineList, writeList, line_tight x]
  | x :: y :: ys => by
    simp [lineList, writeList, line_tight x, lineList_tight (y :: ys)]

theorem lineFields_tight : ∀ fs : List (String × Value), lineFields .tight fs = writeFields fs
  | [] => rfl
  | [(k, v)] => by simp [lineFields, writeFields, line_tight v]
  | (k, v) :: g :: gs => by
    simp [lineFields, writeFields, line_tight v, lineFields_tight (g :: gs)]
end

/-- **The minimised layout of a value is `Canonical.write`**: the canonical writer without the key sort. -/
theorem minimised_eq_write (v : Value) : minimised v = write v := line_tight v

/-- The canonical form is the minimised layout of the value in canonical order (§12). -/
theorem canonical_eq_minimised (v : Value) : canonical v = minimised v.canon := (line_tight _).symm

/-! ## Examples -/

private def compactOf (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok vs => some (String.ofList (compactAll vs))
  | _ => none

private def minimisedOf (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok vs => some (String.ofList (minimisedAll vs))
  | _ => none

-- Spec §11's examples.
#guard compactOf "Person { name: \"John Doe\", age: 30, type: Engineer },\nPerson { name: \"Jane Smith\", age: 28, type: Designer }," ==
  some "Person { name: \"John Doe\", age: 30, type: Engineer },\nPerson { name: \"Jane Smith\", age: 28, type: Designer },\n"
#guard minimisedOf "Person { name: \"John Doe\", age: 30, type: Engineer },\nPerson { name: \"Jane Smith\", age: 28, type: Designer }," ==
  some "Person{name:\"John Doe\",age:30,type:Engineer},\nPerson{name:\"Jane Smith\",age:28,type:Designer},\n"
-- Fields in the order given; numbers normalized; bytes lowercase; strings on one line.
#guard compactOf "{ b: 0xFF, a: x\"0B 34\", \"x-y\": \"\"\"\n  two\n  lines\n  \"\"\", e: {}, l: [] }" ==
  some "{ b: 255, a: x\"0b34\", \"x-y\": \"two\\nlines\", e: {}, l: [] }\n"
-- Variants: bare, a record payload with a space (`Tag {}` too), otherwise `Tag(…)`.
#guard compactOf "[None, Some(1), Circle({ r: 1 }), E {}, Pair({ a: 1 }, 2)]" ==
  some "[None, Some(1), Circle { r: 1 }, E {}, Pair({ a: 1 }, 2)]\n"
#guard minimisedOf "[None, Some(1), Circle({ r: 1 }), E {}, Pair({ a: 1 }, 2)]" ==
  some "[None,Some(1),Circle{r:1},E{},Pair({a:1},2)]\n"
-- Streams: one value per line, a comma after each; a single value has none; no values, no text.
#guard compactOf "A, B { x: 1 }, C, [1, 2], \"s\", D(1, 2), { y: [] }, E," ==
  some "A,\nB { x: 1 },\nC,\n[1, 2],\n\"s\",\nD(1, 2),\n{ y: [] },\nE,\n"
#guard compactOf "1," == some "1\n"
#guard compactOf "// nothing\n" == some ""

end Haus.Layout
