package schema

import (
	"math"
	"strconv"
	"strings"
)

// formatFloat writes a float in the one spelling of spec §15: the fewest
// decimal digits that read back to the same float of the type (bits 32 or
// 64), the closest of those and of two equally close the even one, laid
// out as JavaScript's Number.prototype.toString does, with no + in the
// exponent. NaN and the infinities have no spelling; the caller writes
// them as tags.
func formatFloat(f float64, bits int) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0"
		}
		return "0"
	}
	// d.ddde±x: the shortest digits, correctly rounded.
	e := strconv.FormatFloat(f, 'e', -1, bits)
	neg := strings.HasPrefix(e, "-")
	e = strings.TrimPrefix(e, "-")
	mant, exp, _ := strings.Cut(e, "e")
	digits := strings.Replace(mant, ".", "", 1)
	x, _ := strconv.Atoi(exp)
	k, n := len(digits), x+1 // the value is 0.d1…dk × 10^n
	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	switch {
	case k <= n && n <= 21:
		b.WriteString(digits)
		b.WriteString(strings.Repeat("0", n-k))
	case 0 < n && n <= 21:
		b.WriteString(digits[:n])
		b.WriteByte('.')
		b.WriteString(digits[n:])
	case -6 < n && n <= 0:
		b.WriteString("0.")
		b.WriteString(strings.Repeat("0", -n))
		b.WriteString(digits)
	default:
		b.WriteByte(digits[0])
		if k > 1 {
			b.WriteByte('.')
			b.WriteString(digits[1:])
		}
		b.WriteByte('e')
		b.WriteString(strconv.Itoa(n - 1))
	}
	return b.String()
}
