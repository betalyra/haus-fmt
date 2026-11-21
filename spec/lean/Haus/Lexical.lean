/-!
# Lexical helpers

Character classes, limits and small functions on literals, shared by the
grammar (`Haus.Grammar`, the specification) and the reference parser
(`Haus.Parser`).
-/

namespace Haus

/-- Source text, as Unicode scalar values (the input after UTF-8 decoding). -/
abbrev Text := List Char

/-- Resource limits (spec §7). Parsers MUST accept every input within the defaults. -/
structure Limits where
  /-- Nesting depth of records, arrays and payloads. -/
  maxDepth : Nat := 256
  /-- Characters in one number literal. -/
  maxNumberLength : Nat := 1000
  /-- Largest absolute exponent of a decimal literal. -/
  maxExponent : Nat := 6144
  /-- Characters in one decoded string, or between the quotes of a byte string. -/
  maxStringLength : Nat := 16 * 1024 * 1024
  /--
  Values written for one value, counted as they are written (§7): bounds a
  writer, the canonical form and hashing for a value built in code whose
  parts share each other. A parser never needs it: a parsed value has fewer
  values than characters.
  -/
  maxNodes : Nat := 64 * 1024 * 1024
  deriving Repr, Inhabited

/--
Hex digits in one hex literal, `_` not counted (§7): derived from the number
limit `n` as the largest `h` with `16 ^ h ≤ 10 ^ (n - 1)` (`maxHexDigits_iff`),
so that every integer a literal can hold has a decimal form, sign included,
of at most `n` characters. 829 for the default 1000.

`16 ^ h = 2 ^ (4 · h)`, so `h` is a quarter of the binary logarithm, computed
exactly on the integer `10 ^ (n - 1)`.
-/
def Limits.maxHexDigits (L : Limits) : Nat := Nat.log2 (10 ^ (L.maxNumberLength - 1)) / 4

/-- `maxHexDigits` is the largest `h` with `16 ^ h ≤ 10 ^ (n - 1)`. -/
theorem Limits.maxHexDigits_iff (L : Limits) (h : Nat) :
    h ≤ L.maxHexDigits ↔ 16 ^ h ≤ 10 ^ (L.maxNumberLength - 1) := by
  have hne : 10 ^ (L.maxNumberLength - 1) ≠ 0 := Nat.ne_of_gt (Nat.pow_pos (by decide))
  rw [Limits.maxHexDigits, Nat.le_div_iff_mul_le (by decide), Nat.le_log2 hne,
    show (16 : Nat) = 2 ^ 4 from rfl, ← Nat.pow_mul, Nat.mul_comm]

#guard ({} : Limits).maxHexDigits == 829
#guard 16 ^ 829 ≤ 10 ^ 999 && 10 ^ 999 < 16 ^ 830

/-- Raw bidirectional controls, U+202A–U+202E and U+2066–U+2069 ("Trojan Source"). -/
def isBidi (c : Char) : Bool :=
  (0x202A ≤ c.toNat && c.toNat ≤ 0x202E) || (0x2066 ≤ c.toNat && c.toNat ≤ 0x2069)

/--
A raw control character: C0 (U+0000–U+001F, including tab and line breaks),
DEL (U+007F) or C1 (U+0080–U+009F). They can rewrite what a terminal displays
or truncate text, so they appear in raw text only as tab and line breaks, and
only where the grammar allows (§4).
-/
def isRawControl (c : Char) : Bool := c.toNat < 0x20 || (0x7F ≤ c.toNat && c.toNat ≤ 0x9F)

/--
The line and paragraph separators U+2028 and U+2029. They are allowed raw
in strings, but every writer escapes them (§11, §12, §16), as some software
splits lines at them.
-/
def isLineSep (c : Char) : Bool := 0x2028 ≤ c.toNat && c.toNat ≤ 0x2029

/-- A space or a tab. -/
def isBlank (c : Char) : Bool := c == ' ' || c == '\t'

def isDigit (c : Char) : Bool := '0' ≤ c && c ≤ '9'
def isBinDigit (c : Char) : Bool := c == '0' || c == '1'
def isHexDigit (c : Char) : Bool := isDigit c || ('a' ≤ c && c ≤ 'f') || ('A' ≤ c && c ≤ 'F')
def isUpper (c : Char) : Bool := 'A' ≤ c && c ≤ 'Z'
/-- `[a-z_]`: the first character of a record key. -/
def isLowerStart (c : Char) : Bool := ('a' ≤ c && c ≤ 'z') || c == '_'
/-- `[A-Za-z0-9_]` -/
def isIdentChar (c : Char) : Bool := isUpper c || isLowerStart c || isDigit c

/-- The value of a hex digit (0 for other characters). -/
def hexValue (c : Char) : Nat :=
  if isDigit c then c.toNat - '0'.toNat
  else if 'a' ≤ c && c ≤ 'f' then c.toNat - 'a'.toNat + 10
  else if 'A' ≤ c && c ≤ 'F' then c.toNat - 'A'.toNat + 10
  else 0

/-- The value of a sequence of digits in a radix. -/
def digitsValue (radix : Nat) (ds : Text) : Nat :=
  ds.foldl (fun n c => n * radix + hexValue c) 0

/--
The hex digits of a hex literal (`0x…` or `-0x…`), `_` not counted, for the
limit `maxHexDigits` (§7); 0 for any other literal.
-/
def hexDigitCount : Text → Nat
  | '-' :: '0' :: 'x' :: ds => (ds.filter (· != '_')).length
  | '0' :: 'x' :: ds => (ds.filter (· != '_')).length
  | _ => 0

#guard hexDigitCount "-0xFF_FF".toList == 4 && hexDigitCount "0x00ff".toList == 4
#guard hexDigitCount "0b11".toList == 0 && hexDigitCount "100".toList == 0

