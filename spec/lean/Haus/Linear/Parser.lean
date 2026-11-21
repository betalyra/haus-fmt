import Haus.Linear.Monad
import Haus.Linear.KeySet

/-!
# A reference parser that counts its steps (plan step P3)

`parseC` is `Parser.parse` (`Haus.Parser`) with its steps counted (the cost
model of `Haus.Linear.Monad`) and one change: a record's keys are kept in a
`KeySet` (a binary trie, `Haus.Linear.KeySet`) instead of a list scanned for
each new key, so that finding duplicates takes steps linear in the keys'
characters. `Haus.Linear.Agree` proves that it returns exactly what `parse`
returns; `Haus.Linear.Bound` that it takes linear time.

**Leaves.** Whitespace, numbers, strings, block strings, byte strings and
keys don't call back into values. For them `parseC` runs the reference
parser's own function (`liftP`) and adds its steps, counted by a function
that follows the reference function's recursion: one step per call, one per
character a list function visits (`wsSteps`, `numberCost`,
`basicStringCost`, `blockStringCost`, `bytesCost`, `keyCost`). **Values**,
records, arrays, payloads and files are written out again, with a step for
each call and for each list they copy.
-/

namespace Haus.Linear
open Haus Parser

/-- Runs the reference parser `p`, which takes `c t` steps on input `t`. -/
def liftP {α : Type} (p : P α) (c : Text → Nat) : PC α := fun t => (p.run t, c t)

@[simp] theorem res_liftP {α : Type} (p : P α) (c : Text → Nat) (t : Text) : res (liftP p c) t = p.run t := rfl
@[simp] theorem cost_liftP {α : Type} (p : P α) (c : Text → Nat) (t : Text) : cost (liftP p c) t = c t := rfl

def failC {α : Type} (code : Code) (reason : String) : PC α := liftP (fail code reason) fun _ => 1
def failAtC {α : Type} (code : Code) (reason : String) (t : Text) : PC α := liftP (failAt code reason t) fun _ => 1
def skipC (n : Nat := 1) : PC Unit := liftP (skip n) fun _ => 1
def expectC (c : Char) (code : Code) (what : String) : PC Unit := liftP (expect c code what) fun _ => 1
def takeWhileC (p : Char → Bool) : PC Text := liftP (takeWhile p) fun t => (t.takeWhile p).length + 1

/-! ## Whitespace -/

/-- `blockComment`'s calls. -/
def bcCost : Nat → Text → Nat
  | _, [] => 1
  | d, '/' :: '*' :: r => bcCost (d + 1) r + 1
  | d, '*' :: '/' :: r => if d ≤ 1 then 1 else bcCost (d - 1) r + 1
  | d, c :: r =>
      if isBidi c then 1
      else if isRawControl c && c != '\t' && c != '\n' && !(c == '\r' && r.head? == some '\n') then 1
      else bcCost d r + 1

/-- The line comment's body: what `wsLoop` reads after `//`. -/
def lineBody (r : Text) : Text := r.takeWhile fun c => c != '\n' && c != '\r'

/-- `wsLoop`'s steps: one per call, and the characters its list functions visit. -/
def wsSteps : Nat → Text → Nat
  | 0, _ => 1
  | n + 1, t =>
    match t with
    | ' ' :: r | '\t' :: r | '\n' :: r | '\r' :: '\n' :: r => wsSteps n r + 1
    | '\r' :: _ => 1
    | '/' :: '/' :: r =>
        2 * (lineBody r).length + 3 +
          match (lineBody r).findIdx? fun c => isBidi c || (isRawControl c && c != '\t') with
          | some _ => 0
          | none => wsSteps n (r.dropWhile fun c => c != '\n' && c != '\r')
    | t@('/' :: '*' :: r) =>
        bcCost 1 r + 1 +
          match blockComment t 1 r with
          | .ok r' => wsSteps n r'
          | .error _ => 0
    | '/' :: _ => 1
    | _ => 1

def wsC : PC Unit := liftP ws fun t => wsSteps (t.length + 1) t + 1

/-! ## Numbers -/

def sepTailCost (p : Char → Bool) : Text → Nat
  | '_' :: c :: r => if p c then sepTailCost p r + 1 else 1
  | c :: r => if p c then sepTailCost p r + 1 else 1
  | [] => 1

def digitsCost (p : Char → Bool) : Text → Nat
  | c :: r => if p c then sepTailCost p r + 1 else 1
  | [] => 1

def lexIntCost : Text → Nat
  | '0' :: _ => 1
  | t@(c :: _) => if c != '0' then digitsCost isDigit t + 1 else 1
  | [] => 1

