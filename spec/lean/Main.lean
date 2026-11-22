import Haus.Canonical
import Haus.Layout.Pretty
import Haus.Layout.Format
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
                                  character at a time and split at every position, and
                                  `whole` by parsing the text whole; then DIR/typed.cases.haus
                                  with DIR/typed.schema.haus (spec §15, "Streams"); then
                                  DIR/document.cases.haus, each text as a single document
    haus-ref --positions FILE            the error positions FILE (test-suite/positions/cases.haus,
                                  spec §8): code, line and column of each text parsed whole,
                                  or as a single document where the case says `document: True`
    haus-ref --equality FILE             equals and compare (test-suite/equality/cases.haus, spec
                                  §2, §12) in both directions; compare from the canonical forms
    haus-ref --format-options FILE       the pretty layout's options (test-suite/format/
                                  options.cases.haus, spec §11) with `Layout.prettyAll`
    haus-ref --format-batch STYLE INDENT WIDTH DIR N  like --batch, reformatting each file with
                                  the standard formatter (`Format.format`, spec §11: comments,
                                  blank lines and spellings kept) in STYLE (`pretty`, `compact`,
                                  `minimised`): `ok <the text as a JSON string>`, the parser's
                                  `err <line> <column> <code> <reason>`, or `crash <reason>`
                                  for a bug of the model (fuzz/, the formatters)
    haus-ref --format-suite DIR          run the format suite DIR (test-suite/format) with
                                  `Format.format`: every check of its README, for cases/,
                                  examples/ and valid/, and options.cases.haus
    haus-ref --profile NAME FILE         run the test vectors FILE of the official profile NAME
                                  (`@haus-fmt/money/iso`, `@haus-fmt/geo/wgs84`; spec §13.3)
                                  with its reference checker (Haus/Profiles/)
    haus-ref --profile-batch NAME FILE   for each line `TYPE HEX` of FILE (a value's haus text
                                  as hex-encoded UTF-8): decode with the type of the profile's
                                  package and its codec (schema, then checker): `ok <canonical
                                  form of the encoded result>`, `err <place> <code> <reason>`
                                  when the schema rejects it, or `err $ codec-rejected <reason>`
                                  when the profile does (fuzz/)
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

/-- Two lists of values, equal pairwise (§2). -/
def valuesEquiv (got want : List Value) : Bool :=
  got.length == want.length && (got.zip want).all fun (a, b) => Value.equiv a b

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

/--
`lines.cases.haus`: JSON Lines of self-describing JSON read as a stream
(`readHausJsonLines`, spec §16 "Streams"): `Ok { json, output }`, the values
read; `Err { json, code, path? }`, the error and its place
(`readHausJsonLinesAt`), which starts with the line's index.
-/
def runLinesCases (cases : List Value) : Array String := Id.run do
  let mut failures : Array String := #[]
  for c in cases do
    let shown := canonicalText c
    let some (tag, fs) := jsonCase c | failures := failures.push s!"lines: not a case: {shown}"
    let some json := strField fs "json" | failures := failures.push s!"lines: no json: {shown}"
    match tag with
    | "Ok" =>
      let some (.arr output) := fs.lookup "output" | failures := failures.push s!"lines: no output: {shown}"
      match Haus.JSON.readHausJsonLines {} json.toList with
      | .ok vs => if !valuesEquiv vs output then failures := failures.push s!"lines: {shown}: read {vs.map canonicalText}"
      | .error e => failures := failures.push s!"lines: {shown}: reading failed: {e}"
    | "Err" =>
      let some code := strField fs "code" | failures := failures.push s!"lines: no code: {shown}"
      match Haus.JSON.readHausJsonLinesAt {} json.toList with
      | .ok vs => failures := failures.push s!"lines: {shown}: accepted as {vs.map canonicalText}"
      | .error (p, e) =>
        if e.code.name != code then failures := failures.push s!"lines: {shown}: {e.code} instead of {code} ({e.reason})"
        else if let some path := strField fs "path" then
          let place := Haus.JSON.placeText p
          if place != path then failures := failures.push s!"lines: {shown}: at {place} instead of {path}"
    | _ => failures := failures.push s!"lines: not a case: {shown}"
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
  let lines ← cases "lines"
  count := count + lines.length
  failures := failures ++ runLinesCases lines
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
      | .ok _, .error _ => s!"err $ {Code.codecRejected.name} not accepted by {p.name}"
    | some _, .ok _ => "err $ - not a single value"
  | _ => "err $ - bad line"

