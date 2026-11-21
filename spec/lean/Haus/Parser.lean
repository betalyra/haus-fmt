import Haus.Lexical
import Haus.Value
import Haus.ErrorCode

/-!
# The reference parser

Computes `Haus.Grammar.File`: `parse L t = .ok vs` holds exactly when
`File L t vs` does (`Haus.parse_correct`). Written for clarity, not speed.

A parser `P α` reads from the remaining input (its state) and returns an `α`
or an `Error`. Every function is total, so that it can be reasoned about:
the recursive ones take *fuel*, a bound on their recursion depth. A value
needs fuel above twice its length, so `4 * (length + 1)` is always enough
(the completeness proof shows it), and running out is a bug, not an
answer.
-/

namespace Haus.Parser
open Haus

structure Error where
  /-- The mistake (spec §17). -/
  code : Code
  reason : String
  /-- Characters left in the input where the error is. -/
  remaining : Nat
  deriving Repr

/-- An error at the start of `t`, a suffix of the input. -/
def Error.at (code : Code) (reason : String) (t : Text) : Error := ⟨code, reason, t.length⟩

/-- Reads the remaining input; fails with an `Error`. -/
abbrev P := StateT Text (Except Error)

def fail {α : Type} (code : Code) (reason : String) : P α := do throw (.at code reason (← get))
def failAt {α : Type} (code : Code) (reason : String) (t : Text) : P α := throw (.at code reason t)

/-- Skips `n` characters. -/
def skip (n : Nat := 1) : P Unit := modify (·.drop n)

/-- The longest prefix whose characters satisfy `p`. -/
def takeWhile (p : Char → Bool) : P Text := do
  let t ← get
  set (t.dropWhile p)
  return t.takeWhile p

/-- `U+001B` -/
def codePoint (c : Char) : String :=
  let d := Nat.toDigits 16 c.toNat |>.map Char.toUpper
  "U+" ++ String.ofList (List.replicate (4 - d.length) '0' ++ d)

def describe : Text → String
  | [] => "end of input"
  | '\n' :: _ => "line break"
  | c :: _ => if isRawControl c || isBidi c || isLineSep c then codePoint c else s!"'{c}'"

def expect (c : Char) (code : Code) (what : String) : P Unit := do
  match ← get with
  | d :: r => if c == d then set r else fail code s!"{what}, found {describe (d :: r)}"
  | [] => fail code s!"{what}, found end of input"

/-! ## Whitespace and comments -/

/-- After the `/*` at `start`, `d` levels deep: the input after the matching `*/`. -/
def blockComment (start : Text) : Nat → Text → Except Error Text
  | _, [] => .error (.at .unterminatedComment "unterminated block comment" start)
  | d, '/' :: '*' :: r => blockComment start (d + 1) r
  | d, '*' :: '/' :: r => if d ≤ 1 then .ok r else blockComment start (d - 1) r
  | d, c :: r =>
      if isBidi c then .error (.at .bidiControl "raw bidirectional control character in comment" (c :: r))
      else if isRawControl c && c != '\t' && c != '\n' && !(c == '\r' && r.head? == some '\n') then
        .error (if c == '\r' then .at .loneCarriageReturn "carriage return without a line feed" (c :: r)
          else .at .controlCharacter "raw control character in comment" (c :: r))
      else blockComment start d r

def wsLoop : Nat → P Unit
  | 0 => fail .outOfFuel "out of fuel"
  | n + 1 => do
    match ← get with
    | ' ' :: r | '\t' :: r | '\n' :: r | '\r' :: '\n' :: r => set r; wsLoop n
    | '\r' :: _ => fail .loneCarriageReturn "carriage return without a line feed"
    | '/' :: '/' :: r =>
        set r
        -- The comment ends before its line break; a lone CR is caught by the case above.
        let body ← takeWhile fun c => c != '\n' && c != '\r'
        -- Reported at the first offending character.
        match body.findIdx? fun c => isBidi c || (isRawControl c && c != '\t') with
        | some i =>
            let at_ := r.drop i
            if at_.head?.any isBidi then failAt .bidiControl "raw bidirectional control character in comment" at_
            else failAt .controlCharacter "raw control character in comment" at_
        | none => wsLoop n
    | t@('/' :: '*' :: r) => set (← blockComment t 1 r); wsLoop n
    | '/' :: _ => fail .straySlash "unexpected '/' (comments are // or /* */)"
    | _ => pure ()

