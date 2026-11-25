---
"@haus-fmt/effect": minor
---

Every type of the prelude takes a codec, by its id (`Haus.prelude("Int")` for `prelude#Int`), not only `Decimal`: it applies to every value of the type, in packages' types too, and the declarations type each through `Haus.Lookup`.