def runProfileBatch (name : String) (file : System.FilePath) : IO UInt32 := do
  let some p := Profiles.find? name | IO.eprintln s!"unknown profile {name}"; return 2
  runLineBatch (profileLine p) file

/-! ## Streams (spec §6, §7) -/

/--
A case of the stream suite: the text, the reader's options, the values or the
error code, and `whole`, where given: the values of parsing the whole text
instead (with the default limits; the value limit is a stream reader's only).
An error case may give its `line` and `column` (both, 1-based, as the positions
suite counts them), which every split must report.
-/
def streamCase : Value → Option (String × Haus.Stream.Options × Except String (List Value) × Option (List Value) × Option (Nat × Nat))
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
    let whole ← match fs.lookup "whole" with
      | none => some none
      | some (.variant "Ok" [.arr vs]) => some (some vs)
      | some _ => none
    let place ← match fs.lookup "line", fs.lookup "column" with
      | none, none => some none
      | some (.num l), some (.num c) => do some (some (← l.toNat?, ← c.toNat?))
      | _, _ => none
    return (text, { maxValueLength := max, strict }, result, whole, place)
  | _ => none


/-- The text whole, one character at a time, and in two pieces split at every character. -/
def streamSplits (t : Text) : List (String × List Text) :=
  ("whole", [t]) :: ("by character", t.map ([·])) ::
    (List.range t.length).map fun k => (s!"split at {k}", [t.take k, t.drop k])

/--
A case of `typed.cases.haus`: `Ok { type, text, output }` (the output
`.ok`) or `Err { type, text, code, path }` (the code and the place `.error`).
-/
def typedCase : Value → Option (String × String × Except (String × String) Value)
  | .variant tag [.record fs] => do
    let type ← strField fs "type"
    let text ← strField fs "text"
    match tag with
    | "Ok" => return (type, text, .ok (← fs.lookup "output"))
    | "Err" => return (type, text, .error (← strField fs "code", ← strField fs "path"))
    | _ => none
  | _ => none

/-- The verdict on a case: passed, failed (why), or not run (why). -/
inductive Verdict
  | right
  | wrong (why : String)
  | skip (why : String)

/--
A typed case (`typedCase`) decoded: a `Stream a` type (one of `streams`) by
the model's stream decoding, any other type's one value by `Schema.decode`.
-/
def typedCheck (env : Schema.Env) (streams : List String) (type text : String)
    (want : Except (String × String) Value) : Verdict :=
  match Parser.parse {} text.toList with
  | .error e =>
    let (l, c) := position text.toList e
    .wrong s!"the text: {e.code} at {l}:{c}"
  | .ok vs =>
    -- A type that isn't a stream reads its text as a single document
    -- (`Parser.parseDocument`): anything but one value is `not-one-value`,
    -- placed at the root (`$`).
    let decoded : Option (Except Schema.Error Value) :=
      if streams.contains type then
        some ((Schema.decodeStream env (.ref type) vs).map fun xs => .arr (xs.map Schema.encode))
      else match vs with
        | [v] => some ((Schema.decode env (.ref type) v).map Schema.encode)
        | _ => none
    match want, decoded with
    | .error (code, path), none =>
      if code != Code.notOneValue.name then .wrong s!"not-one-value instead of {code} ({vs.length} values)"
      else if path != "$" then .wrong s!"not-one-value at $ instead of {path}"
      else .right
    | .ok _, none => .wrong s!"not-one-value: {vs.length} values for {type}, not a stream"
    | .ok w, some (.ok got) => if Value.equiv got w then .right else .wrong s!"got {canonicalText got}"
    | .ok _, some (.error e) => .wrong s!"rejected: {schemaErrorText e}"
    | .error _, some (.ok got) => .wrong s!"accepted as {canonicalText got}"
    | .error (code, path), some (.error e) =>
      if codeText e.code != code then .wrong s!"{codeText e.code} instead of {code} ({schemaErrorText e})"
      else if e.place != path then .wrong s!"at {e.place} instead of {path} ({e.reason})"
      else .right

/--
The typed stream cases of DIR (`typed.schema.haus`, `typed.cases.haus`; spec
§15, "Streams"): the schema read by the reference's schema-file checker, a
`Stream a` definition's text parsed whole and its values decoded by the
model's stream decoding (`Schema.decodeStream`, which puts the item's index
in the place), and any other type's text as a single document: its one value
by `Schema.decode`, anything else `not-one-value` at `$` (spec §6).
The results: (passed, failed, skipped) and a line per case.
-/
def runTypedStreams (dir : System.FilePath) : IO (Nat × Nat × Nat) := do
  let schemaFile := dir / "typed.schema.haus"
  let cases ← readCases dir "typed"
  let env ← match ← loadSchemaFile schemaFile with
    | .ok env => pure env
    | .error e => throw (IO.userError s!"{schemaFile}: rejected: {e.message} [{e.code.name}]")
  -- Which definitions are `Stream a`: the loaded environment has the item type only.
  let streams ← match SchemaFile.parse (← IO.FS.readFile schemaFile).toList with
    | .ok p => pure ((p.defs.filter (·.stream)).map (·.name))
    | .error e => throw (IO.userError s!"{schemaFile}: {e.reason}")
  let mut passed := 0
  let mut failed := 0
  let mut skipped := 0
  for c in cases do
    let shown := oneLine (canonicalText c)
    let some (type, text, want) := typedCase c
      | failed := failed + 1; IO.println s!"FAIL typed (not a case): {shown}"
    match typedCheck env streams type text want with
    | .skip why => skipped := skipped + 1; IO.println s!"skip typed {shown}: {why}"
    | .wrong why => failed := failed + 1; IO.println s!"FAIL typed {shown}: {why}"
    | .right => passed := passed + 1; IO.println s!"ok   typed {shown}"
  return (passed, failed, skipped)

