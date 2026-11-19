# Profile `@haus-fmt/money/iso`, version 1

The rule of this profile (spec §13.3, "Profiles"). The test vectors in
[`iso.vectors.haus`](iso.vectors.haus) are examples of it; where they disagree
with this text, the vectors are wrong.

The rule is stated on the values the schema decoded (spec §15).

## `Currency`

A codec implementing this profile accepts a `Currency` exactly when its tag
is three characters, each a capital letter `A`–`Z` (U+0041–U+005A), and it
has no payload.

That is the shape of an ISO 4217 code. Whether the code is assigned is not
checked: the list changes, and which currencies an application takes (a
shop's own list, `BTC`) is the application's choice, made with its own codec.

## `Money(amount, currency)`

A codec accepts a `Money` exactly when its `currency` is accepted as a
`Currency` (above). The amount is any `Decimal`: negative amounts, zero and
any scale are allowed.

## Encoding

A codec writes back exactly what it decoded: the amount as the `Decimal` it
was (its scale kept, `19.90` stays `19.90`, spec §15) and the currency tag.

A value that breaks the rule is a decoding error with the code
`type-mismatch`, at the value's place (spec §15). A codec checks the rule when
encoding too: a host value that breaks it is not written (`cannot-encode`).
