import Haus.Parser
import Haus.Packages.Names
import Haus.SchemaFile.Syntax

/-!
# Reading schema files (spec §14, `grammar.ebnf`)

`parse` reads a schema file's text into its imports and definitions
(`Parsed`), with the error codes of §14 for what the grammar already rules
out: attributes (`attribute-space`, `attribute-arguments`, `attribute-twice`,
`attribute-on-spread`), `...r` (`row-parameter`), `closed < >`
(`closed-empty-variant`), a parameter starting with `_`
(`invalid-parameter`), `_` as a type (`underscore-type`), types nested too
deep (`type-too-deep`). Comments, whitespace and quoted field keys are read
by the data parser's own functions (`Parser.ws`, `Parser.basicString`), so
they have the same rules and codes as in data (§14), and so are an
attribute's arguments (`Parser.value`). A module is read as the bindings read
it; what it names is checked by `declare`.

Everything else is checked on what this returns (`Haus.SchemaFile.Check`).
Like the data parser, every function is total: recursion takes fuel, and
running out is a bug, not an answer.
-/

namespace Haus.SchemaFile
open Haus Parser

/-- `import M (A, B)`: the module as written and the names. -/
structure Import where
  module : String
  names : List String
  deriving Repr, Inhabited

/-- A schema file as written: its imports and definitions, in order. -/
structure Parsed where
  imports : List Import
  defs : List Def
  deriving Repr, Inhabited

namespace Parse

/-- How deep records, variants and parentheses may nest in one type (as the bindings). -/
def maxNesting : Nat := 128

def isLowerIdentStart (c : Char) : Bool := ('a' ≤ c && c ≤ 'z') || c == '_'

/-- An identifier at the start of `t` (`[A-Za-z_][A-Za-z0-9_]*`). -/
def ident (t : Text) : Text := match t with
  | c :: _ => if isUpper c || isLowerIdentStart c then t.takeWhile isIdentChar else []
  | [] => []

def isKeyword (w : Text) : Bool := w == "type".toList || w == "import".toList || w == "closed".toList

/-- Whether a type starts here: a name, a parameter, `closed`, `(`, `{` or `<`. -/
def startsAtom (t : Text) : Bool :=
  match t with
  | c :: _ =>
    if isUpper c then true
    else if isLowerIdentStart c then let w := ident t; !isKeyword w || w == "closed".toList
    else c == '(' || c == '{' || c == '<'
  | [] => false

/-- `found 'x'` for a message. -/
def found (t : Text) : String :=
  match t with
  | [] => "end of file"
  | _ => let w := ident t; if w.isEmpty then describe t else s!"'{msgText (String.ofList w)}'"

def unexpected {α : Type} (what : String) (code : Code := .schemaSyntax) : P α := do
  fail code s!"expected {what}, found {found (← get)}"

/-- `ws`, then the character `c`. -/
def punct (c : Char) : P Unit := do
  ws
  match ← get with
  | d :: r => if c == d then set r else unexpected s!"'{c}'"
  | [] => unexpected s!"'{c}'"

/-- `ws`, then whether `c` is next (not consumed). -/
def isNext (c : Char) : P Bool := do ws; return (← get).head? == some c

/-- A type name `[A-Z][A-Za-z0-9_]*`, after `ws`. -/
def typeName (what : String) : P String := do
  ws
  match ← get with
  | c :: _ => if isUpper c then return String.ofList (← takeWhile isIdentChar) else unexpected what
  | [] => unexpected what

/-! ## Attributes (§14) -/

/-- `@name(…)` as read: its name and arguments. -/
structure Attr where
  name : String
  args : List Value
  /-- Where it starts, for its errors. -/
  at_ : Text

/-- The attributes this version defines. -/
def defined : List String := ["deprecated"]

/-- `value ( "," value )* [","] ")"`, after `(` and `ws`: the arguments of an attribute. -/
def attrArgs (start : Text) : Nat → List Value → P (List Value)
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    ws
    match ← get with
    | ')' :: r =>
      if acc.isEmpty then
        failAt .attributeArguments "an attribute's ( … ) needs at least one value; write the attribute without parentheses" start
      set r; return acc.reverse
    | [] => failAt .unclosedBracket "unclosed '(' of an attribute" start
    | _ =>
      let v ← value {} (4 * ((← get).length + 1)) ({} : Limits).maxDepth
      ws
      match ← get with
      | ',' :: r => set r; attrArgs start n (v :: acc)
      | ')' :: _ => attrArgs start n (v :: acc)
      | _ => fail .missingComma "expected ',' or ')' in the attribute's arguments"