/-- A single-document case: `text` and `Ok(value)` or `Err("code")`. -/
def documentCase : Value → Option (String × Except String Value)
  | .record fs => do
    let text ← strField fs "text"
    match fs.lookup "result" with
    | some (.variant "Ok" [v]) => return (text, .ok v)
    | some (.variant "Err" [.str code]) => return (text, .error code)
    | _ => none
  | _ => none

/--
The single documents of DIR/document.cases.haus (spec §6): each text read by
the reference's single-document reader (`Parser.parseDocument`, default
limits), its value compared as a value (§2), or its error code.
The results: (passed, failed) and a line per case.
-/
def runDocuments (dir : System.FilePath) : IO (Nat × Nat) := do
  let mut passed := 0
  let mut failed := 0
  for c in ← readCases dir "document" do
    let shown := oneLine (canonicalText c)
    let some (text, want) := documentCase c
      | failed := failed + 1; IO.println s!"FAIL document (not a case): {shown}"
    let wrong : Option String := match want, Parser.parseDocument {} text.toList with
      | .ok w, .ok got => if Value.equiv got w then none else some s!"got {canonicalText got}"
      | .ok _, .error e => some s!"rejected: {e.code}"
      | .error _, .ok got => some s!"accepted as {canonicalText got}"
      | .error code, .error e => if e.code.name == code then none else some s!"{e.code} instead of {code}"
    match wrong with
    | none => passed := passed + 1; IO.println s!"ok   document {shown}"
    | some why => failed := failed + 1; IO.println s!"FAIL document {shown}: {why}"
  return (passed, failed)

