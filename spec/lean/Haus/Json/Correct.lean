import Haus.Json.WellFormed
import Haus.Json.SchemaBasedWellFormed
import Haus.Json.TextRoundTrip
import Haus.Json.SchemaBasedFits
import Haus.Secure

/-!
# The JSON mappings, for every parsed value (spec §16)

The round trips of `Haus.Json.SelfDescribing` and
`Haus.Json.SchemaBasedRoundTrip` assume a well-formed value; every value the
reference parser returns is one (`parse_wf`), and has no duplicate keys
(`parse_uniqueKeys`). So they hold for every value of every haus text
(`hausJson_parsed`, `schemaBased_parsed`), and, with
`Haus.Json.TextRoundTrip`, through JSON text too: the JSON written is well
formed (`hausJson_wellFormed`, `toJson_wellFormed`) and, for a value within
the limits, within the JSON limits (`hausJson_fits`, `toJson_fits`), so
reading its text gives the value back (`hausJson_text_parsed`,
`schemaBased_text_parsed`). The text of self-describing JSON also holds no
raw DEL, C1 or bidi control (`JSON.write_clean`), which its strict reader
rejects;
and a file's values written as self-describing JSON Lines, one envelope per
line, read back as the file's values (`hausJsonLines_text_parsed`).
-/

namespace Haus
open Schema

namespace JSON

theorem readHausJsonText_write {L : Limits} {v : Value} (hwf : v.wf = true) (hu : UniqueKeys v)
    (hL : L.SelfDescribingOk) (hfit : v.fits L = true) :
    readHausJsonText L (write (hausJson v)) = .ok v := by
  have hw := hausJson_wellFormed hu
  simp only [readHausJsonText, parseText_write (strict := true) hw ((hausJson_fits hL hfit).textLimits _), bind,
    Except.bind,
    fromHausJson_hausJson v hwf, checkFits, hfit, ↓reduceIte]

/--
**Self-describing JSON text round trip** (§16.2): reading the text of the
self-describing JSON of a well-formed value without duplicate keys gives the
value back, when the value is within the limits. Its self-describing JSON is
then too (`hausJson_fits`), when the limits leave room for the form's member
names, number literals and version (`SelfDescribingOk`, true of the
defaults). Its text holds no raw character the strict reader rejects: the
writer escapes them (`JSON.write_clean`), and `JSON.parseText_write` holds
in strict mode too.
-/
theorem readHausJson_writeHausJson {L : Limits} {v : Value} (hwf : v.wf = true) (hu : UniqueKeys v)
    (hL : L.SelfDescribingOk) (hfit : v.fits L = true) :
    readHausJson L (writeHausJson v) = .ok v := by
  obtain ⟨c, r, he, hc⟩ := write_head (hausJson_wellFormed hu)
  unfold readHausJson writeHausJson
  rw [he, dropBom_start hc, ← he]
  exact readHausJsonText_write hwf hu hL hfit

/--
**Self-describing JSON Lines round trip** (§16, "Streams"): one envelope per
line, read back as the values written, each well formed, without duplicate
keys and within the limits.
-/
theorem readHausJsonLines_writeHausJsonLines {L : Limits} {vs : List Value} (hwf : ∀ v ∈ vs, v.wf = true)
    (hu : ∀ v ∈ vs, UniqueKeys v) (hL : L.SelfDescribingOk) (hfit : ∀ v ∈ vs, v.fits L = true) :
    readHausJsonLines L (writeHausJsonLines vs) = .ok vs := by
  have hw : ∀ j ∈ vs.map hausJson, WellFormed j := by
    intro j hj
    obtain ⟨v, hv, rfl⟩ := List.mem_map.mp hj
    exact hausJson_wellFormed (hu v hv)
  have hl : writeHausJsonLines vs = writeLines (vs.map hausJson) := by
    simp [writeHausJsonLines, writeLines, writeHausJson, List.flatMap_map]
  have hb : dropBom (writeLines (vs.map hausJson)) = writeLines (vs.map hausJson) := by
    cases vs with
    | nil => rfl
    | cons v vs =>
      obtain ⟨c, r, he, hc⟩ := write_head (hw (hausJson v) (by simp))
      simp only [List.map_cons, writeLines, List.flatMap_cons, he, List.cons_append]
      exact dropBom_start hc
  unfold readHausJsonLines
  rw [hl, hb, lines_writeLines hw]
  clear hl hb hw
  induction vs with
  | nil => rfl
  | cons v vs ih =>
    have h1 : (write (hausJson v)).isEmpty = false := by
      cases h : write (hausJson v) with
      | nil => exact absurd h (write_ne_nil (hausJson_wellFormed (hu v (by simp))))
      | cons _ _ => rfl
    have ih := ih (fun x hx => hwf x (List.mem_cons_of_mem _ hx)) (fun x hx => hu x (List.mem_cons_of_mem _ hx))
      (fun x hx => hfit x (List.mem_cons_of_mem _ hx))
    simp only [List.map_cons, List.mapM_cons, h1, Bool.false_eq_true, ↓reduceIte,
      readHausJsonText_write (hwf v (by simp)) (hu v (by simp)) hL (hfit v (by simp)), ih]
    rfl