/-- `@name` or `@name(value, …)`, at the `@`. -/
def attr : P Attr := do
  let start ← get
  skip
  match ← get with
  | c :: _ =>
    if !(('a' ≤ c && c ≤ 'z') || c == '_') then fail .schemaSyntax "expected an attribute name after '@', like @deprecated"
  | [] => fail .schemaSyntax "expected an attribute name after '@', like @deprecated"
  let name := String.ofList (← takeWhile isIdentChar)
  let afterName ← get
  ws
  match ← get with
  | t@('(' :: r) =>
    if t.length != afterName.length then
      failAt .attributeSpace s!"no space is allowed between @{msgText name} and '('" afterName
    set r
    return ⟨name, ← attrArgs t (r.length + 1) [], start⟩
  | _ => set afterName; return ⟨name, [], start⟩

/--
Spec §14: an attribute this version defines takes the arguments it defines,
once per type, field or tag. Any other is accepted as it is.
-/
def checkAttr (before : List Attr) (a : Attr) : P Unit := do
  if !defined.contains a.name then return
  if before.any (·.name == a.name) then failAt .attributeTwice s!"@{msgText a.name} appears twice here" a.at_
  match a.args with
  | [] | [.str _] => return
  | _ =>
    failAt .attributeArguments "@deprecated takes no argument or one string: @deprecated or @deprecated(\"use email\")" a.at_

/-- The attributes before a type, field or tag: how many there were, and where the first is. -/
def attributes : Nat → List Attr → P (List Attr)
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    ws
    match ← get with
    | '@' :: _ =>
      let a ← attr
      checkAttr acc a
      attributes n (acc ++ [a])
    | _ => return acc

/-! ## Types -/

/--
`...Name`, after the `...`. Spec §14: `...Name` is one token, so nothing may come
between `...` and the name: `... Name` and `.../*c*/Name` are `schema-syntax`,
at the character after `...`.
-/
def spread : P String := do
  let t ← get
  let w := ident t
  match t with
  | c :: _ =>
    if isLowerIdentStart c && !isKeyword w then
      fail .rowParameter s!"row parameters (...{msgText (String.ofList w)}) aren't supported; spread a named type instead: ...UserEvent"
    else if isUpper c then return String.ofList (← takeWhile isIdentChar)
    else if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '/' then
      fail .schemaSyntax "...Name is one word: nothing may come between '...' and the type name (...UserEvent)"
    else unexpected "a type name after '...': ...UserEvent"
  | [] => unexpected "a type name after '...': ...UserEvent"

/-- Whether `...` comes next (after `ws`). -/
def isSpread : P Bool := do ws; return (← get).take 3 == ['.', '.', '.']

/-- A field key: an identifier, or a quoted string with the escapes of data (§14). -/
def fieldKey (what : String) : P String := do
  ws
  match ← get with
  | '"' :: _ => basicString {}
  | c :: _ => if isLowerIdentStart c then return String.ofList (← takeWhile isIdentChar) else unexpected what
  | [] => unexpected what

mutual
/-- `Name atom*`, or one atom. -/
def app : Nat → Nat → P Tm
  | 0, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth => do
    ws
    match ← get with
    | c :: _ =>
      if isUpper c then
        let head := String.ofList (← takeWhile isIdentChar)
        return .ref head (← atoms fuel depth [])
      else atom fuel depth
    | [] => atom fuel depth

/-- The atoms that follow, as far as one starts. -/
def atoms : Nat → Nat → List Tm → P (List Tm)
  | 0, _, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth, acc => do
    ws
    if startsAtom (← get) then atoms fuel depth (acc ++ [← atom fuel depth]) else return acc

/-- A name, a parameter, `( type )`, or a record or variant, `closed` or not. -/
def atom : Nat → Nat → P Tm
  | 0, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth => do
    ws
    let t ← get
    let w := ident t
    let deeper : P Unit :=
      if depth + 1 > maxNesting then fail .typeTooDeep s!"types nested deeper than {maxNesting} levels" else pure ()
    match t with
    | c :: r =>
      if isUpper c then return .ref (String.ofList (← takeWhile isIdentChar)) []
      else if w == "closed".toList then
        set (t.drop w.length)
        ws
        match ← get with
        | '{' :: _ => deeper; record fuel (depth + 1) true
        | '<' :: _ => deeper; variant fuel (depth + 1) true
        | _ => unexpected "a record { … } or a variant < … > after 'closed'"
      else if isLowerIdentStart c && !isKeyword w then
        if w == ['_'] then
          fail .underscoreType "types are open by default, so there is no _: write < > for any tag, or use a type parameter"
        set (t.drop w.length)
        return .var (String.ofList w)
      else if c == '(' then
        set r; deeper
        let inner ← app fuel (depth + 1)
        punct ')'
        return inner
      else if c == '{' then deeper; record fuel (depth + 1) false
      else if c == '<' then deeper; variant fuel (depth + 1) false
      else unexpected "a type"
    | [] => unexpected "a type"