/--
`--stream-suite DIR`: every case of DIR/limits.cases.haus (test-suite/stream)
read by the reference stream reader (`Stream.readWith`) whole, one character at
a time, and split at every position, and a case's `whole` values by parsing the
whole text (`Parser.parse`, default limits); then the typed streams of
`runTypedStreams`; then DIR/document.cases.haus, each text read as a single
document (`Parser.parseDocument`, spec §6, `runDocuments`).
-/
def runStreamSuite (dir : System.FilePath) : IO UInt32 := do
  let file := dir / "limits.cases.haus"
  let vs ← match parseBytes (← IO.FS.readBinFile file) with
    | .ok vs => pure vs
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
  let mut failed := 0
  let mut wholes := 0
  let mut wholeFailed := 0
  for v in vs do
    let shown := oneLine (canonicalText v)
    let some (text, o, want, whole, place) := streamCase v
      | failed := failed + 1; IO.println s!"FAIL (not a case): {shown}"
    let wrong := (streamSplits text.toList).filterMap fun (how, chunks) =>
      let (got, err) := Haus.Stream.readWith o {} chunks
      let same := match want, err with
        | .ok ws, none => valuesEquiv got ws
        | .error code, some e => e.code.name == code && place.all (position text.toList e == ·)
        | _, _ => false
      if same then none
      else some s!"{how}: {match err with | some e => s!"{e.code.name} at {position text.toList e}" | none => toString (got.map canonicalText)}"
    match wrong with
    | [] => IO.println s!"ok   {shown}"
    | w :: _ => failed := failed + 1; IO.println s!"FAIL {shown}: {wrong.length} ways, {w}"
    -- `whole`: the text parsed whole, where the value limit doesn't apply.
    if let some ws := whole then
      wholes := wholes + 1
      match Parser.parse {} text.toList with
      | .ok got =>
        if valuesEquiv got ws then IO.println s!"ok   parsed whole: {shown}"
        else
          wholeFailed := wholeFailed + 1
          IO.println s!"FAIL parsed whole: {shown}: got {got.map canonicalText}"
      | .error e =>
        wholeFailed := wholeFailed + 1
        IO.println s!"FAIL parsed whole: {shown}: {e.code}"
  let (typedOk, typedFailed, typedSkipped) ← runTypedStreams dir
  let (docOk, docFailed) ← runDocuments dir
  IO.println s!"{vs.length - failed}/{vs.length} passed"
  IO.println s!"{wholes - wholeFailed}/{wholes} parsed whole as `whole` says"
  IO.println s!"{typedOk}/{typedOk + typedFailed} typed cases passed, {typedSkipped} skipped"
  IO.println s!"{docOk}/{docOk + docFailed} single documents passed"
  return if failed == 0 && wholeFailed == 0 && typedFailed == 0 && docFailed == 0 then 0 else 1

/-! ## Error positions, equality and order, layout options -/

/-- A whole number field: `none` when missing; `some none` when it is no natural number (a negative one). -/
def natField? (fs : List (String × Value)) (k : String) : Option (Option Nat) :=
  match fs.lookup k with
  | some (.num n) => some n.toNat?
  | _ => none

/-- A file of cases: its values, or the reason it can't be read. -/
def readCaseFile (file : System.FilePath) : IO (List Value) := do
  match parseBytes (← IO.FS.readBinFile file) with
  | .ok vs => pure vs
  | .error e => throw (IO.userError s!"{file}: {e}")

/-- The cases of FILE judged by `check`: a line each, then the counts. -/
def runCases (file : System.FilePath) (check : Value → Verdict) : IO UInt32 := do
  let vs ← readCaseFile file
  let mut failed := 0
  let mut skipped := 0
  for v in vs do
    let shown := oneLine (canonicalText v)
    match check v with
    | .right => IO.println s!"ok   {shown}"
    | .wrong why => failed := failed + 1; IO.println s!"FAIL {shown}: {why}"
    | .skip why => skipped := skipped + 1; IO.println s!"skip {shown}: {why}"
  IO.println s!"{vs.length - failed - skipped}/{vs.length - skipped} passed{if skipped == 0 then "" else s!", {skipped} skipped"}"
  return if failed == 0 && vs.length > 0 then 0 else 1