def lexFracCost : Text → Nat
  | '.' :: r => digitsCost isDigit r + 1
  | _ => 1

def lexExpCost : Text → Nat
  | m :: r => if m == 'e' || m == 'E' then digitsCost isDigit (lexSign r).2 + 2 else 1
  | [] => 1

/-- The length of a lexed literal, or 0. -/
def litLen : Option Lexed → Nat
  | some n => n.literal.length
  | none => 0

/-- After the integer part: the fraction and the exponent lexed, and the literal copied. -/
def afterIntCost (s : Text) : Option (Text × Text) → Nat
  | some (i, r) => lexFracCost r + lexExpCost (lexFrac r).2 + (s ++ i ++ (lexFrac r).1 ++ (lexExp (lexFrac r).2).1).length
  | none => 0

/-- The lexers' calls, and the literal they copy. -/
def lexDecimalCost (s r : Text) : Nat := lexIntCost r + 1 + afterIntCost s (lexInt r)

def lexRadixCost (p : Char → Bool) (s pre r : Text) : Nat := digitsCost p r + 1 + litLen (lexRadix p s pre r)

def lexUnsignedCost (s : Text) : Text → Nat
  | '0' :: 'x' :: r =>
      lexRadixCost isHexDigit s ['0', 'x'] r + 1 +
        if (lexRadix isHexDigit s ['0', 'x'] r).isSome then 0 else lexDecimalCost s ('0' :: 'x' :: r)
  | '0' :: 'b' :: r =>
      lexRadixCost isBinDigit s ['0', 'b'] r + 1 +
        if (lexRadix isBinDigit s ['0', 'b'] r).isSome then 0 else lexDecimalCost s ('0' :: 'b' :: r)
  | r => lexDecimalCost s r + 1

def lexNumberCost (t : Text) : Nat := lexUnsignedCost (lexMinus t).1 (lexMinus t).2 + 1

/-- The checks of a lexed number (each visits the literal or its exponent once) and the normalized literal written. -/
def checksCost : Option Lexed → Nat
  | some n => 3 * n.literal.length + n.exponent.length + (normalizeNumber n.literal).length + 4
  | none => 0

/-- `number`'s steps: lexing, then the checks and the normalized literal. -/
def numberCost (t : Text) : Nat := lexNumberCost t + 1 + checksCost (lexNumber t)

def numberC (L : Limits) : PC Value := liftP (number L) numberCost

/-! ## Strings -/

/-- `escape`'s steps: a `\u{…}` escape reads its hex digits (and computes their value). -/
def escapeCost : Text → Nat
  | '\\' :: 'u' :: '{' :: r => 2 * (r.takeWhile isHexDigit).length + 3
  | _ => 2

/-- `chars`' steps, `k` characters read so far; at the end it reverses them. -/
def charsSteps (ok : Char → Bool) (stop : Text → Bool) : Nat → Nat → Text → Nat
  | 0, _, _ => 1
  | n + 1, k, t =>
    if stop t then k + 2
    else match t with
      | [] => 1
      | '\\' :: _ =>
          match escape.run t with
          | .ok (_, r) => escapeCost t + 1 + charsSteps ok stop n (k + 1) r
          | .error _ => escapeCost t + 1
      | c :: r => if isBidi c then 1 else if ok c then charsSteps ok stop n (k + 1) r + 1 else 1

/-- `basicString`'s steps: the characters, then the length check and the copy into a `String`. -/
def basicStringCost (t : Text) : Nat :=
  charsSteps basicChar (·.head? == some '"') (t.length + 1) 0 (t.drop 1) + 3 +
    match (chars "string" t basicChar (·.head? == some '"') (t.length + 1) []).run (t.drop 1) with
    | .ok (s, _) => 2 * s.length
    | .error _ => 0

/-- `findClose`'s calls. -/
def findCloseCost : Text → Nat
  | '\\' :: _ :: r => findCloseCost r + 1
  | '"' :: '"' :: '"' :: _ => 1
  | _ :: r => findCloseCost r + 1
  | [] => 1

/-- `blockLine`'s steps: the line's last character and the indent compared and removed, then its characters. -/
def blockLineCost (indent line : Text) : Nat :=
  let line' := if line.getLast? == some '\r' then line.dropLast else line
  2 * line.length + min indent.length line'.length + 2 +
    if indent <+: line' then
      indent.length + charsSteps blockChar List.isEmpty (line'.length - indent.length + 1) 0 (line'.drop indent.length)
    else line'.length

