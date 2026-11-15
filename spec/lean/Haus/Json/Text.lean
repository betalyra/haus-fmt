import Haus.Json.Base64
import Haus.Canonical

/-!
# JSON text (spec §16)

`JSON.parse L t` reads JSON text (RFC 8259) restricted to I-JSON (RFC 7493),
as §16 says: no duplicate member names, no unpaired surrogates in `\u`
escapes. The input is already decoded UTF-8 (`Text`, Unicode scalar
values), as for the haus parser. Numbers keep their exact text: nothing is
rounded through a binary float.

`JSON.write j` writes JSON compactly, with members in the order given.

Limits (§16, "Limits"):

- a string at most `maxStringLength` characters;
- a number token, as written, at most `maxNumberLength` characters, with an
  exponent at most `maxExponent`;
- JSON nesting at most `4 · maxDepth + 1` for the mappings (`parse`), and
  `maxDepth` without a schema (`parseDepth L L.maxDepth`). The depth of the
  haus value that results is checked by the mappings (`Value.fits`).

A leading byte order mark is ignored (§16, as in haus). `parseLines` reads
JSON Lines (§16, "Streams").

`Haus.Json.TextRoundTrip` proves that `parse` reads back what `write` writes,
for exactly the values `parse` returns (well formed, within the limits), and
the same for JSON Lines.
-/

namespace Haus.JSON
open Haus

/-! ## Limits on numbers -/

/-- The hex form of an integer literal (`-0x…`, as §12 writes it), if the literal is an integer. -/
def hexForm (lit : Text) : Option Text :=
  let (sign, ds) := match lit with
    | '-' :: ds => (['-'], ds)
    | ds => ([], ds)
  if ds != [] && ds.all isDigit then some (sign ++ '0' :: 'x' :: Canonical.hex (digitsValue 10 ds)) else none

/-- The exponent of a literal, as a magnitude: `1.5e-7` has 7. -/
def exponentOf (lit : Text) : Nat :=
  match lit.dropWhile (fun c => c != 'e' && c != 'E') with
  | _ :: e => digitsValue 10 (e.filter isDigit)
  | [] => 0

/--
**A haus number within the limits** (§7): a haus literal can hold it. Its
exponent is at most `maxExponent`, and its literal at most `maxNumberLength`
characters, or, for an integer, its hex form (§12): a valid haus integer
written in hex can have a longer decimal form.
-/
def numberFits (L : Limits) (lit : Text) : Bool :=
  exponentOf lit ≤ L.maxExponent &&
    (lit.length ≤ L.maxNumberLength ||
      -- A hex form is never shorter than 5/6 of the decimal one: don't convert longer ones.
      (lit.length ≤ L.maxNumberLength * 6 / 5 + 4 &&
        match hexForm lit with
        | some h => h.length ≤ L.maxNumberLength
        | none => false))

/-- **A JSON number token within the limits** (§16), as written. -/
def tokenFits (L : Limits) (lit : Text) : Bool :=
  lit.length ≤ L.maxNumberLength && exponentOf lit ≤ L.maxExponent

/-- JSON nesting the mappings allow (§16): `4 · d + 1`. -/
def jsonDepth (L : Limits) : Nat := 4 * L.maxDepth + 1

#guard numberFits {} ("9".toList ++ List.replicate 999 '9')
#guard !numberFits {} ("0.".toList ++ List.replicate 999 '1') && numberFits {} ("1".toList ++ List.replicate 1000 '0')
#guard numberFits {} (Nat.toDigits 10 (16 ^ 998 - 1))
#guard !numberFits {} (Nat.toDigits 10 (16 ^ 998))
#guard numberFits {} "1e6144".toList && !numberFits {} "1e6145".toList && numberFits {} "1E-6144".toList
#guard !tokenFits {} ("1".toList ++ List.replicate 1000 '0') && tokenFits {} "1E-6144".toList

/-! ## Reading -/

def isWs (c : Char) : Bool := c == ' ' || c == '\t' || c == '\n' || c == '\r'

def skipWs (t : Text) : Text := t.dropWhile isWs

/-- Four hex digits. -/
def hex4 : Text → Option (Nat × Text)
  | a :: b :: c :: d :: r =>
    if [a, b, c, d].all isHexDigit then some (digitsValue 16 [a, b, c, d], r) else none
  | _ => none

def isHigh (n : Nat) : Bool := 0xD800 ≤ n && n ≤ 0xDBFF
def isLow (n : Nat) : Bool := 0xDC00 ≤ n && n ≤ 0xDFFF