/--
A case of `positions/cases.haus` (spec §8): `text`, with one mistake, parsed
whole (`Parser.parse`, as `parseAll`), or as a single document
(`Parser.parseDocument`, as `parse`) when the case says `document: True`,
must be rejected with `code` at `line` and `column` (1-based, columns in code
points: `position`).
-/
def positionCase : Value → Verdict
  | .record fs =>
    let document := fs.lookup "document" == some (.variant "True" [])
    let parsed : Text → Except Parser.Error (List Value) := fun t => if document then (Parser.parseDocument {} t).map ([·]) else Parser.parse {} t
    match strField fs "text", strField fs "code", natField? fs "line", natField? fs "column" with
    | some text, some code, some (some line), some (some column) =>
      match parsed text.toList with
      | .ok vs => .wrong s!"accepted: {vs.map canonicalText}"
      | .error e =>
        let (l, c) := position text.toList e
        if e.code.name != code || l != line || c != column then
          .wrong s!"{e.code} at {l}:{c} instead of {code} at {line}:{column} ({e.reason})"
        else .right
    | _, _, _, _ => .wrong "not a case"
  | _ => .wrong "not a case"

/-- The order of two byte strings: -1, 0 or 1, a prefix first. -/
def bytesOrder : List UInt8 → List UInt8 → Int
  | [], [] => 0
  | [], _ :: _ => -1
  | _ :: _, [] => 1
  | x :: xs, y :: ys => if x < y then -1 else if y < x then 1 else bytesOrder xs ys

/-- `compare` (spec §12): the order of the UTF-8 bytes of the canonical forms. -/
def compareValues (a b : Value) : Int :=
  bytesOrder (canonicalText a).toUTF8.toList (canonicalText b).toUTF8.toList

/--
A case of `equality/cases.haus` (spec §2, §12): `equals` (`Value.equiv`) and
`compare` (`compareValues`, from the model's canonical writer) in both
directions.
-/
def equalityCase : Value → Verdict
  | .record fs =>
    let equal := match fs.lookup "equal" with
      | some (.variant "True" []) => some true
      | some (.variant "False" []) => some false
      | _ => none
    let order := match fs.lookup "order" with
      | some (.num n) => n.toInt?
      | _ => none
    match fs.lookup "a", fs.lookup "b", equal, order with
    | some a, some b, some equal, some order =>
      let got := (Value.equiv a b, Value.equiv b a, compareValues a b, compareValues b a)
      if got == (equal, equal, order, -order) then .right
      else .wrong s!"equals {got.1}/{got.2.1}, compare {got.2.2.1}/{got.2.2.2} instead of {equal}, {order}/{-order}"
    | _, _, _, _ => .wrong "not a case"
  | _ => .wrong "not a case"

/--
A case of `format/options.cases.haus` (spec §11): `input` in the pretty
layout (`Layout.prettyAll`; the input has no comments) with `indent` and
`width` where given, the defaults otherwise. The options are natural numbers:
a negative one can't be given, it is rejected by the types (and the case
passes when `Rejected` is expected).
-/
def optionsCase : Value → Verdict
  | .record fs =>
    let indent := natField? fs "indent"
    let width := natField? fs "width"
    match strField fs "input", fs.lookup "result" with
    | some input, some result =>
      match indent, width with
      | some none, _ | _, some none =>
        match result with
        | .variant "Rejected" [] => .right
        | _ => .wrong "a negative option, not a natural number"
      | _, _ =>
        let o : Layout.Options := { indent := (indent.join).getD 2, width := (width.join).getD 80 }
        match Parser.parse {} input.toList, result with
        | .error e, _ => .wrong s!"the input: {e.code}"
        | .ok vs, .variant "Ok" [.str want] =>
          let got := String.ofList (Layout.prettyAll o vs)
          if got == want then .right else .wrong s!"got {oneLine got}"
        | .ok vs, .variant "Rejected" [] => .wrong s!"not rejected: {oneLine (String.ofList (Layout.prettyAll o vs))}"
        | .ok _, _ => .wrong "not a case"
    | _, _ => .wrong "not a case"
  | _ => .wrong "not a case"

