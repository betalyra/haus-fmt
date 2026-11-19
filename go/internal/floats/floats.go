// Package floats rounds a number literal to the nearest float32 or float64,
// ties to even, directly from its exact decimal value (spec §15, "Numbers").
package floats

import (
	"math"
	"math/big"
	"strconv"
	"strings"
)

// maxFast is the most significant digits strconv.ParseFloat is given. It
// keeps at most 800 digits of a long mantissa, and past them it rounds
// wrongly (a halfway value with 810 digits near the smallest normal float64
// comes out a hundred million times too small), so longer literals are
// rounded exactly as a big.Rat.
const maxFast = 760

// Parse rounds a normalized number literal (spec §2: digits, an optional
// `-`, `.` and exponent `e`) to a float of bits 32 or 64. A number too large
// for the type gives an infinity of its sign; one too small, a zero of its
// sign.
func Parse(lit string, bits int) float64 {
	if significant(lit) <= maxFast {
		f, _ := strconv.ParseFloat(lit, bits)
		return f
	}
	r, ok := new(big.Rat).SetString(lit)
	if !ok {
		f, _ := strconv.ParseFloat(lit, bits)
		return f
	}
	var f float64
	if bits == 32 {
		g, _ := r.Float32()
		f = float64(g)
	} else {
		f, _ = r.Float64()
	}
	if f == 0 && strings.HasPrefix(lit, "-") {
		return math.Copysign(0, -1) // a big.Rat has no negative zero
	}
	return f
}

// significant is the number of mantissa digits from the first nonzero one.
func significant(lit string) int {
	m, _, _ := strings.Cut(lit, "e")
	m = strings.TrimLeft(strings.TrimPrefix(m, "-"), "0.")
	return len(m) - strings.Count(m, ".")
}