/--
A string's characters after the opening quote, up to the closing one.
`acc` holds the characters read, reversed, and `n` how many.
-/
def strChars (L : Limits) : Nat → Text → List Char → Nat → Except String (String × Text)
  | 0, _, _, _ => .error "string too long"
  | fuel + 1, t, acc, n =>
    if n > L.maxStringLength then .error s!"string longer than {L.maxStringLength} characters" else
    match t with
    | [] => .error "unterminated string"
    | '"' :: r => .ok (String.ofList acc.reverse, r)
    | '\\' :: c :: r =>
      let one (ch : Char) := strChars L fuel r (ch :: acc) (n + 1)
      match c with
      | '"' => one '"'
      | '\\' => one '\\'
      | '/' => one '/'
      | 'b' => one (Char.ofNat 8)
      | 'f' => one (Char.ofNat 12)
      | 'n' => one '\n'
      | 'r' => one '\r'
      | 't' => one '\t'
      | 'u' =>
        match hex4 r with
        | none => .error "invalid \\u escape"
        | some (h, r) =>
          if isHigh h then
            match r with
            | '\\' :: 'u' :: r' =>
              match hex4 r' with
              | some (l, r'') =>
                if isLow l then
                  strChars L fuel r'' (Char.ofNat (0x10000 + (h - 0xD800) * 0x400 + (l - 0xDC00)) :: acc) (n + 1)
                else .error "unpaired surrogate"
              | none => .error "invalid \\u escape"
            | _ => .error "unpaired surrogate"
          else if isLow h then .error "unpaired surrogate"
          else strChars L fuel r (Char.ofNat h :: acc) (n + 1)
      | _ => .error "invalid escape"
    | c :: r =>
      if c.toNat < 0x20 then .error "control character in a string"
      else strChars L fuel r (c :: acc) (n + 1)

def isNumberChar (c : Char) : Bool := isDigit c || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'

/-- A number: its text, checked against RFC 8259 and the limits. -/
def number (L : Limits) (t : Text) : Except String (JSON × Text) :=
  let lit := t.takeWhile isNumberChar
  if !isJsonNumber lit then .error "invalid number"
  else if !tokenFits L lit then .error "number outside the limits"
  else .ok (.num (String.ofList lit), t.dropWhile isNumberChar)

/-- A literal word: `true`, `false`, `null`. -/
def word (w : String) (j : JSON) (t : Text) : Except String (JSON × Text) :=
  if w.toList.isPrefixOf t then .ok (j, t.drop w.length) else .error "invalid value"

mutual
/-- A value after whitespace. `fuel` bounds the recursion (the text's length is enough), `depth` the nesting left. -/
def value (L : Limits) : Nat → Nat → Text → Except String (JSON × Text)
  | 0, _, _ => .error "out of fuel"
  | fuel + 1, depth, t =>
    match t with
    | '{' :: r =>
      if depth = 0 then .error "nested too deeply" else
      match skipWs r with
      | '}' :: r' => .ok (.obj [], r')
      | r' => members L fuel (depth - 1) r' [] []
    | '[' :: r =>
      if depth = 0 then .error "nested too deeply" else
      match skipWs r with
      | ']' :: r' => .ok (.arr [], r')
      | r' => items L fuel (depth - 1) r' []
    | '"' :: r => (strChars L (r.length + 1) r [] 0).map fun (s, r') => (.str s, r')
    | 't' :: _ => word "true" (.bool true) t
    | 'f' :: _ => word "false" (.bool false) t
    | 'n' :: _ => word "null" .null t
    | c :: _ => if c == '-' || isDigit c then number L t else .error "invalid value"
    | [] => .error "unexpected end"

/-- Array elements from the first one; `acc` reversed. -/
def items (L : Limits) : Nat → Nat → Text → List JSON → Except String (JSON × Text)
  | 0, _, _, _ => .error "out of fuel"
  | fuel + 1, depth, t, acc => do
    let (x, r) ← value L fuel depth t
    match skipWs r with
    | ',' :: r' => items L fuel depth (skipWs r') (x :: acc)
    | ']' :: r' => .ok (.arr (x :: acc).reverse, r')
    | _ => .error "expected , or ]"

/-- Object members from the first one; `acc` reversed, `keys` the names so far. -/
def members (L : Limits) : Nat → Nat → Text → List (String × JSON) → List String →
    Except String (JSON × Text)
  | 0, _, _, _, _ => .error "out of fuel"
  | fuel + 1, depth, t, acc, keys =>
    match t with
    | '"' :: r => do
      let (k, r) ← strChars L (r.length + 1) r [] 0
      if keys.contains k then .error s!"duplicate member name {String.ofList (Canonical.string k)}" else
      match skipWs r with
      | ':' :: r =>
        let (x, r) ← value L fuel depth (skipWs r)
        match skipWs r with
        | ',' :: r' => members L fuel depth (skipWs r') ((k, x) :: acc) (k :: keys)
        | '}' :: r' => .ok (.obj ((k, x) :: acc).reverse, r')
        | _ => .error "expected , or }"
      | _ => .error "expected :"
    | _ => .error "expected a member name"
end

/-- A byte order mark: ignored at the start of the text (§16). -/
def dropBom : Text → Text
  | '\uFEFF' :: t => t
  | t => t

/-- One JSON text, whitespace around it, nesting at most `depth`; no byte order mark. -/
def parseText (L : Limits) (depth : Nat) (t : Text) : Except String JSON := do
  let (j, r) ← value L (2 * t.length + 4) depth (skipWs t)
  if skipWs r = [] then .ok j else .error "text after the value"