/-! ## The standard formatter (spec §11) -/

/-- The standard formatter on text: the result, or the parser's error. -/
def formatText (style : Format.Style) (o : Layout.Options) (s : String) : Except String String :=
  match Format.format {} style o s.toList with
  | .ok t => .ok (String.ofList t)
  | .error e => .error s!"{e.reason} [{e.code}]"

/--
One result of `--format-batch`: `ok` and the formatted text as a JSON
string, the parser's error as `--batch` prints it, or `crash` when the
model's tree disagrees with the parser (a bug of the model).
-/
def formatLine (style : Format.Style) (o : Layout.Options) (bytes : ByteArray) : String :=
  match String.fromUTF8? bytes with
  | none => batchLine bytes
  | some s =>
    match Parser.parse {} s.toList with
    | .error _ => batchLine bytes
    | .ok _ =>
      match Format.format {} style o s.toList with
      | .ok t => s!"ok {(Json.str (String.ofList t)).compress}"
      | .error e => s!"crash {oneLine e.reason}"

def formatUsage := "usage: haus-ref --format-batch (pretty | compact | minimised) INDENT WIDTH DIR N"

/-- The values of a text, or none when it isn't haus. -/
def valuesOf (s : String) : Option (List Value) := (Parser.parse {} s.toList).toOption

/--
Which characters of a haus text are inside a comment: a scan that skips
strings, block strings and byte strings (whose text may look like a
comment) and marks `//` to the end of its line and `/* … */`, nested.
-/
def commentMask : Nat → Text → List Bool
  | 0, _ => []
  | _ + 1, [] => []
  | fuel + 1, t@('/' :: '/' :: r) =>
    let n := 2 + (r.takeWhile fun c => c != '\n' && c != '\r').length
    List.replicate n true ++ commentMask fuel (t.drop n)
  | fuel + 1, t@('/' :: '*' :: r) =>
    let n := match Parser.blockComment t 1 r with
      | .ok rest => t.length - rest.length
      | .error _ => t.length
    List.replicate n true ++ commentMask fuel (t.drop n)
  | fuel + 1, t@('"' :: '"' :: '"' :: r) =>
    let n := match Parser.findClose r with
      | some (_, rest) => t.length - rest.length
      | none => t.length
    List.replicate n false ++ commentMask fuel (t.drop n)
  | fuel + 1, t@('"' :: r) =>
    let n := 1 + Format.quotedLength r
    List.replicate n false ++ commentMask fuel (t.drop n)
  | fuel + 1, _ :: r => false :: commentMask fuel r

/-- The offsets of the lines' last characters that are a space or a tab outside a comment. -/
def trailingBlanks (s : String) : List Nat :=
  let t := s.toList
  let mask := commentMask (t.length + 1) t
  let next := (t.drop 1).map some ++ [none]
  ((t.zip next).zip mask).zipIdx.filterMap fun (((c, n), inComment), i) =>
    if isBlank c && (n == none || n == some '\n') && !inComment then some i else none

/-- What an editor that trims trailing whitespace makes of a text. -/
def trimLines (s : String) : String :=
  "\n".intercalate ((s.splitOn "\n").map fun l => String.ofList (Pretty.trimEnd l.toList))

-- A blank at the end of a line outside a comment (and none inside a string or comment that looks like one).
#guard trailingBlanks "[1, \n  // b \n  /* c\n */ \"x // \", \"\"\"\n  // \n  \"\"\" \n]\t" == [3, 41, 48, 51]
#guard trimLines "a \n\t\nb\t " == "a\n\nb"

def withoutBlankLines (s : String) : String :=
  "\n".intercalate ((s.splitOn "\n").filter (· != ""))

