import Haus.Json.WellFormed
import Haus.Json.PlainRoundTrip

/-!
# The JSON mappings, for every parsed value (spec §16)

The round trips of `Haus.Json.Lossless` and `Haus.Json.PlainRoundTrip` assume
a well-formed value; every value the reference parser returns is one
(`parse_wf`). So, for every value of every haus text:
-/

namespace Haus
open Schema

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

end Haus