/-- JSON text nested at most `depth`, after an optional byte order mark. -/
def parseDepth (L : Limits) (depth : Nat) (t : Text) : Except String JSON := parseText L depth (dropBom t)

/--
**Reading JSON text** for a mapping (§16): one value, with whitespace around
it, within the limits `L`, nested at most `4 · d + 1`. A leading byte order
mark is ignored.
-/
def parse (L : Limits) (t : Text) : Except String JSON := parseDepth L (jsonDepth L) t

/-- Lines of a JSON Lines text: split at line feeds, a CR before one dropped. -/
def lines (t : Text) : List Text :=
  let ls := (t.splitOn '\n').map fun l => if l.getLast? = some '\r' then l.dropLast else l
  -- A line feed after the last value doesn't start another line.
  if ls.getLast? = some [] then ls.dropLast else ls

/--
**JSON Lines** (§16, "Streams"): one JSON text per line. A missing line feed
after the last value and CR LF line ends are accepted, an empty line is an
error, and a byte order mark is ignored only at the start of the stream.
-/
def parseLines (L : Limits) (t : Text) : Except String (List JSON) :=
  (lines (dropBom t)).mapM fun l =>
    if l.isEmpty then .error "empty line" else parseText L (jsonDepth L) l

/-! ## Writing -/

/-- One character of a string: `"`, `\` and control characters escaped, everything else as itself. -/
def escape (c : Char) : Text :=
  match c with
  | '"' => ['\\', '"']
  | '\\' => ['\\', '\\']
  | '\n' => ['\\', 'n']
  | '\r' => ['\\', 'r']
  | '\t' => ['\\', 't']
  | c =>
    if c.toNat < 0x20 then ['\\', 'u', '0', '0', Bytes.hexChar (c.toNat / 16), Bytes.hexChar (c.toNat % 16)]
    else [c]

def writeString (s : String) : Text := '"' :: s.toList.flatMap escape ++ ['"']

mutual
/-- **Writing JSON**, compactly: no whitespace, members in the order given. -/
def write : JSON → Text
  | .null => "null".toList
  | .bool true => "true".toList
  | .bool false => "false".toList
  | .num t => t.toList
  | .str s => writeString s
  | .arr xs => '[' :: writeItems xs ++ [']']
  | .obj ms => '{' :: writeMembers ms ++ ['}']

def writeItems : List JSON → Text
  | [] => []
  | [x] => write x
  | x :: xs => write x ++ ',' :: writeItems xs

def writeMembers : List (String × JSON) → Text
  | [] => []
  | [(k, x)] => writeString k ++ ':' :: write x
  | (k, x) :: ms => writeString k ++ ':' :: write x ++ ',' :: writeMembers ms
end

/-! ## Tests -/

private def rt (s : String) : Option String :=
  match parse {} s.toList with
  | .ok j => some (String.ofList (write j))
  | .error _ => none

#guard rt " { \"a\" : [1, -0.5E+3, true, false, null], \"b\": \"x\\u00e9\\ud83d\\ude00\\n\" } " ==
  some "{\"a\":[1,-0.5E+3,true,false,null],\"b\":\"xé😀\\n\"}"
#guard rt "\"\\u0000\\u001f\\/\"" == some "\"\\u0000\\u001f/\""
#guard rt "{\"a\": 1, \"a\": 2}" == none
#guard rt "\"\\ud83d\"" == none && rt "\"\\ude00\"" == none && rt "\"\\ud83dx\"" == none
#guard rt "[1,]" == none && rt "NaN" == none && rt "01" == none && rt "1." == none && rt "+1" == none
#guard rt "[1] [2]" == none && rt "" == none && rt "\"a\nb\"" == none && rt "tru" == none
#guard rt "\uFEFF1" == some "1" && rt "\uFEFF\uFEFF1" == none
#guard rt ("\"" ++ String.ofList (List.replicate 3 'x') ++ "\"") == some "\"xxx\""
#guard (parse { maxStringLength := 2 } "\"xxx\"".toList).toOption.isNone
#guard (parse { maxDepth := 1 } "[[[[[1]]]]]".toList).toOption.isSome
#guard (parse { maxDepth := 1 } "[[[[[[1]]]]]]".toList).toOption.isNone
#guard (parseDepth { maxDepth := 1 } 1 "[[1]]".toList).toOption.isNone

private def jl (s : String) : Option (List String) :=
  (parseLines {} s.toList).toOption.map (·.map fun j => String.ofList (write j))

#guard jl "1\n[2]\n" == some ["1", "[2]"] && jl "1\r\n2" == some ["1", "2"] && jl "" == some []
#guard jl "\uFEFF1\n2\n" == some ["1", "2"] && jl "1\n\uFEFF2\n" == none
#guard jl "1\n\n2\n" == none && jl "\n" == none && jl "[1,\n2]\n" == none
#guard rt "1e6145" == none

end Haus.JSON
