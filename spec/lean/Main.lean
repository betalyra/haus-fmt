import Haus
import Lean.Data.Json

/-!
`haus-ref`: the reference parser on the command line.

    haus-ref FILE          print FILE's values as self-describing JSON Lines (spec §16.2):
                           one envelope per value
    haus-ref --suite DIR   run the conformance suite in DIR (valid/ and invalid/)
    haus-ref --batch DIR N for DIR/00000.haus … DIR/{N-1}.haus, one line each:
                           `ok <values>` (in the encoding fuzz/ compares parsers in)
                           or `err <line> <column> <code> <reason>` (fuzz/; the code of spec §17)
    haus-ref --canonical FILE     the canonical form of each value in FILE, one per line (spec §12)
    haus-ref --canonical-batch DIR N  like --batch, printing `ok ["<canonical>", …]` (fuzz/)
    haus-ref --time TYPE TEXT     whether TEXT is a valid std/time TYPE (exit 0 or 1)
    haus-ref --time-batch FILE    for each line `TYPE HEX` of FILE (the text as hex-encoded
                                  UTF-8): `ok` or `no` (fuzz/)
    haus-ref --schema-suite DIR [TYPES]  run the schema suite in DIR (spec §15) with the
                                  resolved types in TYPES (default schema-suite.json,
                                  written by scripts/schema-types.ts)
    haus-ref --schema-batch TYPES FILE   for each line `SUITE TYPE HEX` of FILE (a value's haus
                                  text as hex-encoded UTF-8): `ok <canonical form of the
                                  encoded result>` or `err <place> <code> <reason>` (fuzz/;
                                  `-` for an error without a code)
    haus-ref --json-suite DIR [TYPES]    run the JSON suite in DIR (spec §16) with the resolved
                                  types in TYPES (default json-suite.json); the
                                  self-describing cases include every DIR/../valid/NAME.jsonl
    haus-ref --json-batch TYPES FILE     schema-based JSON (spec §16.3): for each line
                                  `SUITE TYPE HEX` (a value's haus text): decode, write:
                                  `ok <JSON>` or `err <place> <code> <reason>`
    haus-ref --json-read-batch TYPES FILE  for each line `SUITE TYPE HEX` (JSON text): read with
                                  the type: `ok <canonical form of the encoded result>` or
                                  `err <place> <code> <reason>` (an error in the text at `$`)
    haus-ref --haus-json-batch FILE      self-describing JSON (spec §16.2): for each line `HEX`
                                  (a haus value): `ok <JSON>` (the envelope) or `err $ - <reason>`
    haus-ref --haus-json-read-batch FILE  for each line `HEX` (JSON text, an envelope):
                                  `ok <canonical form>` or `err $ <code> <reason>`
    haus-ref --import-batch FILE         the same for the JSON import (spec §16.1)
-/

open Haus Lean

/--
The encoding the fuzzer compares parsers in (`suiteJson` in
fuzz/src/runners.ts): self-describing JSON's forms (spec §16.2) without the
underscores and without the envelope.
-/
partial def toJson : Value → Json
  | .num t => Json.mkObj [("num", Json.str t)]
  | .str s => Json.str s
  | .bytes bs => Json.mkObj [("bytes", Json.str (String.join (bs.map hex)))]
  | .arr xs => Json.arr (xs.map toJson).toArray
  | .record fs => Json.mkObj [("rec", Json.mkObj (fs.map fun (k, v) => (k, toJson v)))]
  | .variant t [] => Json.mkObj [("tag", Json.str t)]
  | .variant t xs => Json.mkObj [("tag", Json.str t), ("args", Json.arr (xs.map toJson).toArray)]
where
  hex (b : UInt8) : String :=
    let d := Nat.toDigits 16 b.toNat
    String.ofList (if d.length < 2 then '0' :: d else d)

/-- Line and column (1-based, in characters) of an error. -/
def position (input : Text) (e : Parser.Error) : Nat × Nat :=
  let before := input.take (input.length - e.remaining)
  let line := before.count '\n' + 1
  let column := (before.reverse.takeWhile (· != '\n')).length + 1
  (line, column)

/-- One result of `--batch`. -/
def batchLine (bytes : ByteArray) : String :=
  match String.fromUTF8? bytes with
  | none => s!"err 0 0 {Code.invalidUtf8} invalid UTF-8"
  | some s =>
      let t := s.toList
      match Parser.parse {} t with
      | .ok vs => s!"ok {(Json.arr (vs.map toJson).toArray).compress}"
      | .error e =>
          let (l, c) := position t e
          -- One line per case: line breaks in the reason (from a quoted key, say) as \n.
          s!"err {l} {c} {e.code} {(e.reason.replace "\r" "\\r").replace "\n" "\\n"}"

/-- One result of `--canonical-batch`: the canonical form of each value, as JSON strings. -/
def canonicalLine (bytes : ByteArray) : String :=
  match String.fromUTF8? bytes with
  | none => s!"err 0 0 {Code.invalidUtf8} invalid UTF-8"
  | some s =>
      match Parser.parse {} s.toList with
      | .ok vs => s!"ok {(Json.arr (vs.map fun v => Json.str (String.ofList (Canonical.canonical v))).toArray).compress}"
      | .error _ => batchLine bytes

def runBatch (line : ByteArray → String) (dir : System.FilePath) (n : Nat) : IO UInt32 := do
  let out ← IO.getStdout
  for i in [0:n] do
    let name := String.ofList (List.replicate (5 - (toString i).length) '0') ++ toString i
    out.putStrLn (line (← IO.FS.readBinFile (dir / s!"{name}.haus")))
  return 0

/-- Decode UTF-8 and parse: the values, or the error's code (spec §17) and its message. -/
def parseCoded (bytes : ByteArray) : Except (Code × String) (List Value) :=
  match String.fromUTF8? bytes with
  | none => .error (.invalidUtf8, "invalid UTF-8")
  | some s =>
      let t := s.toList
      match Parser.parse {} t with
      | .ok vs => .ok vs
      | .error e => let (l, c) := position t e; .error (e.code, s!"{e.reason} at {l}:{c}")

/-- Decode UTF-8 and parse. -/
def parseBytes (bytes : ByteArray) : Except String (List Value) :=
  (parseCoded bytes).mapError fun (code, message) => s!"{message} [{code}]"

instance : ToString JSON.Error := ⟨fun e => s!"{e.reason} [{e.code}]"⟩

def jsonText (j : Haus.JSON) : String := String.ofList (Haus.JSON.write j)

def canonicalText (v : Value) : String := String.ofList (Canonical.canonical v)

/--
`valid/NAME.jsonl`: the file's values as self-describing JSON Lines (spec
§16.2), one envelope per value. Each line must be, as data, what writing the
value gives, and reading the lines must give the values back.
-/
def validJsonLines (text : String) (vs : List Value) : Option String :=
  match Haus.JSON.parseLines {} text.toList with
  | .error e => some s!"not JSON Lines: {e}"
  | .ok js =>
    if js.length != vs.length then some s!"{js.length} lines for {vs.length} values" else
    match (js.zip vs).findSome? fun (j, v) =>
      if Haus.JSON.equiv (Haus.JSON.hausJson v) j then none else some s!"wrote {jsonText (Haus.JSON.hausJson v)}" with
    | some e => some e
    | none =>
      match Haus.JSON.readHausJsonLines {} text.toList with
      | .error e => some s!"rejected: {e}"
      | .ok ws =>
        if ws.length == vs.length && (ws.zip vs).all fun (w, v) => Value.equiv w v then none
        else some s!"read {ws.map canonicalText}"