/-- `{ member, … }`, at the `{`. -/
def record : Nat → Nat → Bool → P Tm
  | 0, _, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth, closed => do
    skip
    if ← isNext '|' then fail .schemaSyntax "{| … |} is gone: write closed { … } for a closed record"
    let (ms, ks) ← members fuel depth [] []
    return .node (.record closed ms) ks

def members : Nat → Nat → List Member → List Tm → P (List Member × List Tm)
  | 0, _, _, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth, ms, ks => do
    if ← isNext '}' then skip; return (ms, ks)
    let attrs ← attributes ((← get).length + 1) []
    let (ms, ks) ← if ← isSpread then do
        if let a :: _ := attrs then
          failAt .attributeOnSpread "attributes can't be put on a spread: the fields it copies keep their own" a.at_
        skip 3
        let n ← spread
        pure (ms ++ [.spread], ks ++ [.ref n []])
      else do
        let k ← fieldKey (if attrs.isEmpty then "a field name, ...Name or '}'" else "a field name after the attribute")
        let optional ← isNext '?'
        if optional then skip
        punct ':'
        let ty ← app fuel depth
        pure (ms ++ [.field k optional], ks ++ [ty])
    if ← isNext ',' then skip; members fuel depth ms ks
    else if ← isNext '}' then members fuel depth ms ks
    else unexpected "',' or '}'"

/-- `< alt | … >`, at the `<`. -/
def variant : Nat → Nat → Bool → P Tm
  | 0, _, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth, closed => do
    let start ← get
    skip
    if ← isNext '|' then skip
    let (as, ks) ← alts fuel depth [] []
    if closed && as.isEmpty then failAt .closedEmptyVariant "a closed variant needs at least one tag" start
    return .node (.variant closed as) ks

def alts : Nat → Nat → List Alt → List Tm → P (List Alt × List Tm)
  | 0, _, _, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, depth, as, ks => do
    if ← isNext '>' then skip; return (as, ks)
    let attrs ← attributes ((← get).length + 1) []
    ws
    let t ← get
    let (as, ks) ← match t with
      | c :: _ =>
        if isUpper c then do
          let tag := String.ofList (← takeWhile isIdentChar)
          let args ← atoms fuel depth []
          pure (as ++ [.case tag args.length], ks ++ args)
        else if t.take 3 == ['.', '.', '.'] then do
          if let a :: _ := attrs then
            failAt .attributeOnSpread "attributes can't be put on a spread: the tags it copies keep their own" a.at_
          skip 3
          let n ← spread
          pure (as ++ [.spread], ks ++ [.ref n []])
        else unexpected (if attrs.isEmpty then "a tag, ...Name or '>'" else "a tag after the attribute")
      | [] => unexpected (if attrs.isEmpty then "a tag, ...Name or '>'" else "a tag after the attribute")
    if ← isNext '>' then skip; return (as, ks)
    punct '|'
    -- The grammar has no `|` after the last alternative: `< Y | >` is an error.
    if ← isNext '>' then unexpected "a tag or ...Name after '|'"
    alts fuel depth as ks
end

/-! ## Imports and definitions -/

/--
A character of a package or file module after its `@` or `.`, as every
binding reads one: what it names (a package name, a major version, a path) is
checked by `declare`, with `unknown-module` and `import-version` (§13.3).
-/
def isModuleChar (c : Char) : Bool :=
  isIdentChar c || c == '.' || c == '-' || c == '/' || c == '@'

/--
A character of a package module after its `@`: a module character or `~`.
The bindings read a package import to its end this way, so what follows the
version's `@` (`@a/b@1~x`) is the version, and anything but a `major` there is
`import-version`. A file path has no `~` (grammar `path`): `./a~b` ends
before it, a syntax error.
-/
def isPackageModuleChar (c : Char) : Bool := isModuleChar c || c == '~'

/--
The module of an import (grammar `module`): `std/` and an identifier, or `@`
or `.` and the module characters after it (`@org/name`, `@org/name@1`,
`./file`, `../dir/file`). No whitespace inside: `std/ time` is not a module.
-/
def module : P String := do
  ws
  let t ← get
  match t with
  | 's' :: 't' :: 'd' :: '/' :: c :: r =>
    if isLowerIdentStart c then
      let w := r.takeWhile isIdentChar
      set (r.drop w.length)
      return "std/" ++ String.ofList (c :: w)
    else unexpected "a module like std/time, @org/name or ./file"
  | c :: r =>
    let m := r.takeWhile (if c == '@' then isPackageModuleChar else isModuleChar)
    if (c == '@' || c == '.') && !m.isEmpty then
      set (r.drop m.length)
      return String.ofList (c :: m)
    else unexpected "a module like std/time, @org/name or ./file"
  | [] => unexpected "a module like std/time, @org/name or ./file"

