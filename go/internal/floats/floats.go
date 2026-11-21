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

// Append appends a finite float in the one spelling of spec §15 (bits 32 or
// 64): the shortest digits that read back to the same float, laid out as
// JavaScript's Number.prototype.toString does, with no + in the exponent
// (0.1, 1e21, 1.5e-7, -0). It allocates nothing when dst has room.
func Append(dst []byte, f float64, bits int) []byte {
	if f == 0 {
		if math.Signbit(f) {
			return append(dst, "-0"...)
		}
		return append(dst, '0')
	}
	// d.ddde±x: the shortest digits, correctly rounded.
	var buf [32]byte
	e := strconv.AppendFloat(buf[:0], f, 'e', -1, bits)
	if e[0] == '-' {
		dst = append(dst, '-')
		e = e[1:]
	}
	at := 1
	for e[at] != 'e' {
		at++
	}
	mant, exp := e[:at], e[at+1:]
	var digits [24]byte
	k := copy(digits[:], mant[:1])
	if len(mant) > 1 {
		k += copy(digits[k:], mant[2:]) // without the point
	}
	x := 0
	for _, c := range exp[1:] {
		x = 10*x + int(c-'0')
	}
	if exp[0] == '-' {
		x = -x
	}
	d, n := digits[:k], x+1 // the value is 0.d1…dk × 10^n
	switch {
	case k <= n && n <= 21:
		dst = append(dst, d...)
		for range n - k {
			dst = append(dst, '0')
		}
	case 0 < n && n <= 21:
		dst = append(dst, d[:n]...)
		dst = append(dst, '.')
		dst = append(dst, d[n:]...)
	case -6 < n && n <= 0:
		dst = append(dst, "0."...)
		for range -n {
			dst = append(dst, '0')
		}
		dst = append(dst, d...)
	default:
		dst = append(dst, d[0])
		if k > 1 {
			dst = append(dst, '.')
			dst = append(dst, d[1:]...)
		}
		dst = append(dst, 'e')
		dst = strconv.AppendInt(dst, int64(n-1), 10)
	}
	return dst
}