def runSuite (dir : System.FilePath) : IO UInt32 := do
  let mut failures : Array String := #[]
  let mut count := 0
  for entry in (← (dir / "valid").readDir).qsort (·.fileName < ·.fileName) do
    let some name := entry.fileName.dropSuffix? ".haus" | continue
    count := count + 1
    -- valid/NAME.jsonl: the expected values, as self-describing JSON Lines.
    let expected ← IO.FS.readFile (dir / "valid" / s!"{name}.jsonl")
    match parseBytes (← IO.FS.readBinFile entry.path) with
    | .ok vs =>
        if let some e := validJsonLines expected vs then failures := failures.push s!"valid/{name}: {e}"
        -- The canonical form of each value, one per line (spec §12).
        let file := dir / "valid" / s!"{name}.canonical"
        if ← file.pathExists then
          let canonical := String.join (vs.map fun v => String.ofList (Canonical.canonical v) ++ "\n")
          if canonical != (← IO.FS.readFile file) then
            failures := failures.push s!"valid/{name}.canonical: got {canonical}"
    | .error e => failures := failures.push s!"valid/{name}: rejected: {e}"
  for entry in (← (dir / "invalid").readDir).qsort (·.fileName < ·.fileName) do
    let some name := entry.fileName.dropSuffix? ".haus" | continue
    count := count + 1
    -- invalid/NAME.error: the code it must be rejected with (spec §17).
    let want := (← IO.FS.readFile (dir / "invalid" / s!"{name}.error")).trimAscii.toString
    match parseCoded (← IO.FS.readBinFile entry.path) with
    | .ok vs => failures := failures.push s!"invalid/{name}: accepted: {(Json.arr (vs.map toJson).toArray).compress}"
    | .error (code, message) =>
      if code.name != want then failures := failures.push s!"invalid/{name}: {code} instead of {want}: {message}"
  for f in failures do IO.println f
  IO.println s!"{count - failures.size}/{count} passed"
  return if failures.isEmpty then 0 else 1