/-- A Unicode scalar value: at most U+10FFFF and not a surrogate. -/
def isScalar (n : Nat) : Bool := n ≤ 0x10FFFF && !(0xD800 ≤ n && n ≤ 0xDFFF)

/-- The magnitude of an exponent part such as `e+1_0`, for the limit (§7). -/
def expMagnitude (e : Text) : Nat := digitsValue 10 (e.filter isDigit)

/-- Digits without leading zeros: `007` is `7`, `000` is `0`. -/
def stripZeros (ds : Text) : Text :=
  match ds.dropWhile (· == '0') with
  | [] => ['0']
  | z => z

/--
An exponent's digits and sign, as its value: `+05` is `5`, `-0` is `0`.
The marker `e` is written by the caller.
-/
def normalizeExponent (e : Text) : Text :=
  let (neg, ds) := match e with
    | '-' :: r => (true, r)
    | '+' :: r => (false, r)
    | r => (false, r)
  let ds := stripZeros ds
  if neg && ds != ['0'] then '-' :: ds else ds

/-- The sign of a normalized literal: `-` for a negative literal, zero included. -/
def signText (neg : Bool) : String := if neg then "-" else ""

/-- An integer's normalized literal: `-` (unless 0) and its decimal digits. -/
def intText (neg : Bool) (v : Nat) : Text := (if neg && v != 0 then ['-'] else []) ++ Nat.toDigits 10 v

/--
A number's literal after its sign: digit separators removed, the exponent
written `e` and its value, hex and binary converted to decimal integers.
The sign is kept, also on zero: `-0x0` is `-0`, as `-0` is.
-/
def normalizeBody (neg : Bool) (body : Text) : String :=
  let integer (n : Nat) := signText neg ++ toString n
  match body.filter (· != '_') with
  | '0' :: 'x' :: ds => integer (digitsValue 16 ds)
  | '0' :: 'b' :: ds => integer (digitsValue 2 ds)
  | ds =>
    let mantissa := ds.takeWhile (fun c => c != 'e' && c != 'E')
    let exponent := match ds.dropWhile (fun c => c != 'e' && c != 'E') with
      | _ :: e => 'e' :: normalizeExponent e
      | [] => []
    String.ofList ((if neg then ['-'] else []) ++ mantissa ++ exponent)

/--
The normalized literal of a number (§2): digit separators removed, the
exponent written `e` and its value (`E+05` is `e5`), hex and binary
converted to decimal integers, keeping the sign: `-0x0` is `-0`, as `-0` is.
-/
def normalizeNumber : Text → String
  | '-' :: r => normalizeBody true r
  | r => normalizeBody false r

#guard normalizeNumber "1E+0_5".toList == "1e5"
#guard normalizeNumber "-2.50e-03".toList == "-2.50e-3"
#guard normalizeNumber "1e-0".toList == "1e0"
#guard normalizeNumber "1e000".toList == "1e0"
#guard normalizeNumber "1_000.0".toList == "1000.0"
#guard normalizeNumber "-0x0".toList == "-0" && normalizeNumber "-0b0".toList == "-0"
#guard normalizeNumber "-0".toList == "-0" && normalizeNumber "0x0".toList == "0"
#guard normalizeNumber "0xFF".toList == "255"

/--
The content of a block string ends at the first `"""` that isn't escaped:
true when `t` has none. A backslash escapes the character after it.
-/
def noTripleQuote : Text → Bool
  | '\\' :: _ :: rest => noTripleQuote rest
  | '"' :: '"' :: '"' :: _ => false
  | _ :: rest => noTripleQuote rest
  | [] => true

/-! ## Text quoted in messages (§9.2) -/

/-- A character as a message shows it (§9.2): control, bidi and line-separator
characters as `\u{…}`, in uppercase hex as the canonical form writes them (§12). -/
def shownChar (c : Char) : List Char :=
  if isRawControl c || isBidi c || isLineSep c then
    s!"\\u\{{String.ofList ((Nat.toDigits 16 c.toNat).map Char.toUpper)}}".toList
  else [c]

/-- The pieces that fit in `n` characters, from the front, whole: a cut never
falls inside an escape. -/
def keepPieces : Nat → List (List Char) → List Char
  | _, [] => []
  | n, p :: ps => if p.length ≤ n then p ++ keepPieces (n - p.length) ps else []

/-- Text from the input, for a message (§9.2): control and bidi characters
escaped, and at most 40 characters as shown, after escaping. A longer text is
cut to whole characters in 39 and marked with `…`, which is within the 40. -/
def quoteBody (s : String) : List Char :=
  if (s.toList.map shownChar).flatten.length ≤ 40 then (s.toList.map shownChar).flatten
  else keepPieces 39 (s.toList.map shownChar) ++ ['…']

theorem keepPieces_length_le (n : Nat) (ps : List (List Char)) : (keepPieces n ps).length ≤ n := by
  induction ps generalizing n with
  | nil => simp [keepPieces]
  | cons p ps ih =>
    unfold keepPieces
    split
    · have := ih (n - p.length); simp; omega
    · simp

/-- What a message shows of a text is at most 40 characters, the `…` included (§9.2). -/
theorem quoteBody_length_le (s : String) : (quoteBody s).length ≤ 40 := by
  unfold quoteBody
  split
  · assumption
  · have := keepPieces_length_le 39 (s.toList.map shownChar); simp; omega

/-- `quoteBody` as a string: what a message shows of a token, a key, a name or a version from the input. -/
def msgText (s : String) : String := String.ofList (quoteBody s)

#guard msgText "a\x1bb" = "a\\u{1B}b"

end Haus
