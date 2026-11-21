import Haus.Canonical
import Haus.Layout.Pretty
import Haus.Json.SchemaBased
import Haus.Packages.Suite
import Haus.Profiles.Vectors
import Haus.Stream.Limited
import Haus.SchemaFile.Instances
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
    haus-ref --compact FILE       FILE's values in the compact layout from values (spec §11,
                                  `Layout.compactAll`): one per line, a comma after each when
                                  there is more than one; numbers normalized, keys in source order
    haus-ref --minimised FILE     the same in the minimised layout (`Layout.minimisedAll`)
    haus-ref --pretty FILE [INDENT WIDTH]  the same in the pretty layout without comments
                                  (`Layout.prettyAll`; default indent 2, width 80)
    haus-ref --write-batch LAYOUT DIR N  like --batch, writing each file's values in LAYOUT
                                  (`compact`, `minimised`, or `pretty [INDENT WIDTH]`):
                                  `ok {"values": [<each value alone>, …], "file": <the
                                  file>}` (fuzz/, the value writers)
    haus-ref --time TYPE TEXT     whether TEXT is a valid std/time TYPE (exit 0 or 1)
    haus-ref --time-batch FILE    for each line `TYPE HEX` of FILE (the text as hex-encoded
                                  UTF-8): `ok` or `no` (fuzz/)
    haus-ref --schema-suite DIR [TYPES]  run the schema suite in DIR (spec §14, §15): each
                                  NAME.schema.haus read by the Lean schema-file checker,
                                  invalid/ rejected with its codes, and the cases again with
                                  the types in TYPES (default schema-suite.json, written by
                                  scripts/schema-types.ts)
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
    haus-ref --packages FILE [CASE]      run the package suite FILE (test-suite/packages/cases.haus,
                                  spec §13.3) with the reference resolver, or only the case
                                  CASE, printing its result and the files it read
    haus-ref --stream-suite DIR          run the stream suite DIR/limits.cases.haus (spec §6, §7)
                                  with the reference stream reader, each case whole, one
                                  character at a time and split at every position
    haus-ref --profile NAME FILE         run the test vectors FILE of the official profile NAME
                                  (`@haus-fmt/money/iso`, `@haus-fmt/geo/wgs84`; spec §13.3)
                                  with its reference checker (Haus/Profiles/)
    haus-ref --profile-batch NAME FILE   for each line `TYPE HEX` of FILE (a value's haus text
                                  as hex-encoded UTF-8): decode with the type of the profile's
                                  package and its codec (schema, then checker): `ok <canonical
                                  form of the encoded result>`, `err <place> <code> <reason>`
                                  when the schema rejects it, or `err $ - <reason>` when the
                                  profile does (fuzz/)
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

/--
One result of `--write-batch`: the values written in a layout from values
(spec §11), each on its own (`value` with no line break after it) and the
whole file (`compactAll`, `minimisedAll`, `prettyAll`), as JSON strings:
`ok {"values": […], "file": …}`.
-/
def writeLine (value : Value → Text) (file : List Value → Text) (bytes : ByteArray) : String :=
  match String.fromUTF8? bytes with
  | none => batchLine bytes
  | some s =>
      match Parser.parse {} s.toList with
      | .ok vs =>
          let values := Json.arr (vs.map fun v => Json.str (String.ofList (value v))).toArray
          s!"ok {(Json.mkObj [("values", values), ("file", Json.str (String.ofList (file vs)))]).compress}"
      | .error _ => batchLine bytes

def writeUsage := "usage: haus-ref --write-batch (compact | minimised | pretty [INDENT WIDTH]) DIR N"

/-- The layout `--write-batch` writes: compact, minimised, or pretty with the options. -/
def writeLayout : List String → Option ((Value → Text) × (List Value → Text))
  | ["compact"] => some (Layout.compact, Layout.compactAll)
  | ["minimised"] => some (Layout.minimised, Layout.minimisedAll)
  | ["pretty"] => some (Layout.pretty {} [] 0, Layout.prettyAll {})
  | ["pretty", indent, width] =>
      let o : Layout.Options := { indent := indent.toNat!, width := width.toNat! }
      some (Layout.pretty o [] 0, Layout.prettyAll o)
  | _ => none

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
      -- A record case written by name: the model finds the record itself (`Case.resolve`).
      if let .ok t := p.getObjVal? "named" then return .named tag (← go t)
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
`Err { type, input, code, path }`; for `Err`, the code (spec §17) and the
place (spec §15) as the last part.
-/
def schemaCase : Value → Option (Bool × String × Value × Value × String × String)
  | .variant tag [.record fs] => do
    let ok ← if tag == "Ok" then some true else if tag == "Err" then some false else none
    let .str type ← fs.lookup "type" | none
    let input ← fs.lookup "input"
    let (code, path) ← match ok, fs.lookup "code", fs.lookup "path" with
      | true, _, _ => some ("", "")
      | false, some (.str c), some (.str p) => some (c, p)
      | false, _, _ => none
    return (ok, type, input, (fs.lookup "output").getD input, code, path)
  | _ => none

