import Haus.Value
import Haus.Lexical

/-!
# JSON as data (spec §16)

`JSON` is a JSON value (RFC 8259) as data: a number keeps its exact text
(`1E+2` is not `100`), and an object keeps its members in the order read.

JSON is compared as data (§16): member order and whitespace don't matter,
numbers compare by their text. `JSON.Equiv` says so, the same way
`Value.Equiv` does for haus values: `canon` sorts every object's members by
key (by code point), and two JSON values are equal as data when their
`canon`s are identical.

Also here: the syntax checks the mappings share. A JSON number
(`isJsonNumber`), a normalized haus number literal (§2, `isNormalLit`),
a tag (`isTag`).
-/

namespace Haus

/-- A JSON value. Numbers keep their exact text; objects keep their members in order. -/
inductive JSON where
  | null
  | bool (b : Bool)
  /-- A number, as its text: `-1.5E+3`. -/
  | num (text : String)
  | str (s : String)
  | arr (items : List JSON)
  | obj (members : List (String × JSON))
  deriving Repr, Inhabited, BEq

namespace JSON

mutual
/-- Objects with their members sorted by key (by code point). Nothing else changes. -/
def canon : JSON → JSON
  | .arr xs => .arr (canonList xs)
  | .obj ms => .obj ((canonMembers ms).mergeSort fun a b => a.1 ≤ b.1)
  | j => j

def canonList : List JSON → List JSON
  | [] => []
  | x :: xs => canon x :: canonList xs

def canonMembers : List (String × JSON) → List (String × JSON)
  | [] => []
  | (k, v) :: ms => (k, canon v) :: canonMembers ms
end

/--
**JSON compared as data** (§16): the same structure, with member order
ignored and numbers compared by their text.
-/
def Equiv (a b : JSON) : Prop := a.canon = b.canon

/-- `Equiv`, computed. -/
def equiv (a b : JSON) : Bool := a.canon == b.canon

theorem Equiv.refl (a : JSON) : Equiv a a := rfl
theorem Equiv.symm {a b : JSON} (h : Equiv a b) : Equiv b a := Eq.symm h
theorem Equiv.trans {a b c : JSON} (h : Equiv a b) (h' : Equiv b c) : Equiv a c := Eq.trans h h'

theorem canonList_eq : ∀ xs : List JSON, canonList xs = xs.map canon
  | [] => rfl
  | x :: xs => by simp [canonList, canonList_eq xs]

theorem canonMembers_eq : ∀ ms : List (String × JSON), canonMembers ms = ms.map fun kv => (kv.1, kv.2.canon)
  | [] => rfl
  | (k, v) :: ms => by simp [canonMembers, canonMembers_eq ms]

#guard equiv (.obj [("a", .num "1"), ("b", .arr [.null])]) (.obj [("b", .arr [.null]), ("a", .num "1")])
#guard !equiv (.num "1E+2") (.num "100")
#guard !equiv (.arr [.num "1", .num "2"]) (.arr [.num "2", .num "1"])

end JSON

/-! ## Syntax checks -/

/-- `0`, or a digit 1–9 followed by digits: an integer without leading zeros. -/
def isIntDigits : Text → Bool
  | [] => false
  | ['0'] => true
  | c :: cs => isDigit c && c != '0' && cs.all isDigit

/-- An optional `-`, then the rest. -/
def dropMinus : Text → Text
  | '-' :: r => r
  | r => r

/-- `frac? exp?` after the integer part, for `isJsonNumber`. -/
def jsonTail : Text → Bool
  | '.' :: r =>
    let fr := r.takeWhile isDigit
    fr != [] && jsonExp (r.dropWhile isDigit)
  | r => jsonExp r
where
  jsonExp : Text → Bool
    | [] => true
    | c :: r =>
      (c == 'e' || c == 'E') &&
        let ds := match r with
          | '+' :: d => d
          | '-' :: d => d
          | d => d
        ds != [] && ds.all isDigit

/-- **A JSON number** (RFC 8259): `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?` -/
def isJsonNumber (t : Text) : Bool :=
  let t := dropMinus t
  isIntDigits (t.takeWhile isDigit) && jsonTail (t.dropWhile isDigit)

/-- `frac? exp?` of a normalized literal: the exponent written `e` and its value. -/
def normalTail : Text → Bool
  | '.' :: r =>
    let fr := r.takeWhile isDigit
    fr != [] && normalExp (r.dropWhile isDigit)
  | r => normalExp r
where
  normalExp : Text → Bool
    | [] => true
    | ['e', '-', '0'] => false
    | 'e' :: '-' :: ds => isIntDigits ds
    | 'e' :: ds => isIntDigits ds
    | _ => false

/--
**A normalized number literal** (§2): a JSON number whose exponent, if any,
is written `e` and its value (no `+`, no leading zeros, no `-0`). These are
the literals `Value.num` holds: `19.90`, `-0`, `1e5`, `255`.
-/
def isNormalLit (t : Text) : Bool :=
  let t := dropMinus t
  isIntDigits (t.takeWhile isDigit) && normalTail (t.dropWhile isDigit)

/-- `[A-Z][A-Za-z0-9_]*`: a tag (§4). -/
def isTag : Text → Bool
  | c :: cs => isUpper c && cs.all isIdentChar
  | [] => false

#guard ["0", "-0", "19.90", "1E+05", "1e-7", "-1.5e3", "123"].all (isJsonNumber ·.toList)
#guard !(["01", "+1", "1.", ".5", "1e", "1e+", "0x1F", "NaN", "", "-", "1_0"].any (isJsonNumber ·.toList))
#guard ["0", "-0", "19.90", "1e5", "1e-7", "-1.5e3", "1e0", "255"].all (isNormalLit ·.toList)
#guard !(["01", "1E5", "1e+5", "1e05", "1e-0", "0xFF", "1.", "1_000"].any (isNormalLit ·.toList))
#guard isTag "Circle".toList && isTag "A_1".toList && !isTag "circle".toList && !isTag "".toList

end Haus
