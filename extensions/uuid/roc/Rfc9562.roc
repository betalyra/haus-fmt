## The profile @haus-fmt/uuid/rfc9562 (../profiles/rfc9562.md) as a codec
## (spec §13.4) for `@haus-fmt/uuid@1#Uuid`: `Uuid("0190c7a8-…")` ↔
## `"0190c7a8-…"`. A Uuid is accepted exactly when its text is 32 digits
## 0–9, a–f in groups 8-4-4-4-12, joined by hyphens, lowercase only, of any
## version. The text is the UUID's one spelling, so the value is kept.
import HausFmtUuid

Rfc9562 := [].{

	## The UUID's text: `0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57`.
	Target : Str

	decode : HausFmtUuid.Uuid -> Try(Target, Str)
	decode = |uuid| match uuid {
		Uuid(text) if is_text(text) => Ok(text)
		Uuid(_) => Err("not a UUID of the rfc9562 profile: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens")
	}

	encode : Target -> HausFmtUuid.Uuid
	encode = |text| Uuid(text)

	## Whether `text` is 36 bytes: hyphens at 8, 13, 18 and 23, and 0–9, a–f everywhere else.
	is_text : Str -> Bool
	is_text = |text| {
		bytes = text.to_utf8()
		var $ok = bytes.len() == 36
		var $i = 0
		while $ok and $i < 36 {
			b = match bytes.get($i) {
				Ok(x) => x
				Err(_) => 0
			}
			$ok = if $i == 8 or $i == 13 or $i == 18 or $i == 23 {
				b == '-'
			} else {
				(b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')
			}
			$i = $i + 1
		}
		$ok
	}
}
