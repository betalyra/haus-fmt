package floats

import (
	"math"
	"math/big"
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