/-- An error's code as the batch runners print it: `-` for none. -/
def codeText : Option Code → String
  | some c => c.name
  | none => "-"

/-- The cases of a suite with an environment: the failures. -/
def schemaCases (name : String) (env : Schema.Env) (cases : List Value) : Array String := Id.run do
  let mut failures : Array String := #[]
  for c in cases do
    let shown := String.ofList (Canonical.canonical c)
    match schemaCase c with
    | none => failures := failures.push s!"{name}: not a case: {shown}"
    | some (true, type, input, output, _, _) =>
      match decodeCanonical env type input with
      | .ok got =>
        let want := String.ofList (Canonical.canonical output)
        if got != want then failures := failures.push s!"{name}: {shown}: got {got}"
      | .error e => failures := failures.push s!"{name}: {shown}: {e.place}: {e.reason}"
    | some (false, type, input, _, code, path) =>
      match decodeCanonical env type input with
      | .ok got => failures := failures.push s!"{name}: {shown}: accepted as {got}"
      | .error e =>
        if codeText e.code != code then
          failures := failures.push s!"{name}: {shown}: {codeText e.code} instead of {code} ({e.place}: {e.reason})"
        else if e.place != path then
          failures := failures.push s!"{name}: {shown}: at {e.place} instead of {path} ({e.reason})"
  return failures

/-- `NAME.cases.haus` in `dir`: its values. -/
def readCases (dir : System.FilePath) (name : String) : IO (List Value) := do
  match parseBytes (← IO.FS.readBinFile (dir / s!"{name}.cases.haus")) with
  | .ok vs => pure vs
  | .error e => throw (IO.userError s!"{name}.cases.haus: {e}")

/-- The files in `dir` ending in `ext`, without it, sorted. -/
def namesIn (dir : System.FilePath) (ext : String) : IO (List String) := do
  if !(← dir.isDir) then return []
  let names := (← dir.readDir).toList.filterMap fun e =>
    if e.fileName.endsWith ext then some (e.fileName.dropEnd ext.length).toString else none
  return names.mergeSort (· ≤ ·)

