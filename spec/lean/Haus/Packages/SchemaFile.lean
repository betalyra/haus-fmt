import Haus.Parser
import Haus.Packages.Names

/-!
# What package resolution reads from a schema file (spec §13.3, §14)

Resolution needs only a schema file's imports (`import M (A, B)`, grammar
`import` and `module`) and the names of the types it defines (`type X …`),
to check that an imported name is defined. `scan` reads exactly that and
skips the bodies of definitions: brackets are balanced, strings and comments
skipped, and a definition ends where the next `import`, `type` or attribute
starts at the top level. It is not a schema checker: the type language
(§14) is outside this model.

The checks of §13.3 "Imports" that need no other file are made here: a
module that is neither `std/…`, `@org/name[@N]` nor `./…`/`../…`
(`unknown-module`), an import naming something other than a major version
(`import-version`), a name imported twice (`duplicate-import`), a type
defined twice or also imported (`duplicate-type`).
-/

namespace Haus.Packages

/-- An error: its code (spec §17) and message. -/
structure Err where
  code : Code
  message : String
  deriving Repr

/-- What an import names. -/
inductive Module where
  /-- A standard module, `std/time`. -/
  | std (name : String)
  /-- A package, `@org/name`, with the major version it asserts (`@1`), if any. -/
  | pkg (name : String) (major : Option String)
  /-- A schema file, `./common` or `../x/common`, without `.schema.haus`. -/
  | file (path : String)
  deriving Repr, DecidableEq, Inhabited

def Module.show : Module → String
  | .std n => s!"std/{n}"
  | .pkg n none => n
  | .pkg n (some m) => s!"{n}@{m}"
  | .file p => p

structure Import where
  module : Module
  names : List String
  deriving Repr, Inhabited

/-- A schema file as resolution sees it. -/
structure Scanned where
  imports : List Import
  types : List String
  deriving Repr, Inhabited

/-- The standard modules (§13.2) and the types they define. -/
def stdModules : List (String × List String) :=
  [("time", ["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"])]

namespace Scan

abbrev R := Except Err

def syntaxErr {α} (what : String) : R α := .error ⟨.schemaSyntax, what⟩

/-- Blanks, line breaks and comments, with the haus lexer's rules (§4). -/
def ws (t : Text) : R Text :=
  match (Parser.ws).run t with
  | .ok (_, r) => .ok r
  | .error e => .error ⟨e.code, e.reason⟩

def isTypeStart (c : Char) : Bool := isUpper c

/-- A keyword at the start of `t`: `w` not followed by an identifier character. -/
def keyword (w : String) (t : Text) : Option Text :=
  let ws := w.toList
  if t.take ws.length == ws && !((t.drop ws.length).head?.any isIdentChar) then some (t.drop ws.length) else none

/-- A type name `[A-Z][A-Za-z0-9_]*`, and the rest. -/
def typeName (t : Text) : R (String × Text) :=
  match t with
  | c :: _ =>
    if isTypeStart c then .ok (String.ofList (t.takeWhile isIdentChar), t.dropWhile isIdentChar)
    else syntaxErr "expected a type name"
  | [] => syntaxErr "expected a type name, found end of input"

/-- `"…"` (and `"""…"""`), after the opening quote: the rest after the string. -/
def skipString : Text → R Text
  | '\\' :: _ :: r => skipString r
  | '"' :: r => .ok r
  | _ :: r => skipString r
  | [] => syntaxErr "unterminated string"

def skipBlock : Text → R Text
  | '"' :: '"' :: '"' :: r => .ok r
  | _ :: r => skipBlock r
  | [] => syntaxErr "unterminated block string"