/-- `ws`: blanks, line breaks and comments. -/
def ws : P Unit := do wsLoop ((← get).length + 1)

/-! ## Numbers

Lexing is pure: each function returns what it read and the rest. -/

/-- `( "_"? d )*`: the longest such prefix, and the rest. -/
def sepTail (p : Char → Bool) : Text → Text × Text
  | '_' :: c :: r =>
      if p c then let (a, b) := sepTail p r; ('_' :: c :: a, b) else ([], '_' :: c :: r)
  | c :: r => if p c then let (a, b) := sepTail p r; (c :: a, b) else ([], c :: r)
  | [] => ([], [])

/-- `d ( "_"? d )*` -/
def digits (p : Char → Bool) : Text → Option (Text × Text)
  | c :: r => if p c then let (a, b) := sepTail p r; some (c :: a, b) else none
  | [] => none

/-- `int ::= "0" | [1-9] ( "_"? [0-9] )*` -/
def lexInt : Text → Option (Text × Text)
  | '0' :: r => some (['0'], r)
  | t@(c :: _) => if c != '0' then digits isDigit t else none
  | [] => none

/-- `frac ::= "." digits`, or nothing. -/
def lexFrac : Text → Text × Text
  | '.' :: r => match digits isDigit r with
    | some (ds, b) => ('.' :: ds, b)
    | none => ([], '.' :: r)
  | r => ([], r)

/-- `[+-]?`, or nothing. -/
def lexSign : Text → Text × Text
  | '+' :: r => (['+'], r)
  | '-' :: r => (['-'], r)
  | r => ([], r)

/-- `exp ::= [eE] [+-]? digits`, or nothing. -/
def lexExp : Text → Text × Text
  | m :: r =>
      if m == 'e' || m == 'E' then
        match digits isDigit (lexSign r).2 with
        | some (ds, b) => (m :: (lexSign r).1 ++ ds, b)
        | none => ([], m :: r)
      else ([], m :: r)
  | [] => ([], [])

/-- A lexed number: the whole literal, its exponent part (empty for hex and binary), the rest. -/
structure Lexed where
  literal : Text
  exponent : Text
  rest : Text

/-- `int frac? exp?`, after the sign `s`. -/
def lexDecimal (s r : Text) : Option Lexed := do
  let (i, r) ← lexInt r
  let (f, r) := lexFrac r
  let (e, r) := lexExp r
  return ⟨s ++ i ++ f ++ e, e, r⟩

/-- Digits after a radix prefix such as `0x`, after the sign `s`. -/
def lexRadix (p : Char → Bool) (s pre r : Text) : Option Lexed :=
  (digits p r).map fun (ds, b) => ⟨s ++ pre ++ ds, [], b⟩

/-- `"-"?`: the sign and the rest. -/
def lexMinus : Text → Text × Text
  | '-' :: r => (['-'], r)
  | r => ([], r)

/-- `decimal | "0x" hex | "0b" binary`, after the sign `s`. -/
def lexUnsigned (s : Text) : Text → Option Lexed
  | '0' :: 'x' :: r => lexRadix isHexDigit s ['0', 'x'] r <|> lexDecimal s ('0' :: 'x' :: r)
  | '0' :: 'b' :: r => lexRadix isBinDigit s ['0', 'b'] r <|> lexDecimal s ('0' :: 'b' :: r)
  | r => lexDecimal s r

/-- `"-"? ( decimal | "0x" hex | "0b" binary )` -/
def lexNumber (t : Text) : Option Lexed := lexUnsigned (lexMinus t).1 (lexMinus t).2

