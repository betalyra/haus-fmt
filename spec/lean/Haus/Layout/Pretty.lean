import Haus.Layout.Compact
import Haus.Pretty.BlockString

/-!
# The pretty layout, from values (spec §11)

`pretty o ind used v` is the pretty layout of the value `v` without
comments, as spec §11 and the TypeScript formatter write it when
serializing values with no source text, with the options `o` (indent width,
default 2, and line width, default 80): `v` starts on a line that is
indented by `ind` and has `used` columns taken before `v` and after it (an
entry's indent, its key and `: `, and the comma after it).

* A non-empty record or array is one entry per line, each followed by `,`,
  indented one level deeper, with the closing bracket on its own line at
  `ind`; empty ones are `{}` and `[]`. `Tag({ … })` is `Tag { … }`.
* A positional payload `Tag(a, b)` stays on its line when it can (`flat`:
  no non-empty record or array in it, and no string with a line feed) and
  fits the width, counted in code points over the whole line, comma
  included; otherwise it has one argument per line, like an array.
* A string with a line feed is a block string (`Pretty.blockString`, L4)
  with its lines one level deeper than the entry; other strings are `"…"`.
  Numbers, byte strings and keys as in every layout (`Canonical`).

A file (`prettyAll`): a single value on its own, with a line break after it;
more than one each followed by `,` and a line break, with a blank line after
each value that spans more than one line and isn't the last. With the
option `stream` (§11), a single value is followed by `,` too.

The round trip is proven in `Haus.Layout.PrettyRoundTrip`.
-/

namespace Haus.Layout
open Haus Canonical

/--
The layouts' options (spec §11): for pretty, spaces per level and the line
width for positional payloads; for every layout, whether the file is a
stream (`stream`: a comma after every top-level item, a single one too).
-/
structure Options where
  indent : Nat := 2
  width : Nat := 80
  stream : Bool := false

/-- One level deeper. -/
def deeper (o : Options) (ind : Text) : Text := ind ++ List.replicate o.indent ' '

mutual
/-- Can the value stay on one line in the pretty layout: no non-empty record or array, no string with a line feed. -/
def flat : Value → Bool
  | .num _ => true
  | .str s => !s.toList.contains '\n'
  | .bytes _ => true
  | .arr [] => true
  | .arr (_ :: _) => false
  | .record [] => true
  | .record (_ :: _) => false
  | .variant _ xs => flatList xs

def flatList : List Value → Bool
  | [] => true
  | x :: xs => flat x && flatList xs
end

/-- A container: `op cl` when empty, otherwise `op`, a line break, its entries, and `cl` at the indent `ind`. -/
def block {α : Type} (ind : Text) (op cl : Char) (xs : List α) (inside : Text) : Text :=
  match xs with
  | [] => [op, cl]
  | _ :: _ => op :: '\n' :: inside ++ ind ++ [cl]

mutual
/-- **The pretty layout** of a value at the indent `ind`, with `used` columns of its line taken. -/
def pretty (o : Options) (ind : Text) (used : Nat) : Value → Text
  | .num s => number s
  | .str s => if s.toList.contains '\n' then Pretty.blockString (deeper o ind) s else string s
  | .bytes bs => bytes bs
  | .arr xs => block ind '[' ']' xs (prettyItems o (deeper o ind) xs)
  | .record fs => block ind '{' '}' fs (prettyFields o (deeper o ind) fs)
  | .variant t [] => t.toList
  | .variant t [.record fs] => t.toList ++ ' ' :: block ind '{' '}' fs (prettyFields o (deeper o ind) fs)
  | .variant t (x :: xs) =>
    if flatList (x :: xs) && used + (compact (.variant t (x :: xs))).length ≤ o.width then
      compact (.variant t (x :: xs))
    else t.toList ++ block ind '(' ')' (x :: xs) (prettyItems o (deeper o ind) (x :: xs))

/-- Items at the indent `ind`, one per line, each followed by `,`. -/
def prettyItems (o : Options) (ind : Text) : List Value → Text
  | [] => []
  | x :: xs => ind ++ pretty o ind (ind.length + 1) x ++ ',' :: '\n' :: prettyItems o ind xs

/-- Fields `key: value` at the indent `ind`, one per line, each followed by `,`. -/
def prettyFields (o : Options) (ind : Text) : List (String × Value) → Text
  | [] => []
  | (k, v) :: fs =>
    ind ++ key k ++ ':' :: ' ' :: pretty o ind (ind.length + (key k).length + 3) v ++ ',' :: '\n' ::
      prettyFields o ind fs
end

/-- The values of a stream, each followed by `,` and a line break, and by a blank line if it spans lines and isn't the last. -/
def prettyStream (o : Options) : List Value → Text
  | [] => []
  | v :: vs =>
    let t := pretty o [] 1 v
    t ++ ',' :: '\n' :: ((if t.contains '\n' && !vs.isEmpty then ['\n'] else []) ++ prettyStream o vs)

/--
**A file or stream in the pretty layout**, without comments. A single value
is written without a comma, unless the options say the file is a stream
(`o.stream`, §11).
-/
def prettyAll (o : Options) : List Value → Text
  | [] => []
  | [v] => if o.stream then prettyStream o [v] else pretty o [] 0 v ++ ['\n']
  | v :: w :: ws => prettyStream o (v :: w :: ws)

/-! ## Examples -/

private def prettyOf (src : String) (o : Options := {}) : Option String :=
  match Parser.parse {} src.toList with
  | .ok vs => some (String.ofList (prettyAll o vs))
  | _ => none

-- Spec §11's example.
#guard prettyOf "Person { name: \"John Doe\", tags: [\"a\", \"b\"], price: Money(7.90, EUR) }" ==
  some "Person {\n  name: \"John Doe\",\n  tags: [\n    \"a\",\n    \"b\",\n  ],\n  price: Money(7.90, EUR),\n}\n"
-- A payload holding a non-empty record or array never fits: `Some([1])` is five lines.
#guard prettyOf "Some([1])" == some "Some(\n  [\n    1,\n  ],\n)\n"
-- Empty containers, `Tag {}`, and a string with a line feed as a block string one level deeper.
#guard prettyOf "{ a: {}, b: [], c: E {}, d: \"x\\ny\" }" ==
  some "{\n  a: {},\n  b: [],\n  c: E {},\n  d: \"\"\"\n    x\n    y\n    \"\"\",\n}\n"
-- The width counts the whole line, comma included: 80 columns fit, 81 don't.
#guard prettyOf "{ fits: Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\") }" ==
  some "{\n  fits: Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"),\n}\n"