/-- `mapM blockLine` stops at the first line that fails. -/
def blockLinesCost (indent : Text) : List Text → Nat
  | [] => 1
  | l :: ls => blockLineCost indent l + 1 +
      match blockLine indent l with
      | .ok _ => blockLinesCost indent ls
      | .error _ => 0

/-- Joining the decoded lines, checking the length and copying into a `String`. -/
def joinCost : Except Error (List Text) → Nat
  | .ok ds => 3 * (List.intercalate ['\n'] ds).length + 1
  | .error _ => 0

/-- The closing line's blanks, the indent. -/
def indentOf (lines : List Text) : Text := lines.getLast?.getD []

/--
After the content is found: splitting it into lines (one step per character),
the last line checked, the lines decoded, then joined.
-/
def linesCost (content : Text) : Nat :=
  content.length + 2 * (splitLines content).length + (indentOf (splitLines content)).length + 3 +
    if !(indentOf (splitLines content)).all isBlank then 0
    else blockLinesCost (indentOf (splitLines content)) (splitLines content).dropLast +
      joinCost ((splitLines content).dropLast.mapM (blockLine (indentOf (splitLines content))))

def foundCost : Option (Text × Text) → Nat
  | some (content, _) => linesCost content
  | none => 0

/-- `blockBody`'s steps: finding the end, then the lines. -/
def blockBodyCost (t : Text) : Nat := findCloseCost t + 1 + foundCost (findClose t)

/-- After the opening quotes and blanks: the line break, then the body. -/
def openCost : Text → Nat
  | '\r' :: '\n' :: r | '\n' :: r => blockBodyCost r
  | _ => 0

/-- `blockString`'s steps: the opening line, then the body. -/
def blockStringCost (t : Text) : Nat :=
  ((t.drop 3).takeWhile isBlank).length + 3 + openCost ((t.drop 3).dropWhile isBlank)

/-- `byteChars`' calls. -/
def byteCharsCost : Text → Nat
  | '"' :: _ => 1
  | c :: r =>
      if isBlank c then byteCharsCost r + 1
      else if !isHexDigit c then 1
      else match r with
        | l :: r' => if isHexDigit l then byteCharsCost r' + 1 else 1
        | [] => 1
  | [] => 1

def bytesCost (t : Text) : Nat := byteCharsCost (t.drop 2) + 2

/-- `key`'s steps: a quoted key is a string; a bare key is read, then copied into a `String`. -/
def keyCost : Text → Nat
  | '"' :: '"' :: '"' :: _ => 1
  | t@('"' :: _) => basicStringCost t + 1
  | t@(c :: _) => if isLowerStart c then 3 * (t.takeWhile isIdentChar).length + 3 else 1
  | [] => 1

def keyC (L : Limits) : PC String := liftP (key L) keyCost
def basicStringC (L : Limits) : PC String := liftP (basicString L) basicStringCost
def blockStringC (L : Limits) : PC String := liftP (blockString L) blockStringCost
def bytesC (L : Limits) : PC Value := liftP (bytes L) bytesCost

/-! ## Values -/