def number (L : Limits) : P Value := do
  let some n := lexNumber (← get) | fail .invalidNumber "invalid number"
  -- A number must not run into a following identifier or `.`: `007`, `1.`, `1_`.
  if n.rest.head?.any (fun c => isIdentChar c || c == '.') then fail .invalidNumber "invalid number"
  if n.literal.length > L.maxNumberLength then fail .numberTooLong s!"number literal longer than {L.maxNumberLength} characters"
  if hexDigitCount n.literal > L.maxHexDigits then fail .numberTooLong s!"hex literal with more than {L.maxHexDigits} hex digits"
  if expMagnitude n.exponent > L.maxExponent then fail .exponentTooLarge s!"exponent larger than {L.maxExponent}"
  set n.rest
  return .num (normalizeNumber n.literal)

/-! ## Strings -/

/-- At a backslash: the character it escapes. -/
def escape : P Char := do
  match ← get with
  | '\\' :: '"' :: r => set r; return '"'
  | '\\' :: '\\' :: r => set r; return '\\'
  | '\\' :: 'n' :: r => set r; return '\n'
  | '\\' :: 'r' :: r => set r; return '\r'
  | '\\' :: 't' :: r => set r; return '\t'
  | t@('\\' :: 'u' :: '{' :: r) =>
      let ds := r.takeWhile isHexDigit
      let v := digitsValue 16 ds
      match r.dropWhile isHexDigit with
      | '}' :: r'' =>
          if ds.length < 1 || ds.length > 6 then failAt .invalidUnicodeEscape "invalid unicode escape: expected \\u{1-6 hex digits}" t
          else if !isScalar v then failAt .invalidUnicodeEscape s!"\\u\{{String.ofList ds}} is not a Unicode scalar value" t
          else set r''; return Char.ofNat v
      | _ => failAt .invalidUnicodeEscape "invalid unicode escape: expected \\u{1-6 hex digits}" t
  -- `\u` without braces, as in JSON: `\u0041`.
  | t =>
      let braceless := t.take 2 == ['\\', 'u']
      fail (if braceless then .invalidUnicodeEscape else .invalidEscape)
        (if braceless then "invalid unicode escape: expected \\u{1-6 hex digits}" else "invalid escape")

/--
Characters allowed by `ok`, and escapes, until `stop` holds for the rest: their
text. Running out of input is reported at `start`, the opening quote.
-/
def chars (what : String) (start : Text) (ok : Char → Bool) (stop : Text → Bool) : Nat → Text → P Text
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    let t ← get
    if stop t then return acc.reverse
    match t with
    | [] => failAt (if what == "string" then .unterminatedString else .unterminatedBlockString) s!"unterminated {what}" start
    | '\\' :: _ => chars what start ok stop n ((← escape) :: acc)
    | c :: r =>
        if isBidi c then fail .bidiControl "raw bidirectional control character (write it as an escape)"
        else if ok c then set r; chars what start ok stop n (c :: acc)
        else fail (if c == '\n' then .stringLineBreak else .controlCharacter) s!"{describe t} is not allowed in a {what}"

/-- `basic_char`, apart from the backslash and bidi controls (checked by `chars`). -/
def basicChar (c : Char) : Bool := c != '"' && !isRawControl c
/-- `block_char`, apart from the backslash and bidi controls. -/
def blockChar (c : Char) : Bool := c == '\t' || !isRawControl c

def checkLength (L : Limits) (s : Text) (start : Text) : P String :=
  if s.length > L.maxStringLength then failAt .stringTooLong s!"string longer than {L.maxStringLength} characters" start
  else return String.ofList s

/-- A record key or tag (§7): at most `maxStringLength` characters, like a string. -/
def checkName (L : Limits) (what : String) (s : Text) (start : Text) : P String :=
  if s.length > L.maxStringLength then
    failAt (if what == "key" then .keyTooLong else .tagTooLong) s!"{what} longer than {L.maxStringLength} characters" start
  else return String.ofList s

def basicString (L : Limits) : P String := do
  let start ← get
  skip
  let s ← chars "string" start basicChar (·.head? == some '"') (start.length + 1) []
  skip
  checkLength L s start

