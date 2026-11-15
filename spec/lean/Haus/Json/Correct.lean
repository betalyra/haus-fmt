import Haus.Json.WellFormed
import Haus.Json.PlainRoundTrip
import Haus.Json.TextRoundTrip
import Haus.Secure

/-!
# The JSON mappings, for every parsed value (spec §16)

The round trips of `Haus.Json.Lossless` and `Haus.Json.PlainRoundTrip` assume
a well-formed value; every value the reference parser returns is one
(`parse_wf`). So they hold for every value of every haus text
(`lossless_parsed`, `plain_parsed`), and, with `Haus.Json.TextRoundTrip`,
through JSON text too: reading the written text gives the value back
(`lossless_text_parsed`, `plain_text_parsed`) when the JSON is within the
limits.
-/

namespace Haus
open Schema

namespace JSON

/-- The lossless form of a value without duplicate keys is well-formed JSON. -/
theorem lossless_wellFormed {v : Value} (h : UniqueKeys v) : WellFormed (lossless v) := by
  induction h with
  | num s => exact .obj _ (by simp) (by simpa using .str _)
  | str s => exact .str _
  | bytes bs => exact .obj _ (by simp) (by simpa using .str _)
  | arr xs _ ih =>
    rw [lossless, losslessList_eq]
    exact .arr _ (by simpa using ih)
  | record fs hnd _ ih =>
    rw [lossless, losslessFields_eq]
    have hin : WellFormed (.obj (fs.map fun kv => (kv.1, lossless kv.2))) := by
      refine .obj _ (by rw [List.map_map]; exact hnd) ?_
      intro m hm
      obtain ⟨kv, hkv, rfl⟩ := List.mem_map.mp hm
      exact ih kv hkv
    exact .obj _ (by simp) (by simpa using hin)
  | variant t xs _ ih =>
    rw [lossless, losslessList_eq]
    cases xs with
    | nil => exact .obj _ (by simp) (by simpa using .str _)
    | cons x xs =>
      exact .obj _ (by simp) (by simpa using ⟨.str _, .arr _ (by simpa using ih)⟩)

/--
**Lossless JSON text round trip** (§16.2): reading the text of the lossless
form of a well-formed value without duplicate keys gives the value back, when
the value and its lossless JSON are within the limits.
-/
theorem readLossless_writeLossless {L : Limits} {v : Value} (hwf : v.wf = true) (hu : UniqueKeys v)
    (hfit : v.fits L = true) (hf : Fits L (jsonDepth L) (lossless v)) :
    readLossless L (writeLossless v) = .ok v := by
  simp [readLossless, writeLossless, parse_write (lossless_wellFormed hu) hf, bind, Except.bind,
    fromLossless_lossless v hwf, checkFits, hfit]

end JSON

/-- **Lossless round trip** (§16.2) for every parsed value: reading its lossless JSON gives it back. -/
theorem lossless_parsed {L : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) : JSON.fromLossless (JSON.lossless v) = .ok v :=
  JSON.fromLossless_lossless v (parse_wf h v hv)

/--
**Plain round trip** (§16.3) for every parsed value a type decodes: reading
the plain JSON of the decoded value gives it back.
-/
theorem plain_parsed {L : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {env : Env} {t : Ty} {x : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hj : toJson env t x = .ok j) : fromJson env t j = .ok x :=
  plain_round_trip hx (parse_wf h v hv) hj

/-- **Plain JSON text round trip** (§16.3): reading the text of a decoded value's plain JSON gives the value back. -/
theorem readPlain_write {L : Limits} {env : Env} {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hv : v.wf = true) (hj : toJson env t x = .ok j) (hw : JSON.WellFormed j)
    (hf : JSON.Fits L (JSON.jsonDepth L) j) (hfit : (encode x).fits L = true) :
    readPlain L env t (JSON.write j) = .ok x := by
  simp [readPlain, JSON.parse_write hw hf, bind, Except.bind, plain_round_trip h hv hj, Except.mapError, hfit]

/-- The lossless text round trip for every parsed value. -/
theorem lossless_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) (hfit : v.fits L' = true) (hf : JSON.Fits L' (JSON.jsonDepth L') (JSON.lossless v)) :
    JSON.readLossless L' (JSON.writeLossless v) = .ok v :=
  JSON.readLossless_writeLossless (parse_wf h v hv) (parse_uniqueKeys h v hv) hfit hf

/-- The plain text round trip for every parsed value a type decodes. -/
theorem plain_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {env : Env} {t : Ty} {x : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hj : toJson env t x = .ok j) (hw : JSON.WellFormed j)
    (hf : JSON.Fits L' (JSON.jsonDepth L') j) (hfit : (encode x).fits L' = true) :
    readPlain L' env t (JSON.write j) = .ok x :=
  readPlain_write hx (parse_wf h v hv) hj hw hf hfit

end Haus
