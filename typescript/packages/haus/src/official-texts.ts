/**
 * The files of the official packages (packages.md §3), byte for byte those
 * of `extensions/<name>/` at the version this library ships. A test compares
 * them with the files (test/official.test.ts): after a release of an official
 * package, copy its `package.haus` and `schema.haus` here again.
 */

const lines = (...ls: readonly string[]): string => ls.join("\n") + "\n"

export const MONEY_MANIFEST = lines(
  "// The manifest of a schema package: its name and version are the identity of",
  "// its types in every language (@haus-fmt/money@1#Money). `rules` gives a type",
  "// its package rule, defined in rules/<name>.md (packages.md §4, §6); Money is",
  "// covered through its Currency.",
  `{ name: "@haus-fmt/money", version: "1.0.1", rules: { "Currency": "iso" } }`,
)

export const MONEY_SCHEMA = lines(
  "// @haus-fmt/money: exact amounts with a currency.",
  "//",
  "//   import @haus-fmt/money (Money, Currency)",
  "//",
  "// An official extension: an ordinary schema, maintained with haus. It fixes",
  "// the shape only. Which currencies an application accepts (ISO 4217 codes, a",
  "// shop's own list, BTC) is its own choice, made with a codec; the iso",
  "// profile (profiles/iso.md) is the recommended one.",
  "",
  "// An exact amount: Money(19.99, EUR). The scale is kept (19.90 is not 19.9).",
  "type Money = closed < Money Decimal Currency >",
  "",
  "// A currency, written as a bare tag: EUR, USD, BTC.",
  "type Currency = < >",
)

export const GEO_MANIFEST = lines(`{ name: "@haus-fmt/geo", version: "1.0.1", rules: { "LatLng": "wgs84", "BBox": "wgs84" } }`)

export const GEO_SCHEMA = lines(
  "// @haus-fmt/geo: points and boxes on the earth.",
  "//",
  "//   import @haus-fmt/geo (LatLng, BBox)",
  "//",
  "// Degrees in WGS 84, latitude first. The schema fixes the shape; the ranges",
  "// are the wgs84 profile (profiles/wgs84.md), checked by codecs.",
  "",
  "// A point: LatLng(38.7223, -9.1393) is Lisbon.",
  "type LatLng = closed < LatLng Float64 Float64 >",
  "",
  "// A box from its south-west to its north-east corner.",
  "type BBox = closed < BBox LatLng LatLng >",
)

export const UUID_MANIFEST = lines(
  "// The manifest of a schema package: its name and version are the identity of",
  "// its types in every language (@haus-fmt/uuid@1#Uuid). `rules` gives a type",
  "// its package rule, defined in rules/<name>.md (packages.md §4, §6).",
  `{ name: "@haus-fmt/uuid", version: "1.0.1", rules: { "Uuid": "rfc9562" } }`,
)

export const UUID_SCHEMA = lines(
  "// @haus-fmt/uuid: universally unique identifiers.",
  "//",
  "//   import @haus-fmt/uuid (Uuid)",
  "//",
  "// An official extension: an ordinary schema, maintained with haus. It fixes",
  "// the shape only; the text form of RFC 9562, in lowercase, is the rfc9562",
  "// profile (profiles/rfc9562.md), checked by codecs. Every version is the same",
  "// type: a schema that wants version 7 only says so in a comment, and the",
  "// application checks it.",
  "",
  `// A UUID: Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57").`,
  "type Uuid = closed < Uuid String >",
)