/--
A schema file's bytes read by the reference's schema-file checker
(`Haus.SchemaFile.load`): decoded as UTF-8 first, with `invalid-utf8` as in
data (spec §14 shares data's text rules).
-/
def loadSchemaFile (file : System.FilePath) : IO (SchemaFile.C Schema.Env) := do
  match String.fromUTF8? (← IO.FS.readBinFile file) with
  | none => return .error ⟨.invalidUtf8, "invalid UTF-8"⟩
  | some text => return SchemaFile.load text.toList

/--
The schema suite in `dir`: each `NAME.schema.haus` read by the reference's
own schema-file checker (`Haus.SchemaFile.load`) and its `NAME.cases.haus`
decoded with it; each `invalid/NAME.schema.haus` rejected with the code in
`invalid/NAME.error`; and the cases again with the types the TypeScript
binding resolved (`types`, from `scripts/schema-types.ts`), so that both
resolutions are compared on every case.
-/
def runSchemaSuite (dir types : System.FilePath) : IO UInt32 := do
  let mut failures : Array String := #[]
  let mut skipped : Array String := #[]
  -- The schema files, read here.
  let mut count := 0
  let mut bad := 0
  for name in ← namesIn dir ".cases.haus" do
    let cases ← readCases dir name
    count := count + cases.length
    match ← loadSchemaFile (dir / s!"{name}.schema.haus") with
    | .error e =>
      bad := bad + cases.length
      failures := failures.push s!"{name}.schema.haus: rejected: {e.message} [{e.code.name}]"
    | .ok env =>
      let fs := schemaCases name env cases
      bad := bad + fs.size
      failures := failures ++ fs
  -- Schema files the checker must reject, with their code.
  let mut invalid := 0
  let mut invalidBad := 0
  for name in ← namesIn (dir / "invalid") ".schema.haus" do
    invalid := invalid + 1
    let want := (← IO.FS.readFile (dir / "invalid" / s!"{name}.error")).trimAscii.toString
    match ← loadSchemaFile (dir / "invalid" / s!"{name}.schema.haus") with
    | .ok _ =>
      invalidBad := invalidBad + 1
      failures := failures.push s!"invalid/{name}.schema.haus: accepted, expected {want}"
    | .error e =>
      if e.code.name != want then
        invalidBad := invalidBad + 1
        failures := failures.push s!"invalid/{name}.schema.haus: {e.code.name} instead of {want} ({e.message})"
  -- The same cases with the types of TYPES.
  let mut typed := 0
  let mut typedBad := 0
  for (name, env) in ← readSuites types do
    let cases ← readCases dir name
    match env with
    | .error e => skipped := skipped.push s!"{types}: {name}: {cases.length} cases skipped, the schema file is rejected: {e}"
    | .ok env =>
      let fs := schemaCases name env cases
      typed := typed + cases.length
      typedBad := typedBad + fs.size
      failures := failures ++ fs.map (s!"{types}: " ++ ·)
  for f in failures do IO.println f
  for s in skipped do IO.println s
  IO.println s!"{count - bad}/{count} passed, schema files read by the Lean checker"
  IO.println s!"{invalid - invalidBad}/{invalid} invalid schema files rejected with their code"
  IO.println s!"{typed - typedBad}/{typed} passed with the types of {types}"
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
      -- `code`: the error code (spec §17) reading must fail with; `path`, if given, its place in the JSON.
      let some code := strField fs "code" | failures := failures.push s!"schema-based: no code: {shown}"
      match readJsonCanonical env type json with
      | .ok got => failures := failures.push s!"schema-based: {shown}: accepted as {got}"
      | .error e =>
        if codeText e.code != code then
          failures := failures.push s!"schema-based: {shown}: {codeText e.code} instead of {code} ({schemaErrorText e})"
        else if let some path := strField fs "path" then
          if e.place != path then failures := failures.push s!"schema-based: {shown}: at {e.place} instead of {path}"
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
      match Haus.JSON.readHausJsonAt {} json.toList with
      | .ok v => failures := failures.push s!"self-describing: {shown}: accepted as {canonicalText v}"
      | .error (p, e) =>
        if e.code.name != code then failures := failures.push s!"self-describing: {shown}: {e.code} instead of {code} ({e.reason})"
        else if let some path := strField fs "path" then
          let place := Haus.JSON.placeText p
          if place != path then failures := failures.push s!"self-describing: {shown}: at {place} instead of {path}"
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
      | .error e =>
        if e.code.name != code then failures := failures.push s!"import: {shown}: {e.code} instead of {code} ({e.reason})"
        -- The import's errors are errors in the text (§16.1): they have no place in a value.
        else if (strField fs "path").isSome then failures := failures.push s!"import: {shown}: no place to compare"
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

/--
One line of `--schema-check-batch`: `HEX`, a schema file's bytes, read by the
reference's schema-file checker as `loadSchemaFile` reads a file: `ok`, or
`err <code> <message>`.
-/
def schemaCheckLine (line : String) : String :=
  match String.fromUTF8? (unhex line) with
  | none => "err invalid-utf8 invalid UTF-8"
  | some text =>
    match SchemaFile.load text.toList with
    | .ok _ => "ok"
    | .error e => s!"err {e.code.name} {oneLine e.message}"

/-! ## Package resolution (spec §13.3) -/

/--
`--packages FILE [NAME]`: every case of the package suite in FILE
(`test-suite/packages/cases.haus`), or only the case NAME, with its message
and the files read. Cases marked `should` are run: the reference makes the
version check.
-/
def runPackages (file : System.FilePath) (only : Option String) : IO UInt32 := do
  let vs ← match parseBytes (← IO.FS.readBinFile file) with
    | .ok vs => pure vs
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
  let mut failed := 0
  let mut count := 0
  for v in vs do
    match Packages.Suite.decode v with
    | .error e => IO.println s!"FAIL (case not read): {e}"; failed := failed + 1; count := count + 1
    | .ok c =>
      if only.any (· != c.name) then continue
      count := count + 1
      let (verdict, o) := Packages.Suite.check c
      let should := if c.should then " (should)" else ""
      match verdict with
      | none => IO.println s!"ok   {c.name}{should}"
      | some why => failed := failed + 1; IO.println s!"FAIL {c.name}{should}: {why}"
      if only.isSome then
        IO.println s!"     {Packages.Suite.showResult o.result}"
        IO.println s!"     read: {o.reads.map Packages.showPath}"
  IO.println s!"{count - failed}/{count} passed"
  return if failed == 0 then 0 else 1

/-! ## Profiles (spec §13.3) -/

/-- `--profile NAME FILE`: every vector of FILE, with the reference checker of the profile NAME. -/
def runProfile (name : String) (file : System.FilePath) : IO UInt32 := do
  let some p := Profiles.find? name
    | IO.eprintln s!"unknown profile {name} ({(Profiles.all.map (·.name))})"; return 2
  let vs ← match parseBytes (← IO.FS.readBinFile file) with
    | .ok vs => pure vs
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
  let mut failed := 0
  for v in vs do
    let shown := oneLine (String.ofList (Canonical.canonical v))
    match Profiles.Vector.ofValue v >>= fun vec => (vec.run p).map (vec, ·) with
    | .ok (vec, what) => IO.println s!"ok   {if vec.accept then "Accept" else "Reject"} {vec.type} {vec.value}: {what}"
    | .error why => failed := failed + 1; IO.println s!"FAIL {shown}: {why}"
  IO.println s!"{vs.length - failed}/{vs.length} passed"
  return if failed == 0 then 0 else 1

/-- One line of `--profile-batch`: `TYPE HEX`. -/
def profileLine (p : Profiles.Profile) (line : String) : String :=
  match line.splitOn " " with
  | [type, hex] =>
    match p.check? type, parseBytes (unhex hex) with
    | none, _ => s!"err $ - {type} is not a type of {p.name}"
    | some _, .error e => s!"err $ - {oneLine e}"
    | some check, .ok [v] =>
      match Schema.decode p.env (.ref type) v, p.decode type check v with
      | _, .ok x => s!"ok {canonicalText (Schema.encode x)}"
      | .error e, _ => errLine e
      | .ok _, .error _ => s!"err $ - not accepted by {p.name}"
    | some _, .ok _ => "err $ - not a single value"
  | _ => "err $ - bad line"

def runProfileBatch (name : String) (file : System.FilePath) : IO UInt32 := do
  let some p := Profiles.find? name | IO.eprintln s!"unknown profile {name}"; return 2
  runLineBatch (profileLine p) file

/-! ## Streams (spec §6, §7) -/

/-- A case of the stream suite: the text, the reader's options, and the values or the error code. -/
def streamCase : Value → Option (String × Haus.Stream.Options × Except String (List Value))
  | .record fs => do
    let .str text ← fs.lookup "text" | none
    let .num n ← fs.lookup "maxValueLength" | none
    let max ← n.toNat?
    let strict := match fs.lookup "strict" with
      | some (.variant "True" []) => true
      | _ => false
    let result ← match fs.lookup "result" with
      | some (.variant "Ok" [.arr vs]) => some (.ok vs)
      | some (.variant "Err" [.str code]) => some (.error code)
      | _ => none
    return (text, { maxValueLength := max, strict }, result)
  | _ => none

/-- The text whole, one character at a time, and in two pieces split at every character. -/
def streamSplits (t : Text) : List (String × List Text) :=
  ("whole", [t]) :: ("by character", t.map ([·])) ::
    (List.range t.length).map fun k => (s!"split at {k}", [t.take k, t.drop k])

/--
`--stream-suite DIR`: every case of DIR/limits.cases.haus (test-suite/stream)
read by the reference stream reader (`Stream.readWith`) whole, one character at
a time, and split at every position.
-/
def runStreamSuite (dir : System.FilePath) : IO UInt32 := do
  let file := dir / "limits.cases.haus"
  let vs ← match parseBytes (← IO.FS.readBinFile file) with
    | .ok vs => pure vs
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
  let mut failed := 0
  for v in vs do
    let shown := oneLine (canonicalText v)
    let some (text, o, want) := streamCase v
      | failed := failed + 1; IO.println s!"FAIL (not a case): {shown}"
    let wrong := (streamSplits text.toList).filterMap fun (how, chunks) =>
      let (got, err) := Haus.Stream.readWith o {} chunks
      let same := match want, err with
        | .ok ws, none => got.length == ws.length && (got.zip ws).all fun (a, b) => Value.equiv a b
        | .error code, some e => e.code.name == code
        | _, _ => false
      if same then none
      else some s!"{how}: {match err with | some e => e.code.name | none => toString (got.map canonicalText)}"
    match wrong with
    | [] => IO.println s!"ok   {shown}"
    | w :: _ => failed := failed + 1; IO.println s!"FAIL {shown}: {wrong.length} ways, {w}"
  IO.println s!"{vs.length - failed}/{vs.length} passed"
  return if failed == 0 then 0 else 1

/-- `--compact`, `--minimised`, `--pretty`: FILE's values written in a layout, from values. -/
def runLayout (write : List Value → Text) (file : System.FilePath) : IO UInt32 := do
  match parseBytes (← IO.FS.readBinFile file) with
  | .ok vs => IO.print (String.ofList (write vs)); return 0
  | .error e => IO.eprintln s!"error: {e}"; return 1

def main : List String → IO UInt32
  | ["--stream-suite", dir] => runStreamSuite dir
  | ["--profile", name, file] => runProfile name file
  | ["--profile-batch", name, file] => runProfileBatch name file
  | ["--packages", file] => runPackages file none
  | ["--packages", file, name] => runPackages file (some name)
  | ["--suite", dir] => runSuite dir
  | ["--batch", dir, n] => runBatch batchLine dir n.toNat!
  | ["--canonical-batch", dir, n] => runBatch canonicalLine dir n.toNat!
  | "--write-batch" :: args =>
      match args.reverse with
      | n :: dir :: layout =>
          match writeLayout layout.reverse with
          | some (value, file) => runBatch (writeLine value file) dir n.toNat!
          | none => do IO.eprintln writeUsage; return 2
      | _ => do IO.eprintln writeUsage; return 2
  | ["--canonical", file] => do
      match parseBytes (← IO.FS.readBinFile file) with
      | .ok vs => for v in vs do IO.println (String.ofList (Canonical.canonical v))
                  return 0
      | .error e => IO.eprintln s!"error: {e}"; return 1
  | ["--document", file] => do
      match String.fromUTF8? (← IO.FS.readBinFile file) with
      | none => IO.eprintln s!"error: invalid UTF-8 [{Code.invalidUtf8}]"; return 1
      | some s =>
          let t := s.toList
          match Parser.parseDocument {} t with
          | .ok v => IO.println (jsonText (Haus.JSON.hausJson v)); return 0
          | .error e =>
              let (l, c) := position t e
              IO.eprintln s!"error: {e.reason} at {l}:{c} [{e.code}]"; return 1
  | ["--compact", file] => runLayout Layout.compactAll file
  | ["--minimised", file] => runLayout Layout.minimisedAll file
  | ["--pretty", file] => runLayout (Layout.prettyAll {}) file
  | ["--pretty", file, indent, width] =>
      runLayout (Layout.prettyAll { indent := indent.toNat!, width := width.toNat! }) file
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
  | ["--schema-check-batch", file] => runLineBatch schemaCheckLine file
  | [file] => do
      match parseBytes (← IO.FS.readBinFile file) with
      | .ok vs => IO.print (String.ofList (Haus.JSON.writeHausJsonLines vs)); return 0
      | .error e => IO.eprintln s!"error: {e}"; return 1
  | _ => do IO.eprintln "usage: haus-ref FILE | --document FILE | --suite DIR | --batch DIR N | --canonical FILE | --compact FILE | --minimised FILE | --pretty FILE [INDENT WIDTH] | --canonical-batch DIR N | --write-batch LAYOUT DIR N | --time TYPE TEXT | --time-batch FILE | --schema-suite DIR [TYPES] | --schema-batch TYPES FILE | --json-suite DIR [TYPES] | --json-batch TYPES FILE | --json-read-batch TYPES FILE | --haus-json-batch FILE | --haus-json-read-batch FILE | --import-batch FILE | --schema-check-batch FILE | --packages FILE [CASE] | --profile NAME FILE | --profile-batch NAME FILE | --stream-suite DIR"; return 2