def timeType? (name : String) : Option Time.TimeType :=
  Time.TimeType.all.find? (·.name == name)

/-- The bytes of hex text. -/
def unhex (hex : String) : ByteArray :=
  let digit (c : Char) : Nat := if c.isDigit then c.toNat - '0'.toNat else c.toNat - 'a'.toNat + 10
  let cs := hex.toList.toArray
  ⟨(Array.range (cs.size / 2)).map fun i => UInt8.ofNat (digit cs[2 * i]! * 16 + digit cs[2 * i + 1]!)⟩

/-- One line of `--time-batch`: `TYPE HEX`. -/
def timeLine (line : String) : String :=
  match line.splitOn " " with
  | [ty, hex] =>
      match timeType? ty, String.fromUTF8? (unhex hex) with
      | some t, some text => if Time.check t text.toList then "ok" else "no"
      | none, _ => s!"err unknown type {ty}"
      | _, none => "err invalid UTF-8"
  | _ => "err bad line"

def runTimeBatch (file : System.FilePath) : IO UInt32 := do
  let out ← IO.getStdout
  for line in (← IO.FS.lines file) do
    if !line.isEmpty then out.putStrLn (timeLine line)
  return 0

/-! ## Schema decoding (spec §15) -/

/-- Converting types: the definitions made for the prelude's `Maybe` so far. -/
abbrev TyM := StateT (List (String × Schema.Ty)) (Except String)

/--
A type in the JSON form of `scripts/schema-types.ts`. With `prelude`, the
prelude's `Bool` and `Maybe` are kept apart from a schema's own variants of
the same shape (spec §16.3): `Bool` is the name `Bool` (defined by
`readSuites`), and each use of `Maybe` a definition of its own, named
`Maybe#k` (`Schema.preludeMaybe`), so that it also keeps the place it is
written in.
-/
partial def tyOfJsonM (prelude : Bool) (j : Json) : TyM Schema.Ty := do
  let go := tyOfJsonM prelude
  if let .ok (name : String) := j.getObjValAs? String "builtin" then
    if prelude && name == "Bool" then return .ref "Bool"
    return ← builtin name
  if let .ok (name : String) := j.getObjValAs? String "time" then
    let some k := Time.TimeType.all.find? (·.name == name) | throw s!"unknown std/time type {name}"
    return .time k
  if let .ok (name : String) := j.getObjValAs? String "ref" then return .ref name
  if let .ok t := j.getObjVal? "array" then return .array (← go t)
  if let .ok t := j.getObjVal? "map" then return .map (← go t)
  if let .ok t := j.getObjVal? "maybe" then
    let a ← go t
    if !prelude then return .maybe a
    let n := s!"Maybe#{(← get).length}"
    modify (· ++ [(n, .maybe a)])
    return .ref n
  if let .ok t := j.getObjVal? "secret" then return .secret (← go t)
  if let .ok r := j.getObjVal? "record" then
    let (closed, fields) ← record r
    return .record closed fields
  if let .ok v := j.getObjVal? "variant" then
    let closed ← v.getObjValAs? Bool "closed"
    let cases ← (← v.getObjValAs? (Array Json) "cases").toList.mapM fun c => do
      let tag ← c.getObjValAs? String "tag"
      let p : Json ← c.getObjVal? "payload"
      if p == Json.str "none" then return Schema.Case.bare tag
      if let .ok r := p.getObjVal? "record" then
        let (cl, fields) ← record r
        return .record tag cl fields
      return .positional tag (← (← p.getObjValAs? (Array Json) "positional").toList.mapM go)
    return .variant closed cases
  throw s!"not a type: {j.compress}"