/-- Splits at the first unescaped `"""`: the content before it and the rest after it. -/
def findClose : Text → Option (Text × Text)
  | '\\' :: c :: r => (findClose r).map fun (a, b) => ('\\' :: c :: a, b)
  | '"' :: '"' :: '"' :: r => some ([], r)
  | c :: r => (findClose r).map fun (a, b) => (c :: a, b)
  | [] => none

/-- Splits at line feeds. -/
def splitLines : Text → List Text
  | [] => [[]]
  | '\n' :: r => [] :: splitLines r
  | c :: r => match splitLines r with
    | l :: ls => (c :: l) :: ls
    | [] => [[c]]

/-- One content line of a block string: the indent removed and escapes processed. -/
def blockLine (indent line : Text) : Except Error Text :=
  -- A carriage return is only allowed as part of CRLF.
  let line := if line.getLast? == some '\r' then line.dropLast else line
  if indent <+: line then
    let raw := line.drop indent.length
    (chars "block string" raw blockChar List.isEmpty (raw.length + 1) []).run' raw
  else if line.all isBlank then .ok []
  else .error (.at .blockStringIndent "line is indented less than the closing \"\"\"" line)

/-- A content line without the carriage return of its CR LF, as `blockLine` reads it. -/
def lineText (line : Text) : Text := if line.getLast? == some '\r' then line.dropLast else line