/-- `( Name, … )`, after the `(`. -/
def importNames : Nat → List String → P (List String)
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    if ← isNext ')' then
      if acc.isEmpty then unexpected "a type name (an import names at least one type)" .unknownImport
      skip; return acc
    let name ← typeName "a type name"
    if ← isNext ')' then importNames n (acc ++ [name])
    else punct ','; importNames n (acc ++ [name])

/-- An import, after `import`. -/
def importDecl : P Import := do
  let m ← module
  punct '('
  return ⟨m, ← importNames ((← get).length + 1) []⟩

/-- `( param )*`: lowercase names that aren't keywords. -/
def params : Nat → List String → P (List String)
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    ws
    let t ← get
    let w := ident t
    match t with
    | c :: _ =>
      if isLowerIdentStart c && !isKeyword w then
        if c == '_' then unexpected "a type parameter (starting with a lowercase letter)" .invalidParameter
        set (t.drop w.length)
        params n (acc ++ [String.ofList w])
      else return acc
    | [] => return acc

/-- A definition, after `type`. `type X = Stream T` is a stream of `T`. -/
def typeDecl : P Def := do
  let name ← typeName "a type name (starting with a capital letter)"
  let ps ← params ((← get).length + 1) []
  punct '='
  let t ← get
  let body ← app (8 * (t.length + 1)) 0
  return match body with
    | .ref "Stream" [item] => { name, params := ps, body := item, stream := true }
    | body => { name, params := ps, body }

/-- The items of a file. -/
def items : Nat → Parsed → P Parsed
  | 0, _ => fail .outOfFuel "out of fuel"
  | n + 1, acc => do
    ws
    let t ← get
    if t.isEmpty then return acc
    let attrs ← attributes (t.length + 1) []
    ws
    let t ← get
    let w := ident t
    if w == "type".toList then
      set (t.drop 4)
      items n { acc with defs := acc.defs ++ [← typeDecl] }
    else if !attrs.isEmpty then
      unexpected "a type definition after the attribute (attributes go before a type, a field or a tag)"
    else if w == "import".toList then
      set (t.drop 6)
      items n { acc with imports := acc.imports ++ [← importDecl] }
    else unexpected "'type' or 'import'"

end Parse

/-- A schema file's imports and definitions, or the first error (spec §14). -/
def parse (input : Text) : Except Parser.Error Parsed :=
  let t := match input with
    | '﻿' :: r => r
    | r => r
  (Parse.items (t.length + 1) ⟨[], []⟩).run' t

private def codeOf (src : String) : Option Code :=
  match parse src.toList with
  | .error e => some e.code
  | .ok _ => none

#guard codeOf "type A = { @deprecated (\"x\") x: Int }" == some .attributeSpace
#guard codeOf "type A = { @deprecated(1) x: Int }" == some .attributeArguments
#guard codeOf "@deprecated(\"a\", \"b\")\ntype A = Int" == some .attributeArguments
#guard codeOf "type A = { @deprecated @deprecated(\"x\") x: Int }" == some .attributeTwice
#guard codeOf "type B = { x: Int }\ntype A = { @deprecated ...B }" == some .attributeOnSpread
#guard codeOf "type A = closed < >" == some .closedEmptyVariant
#guard codeOf "type A r = { x: Int, ...r }" == some .rowParameter
#guard codeOf "type B = { x: Int }\ntype A = { ... B }" == some .schemaSyntax
#guard codeOf "type B = { x: Int }\ntype A = { .../*c*/B }" == some .schemaSyntax
#guard codeOf "type B = < X >\ntype A = < ...\nB >" == some .schemaSyntax
#guard codeOf "type B = < X >\ntype A = < ...B | Y >" == none
#guard codeOf "type P _x = { a: _x }" == some .invalidParameter
#guard codeOf "type A = < Y | >" == some .schemaSyntax
#guard codeOf "type A = < | Y >" == none
#guard codeOf "type A = < | >" == none
#guard codeOf "import std/ time (Date)" == some .schemaSyntax
#guard codeOf "import foo/bar (A)" == some .schemaSyntax
#guard codeOf "import std/time/x (Date)" == some .straySlash
#guard codeOf "import std/time ()" == some .unknownImport
#guard codeOf "type A = < X | Y Int (List a) | Z { a: Int, \"b c\"?: Maybe a } | ...B >\n// c\ntype B = Int" == none
#guard (parse "type List a = < Nil | Cons a (List a) >".toList).toOption.map (·.defs.map (·.body)) ==
  some [.node (.variant false [.case "Nil" 0, .case "Cons" 2]) [.var "a", .ref "List" [.var "a"]]]

end Haus.SchemaFile