where
  builtin : String → Except String Schema.Ty
    | "String" => pure .string | "Bytes" => pure .bytes | "Bool" => pure .bool
    | "Int" => pure (.int .int) | "Decimal" => pure .decimal | "Any" => pure .any
    | "Float32" => pure (.float .f32) | "Float64" => pure (.float .f64)
    | "Int8" => pure (.int (.signed 8)) | "Int16" => pure (.int (.signed 16))
    | "Int32" => pure (.int (.signed 32)) | "Int64" => pure (.int (.signed 64))
    | "UInt8" => pure (.int (.unsigned 8)) | "UInt16" => pure (.int (.unsigned 16))
    | "UInt32" => pure (.int (.unsigned 32)) | "UInt64" => pure (.int (.unsigned 64))
    | name => throw s!"unknown built-in type {name}"
  record (r : Json) : TyM (Bool × List Schema.Field) := do
    let fields ← (← r.getObjValAs? (Array Json) "fields").toList.mapM fun f => do
      return Schema.Field.mk (← f.getObjValAs? String "key") (← f.getObjValAs? Bool "optional")
        (← tyOfJsonM prelude (← f.getObjVal? "type"))
    return (← r.getObjValAs? Bool "closed", fields)

/-- A type in the JSON form of `scripts/schema-types.ts`, the prelude's variants by shape (spec §15). -/
def tyOfJson (j : Json) : Except String Schema.Ty := (tyOfJsonM false j).run' []

/--
Each suite of a TYPES file: its environment, or why its schema file was
rejected. With `prelude`, the prelude's `Bool` and `Maybe` are kept apart
by name (`tyOfJsonM`), for the JSON mappings.
-/
def readSuites (file : System.FilePath) (prelude : Bool := false) :
    IO (List (String × Except String Schema.Env)) := do
  let json ← IO.ofExcept (Json.parse (← IO.FS.readFile file))
  let suites ← IO.ofExcept (json.getObjValAs? (Array Json) "suites")
  suites.toList.mapM fun s => do
    let name ← IO.ofExcept (s.getObjValAs? String "name")
    if let .ok e := s.getObjValAs? String "error" then return (name, .error e)
    let defs ← IO.ofExcept (s.getObjValAs? (Array Json) "defs")
    let convert (d : Json) : TyM (String × Schema.Ty) := do
      let #[k, t] ← (d.getArr? : Except String (Array Json)) | throw s!"not a definition: {d.compress}"
      return ((← (k.getStr? : Except String String)), ← tyOfJsonM prelude t)
    let (defs, made) ← IO.ofExcept ((defs.toList.mapM convert).run [])
    -- The prelude's `Bool` and each use of its `Maybe`, by name.
    let defs := if prelude then defs ++ made ++ [("Bool", Schema.Ty.bool)] else defs
    return (name, .ok ⟨defs⟩)

/-- Decode with a named type, then encode: the canonical form of the result (spec §12). -/
def decodeCanonical (env : Schema.Env) (type : String) (v : Value) : Except Schema.Error String :=
  (Schema.decode env (.ref type) v).map fun x => String.ofList (Canonical.canonical (Schema.encode x))

