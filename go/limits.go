package haus

import (
	"fmt"
	"math"
)

// MaxSupportedDepth is the deepest nesting this binding supports (spec §7).
// The parser, the formatter and the canonical form recurse once per level of
// nesting; Go stacks grow on demand, so this is far above the default of 256,
// but bounded so that a configured limit can't make hostile input use
// unbounded stack. A larger [Limits.MaxDepth] is rejected with the code
// unsupported-depth.
const MaxSupportedDepth = 10000

// Limits are the resource limits of spec §7, enforced while parsing. A field
// that is zero (or negative) takes its default, so Limits{MaxDepth: 64} only
// lowers the depth limit. [DefaultLimits] returns the defaults.
type Limits struct {
	// MaxDepth is the deepest nesting of records, arrays and payloads, counted
	// on the text as written (spec §7). Default 256; at most
	// [MaxSupportedDepth].
	MaxDepth int
	// MaxNumberLength is the most characters in one number literal, sign,
	// separators and exponent included. Default 1000. It also limits hex
	// literals to the most hex digits whose value fits the limit in decimal
	// (829 for 1000, see [Limits.MaxHexDigits]).
	MaxNumberLength int
	// MaxExponent is the largest absolute exponent of a number. Default 6144.
	MaxExponent int
	// MaxStringLength is the most characters (code points) in one string,
	// record key or tag, or between the quotes of a byte string.
	// Default 16 Mi.
	MaxStringLength int
	// MaxValueLength is the most characters in one top-level value of a
	// stream, counted from the previous top-level comma (or the start, after a
	// byte order mark) up to the next one. Default 64 Mi. Only a
	// [StreamReader] applies it, as it bounds the reader's memory; [ParseAll]
	// and the other functions given the whole text don't (spec §7).
	MaxValueLength int
}

// The default limits of spec §7.
const (
	DefaultMaxDepth        = 256
	DefaultMaxNumberLength = 1000
	DefaultMaxExponent     = 6144
	DefaultMaxStringLength = 16 << 20
	DefaultMaxValueLength  = 64 << 20
)

// DefaultLimits returns the default limits of spec §7.
func DefaultLimits() Limits {
	return Limits{
		MaxDepth:        DefaultMaxDepth,
		MaxNumberLength: DefaultMaxNumberLength,
		MaxExponent:     DefaultMaxExponent,
		MaxStringLength: DefaultMaxStringLength,
		MaxValueLength:  DefaultMaxValueLength,
	}
}

// resolve fills in the defaults and checks the depth limit.
func (l Limits) resolve() (Limits, error) {
	d := DefaultLimits()
	pick := func(v, def int) int {
		if v <= 0 {
			return def
		}
		return v
	}
	r := Limits{
		MaxDepth:        pick(l.MaxDepth, d.MaxDepth),
		MaxNumberLength: pick(l.MaxNumberLength, d.MaxNumberLength),
		MaxExponent:     pick(l.MaxExponent, d.MaxExponent),
		MaxStringLength: pick(l.MaxStringLength, d.MaxStringLength),
		MaxValueLength:  pick(l.MaxValueLength, d.MaxValueLength),
	}
	if r.MaxDepth > MaxSupportedDepth {
		return r, newError(CodeUnsupportedDepth,
			fmt.Sprintf("MaxDepth %d is more than the supported maximum, %d", r.MaxDepth, MaxSupportedDepth))
	}
	return r, nil
}

// MaxHexDigits returns the most hex digits (leading zeros counted, _ not) in
// one hex literal: the largest h with 16^h ≤ 10^(n−1) for the number limit n,
// so that every integer's decimal form, sign included, fits in n characters
// (spec §7). 829 for the default 1000.
func (l Limits) MaxHexDigits() int {
	n := l.MaxNumberLength
	if n <= 0 {
		n = DefaultMaxNumberLength
	}
	return maxHexDigits(n)
}

func maxHexDigits(n int) int {
	if n <= 1 {
		return 0
	}
	// h = floor((n-1) / log10(16)), corrected for rounding at the boundary.
	h := int(float64(n-1) / math.Log10(16))
	for h > 0 && float64(h)*math.Log10(16) > float64(n-1)+1e-9 {
		h--
	}
	for float64(h+1)*math.Log10(16) <= float64(n-1)-1e-9 {
		h++
	}
	return h
}