/--
The error of the first content line that fails, placed in the input (§8): at
the offending character, or at the start of a line indented less than the
closing quotes. `t` is the input at the start of the first line of `ls`.
`blockLine` places its error in the line (the characters left in it), so
the line's place in the input is added.
-/
def placeLineError (indent : Text) (e : Error) : Text → List Text → Error
  | _, [] => e
  | t, l :: ls =>
    match blockLine indent l with
    | .error e' => { e' with remaining := t.length - ((lineText l).length - e'.remaining) }
    | .ok _ => placeLineError indent e (t.drop (l.length + 1)) ls

/-- After the opening line of the block string at `start`: the content up to and including the closing quotes. -/
def blockBody (L : Limits) (start : Text) : P String := do
  let t ← get
  let some (content, rest) := findClose t | failAt .unterminatedBlockString "unterminated block string" start
  let lines := splitLines content
  let indent := lines.getLast?.getD []
  -- Text before the closing quotes on their line: at the closing quotes.
  if !indent.all isBlank then throw ⟨.blockStringClosing, "closing \"\"\" must be on its own line", rest.length + 3⟩
  -- An error inside the content is placed at the offending character (§8).
  let decoded ← match (lines.dropLast).mapM (blockLine indent) with
    | .ok ds => pure ds
    | .error e => throw (placeLineError indent e t lines.dropLast)
  set rest
  checkLength L (List.intercalate ['\n'] decoded) start

def blockString (L : Limits) : P String := do
  let start ← get
  skip 3
  let _ ← takeWhile isBlank
  match ← get with
  | '\r' :: '\n' :: r | '\n' :: r => set r
  | _ => fail .blockStringOpening "opening \"\"\" must be followed by a line break"
  blockBody L start

/-! ## Byte strings -/

/-- The text between the quotes of `x"…"`: hex pairs and blanks until `"`. -/
def byteChars : Text → Except Error (List UInt8 × Text)
  | '"' :: r => .ok ([], r)
  | t@(c :: r) =>
      if isBlank c then byteChars r
      else if !isHexDigit c then .error (.at .bytesNotHex s!"{describe t} in byte string (expected hex digits)" t)
      else match r with
        | l :: r' =>
            if isHexDigit l then
              (byteChars r').map fun (bs, rest) => (UInt8.ofNat (hexValue c * 16 + hexValue l) :: bs, rest)
            else .error (.at .bytesOddDigits "a byte needs two hex digits" t)
        | [] => .error (.at .unterminatedBytes "unterminated byte string" [])
  | [] => .error (.at .unterminatedBytes "unterminated byte string" [])

def bytes (L : Limits) : P Value := do
  let start ← get
  -- An unterminated byte string is reported at its start, like a string.
  let (bs, rest) ← match byteChars (start.drop 2) with
    | .ok r => pure r
    | .error e => if e.code == .unterminatedBytes then failAt e.code e.reason start else throw e
  if start.length - rest.length - 3 > L.maxStringLength then
    failAt .stringTooLong s!"byte string longer than {L.maxStringLength} characters" start
  set rest
  return .bytes bs

/-! ## Values -/

def key (L : Limits) : P String := do
  match ← get with
  | '"' :: '"' :: '"' :: _ => fail .blockStringKey "block strings can't be record keys"
  | '"' :: _ => basicString L
  | t@(c :: _) =>
      if isLowerStart c then checkName L "key" (← takeWhile isIdentChar) t
      else if isUpper c then fail .uppercaseKey "record keys must start with a lowercase letter or '_'; quote it"
      else fail .expectedKey s!"expected a record key, found {describe t}"
  | [] => fail .expectedKey "expected a record key, found end of input"

/-- The error for a lowercase word where a value should be. -/
def identifierError (word : String) : String :=
  let hint :=
    if word == "true" || word == "false" then " (booleans are the variants True / False)"
    else if word == "null" then " (use the variant None)"
    else ""
  s!"unexpected identifier '{msgText word}': lowercase identifiers can only be record keys{hint}"

/-- Its code: `true` and `false` aren't booleans, `null` isn't a value, other words aren't strings. -/
def identifierCode (word : String) : Code :=
  if word == "true" || word == "false" then .booleanLiteral
  else if word == "null" then .nullLiteral
  else .bareIdentifier

/--
After the value `v`, something other than a comma or the closing bracket:
which mistake it is. A payload `(…)` or `{…}` after a tag without one (so a
line break or a comment came between them), a closing bracket of the wrong
kind, or a missing comma.
-/
def separatorCode (v : Value) : Text → Code
  | c :: _ =>
      if (c == '(' || c == '{') && (match v with | .variant _ [] => true | _ => false) then .payloadNewline
      else if c == '}' || c == ']' || c == ')' then .unexpectedCloser
      else .missingComma
  | [] => .missingComma

mutual
  /-- A value, within `budget` levels of nesting. -/
  def value (L : Limits) : Nat → Nat → P Value
    | 0, _ => fail .outOfFuel "out of fuel"
    | fuel + 1, budget => do
      match ← get with
      | '{' :: _ => return .record (← record L fuel budget)
      | '[' :: _ => return .arr (← items L fuel budget ']')
      | '"' :: '"' :: '"' :: _ => return .str (← blockString L)
      | '"' :: _ => return .str (← basicString L)
      | 'x' :: '"' :: _ => bytes L
      | t@(c :: _) =>
          if c == '-' || isDigit c then number L
          else if isUpper c then variant L fuel budget
          else if isLowerStart c then
            let word := String.ofList (t.takeWhile isIdentChar)
            fail (identifierCode word) (identifierError word)
          -- `+1` and `.5`: a number written the way other languages allow.
          else fail (if c == '+' || c == '.' then .invalidNumber else .expectedValue) s!"expected a value, found {describe t}"
      | [] => fail .expectedValue "expected a value, found end of input"

  /-- `Tag`, `Tag(…)` or `Tag { … }`. A payload starts on the tag's line. -/
  def variant (L : Limits) : Nat → Nat → P Value
    | 0, _ => fail .outOfFuel "out of fuel"
    | fuel + 1, budget => do
      let start ← get
      let name ← checkName L "tag" (← takeWhile isIdentChar) start
      let afterTag ← get
      let _ ← takeWhile isBlank
      match ← get with
      | t@('(' :: _) =>
          let xs ← items L fuel budget ')'
          if xs.isEmpty then failAt .emptyPayload s!"empty payload: write '{msgText name}' without parentheses" t
          return .variant name xs
      | '{' :: _ => return .variant name [.record (← record L fuel budget)]
      | _ => set afterTag; return .variant name []

  /-- `{ … }`: one level. -/
  def record (L : Limits) : Nat → Nat → P (List (String × Value))
    | 0, _ => fail .outOfFuel "out of fuel"
    | _, 0 => fail .nestingTooDeep s!"nesting deeper than {L.maxDepth} levels"
    | fuel + 1, budget + 1 => do
      let start ← get
      skip
      ws
      fields L fuel budget start []

  def fields (L : Limits) : Nat → Nat → Text → List (String × Value) → P (List (String × Value))
    | 0, _, _, _ => fail .outOfFuel "out of fuel"
    | fuel + 1, budget, start, acc => do
      match ← get with
      | '}' :: r => set r; return acc.reverse
      | [] => failAt .unclosedBracket "unclosed '{'" start
      | t =>
          let k ← key L
          -- A duplicate key is reported at its name, before its value is read (§8).
          if acc.any (·.1 == k) then failAt .duplicateKey s!"duplicate key '{msgText k}'" t
          ws
          expect ':' .missingColon s!"expected ':' after key '{msgText k}'"
          ws
          let v ← value L fuel budget
          ws
          match ← get with
          | ',' :: r => set r; ws; fields L fuel budget start ((k, v) :: acc)
          | '}' :: r => set r; return ((k, v) :: acc).reverse
          | [] => failAt .unclosedBracket "unclosed '{'" start
          | r => fail (separatorCode v r) s!"expected ',' or '}', found {describe r}"

  /-- `[ … ]` or `( … )`: one level. -/
  def items (L : Limits) : Nat → Nat → Char → P (List Value)
    | 0, _, _ => fail .outOfFuel "out of fuel"
    | _, 0, _ => fail .nestingTooDeep s!"nesting deeper than {L.maxDepth} levels"
    | fuel + 1, budget + 1, close => do
      let start ← get
      skip
      ws
      itemsLoop L fuel budget close start []

  def itemsLoop (L : Limits) : Nat → Nat → Char → Text → List Value → P (List Value)
    | 0, _, _, _, _ => fail .outOfFuel "out of fuel"
    | fuel + 1, budget, close, start, acc => do
      match ← get with
      | c :: r =>
          if c == close then set r; return acc.reverse
          let v ← value L fuel budget
          ws
          match ← get with
          | ',' :: r => set r; ws; itemsLoop L fuel budget close start (v :: acc)
          | c :: r =>
              if c == close then set r; return (v :: acc).reverse
              else fail (separatorCode v (c :: r)) s!"expected ',' or '{close}', found {describe (c :: r)}"
          | [] => failAt .unclosedBracket s!"unclosed bracket" start
      | [] => failAt .unclosedBracket s!"unclosed bracket" start
end

/-! ## Files -/

def fileLoop (L : Limits) (fuel : Nat) : Nat → List Value → P (List Value)
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    if (← get).isEmpty then return acc.reverse
    let v ← value L fuel L.maxDepth
    ws
    match ← get with
    | [] => return (v :: acc).reverse
    | ',' :: r => set r; ws; fileLoop L fuel n (v :: acc)
    | r => fail (separatorCode v r) s!"expected ',' between top-level values, found {describe r}"

/--
Spec §10: a file whose text (after a byte order mark) starts with `#haus` is
written for a later version of haus. `#` starts nothing, so such a file is
rejected at its start in any case; this names the reason.
-/
def directive (t : Text) (e : Error) : Error :=
  if "#haus".toList.isPrefixOf t then
    .at .versionDirective "this file starts with a #haus version directive: it needs a newer version of haus" t
  else e

/-- A file: its values, or the first error. A leading byte order mark is skipped. -/
def parse (L : Limits) (input : Text) : Except Error (List Value) :=
  let t := match input with
    | '\uFEFF' :: r => r
    | r => r
  let fuel := 4 * (t.length + 1)
  ((do ws; fileLoop L fuel fuel []).run' t).mapError (directive t)

/--
**A single document** (§6): exactly one value. A sequence of two or more
values, and an input with no value (empty, or only whitespace and comments),
are `not-one-value`, reported at the end of the input; a comma after the one
value is allowed, as in a stream (`1,` is a single document).
-/
def parseDocument (L : Limits) (input : Text) : Except Error Value :=
  match parse L input with
  | .error e => .error e
  | .ok [v] => .ok v
  | .ok [] => .error ⟨.notOneValue, "expected one value, found none", 0⟩
  | .ok _ => .error ⟨.notOneValue, "expected one value, found more than one", 0⟩

/-- A single document is a file of one value (§1). -/
theorem parseDocument_ok_iff {L : Limits} {input : Text} {v : Value} :
    parseDocument L input = .ok v ↔ parse L input = .ok [v] := by
  unfold parseDocument
  split <;> simp_all

private def documentCode (src : String) : Option Code :=
  match parseDocument {} src.toList with
  | .error e => some e.code
  | .ok _ => none
#guard documentCode "1" == none && documentCode "1," == none && documentCode " // c\n{ a: 1 }, // d\n" == none
#guard documentCode "" == some .notOneValue && documentCode " /* c */ \n" == some .notOneValue
#guard documentCode "1, 2" == some .notOneValue && documentCode "1, 2," == some .notOneValue
#guard documentCode "1 2" == some .missingComma && documentCode "," == some .expectedValue

-- Record keys and tags count against the string limit (§7), like strings.
private def accepts (src : String) : Bool := (parse { maxStringLength := 3 } src.toList).toOption.isSome
#guard accepts "{abc: Abc, \"xyz\": Abc(1), q: Abc { r: 1 }}"
#guard !accepts "{abcd: 1}" && !accepts "{\"abcd\": 1}" && !accepts "Abcd" && !accepts "Abcd(1)" && !accepts "Abcd {}"
#guard (parse { maxStringLength := 3 } "[1, Abcd]".toList) matches .error ⟨.tagTooLong, "tag longer than 3 characters", 5⟩
-- Codes (spec §17): a payload on the next line, a missing comma, a stray closer, a version directive.
private def codeOf (src : String) : Option Code :=
  match parse {} src.toList with
  | .error e => some e.code
  | .ok _ => none
#guard codeOf "Heartbeat\n{ a: 1 }" == some .payloadNewline && codeOf "[A /* c */ (1)]" == some .payloadNewline
#guard codeOf "[1 2]" == some .missingComma && codeOf "A(1)(2)" == some .missingComma
#guard codeOf "[1}" == some .unexpectedCloser && codeOf "{ a: 1 }}" == some .unexpectedCloser
#guard codeOf "#haus 2\n1" == some .versionDirective && codeOf "\uFEFF#haus 2" == some .versionDirective
#guard codeOf "{ x: null }" == some .nullLiteral && codeOf "+1" == some .invalidNumber
-- A hex literal has at most 829 hex digits for the default number limit of 1000 (§7);
-- `_` doesn't count, leading zeros do, and a decimal literal may have 1000 digits.
private def hexLit (sign : String) (n : Nat) (sep : Bool := false) : String :=
  sign ++ "0x" ++ (if sep then "f_" ++ String.ofList (List.replicate (n - 1) 'f') else String.ofList (List.replicate n 'f'))
#guard codeOf (hexLit "" 829) == none && codeOf (hexLit "-" 829) == none && codeOf (hexLit "" 829 (sep := true)) == none
#guard codeOf (hexLit "" 830) == some .numberTooLong && codeOf (hexLit "-" 830) == some .numberTooLong &&
  codeOf (hexLit "" 830 (sep := true)) == some .numberTooLong
#guard codeOf ("0x" ++ String.ofList (List.replicate 830 '0')) == some .numberTooLong
#guard codeOf ("0x" ++ String.ofList (List.replicate 829 '0')) == none
#guard codeOf (String.ofList (List.replicate 1000 '9')) == none && codeOf ("0b" ++ String.ofList (List.replicate 998 '1')) == none
-- So the largest hex integer has a decimal form of at most 1000 characters, sign included.
#guard match parse {} (hexLit "-" 829).toList with
  | .ok [.num s] => s.length == 1000 && s.startsWith "-"
  | _ => false

end Haus.Parser