/--
A case of `NAME.cases.haus`: `Ok { type, input, output? }` or
`Err { type, input, code }`; for `Err`, the code (spec §17) as the last part.
-/
def schemaCase : Value → Option (Bool × String × Value × Value × String)
  | .variant tag [.record fs] => do
    let ok ← if tag == "Ok" then some true else if tag == "Err" then some false else none
    let .str type ← fs.lookup "type" | none
    let input ← fs.lookup "input"
    let code ← match ok, fs.lookup "code" with
      | true, _ => some ""
      | false, some (.str c) => some c
      | false, _ => none
    return (ok, type, input, (fs.lookup "output").getD input, code)
  | _ => none

/-- An error's code as the batch runners print it: `-` for none. -/
def codeText : Option Code → String
  | some c => c.name
  | none => "-"

def runSchemaSuite (dir types : System.FilePath) : IO UInt32 := do
  let mut failures : Array String := #[]
  let mut skipped : Array String := #[]
  let mut count := 0
  for (name, env) in ← readSuites types do
    let cases ← match parseBytes (← IO.FS.readBinFile (dir / s!"{name}.cases.haus")) with
      | .ok vs => pure vs
      | .error e => throw (IO.userError s!"{name}.cases.haus: {e}")
    match env with
    | .error e => skipped := skipped.push s!"{name}: {cases.length} cases skipped, the schema file is rejected: {e}"
    | .ok env =>
      for c in cases do
        count := count + 1
        let shown := String.ofList (Canonical.canonical c)
        match schemaCase c with
        | none => failures := failures.push s!"{name}: not a case: {shown}"
        | some (true, type, input, output, _) =>
          match decodeCanonical env type input with
          | .ok got =>
            let want := String.ofList (Canonical.canonical output)
            if got != want then failures := failures.push s!"{name}: {shown}: got {got}"
          | .error e => failures := failures.push s!"{name}: {shown}: {e.place}: {e.reason}"
        | some (false, type, input, _, code) =>
          match decodeCanonical env type input with
          | .ok got => failures := failures.push s!"{name}: {shown}: accepted as {got}"
          | .error e =>
            if codeText e.code != code then
              failures := failures.push s!"{name}: {shown}: {codeText e.code} instead of {code} ({e.place}: {e.reason})"
  for f in failures do IO.println f
  for s in skipped do IO.println s
  IO.println s!"{count - failures.size}/{count} passed"
  return if failures.isEmpty then 0 else 1

/-- One line of `--schema-batch`: `SUITE TYPE HEX`. -/
def schemaLine (suites : List (String × Except String Schema.Env)) (line : String) : String :=
  match line.splitOn " " with
  | [suite, type, hex] =>
    match suites.lookup suite, parseBytes (unhex hex) with
    | some (.ok env), .ok [v] =>
      match decodeCanonical env type v with
      | .ok got => s!"ok {got}"
      | .error e => s!"err {e.place} {codeText e.code} {(e.reason.replace "\r" "\\r").replace "\n" "\\n"}"
    | some (.ok _), _ => "err $ - not a single value"
    | some (.error _), _ => "err $ - schema rejected"
    | none, _ => s!"err $ - unknown suite {suite}"
  | _ => "err $ - bad line"

def runSchemaBatch (types file : System.FilePath) : IO UInt32 := do
  let suites ← readSuites types
  let out ← IO.getStdout
  for line in (← IO.FS.lines file) do
    if !line.isEmpty then out.putStrLn (schemaLine suites line)
  return 0

/-! ## JSON (spec §16) -/

/-- A JSON reader's or writer's error with its place and code, as the suites show it. -/
def schemaErrorText (e : Schema.Error) : String := s!"{e.place}: {e.reason} [{codeText e.code}]"

/-- A case of a JSON suite: its tag and fields. -/
def jsonCase : Value → Option (String × List (String × Value))
  | .variant tag [.record fs] => some (tag, fs)
  | _ => none

def strField (fs : List (String × Value)) (k : String) : Option String :=
  match fs.lookup k with
  | some (.str s) => some s
  | _ => none

/-- Read schema-based JSON text with a type and encode the result: its canonical form. -/
def readJsonCanonical (env : Schema.Env) (type : String) (json : String) : Except Schema.Error String :=
  (Schema.readJson {} env (.ref type) json.toList).map fun x => canonicalText (Schema.encode x)