#guard prettyOf "{ over: Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\") }" ==
  some "{\n  over: Pair(\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n    \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n  ),\n}\n"
-- Streams: a comma after every item, a blank line after each multi-line item that another follows.
#guard prettyOf "A, B { x: 1 }, C, [1, 2], \"s\", D(1, 2), { y: [] }, E," ==
  some "A,\nB {\n  x: 1,\n},\n\nC,\n[\n  1,\n  2,\n],\n\n\"s\",\nD(1, 2),\n{\n  y: [],\n},\n\nE,\n"
-- A single item has no comma, so it has one column more.
#guard prettyOf "Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\")" ==
  some "Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\")\n"
#guard prettyOf "// nothing\n" == some ""
-- Told that the file is a stream: a comma after a single item too, and the comma counts toward the width.
#guard prettyOf "Paged { n: 1 }" { stream := true } == some "Paged {\n  n: 1,\n},\n"
#guard prettyOf "Pair(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\")" { stream := true } ==
  some "Pair(\n  \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n  \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n),\n"
#guard prettyOf "A, B" { stream := true } == prettyOf "A, B"
#guard prettyOf "// nothing\n" { stream := true } == some ""
-- Options: test-suite/format/cases/width-options (indent 4, width 40), byte for byte.
#guard prettyOf "{ short: Point(1, 2), long: Pair(\"aaaaaaaaaa\", \"bbbbbbbbbbbbbbbb\"), longer: Pair(\"aaaaaaaaaa\", \"bbbbbbbbbbbbbbbbb\"), list: [Money(7.90, EUR), Money(12.50, EUR)], text: \"a\\nb\" }"
    { indent := 4, width := 40 } ==
  some "{\n    short: Point(1, 2),\n    long: Pair(\n        \"aaaaaaaaaa\",\n        \"bbbbbbbbbbbbbbbb\",\n    ),\n    longer: Pair(\n        \"aaaaaaaaaa\",\n        \"bbbbbbbbbbbbbbbbb\",\n    ),\n    list: [\n        Money(7.90, EUR),\n        Money(12.50, EUR),\n    ],\n    text: \"\"\"\n        a\n        b\n        \"\"\",\n}\n"

/-! ## Numbers of any length (§11)

The layouts write a value's numbers in normalized form, always in decimal,
whatever their length: the writers above are total and apply no limits
(§11, "Writers apply no limits"). A value is within the limits it was built
with: the constructors check a number on its normalized literal (`Built.num`),
and a parsed value within the limits is read back by a reader with the same
limits (a hex literal is bounded so that its decimal form fits, §7). A value
parsed with larger limits may hold an integer longer than another reader's
number limit, and that reader rejects the text (`number-too-long`).
`intsFit` says whether a reader with the limits `L` reads a value's
integers back; the writers don't check it. -/

/-- An integer literal: digits, with an optional `-`. -/
def isIntLiteral : Text → Bool
  | '-' :: ds => !ds.isEmpty && ds.all isDigit
  | ds => !ds.isEmpty && ds.all isDigit

mutual
/-- Every integer of a value has a decimal form within the number limit. -/
def intsFit (L : Limits) : Value → Bool
  | .num s => !isIntLiteral s.toList || s.length ≤ L.maxNumberLength
  | .arr xs => intsFitList L xs
  | .record fs => intsFitFields L fs
  | .variant _ xs => intsFitList L xs
  | _ => true

def intsFitList (L : Limits) : List Value → Bool
  | [] => true
  | x :: xs => intsFit L x && intsFitList L xs

def intsFitFields (L : Limits) : List (String × Value) → Bool
  | [] => true
  | (_, x) :: fs => intsFit L x && intsFitFields L fs
end

-- Every integer is written whole, also one longer than the default number limit.
#guard compactAll [.num (toString (10 ^ 1000))] == (toString (10 ^ 1000)).toList ++ ['\n']
#guard intsFit {} (.num (toString (10 ^ 999))) && intsFit {} (.num ("-" ++ toString (10 ^ 998)))
#guard !intsFit {} (.arr [.num (toString (10 ^ 1000))])
#guard !intsFitList {} [.num "1", .variant "Some" [.num ("-" ++ toString (10 ^ 999))]]
-- Only integers: a decimal is written as its literal.
#guard intsFit { maxNumberLength := 3 } (.num "1.25") && !intsFit { maxNumberLength := 3 } (.num "1000")

end Haus.Layout