/--
The body of a definition (or an attribute's arguments) at bracket depth `d`:
the rest where the next top-level item starts. `fuel` is the input's length.
-/
def skipBody : Nat → Nat → Text → R Text
  | 0, _, _ => .error ⟨.outOfFuel, "out of fuel"⟩
  | _ + 1, _, [] => .ok []
  | n + 1, d, t@(c :: r) =>
    if c == '"' then
      if r.take 2 == ['"', '"'] then do skipBody n d (← skipBlock (r.drop 2)) else do skipBody n d (← skipString r)
    else if c == '/' then do
      let r' ← ws t
      if r'.length < t.length then skipBody n d r' else syntaxErr "unexpected '/'"
    else if c == '(' || c == '{' || c == '<' then skipBody n (d + 1) r
    else if c == ')' || c == '}' || c == '>' then
      if d == 0 then syntaxErr s!"unexpected '{c}'" else skipBody n (d - 1) r
    else if d == 0 && c == '@' then .ok t
    else if d == 0 && isIdentChar c then
      let w := t.takeWhile isIdentChar
      if w == "type".toList || w == "import".toList then .ok t else skipBody n d (t.dropWhile isIdentChar)
    else skipBody n d r

/-- `( type_name ( "," type_name )* [","] )`, after the `(`. -/
def names : Nat → Text → List String → R (List String × Text)
  | 0, _, _ => .error ⟨.outOfFuel, "out of fuel"⟩
  | n + 1, t, acc => do
    let t ← ws t
    match t with
    | ')' :: r => if acc.isEmpty then syntaxErr "an import names at least one type" else .ok (acc.reverse, r)
    | _ =>
      let (name, t) ← typeName t
      let t ← ws t
      match t with
      | ',' :: r => names n r (name :: acc)
      | ')' :: r => .ok ((name :: acc).reverse, r)
      | _ => syntaxErr "expected ',' or ')' in an import"

def isPathChar (c : Char) : Bool := isIdentChar c || c == '.' || c == '/' || c == '-'

/-- A module as written: `std/time`, `@org/name`, `@org/name@1`, `./common`. -/
def module (m : String) : R Module :=
  if m.startsWith "std/" then .ok (.std (m.drop 4).toString)
  else if m.startsWith "./" || m.startsWith "../" then
    if m.all isPathChar then .ok (.file m) else syntaxErr s!"a path with characters other than A–Z, a–z, 0–9, _, ., / and -"
  else if m.startsWith "@" then
    match ((m.drop 1).toString.splitOn "@") with
    | [n] => if isPackageName ("@" ++ n) then .ok (.pkg ("@" ++ n) none)
             else .error ⟨.unknownModule, s!"{quote m} is not a package name (@org/name, in lowercase)"⟩
    | n :: vs =>
      if !isPackageName ("@" ++ n) then .error ⟨.unknownModule, s!"{quote m} is not a package name (@org/name, in lowercase)"⟩
      else match vs with
        | [v] => if isMajor v then .ok (.pkg ("@" ++ n) (some v))
                 else .error ⟨.importVersion, s!"{quote m}: an import names a major version only (@1), without leading zeros"⟩
        | _ => .error ⟨.importVersion, s!"{quote m}: an import names a major version only (@1)"⟩
    | [] => .error ⟨.unknownModule, s!"{quote m} is not a module"⟩
  else .error ⟨.unknownModule, s!"{quote m} is neither std/…, a package @org/name nor a file ./name"⟩

/-- An import, after `import`. -/
def importDecl (t : Text) : R (Import × Text) := do
  let t ← ws t
  let tok := t.takeWhile fun c => !(c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '(')
  let m ← module (String.ofList tok)
  let t ← ws (t.drop tok.length)
  match t with
  | '(' :: r =>
    let (ns, r) ← names (r.length + 1) r []
    .ok (⟨m, ns⟩, r)
  | _ => syntaxErr "expected '(' and the imported names"

/-- The items of a schema file: imports and definitions, in order. -/
def items : Nat → Text → List Import → List String → R Scanned
  | 0, _, _, _ => .error ⟨.outOfFuel, "out of fuel"⟩
  | n + 1, t, is, ts => do
    let t ← ws t
    match t with
    | [] => .ok ⟨is.reverse, ts.reverse⟩
    | '@' :: r =>
      -- An attribute: its name and arguments, then the definition it is written before.
      let r := r.dropWhile isIdentChar
      match r with
      | '(' :: r' => items n (← skipBody (r'.length + 1) 1 r') is ts
      | _ => items n r is ts
    | _ =>
      match keyword "import" t, keyword "type" t with
      | some r, _ => let (i, r) ← importDecl r; items n r (i :: is) ts
      | _, some r =>
        let (name, r) ← typeName (← ws r)
        items n (← skipBody (r.length + 1) 0 r) is (name :: ts)
      | none, none => syntaxErr "expected an import or a type definition"

end Scan

/-- The first element that occurs twice. -/
def firstDuplicate : List String → Option String
  | [] => none
  | x :: xs => if x ∈ xs then some x else firstDuplicate xs

/-- Reads a schema file's imports and defined type names, and checks them (spec §13.3, §14). -/
def scan (t : Text) : Except Err Scanned := do
  let s ← Scan.items (t.length + 1) t [] []
  let imported := s.imports.flatMap (·.names)
  if let some n := firstDuplicate imported then
    throw ⟨.duplicateImport, s!"{n} is imported twice"⟩
  if let some n := firstDuplicate s.types then
    throw ⟨.duplicateType, s!"{n} is defined twice"⟩
  if let some n := s.types.find? (· ∈ imported) then
    throw ⟨.duplicateType, s!"{n} is imported and also defined"⟩
  for i in s.imports do
    if let .std m := i.module then
      match stdModules.lookup m with
      | none => throw ⟨.unknownModule, s!"there is no standard module std/{quote m}" ++
          (if m == "money" then "; import @haus-fmt/money instead" else "")⟩
      | some ts =>
        if let some n := i.names.find? (· ∉ ts) then
          throw ⟨.unknownImport, s!"std/{m} has no type {n}"⟩
  return s

private def scanOk (s : String) : Option (List Module × List (List String) × List String) :=
  match scan s.toList with
  | .ok r => some (r.imports.map (·.module), r.imports.map (·.names), r.types)
  | .error _ => none

private def scanCode (s : String) : Option Code :=
  match scan s.toList with
  | .ok _ => none
  | .error e => some e.code

#guard scanOk "import @acme/orders@1 (Order)\ntype Root = { order: Order }" ==
  some ([.pkg "@acme/orders" (some "1")], [["Order"]], ["Root"])
#guard scanOk "import ./billing/common (Iban)\nimport ../x (A, B,)\n// c\n@deprecated(\"x\") type T a = < A { type: a } | B > type U = Array T" ==
  some ([.file "./billing/common", .file "../x"], [["Iban"], ["A", "B"]], ["T", "U"])
#guard scanOk "import std/time (Date)\ntype A = { at: Date, s: \"type\" }" == some ([.std "time"], [["Date"]], ["A"])
#guard scanCode "import @acme/common@1.1 (A)" == some .importVersion
#guard scanCode "import @acme/common@01 (A)" == some .importVersion
#guard scanCode "import std/money (Money)" == some .unknownModule
#guard scanCode "import @Acme/common (A)" == some .unknownModule
#guard scanCode "import @acme/a (A)\nimport @acme/b (A)" == some .duplicateImport
#guard scanCode "import @acme/a (A)\ntype A = Int" == some .duplicateType
#guard scanCode "API_TOKEN=do-not-print" == some .schemaSyntax
#guard scanCode "import ./a~b (A)" == some .schemaSyntax

end Haus.Packages