/-- Decode a haus value with a type and write it as schema-based JSON. -/
def writeSchemaBased (env : Schema.Env) (type : String) (v : Value) : Except String Haus.JSON := do
  let x ← (Schema.decode env (.ref type) v).mapError schemaErrorText
  (Schema.toJson env (.ref type) x).mapError schemaErrorText

def runSchemaBasedCases (env : Schema.Env) (cases : List Value) : Array String := Id.run do
  let mut failures : Array String := #[]
  for c in cases do
    let shown := canonicalText c
    let some (tag, fs) := jsonCase c | failures := failures.push s!"schema-based: not a case: {shown}"
    let some type := strField fs "type" | failures := failures.push s!"schema-based: no type: {shown}"
    let some json := strField fs "json" | failures := failures.push s!"schema-based: no json: {shown}"
    match tag with
    | "Ok" =>
      let some input := fs.lookup "input" | failures := failures.push s!"schema-based: no input: {shown}"
      let want := canonicalText ((fs.lookup "output").getD input)
      match writeSchemaBased env type input, Haus.JSON.parse {} json.toList with
      | .ok got, .ok exp =>
        if !Haus.JSON.equiv got exp then failures := failures.push s!"schema-based: {shown}: wrote {jsonText got}"
      | .error e, _ => failures := failures.push s!"schema-based: {shown}: writing failed: {e}"
      | _, .error e => failures := failures.push s!"schema-based: {shown}: the case's JSON: {e}"
      match readJsonCanonical env type json with
      | .ok got => if got != want then failures := failures.push s!"schema-based: {shown}: read {got}"
      | .error e => failures := failures.push s!"schema-based: {shown}: reading failed: {schemaErrorText e}"
    | "Read" =>
      let some output := fs.lookup "output" | failures := failures.push s!"schema-based: no output: {shown}"
      match readJsonCanonical env type json with
      | .ok got => if got != canonicalText output then failures := failures.push s!"schema-based: {shown}: read {got}"
      | .error e => failures := failures.push s!"schema-based: {shown}: reading failed: {schemaErrorText e}"
    | "Err" =>
      -- `code`: the error code (spec §17) reading must fail with.
      let some code := strField fs "code" | failures := failures.push s!"schema-based: no code: {shown}"
      match readJsonCanonical env type json with
      | .ok got => failures := failures.push s!"schema-based: {shown}: accepted as {got}"
      | .error e =>
        if codeText e.code != code then
          failures := failures.push s!"schema-based: {shown}: {codeText e.code} instead of {code} ({schemaErrorText e})"
    | _ => failures := failures.push s!"schema-based: not a case: {shown}"
  return failures

def runSelfDescribingCases (cases : List Value) : Array String := Id.run do
  let mut failures : Array String := #[]
  for c in cases do
    let shown := canonicalText c
    let some (tag, fs) := jsonCase c | failures := failures.push s!"self-describing: not a case: {shown}"
    let some json := strField fs "json" | failures := failures.push s!"self-describing: no json: {shown}"
    let read := Haus.JSON.readHausJson {} json.toList
    match tag with
    | "Ok" =>
      let some input := fs.lookup "input" | failures := failures.push s!"self-describing: no input: {shown}"
      match Haus.JSON.parseDepth {} (Haus.JSON.hausJsonDepth {}) json.toList with
      | .ok exp =>
        if !Haus.JSON.equiv (Haus.JSON.hausJson input) exp then
          failures := failures.push s!"self-describing: {shown}: wrote {jsonText (Haus.JSON.hausJson input)}"
      | .error e => failures := failures.push s!"self-describing: {shown}: the case's JSON: {e}"
      match read with
      | .ok v => if !Value.equiv v input then failures := failures.push s!"self-describing: {shown}: read {canonicalText v}"
      | .error e => failures := failures.push s!"self-describing: {shown}: reading failed: {e}"
    | "Err" =>
      let some code := strField fs "code" | failures := failures.push s!"self-describing: no code: {shown}"
      match read with
      | .ok v => failures := failures.push s!"self-describing: {shown}: accepted as {canonicalText v}"
      | .error e => if e.code.name != code then failures := failures.push s!"self-describing: {shown}: {e.code} instead of {code} ({e.reason})"
    | _ => failures := failures.push s!"self-describing: not a case: {shown}"
  return failures

