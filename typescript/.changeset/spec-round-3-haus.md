---
"@haus-fmt/haus": minor
---

Checking data with a schema: `checkText` checks a data file's text and gives each issue a `code` and a `path`. A `Stream` is checked item by item, so a syntax error comes after the errors of the items before it; each missing field is an error of its own; the check stops after 200 errors (hints don't count) and says so (`stopped`).
A tag that breaks the tag rule is `invalid-tag`, also when it holds a lone surrogate (it was `cannot-encode`).
Codecs apply to every named type: the prelude's and std/time's too (`prelude#Decimal`, `std/time#Instant`), wherever the type occurs, in packages' types too. A codec whose id no type has never runs: `compiled.warnings` lists `unused-codec` for it.
