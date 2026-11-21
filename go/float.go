package haus

import (
	"math"

	"github.com/betalyra/haus-fmt/go/internal/floats"
)

// FormatFloat writes a float in the one spelling of spec §15 ("Floats"):
// the fewest decimal digits that read back to the same float of the type
// (bitSize 32 for Float32, 64 for Float64), the closest of those and of
// two equally close the one ending in an even digit, laid out as
// JavaScript's Number.prototype.toString does, with no + in the exponent:
// 0.1, 1e21, 1.5e-7, -0. NaN and the infinities are written as the tags
// that stand for them: NaN, Infinity, NegInfinity.
//
// For a Float32, f must be a float32 value converted to float64.
func FormatFloat(f float64, bitSize int) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "NegInfinity"
	}
	var buf [32]byte
	return string(floats.Append(buf[:0], f, bitSize))
}

// FloatValue returns the value an encoder writes for a Float64 (spec §15):
// a [Number] in its one spelling ([FormatFloat]), or the tag NaN, Infinity
// or NegInfinity.
func FloatValue(f float64) Value { return floatValue(f, 64) }

// Float32Value is [FloatValue] for a Float32.
func Float32Value(f float32) Value { return floatValue(float64(f), 32) }

func floatValue(f float64, bitSize int) Value {
	s := FormatFloat(f, bitSize)
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return Variant{Tag: Tag{name: s}}
	}
	return Number{lit: s}
}

// Float64 returns the number rounded to the nearest float64 (ties to even),
// directly from its exact decimal value, as a Float64 decodes it (spec §15).
// A number too large for a float64 gives an infinity and ok false; a number
// too small rounds to zero, keeping its sign.
func (n Number) Float64() (f float64, ok bool) {
	f = floats.Parse(n.String(), 64)
	return f, !math.IsInf(f, 0)
}