def runImportCases (cases : List Value) : Array String := Id.run do
  let mut failures : Array String := #[]
  for c in cases do
    let shown := canonicalText c
    let some (tag, fs) := jsonCase c | failures := failures.push s!"import: not a case: {shown}"
    let some json := strField fs "json" | failures := failures.push s!"import: no json: {shown}"
    let read := Haus.JSON.readImport {} json.toList
    match tag with
    | "Read" =>
      let some output := fs.lookup "output" | failures := failures.push s!"import: no output: {shown}"
      match read with
      | .ok v => if !Value.equiv v output then failures := failures.push s!"import: {shown}: read {canonicalText v}"
      | .error e => failures := failures.push s!"import: {shown}: reading failed: {e}"
    | "Err" =>
      let some code := strField fs "code" | failures := failures.push s!"import: no code: {shown}"
      match read with
      | .ok v => failures := failures.push s!"import: {shown}: accepted as {canonicalText v}"
      | .error e => if e.code.name != code then failures := failures.push s!"import: {shown}: {e.code} instead of {code} ({e.reason})"
    | _ => failures := failures.push s!"import: not a case: {shown}"
  return failures

def runJsonSuite (dir types : System.FilePath) : IO UInt32 := do
  let cases (name : String) : IO (List Value) := do
    match parseBytes (← IO.FS.readBinFile (dir / s!"{name}.cases.haus")) with
    | .ok vs => pure vs
    | .error e => throw (IO.userError s!"{name}.cases.haus: {e}")
  let mut failures : Array String := #[]
  let mut count := 0
  for (name, env) in ← readSuites types (prelude := true) do
    let cs ← cases name
    count := count + cs.length
    match env with
    | .error e => failures := failures.push s!"{name}: the schema file is rejected: {e}"
    | .ok env => failures := failures ++ runSchemaBasedCases env cs
  let selfDescribing ← cases "self-describing"
  count := count + selfDescribing.length
  failures := failures ++ runSelfDescribingCases selfDescribing
  let imports ← cases "import"
  count := count + imports.length
  failures := failures ++ runImportCases imports
  -- Every valid/NAME.jsonl is a self-describing case too: one envelope per value of NAME.haus.
  let valid := dir / ".." / "valid"
  for entry in (← valid.readDir).qsort (·.fileName < ·.fileName) do
    let some name := entry.fileName.dropSuffix? ".haus" | continue
    count := count + 1
    match parseBytes (← IO.FS.readBinFile entry.path) with
    | .error e => failures := failures.push s!"valid/{name}: rejected: {e}"
    | .ok vs =>
      if let some e := validJsonLines (← IO.FS.readFile (valid / s!"{name}.jsonl")) vs then
        failures := failures.push s!"valid/{name}.jsonl: {e}"
  for f in failures do IO.println f
  IO.println s!"{count - failures.size}/{count} passed"
  return if failures.isEmpty then 0 else 1

def oneLine (s : String) : String := (s.replace "\r" "\\r").replace "\n" "\\n"

/-- An error as the JSON batch modes print it: `err <place> <code> <reason>` (`-` for no code). -/
def errLine (e : Schema.Error) : String := s!"err {e.place} {codeText e.code} {oneLine e.reason}"

/-- One line of `--json-batch` (`write`) or `--json-read-batch`: `SUITE TYPE HEX`. -/
def jsonLine (write : Bool) (suites : List (String × Except String Schema.Env)) (line : String) : String :=
  match line.splitOn " " with
  | [suite, type, hex] =>
    match suites.lookup suite with
    | some (.ok env) =>
      if write then
        match parseBytes (unhex hex) with
        | .ok [v] =>
          match Schema.decode env (.ref type) v with
          | .error e => errLine e
          | .ok x =>
            match Schema.toJson env (.ref type) x with
            | .ok j => s!"ok {jsonText j}"
            | .error e => errLine e
        | _ => "err $ - not a single value"
      else
        match String.fromUTF8? (unhex hex) with
        | none => "err $ invalid-utf8 invalid UTF-8"
        | some text =>
          match Schema.readJson {} env (.ref type) text.toList with
          | .error e => errLine e
          | .ok x => s!"ok {canonicalText (Schema.encode x)}"
    | some (.error _) => "err $ - schema rejected"
    | none => s!"err $ - unknown suite {suite}"
  | _ => "err $ - bad line"

