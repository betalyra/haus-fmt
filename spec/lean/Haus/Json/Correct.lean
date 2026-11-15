import Haus.Json.WellFormed
import Haus.Json.PlainWellFormed
import Haus.Json.TextRoundTrip
import Haus.Json.PlainFits
import Haus.Secure

/-!
# The JSON mappings, for every parsed value (spec §16)

The round trips of `Haus.Json.Lossless` and `Haus.Json.PlainRoundTrip` assume
a well-formed value; every value the reference parser returns is one
(`parse_wf`), and has no duplicate keys (`parse_uniqueKeys`). So they hold
for every value of every haus text (`lossless_parsed`, `plain_parsed`), and,
with `Haus.Json.TextRoundTrip`, through JSON text too: the JSON written is
well formed (`lossless_wellFormed`, `toJson_wellFormed`) and, for a value
within the limits, within the JSON limits (`lossless_fits`, `toJson_fits`),
so reading its text gives the value back (`lossless_text_parsed`,
`plain_text_parsed`).
-/

namespace Haus
open Schema

namespace JSON

/--
**Lossless JSON text round trip** (§16.2): reading the text of the lossless
form of a well-formed value without duplicate keys gives the value back, when
the value is within the limits. Its lossless JSON is then too
(`lossless_fits`), when the limits leave room for the lossless form's member
names and number literals (`LosslessOk`, true of the defaults).
-/
theorem readLossless_writeLossless {L : Limits} {v : Value} (hwf : v.wf = true) (hu : UniqueKeys v)
    (hL : L.LosslessOk) (hfit : v.fits L = true) :
    readLossless L (writeLossless v) = .ok v := by
  simp [readLossless, writeLossless, parse_write (lossless_wellFormed hu) (lossless_fits hL hfit), bind, Except.bind,
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

/--
**Plain JSON text round trip** (§16.3): reading the text of a decoded value's
plain JSON gives the value back, when the value has no duplicate keys and its
encoding is within the limits. The JSON is well formed (`toJson_wellFormed`)
and within the JSON limits (`toJson_fits`), when the limits leave room for
plain JSON's member names, numbers in strings and number tokens (`PlainOk`,
true of the defaults).
-/
theorem readPlain_write {L : Limits} {env : Env} {t : Ty} {v : Value} {x : Typed} {j : JSON}
    (h : decode env t v = .ok x) (hv : v.wf = true) (hu : UniqueKeys v) (hj : toJson env t x = .ok j)
    (hL : L.PlainOk) (hfit : (encode x).fits L = true) :
    readPlain L env t (JSON.write j) = .ok x := by
  simp [readPlain, JSON.parse_write (toJson_wellFormed h hu hj) (toJson_fits hL h hfit hj), bind, Except.bind, plain_round_trip h hv hj, Except.mapError, hfit]

/-- The lossless text round trip for every parsed value within the limits it is read with. -/
theorem lossless_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) (hL : L'.LosslessOk) (hfit : v.fits L' = true) :
    JSON.readLossless L' (JSON.writeLossless v) = .ok v :=
  JSON.readLossless_writeLossless (parse_wf h v hv) (parse_uniqueKeys h v hv) hL hfit

/-- The plain text round trip for every parsed value a type decodes, within the limits it is read with. -/
theorem plain_text_parsed {L L' : Limits} {input : Text} {vs : List Value} (h : Parser.parse L input = .ok vs)
    {v : Value} (hv : v ∈ vs) {env : Env} {t : Ty} {x : Typed} {j : JSON}
    (hx : decode env t v = .ok x) (hj : toJson env t x = .ok j)
    (hL : L'.PlainOk) (hfit : (encode x).fits L' = true) :
    readPlain L' env t (JSON.write j) = .ok x :=
  readPlain_write hx (parse_wf h v hv) (parse_uniqueKeys h v hv) hj hL hfit

end Haus