/-- `NAME.options`: `{ indent: 4, width: 40 }`, for every layout; the default for an option not given. -/
def readFormatOptions (file : System.FilePath) : IO Layout.Options := do
  if !(← file.pathExists) then return {}
  match ← readCaseFile file with
  | [.record fs] =>
    let get (k : String) (d : Nat) := ((natField? fs k).join).getD d
    return { indent := get "indent" 2, width := get "width" 80 }
  | _ => throw (IO.userError s!"{file}: expected a record")

def styleName : Format.Style → String
  | .pretty => "pretty"
  | .compact => "compact"
  | .minimised => "minimised"

/--
The checks of `test-suite/format/README.md` for one input: the three
layouts give the expected files; formatting each result again changes
nothing, and it has the input's values; the minimised result formatted as
pretty is the compact one formatted as pretty, and the pretty file without
its comments (the input formatted without them, F15), blank lines aside;
no line of the pretty result ends in a blank outside a comment, and it has
the same values with its lines trimmed. The failures.
-/
def formatChecks (name input : String) (o : Layout.Options) (expected : Format.Style → IO String) :
    IO (Array String) := do
  let mut failures : Array String := #[]
  let some values := valuesOf input | return #[s!"{name}: the input isn't haus"]
  let mut outs : List (Format.Style × String) := []
  for style in [Format.Style.pretty, .compact, .minimised] do
    let label := s!"{name} ({styleName style})"
    match formatText style o input with
    | .error e => failures := failures.push s!"{label}: rejected: {e}"
    | .ok out =>
      outs := outs ++ [(style, out)]
      let want ← expected style
      if out != want then failures := failures.push s!"{label}:\n  got  {oneLine out}\n  want {oneLine want}"
      if out.contains '\r' then failures := failures.push s!"{label}: a carriage return"
      match formatText style o out with
      | .ok again => if again != out then failures := failures.push s!"{label}: formatted again: {oneLine again}"
      | .error e => failures := failures.push s!"{label}: the output is rejected: {e}"
      if valuesOf out != some values then failures := failures.push s!"{label}: other values"
      if style != .pretty && out.any isLineSep then failures := failures.push s!"{label}: a raw U+2028 or U+2029"
  match outs.lookup .pretty, outs.lookup .compact, outs.lookup .minimised with
  | some pretty, some compact, some minimised =>
    let fromMinimised := (formatText .pretty o minimised).toOption
    if fromMinimised != (formatText .pretty o compact).toOption then
      failures := failures.push s!"{name}: minimised and compact formatted as pretty differ"
    let bare := (Format.read {} input.toList).toOption.map fun f => String.ofList (Format.prettyFile o f.dropComments)
    if fromMinimised.map withoutBlankLines != bare.map withoutBlankLines then
      failures := failures.push s!"{name}: minimised formatted as pretty isn't the pretty file without comments: {oneLine (fromMinimised.getD "")}"
    let blanks := trailingBlanks pretty
    if !blanks.isEmpty then failures := failures.push s!"{name} (pretty): lines ending in a blank, at {blanks}"
    if valuesOf (trimLines pretty) != some values then failures := failures.push s!"{name} (pretty): trimming the lines changes the values"
  | _, _, _ => pure ()
  return failures

/--
A case of `format/options.cases.haus` with the standard formatter, as
`optionsCase` (`--format-options`) checks it with `Layout.prettyAll`.
-/
def formatOptionsCase : Value → Verdict
  | .record fs =>
    let indent := natField? fs "indent"
    let width := natField? fs "width"
    match strField fs "input", fs.lookup "result" with
    | some input, some result =>
      match indent, width with
      | some none, _ | _, some none =>
        match result with
        | .variant "Rejected" [] => .right
        | _ => .wrong "a negative option, not a natural number"
      | _, _ =>
        let o : Layout.Options := { indent := (indent.join).getD 2, width := (width.join).getD 80 }
        match formatText .pretty o input, result with
        | .error e, _ => .wrong s!"the input: {e}"
        | .ok got, .variant "Ok" [.str want] => if got == want then .right else .wrong s!"got {oneLine got}"
        | .ok got, .variant "Rejected" [] => .wrong s!"not rejected: {oneLine got}"
        | .ok _, _ => .wrong "not a case"
    | _, _ => .wrong "not a case"
  | _ => .wrong "not a case"