end JSON

/-- **Self-describing round trip** (§16.2) for every parsed value: reading its self-describing JSON gives it back. -/
theorem hausJson_parsed {L : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) : JSON.fromHausJson (JSON.hausJson v) = .ok v :=
  JSON.fromHausJson_hausJson v (parse_wf h v hv)

/--
**Schema-based round trip** (§16.3) for every parsed value a type decodes:
reading the schema-based JSON of the decoded value gives it back.
-/
theorem schemaBased_parsed {L : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {env : Env} {t : Ty} {x : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hj : toJson env t x = .ok j) : fromJson env t j = .ok x :=
  schemaBased_round_trip hx (parse_wf h v hv) hj

/--
**Schema-based JSON text round trip** (§16.3): reading the text of a decoded
value's schema-based JSON gives the value back, when the value has no
duplicate keys and its encoding is within the limits. The JSON is well formed
(`toJson_wellFormed`) and within the JSON limits (`toJson_fits`), when the
limits leave room for schema-based JSON's member names and numbers in
strings (`SchemaBasedOk`, the same as `SelfDescribingOk`, true of the defaults).
-/
theorem readJson_write {L : Limits} {env : Env} {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hv : v.wf = true) (hu : UniqueKeys v) (hj : toJson env t x = .ok j)
    (hL : L.SchemaBasedOk) (hfit : (encode x).fits L = true) :
    readJson L env t (JSON.write j) = .ok x := by
  simp [readJson, JSON.parseDepth_write (toJson_wellFormed h hu hj) ((toJson_fits hL h hfit hj).textLimits _), bind,
    Except.bind,
    schemaBased_round_trip h hv hj, Except.mapError, hfit]

/-- The self-describing text round trip for every parsed value within the limits it is read with. -/
theorem hausJson_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) (hL : L'.SelfDescribingOk) (hfit : v.fits L' = true) :
    JSON.readHausJson L' (JSON.writeHausJson v) = .ok v :=
  JSON.readHausJson_writeHausJson (parse_wf h v hv) (parse_uniqueKeys h v hv) hL hfit

/--
A parsed file's values as self-describing JSON Lines (§16, "Streams"), one
envelope per value, read back as the file's values, when they are within the
limits they are read with. This is how the conformance suite's
`valid/NAME.jsonl` holds `valid/NAME.haus`.
-/
theorem hausJsonLines_text_parsed {L L' : Limits} {input : Text} {vs : List Value}
    (h : Parser.parse L input = .ok vs) (hL : L'.SelfDescribingOk) (hfit : ∀ v ∈ vs, v.fits L' = true) :
    JSON.readHausJsonLines L' (JSON.writeHausJsonLines vs) = .ok vs :=
  JSON.readHausJsonLines_writeHausJsonLines (parse_wf h) (parse_uniqueKeys h) hL hfit

/-- The schema-based text round trip for every parsed value a type decodes, within the limits it is read with. -/
theorem schemaBased_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {env : Env} {t : Ty} {x : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hj : toJson env t x = .ok j)
    (hL : L'.SchemaBasedOk) (hfit : (encode x).fits L' = true) :
    readJson L' env t (JSON.write j) = .ok x :=
  readJson_write hx (parse_wf h v hv) (parse_uniqueKeys h v hv) hj hL hfit

end Haus