mutual
  def valueC (L : Limits) : Nat → Nat → PC Value
    | 0, _ => failC .outOfFuel "out of fuel"
    | fuel + 1, budget => do
      tick 1
      match ← get with
      | '{' :: _ => return .record (← recordC L fuel budget)
      | '[' :: _ => return .arr (← itemsC L fuel budget ']')
      | '"' :: '"' :: '"' :: _ => return .str (← blockStringC L)
      | '"' :: _ => return .str (← basicStringC L)
      | 'x' :: '"' :: _ => bytesC L
      | t@(c :: _) =>
          if c == '-' || isDigit c then numberC L
          else if isUpper c then variantC L fuel budget
          else if isLowerStart c then
            tick ((t.takeWhile isIdentChar).length + 1)
            let word := String.ofList (t.takeWhile isIdentChar)
            failC (identifierCode word) (identifierError word)
          else failC (if c == '+' || c == '.' then .invalidNumber else .expectedValue) s!"expected a value, found {describe t}"
      | [] => failC .expectedValue "expected a value, found end of input"

  def variantC (L : Limits) : Nat → Nat → PC Value
    | 0, _ => failC .outOfFuel "out of fuel"
    | fuel + 1, budget => do
      tick 1
      let start ← get
      let w ← takeWhileC isIdentChar
      tick (w.length + 1)
      let name ← liftP (checkName L "tag" w start) fun _ => 0
      let afterTag ← get
      let _ ← takeWhileC isBlank
      match ← get with
      | t@('(' :: _) =>
          let xs ← itemsC L fuel budget ')'
          if xs.isEmpty then failAtC .emptyPayload s!"empty payload: write '{msgText name}' without parentheses" t
          return .variant name xs
      | '{' :: _ => return .variant name [.record (← recordC L fuel budget)]
      | _ => set afterTag; return .variant name []

  def recordC (L : Limits) : Nat → Nat → PC (List (String × Value))
    | 0, _ => failC .outOfFuel "out of fuel"
    | _, 0 => failC .nestingTooDeep s!"nesting deeper than {L.maxDepth} levels"
    | fuel + 1, budget + 1 => do
      tick 1
      let start ← get
      skipC
      wsC
      fieldsC L fuel budget start [] .empty

  /-- `fields`, with the keys read so far also in `ks`. -/
  def fieldsC (L : Limits) : Nat → Nat → Text → List (String × Value) → KeySet → PC (List (String × Value))
    | 0, _, _, _, _ => failC .outOfFuel "out of fuel"
    | fuel + 1, budget, start, acc, ks => do
      tick 1
      match ← get with
      | '}' :: r => set r; tick (acc.length + 1); return acc.reverse
      | [] => failAtC .unclosedBracket "unclosed '{'" start
      | t =>
          let k ← keyC L
          wsC
          expectC ':' .missingColon s!"expected ':' after key '{msgText k}'"
          wsC
          let v ← valueC L fuel budget
          let p := keyBits k.toList
          tick (p.length + 1)
          tick (ks.memC p).2
          if (ks.memC p).1 then failAtC .duplicateKey s!"duplicate key '{msgText k}'" t
          tick (ks.insertC p).2
          wsC
          tick 1
          match ← get with
          | ',' :: r => set r; wsC; fieldsC L fuel budget start ((k, v) :: acc) (ks.insertC p).1
          | '}' :: r => set r; tick (acc.length + 2); return ((k, v) :: acc).reverse
          | [] => failAtC .unclosedBracket "unclosed '{'" start
          | r => failC (separatorCode v r) s!"expected ',' or '}}', found {describe r}"

  def itemsC (L : Limits) : Nat → Nat → Char → PC (List Value)
    | 0, _, _ => failC .outOfFuel "out of fuel"
    | _, 0, _ => failC .nestingTooDeep s!"nesting deeper than {L.maxDepth} levels"
    | fuel + 1, budget + 1, close => do
      tick 1
      let start ← get
      skipC
      wsC
      itemsLoopC L fuel budget close start []

  def itemsLoopC (L : Limits) : Nat → Nat → Char → Text → List Value → PC (List Value)
    | 0, _, _, _, _ => failC .outOfFuel "out of fuel"
    | fuel + 1, budget, close, start, acc => do
      tick 1
      match ← get with
      | c :: r =>
          if c == close then set r; tick (acc.length + 1); return acc.reverse
          let v ← valueC L fuel budget
          wsC
          tick 1
          match ← get with
          | ',' :: r => set r; wsC; itemsLoopC L fuel budget close start (v :: acc)
          | c :: r =>
              if c == close then set r; tick (acc.length + 2); return (v :: acc).reverse
              else failC (separatorCode v (c :: r)) s!"expected ',' or '{close}', found {describe (c :: r)}"
          | [] => failAtC .unclosedBracket s!"unclosed bracket" start
      | [] => failAtC .unclosedBracket s!"unclosed bracket" start
end

/-! ## Files -/

def fileLoopC (L : Limits) (fuel : Nat) : Nat → List Value → PC (List Value)
  | 0, _ => failC .outOfFuel "out of fuel"
  | n + 1, acc => do
    tick 1
    if (← get).isEmpty then tick (acc.length + 1); return acc.reverse
    let v ← valueC L fuel L.maxDepth
    wsC
    tick 1
    match ← get with
    | [] => tick (acc.length + 2); return (v :: acc).reverse
    | ',' :: r => set r; wsC; fileLoopC L fuel n (v :: acc)
    | r => failC (separatorCode v r) s!"expected ',' between top-level values, found {describe r}"

/-- The body of `parseC`, after the byte order mark. -/
def fileC (L : Limits) (t : Text) : PC (List Value) := do wsC; fileLoopC L (4 * (t.length + 1)) (4 * (t.length + 1)) []

/--
**The counting parser**: what `parse L input` returns (`parseC_eq`), and the
steps it took (`parseC_cost`).
-/
def parseC (L : Limits) (input : Text) : Except Error (List Value) × Nat :=
  let t := match input with
    | '﻿' :: r => r
    | r => r
  (((res (fileC L t) t).map Prod.fst).mapError (directive t), cost (fileC L t) t + 2)

end Haus.Linear
