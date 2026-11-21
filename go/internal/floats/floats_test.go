package floats

import (
	"math"
	"math/big"
	"math/rand/v2"
	"strconv"
	"strings"
	"testing"
)

// exact is the exact decimal value of x: every binary float has one.
func exact(x *big.Float) string {
	s := x.Text('f', 1200)
	return strings.TrimRight(strings.TrimRight(s, "0"), ".")
}

// TestLongHalfway: literals with hundreds of digits, exactly halfway between
// two floats or a hair above, round as their exact value says (found by the
// differential fuzzer: strconv.ParseFloat rounds such literals of more than
// 800 digits wrongly near the subnormals).
func TestLongHalfway(t *testing.T) {
	for _, bits := range []uint64{1, 2, 3, 0xfffffffffffff, 0x10000000000000, 0x10000000000001, 0x123456789abcd, 0x7fefffffffffffe} {
		lo, hi := math.Float64frombits(bits), math.Float64frombits(bits+1)
		mid := new(big.Float).SetPrec(2000).Add(big.NewFloat(lo), big.NewFloat(hi))
		mid.Quo(mid, big.NewFloat(2))
		half := exact(mid)
		even := lo
		if bits%2 == 1 {
			even = hi
		}
		cases := map[string]float64{
			half:                                  even,
			half + strings.Repeat("0", 100) + "1": hi,
			"-" + half + strings.Repeat("0", 100) + "1": -hi,
		}
		for lit, want := range cases {
			if got := Parse(lit, 64); got != want {
				t.Errorf("%d digits near %g: got %g, want %g", len(lit), lo, got, want)
			}
		}
	}
}

func TestZerosAndInfinities(t *testing.T) {
	long := strings.Repeat("1", 900)
	cases := []struct {
		lit  string
		bits int
		want float64
	}{
		{long + "e-7000", 64, 0},
		{"-" + long + "e-7000", 64, math.Copysign(0, -1)},
		{long + "e6000", 64, math.Inf(1)},
		{"-" + long + "e100", 32, math.Inf(-1)},
		{"0." + long, 32, float64(float32(0.11111111))},
	}
	for _, c := range cases {
		got := Parse(c.lit, c.bits)
		if got != c.want || math.Signbit(got) != math.Signbit(c.want) {
			t.Errorf("%.20s… as float%d: got %g, want %g", c.lit, c.bits, got, c.want)
		}
	}
}

// spelling is the one spelling of spec §15 built from strconv's shortest
// digits with strings, as the binding wrote it before Append: what Append
// must write.
func spelling(f float64, bits int) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0"
		}
		return "0"
	}
	e := strconv.FormatFloat(f, 'e', -1, bits)
	neg := strings.HasPrefix(e, "-")
	mant, exp, _ := strings.Cut(strings.TrimPrefix(e, "-"), "e")
	digits := strings.Replace(mant, ".", "", 1)
	x, _ := strconv.Atoi(exp)
	k, n := len(digits), x+1
	s := ""
	switch {
	case k <= n && n <= 21:
		s = digits + strings.Repeat("0", n-k)
	case 0 < n && n <= 21:
		s = digits[:n] + "." + digits[n:]
	case -6 < n && n <= 0:
		s = "0." + strings.Repeat("0", -n) + digits
	default:
		s = digits[:1]
		if k > 1 {
			s += "." + digits[1:]
		}
		s += "e" + strconv.Itoa(n-1)
	}
	if neg {
		s = "-" + s
	}
	return s
}

func TestAppend(t *testing.T) {
	floats := []float64{0, math.Copysign(0, -1), 1, -1, 0.1, 1.5e-7, 1e-7, 1e-6, 123e-9, 1e20, 1e21, 1.5e21, 123456789012345678901,
		math.MaxFloat64, math.SmallestNonzeroFloat64, -math.MaxFloat64, 5e-324, 2.2250738585072014e-308, 100, 1234.5678, 0.000001234}
	rng := rand.New(rand.NewPCG(1, 2))
	for range 200_000 {
		floats = append(floats, math.Float64frombits(rng.Uint64()))
		floats = append(floats, float64(rng.IntN(2_000_000)-1_000_000)/math.Pow10(rng.IntN(30)))
	}
	for _, f := range floats {
		if math.IsNaN(f) || math.IsInf(f, 0) {
			continue
		}
		for _, bits := range []int{64, 32} {
			x := f
			if bits == 32 {
				x = float64(float32(f))
				if math.IsInf(x, 0) {
					continue
				}
			}
			if got, want := string(Append(nil, x, bits)), spelling(x, bits); got != want {
				t.Fatalf("%v as float%d: Append writes %s, want %s", x, bits, got, want)
			}
		}
	}
}