def runJsonBatch (write : Bool) (types file : System.FilePath) : IO UInt32 := do
  let suites ← readSuites types (prelude := true)
  let out ← IO.getStdout
  for line in (← IO.FS.lines file) do
    if !line.isEmpty then out.putStrLn (jsonLine write suites line)
  return 0

/-- One line of `--haus-json-batch`: a haus value as self-describing JSON, in its envelope. -/
def hausJsonLine (line : String) : String :=
  match parseBytes (unhex line) with
  | .ok [v] => s!"ok {jsonText (Haus.JSON.hausJson v)}"
  | .ok _ => "err $ - not a single value"
  | .error e => s!"err $ - {oneLine e}"

/-- One line of `--haus-json-read-batch` or `--import-batch`: JSON text read as a haus value. -/
def readLine (read : Text → Except JSON.Error Value) (line : String) : String :=
  match String.fromUTF8? (unhex line) with
  | none => "err $ invalid-utf8 invalid UTF-8"
  | some text =>
    match read text.toList with
    | .ok v => s!"ok {canonicalText v}"
    | .error e => s!"err $ {e.code} {oneLine e.reason}"

def runLineBatch (f : String → String) (file : System.FilePath) : IO UInt32 := do
  let out ← IO.getStdout
  for line in (← IO.FS.lines file) do
    if !line.isEmpty then out.putStrLn (f line)
  return 0

def main : List String → IO UInt32
  | ["--suite", dir] => runSuite dir
  | ["--batch", dir, n] => runBatch batchLine dir n.toNat!
  | ["--canonical-batch", dir, n] => runBatch canonicalLine dir n.toNat!
  | ["--canonical", file] => do
      match parseBytes (← IO.FS.readBinFile file) with
      | .ok vs => for v in vs do IO.println (String.ofList (Canonical.canonical v))
                  return 0
      | .error e => IO.eprintln s!"error: {e}"; return 1
  | ["--time", ty, text] =>
      match timeType? ty with
      | some t => do
          let ok := Time.check t text.toList
          IO.println (if ok then "ok" else "invalid"); return if ok then 0 else 1
      | none => do IO.eprintln s!"{ty} is not a std/time type"; return 2
  | ["--time-batch", file] => runTimeBatch file
  | ["--schema-suite", dir] => runSchemaSuite dir "schema-suite.json"
  | ["--schema-suite", dir, types] => runSchemaSuite dir types
  | ["--schema-batch", types, file] => runSchemaBatch types file
  | ["--json-suite", dir] => runJsonSuite dir "json-suite.json"
  | ["--json-suite", dir, types] => runJsonSuite dir types
  | ["--json-batch", types, file] => runJsonBatch true types file
  | ["--json-read-batch", types, file] => runJsonBatch false types file
  | ["--haus-json-batch", file] => runLineBatch hausJsonLine file
  | ["--haus-json-read-batch", file] => runLineBatch (readLine (Haus.JSON.readHausJson {})) file
  | ["--import-batch", file] => runLineBatch (readLine (Haus.JSON.readImport {})) file
  | [file] => do
      match parseBytes (← IO.FS.readBinFile file) with
      | .ok vs => IO.print (String.ofList (Haus.JSON.writeHausJsonLines vs)); return 0
      | .error e => IO.eprintln s!"error: {e}"; return 1
  | _ => do IO.eprintln "usage: haus-ref FILE | --suite DIR | --batch DIR N | --canonical FILE | --canonical-batch DIR N | --time TYPE TEXT | --time-batch FILE | --schema-suite DIR [TYPES] | --schema-batch TYPES FILE | --json-suite DIR [TYPES] | --json-batch TYPES FILE | --json-read-batch TYPES FILE | --haus-json-batch FILE | --haus-json-read-batch FILE | --import-batch FILE"; return 2