/--
`--format-suite DIR`: the format suite (`test-suite/format/README.md`) with
the standard formatter: `DIR/cases` and `DIR/examples` (inputs and expected
files side by side), the conformance suite's `DIR/../valid` (expected files
in `DIR/valid`), then `DIR/options.cases.haus`.
-/
def runFormatSuite (dir : System.FilePath) : IO UInt32 := do
  let mut failures : Array String := #[]
  let mut failed := 0
  let mut count := 0
  let groups : List (String × System.FilePath × System.FilePath) :=
    [("cases", dir / "cases", dir / "cases"), ("examples", dir / "examples", dir / "examples"),
     ("valid", dir / ".." / "valid", dir / "valid")]
  for (group, inputs, outputs) in groups do
    for name in ← namesIn inputs ".haus" do
      count := count + 1
      let label := s!"{group}/{name}"
      let some input := String.fromUTF8? (← IO.FS.readBinFile (inputs / s!"{name}.haus"))
        | failures := failures.push s!"{label}: invalid UTF-8"; failed := failed + 1; continue
      let o ← readFormatOptions (outputs / s!"{name}.options")
      let expected (s : Format.Style) : IO String := do
        let file := outputs / s!"{name}.{styleName s}"
        if ← file.pathExists then IO.FS.readFile file else return s!"({file} is missing)"
      let found ← formatChecks label input o expected
      if !found.isEmpty then failed := failed + 1
      failures := failures ++ found
  for f in failures do IO.println s!"FAIL {f}"
  IO.println s!"{count - failed}/{count} inputs passed every check"
  IO.println "options.cases.haus:"
  let options ← runCases (dir / "options.cases.haus") formatOptionsCase
  return if failures.isEmpty && options == 0 then 0 else 1

/-- `--compact`, `--minimised`, `--pretty`: FILE's values written in a layout, from values. -/
def runLayout (write : List Value → Text) (file : System.FilePath) : IO UInt32 := do
  match parseBytes (← IO.FS.readBinFile file) with
  | .ok vs => IO.print (String.ofList (write vs)); return 0
  | .error e => IO.eprintln s!"error: {e}"; return 1

def main : List String → IO UInt32
  | ["--positions", file] => runCases file positionCase
  | ["--equality", file] => runCases file equalityCase
  | ["--format-options", file] => runCases file optionsCase
  | ["--format-suite", dir] => runFormatSuite dir
  | ["--format-batch", style, indent, width, dir, n] =>
      match Format.Style.ofString? style, indent.toNat?, width.toNat? with
      | some style, some indent, some width => runBatch (formatLine style { indent, width }) dir n.toNat!
      | _, _, _ => do IO.eprintln formatUsage; return 2
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
  | _ => do IO.eprintln "usage: haus-ref FILE | --document FILE | --suite DIR | --batch DIR N | --canonical FILE | --compact FILE | --minimised FILE | --pretty FILE [INDENT WIDTH] | --canonical-batch DIR N | --write-batch LAYOUT DIR N | --time TYPE TEXT | --time-batch FILE | --schema-suite DIR [TYPES] | --schema-batch TYPES FILE | --json-suite DIR [TYPES] | --json-batch TYPES FILE | --json-read-batch TYPES FILE | --haus-json-batch FILE | --haus-json-read-batch FILE | --import-batch FILE | --schema-check-batch FILE | --packages FILE [CASE] | --profile NAME FILE | --profile-batch NAME FILE | --stream-suite DIR | --positions FILE | --equality FILE | --format-options FILE | --format-suite DIR | --format-batch STYLE INDENT WIDTH DIR N"; return 2
