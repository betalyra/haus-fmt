package haus

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// The parser and the writers take time linear in the input (spec §7, §9.8):
// a duplicate-key check that scans a list, or hashes with a known seed,
// would make crafted records quadratic; so would copying a container at
// every level. Each case runs at n and at 4n; linear time grows about 4×,
// quadratic 16×, and the test asks for less than 8×. The best of a few
// runs of each counts, and a busy machine gets a few more tries.

// linearRuns is how many times each size runs (the fastest counts), and
// linearTries how many times a case is measured before it fails.
const (
	linearRuns  = 5
	linearTries = 4
)

// fastest returns the shortest time of linearRuns calls of f.
func fastest(f func()) time.Duration {
	best := time.Duration(1<<63 - 1)
	for range linearRuns {
		start := time.Now()
		f()
		best = min(best, time.Since(start))
	}
	return best
}

// assertLinear checks that work(4n) takes less than 8× work(n).
func assertLinear(t *testing.T, n int, work func(n int) func()) {
	t.Helper()
	small, large := work(n), work(4*n)
	var ratio float64
	for range linearTries {
		ratio = float64(fastest(large)) / float64(max(fastest(small), time.Microsecond))
		if ratio < 8 {
			return
		}
	}
	t.Errorf("4× the input took %.1f× the time", ratio)
}

// parsing returns a function that parses text, which must parse.
func parsing(t *testing.T, text string, limits Limits) func() {
	return func() {
		if _, err := ParseAllWith([]byte(text), limits); err != nil {
			t.Fatal(err)
		}
	}
}

// joined writes entry(0), …, entry(n-1) joined by ", " in open … closer.
func joined(n int, open, closer string, entry func(i int) string) string {
	var b strings.Builder
	b.WriteString(open)
	for i := range n {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(entry(i))
	}
	b.WriteString(closer)
	return b.String()
}

func TestParseIsLinear(t *testing.T) {
	if testing.Short() {
		t.Skip("timing")
	}
	deep := Limits{MaxDepth: MaxSupportedDepth}
	cases := []struct {
		name   string
		n      int
		text   func(n int) string
		limits Limits
	}{
		{"many keys", 20_000, func(n int) string {
			return joined(n, "{ ", " }", func(i int) string { return fmt.Sprintf("k%d: %d", i, i) })
		}, Limits{}},
		{"keys alike", 20_000, func(n int) string {
			// Long keys of one length that differ only at their end.
			prefix := strings.Repeat("a", 40)
			return joined(n, "{ ", " }", func(i int) string { return fmt.Sprintf("%s%08d: 1", prefix, i) })
		}, Limits{}},
		{"many small records", 5_000, func(n int) string {
			return joined(n, "[", "]", func(i int) string { return fmt.Sprintf("{ a: %d, b: %q, c: None }", i, "x") })
		}, Limits{}},
		{"long string", 200_000, func(n int) string {
			return `"` + strings.Repeat(`abc\n\u{1F600}é`, n/10) + `"`
		}, Limits{}},
		{"deep nesting", 2_000, func(n int) string {
			return strings.Repeat("[", n) + strings.Repeat("]", n)
		}, deep},
		{"deep payloads", 2_000, func(n int) string {
			return strings.Repeat("Some(", n) + "1" + strings.Repeat(")", n)
		}, deep},
		{"many short values", 50_000, func(n int) string {
			return joined(n, "[", "]", func(i int) string { return fmt.Sprint(i % 10) })
		}, Limits{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertLinear(t, c.n, func(n int) func() { return parsing(t, c.text(n), c.limits) })
		})
	}
}

func TestWriteIsLinear(t *testing.T) {
	if testing.Short() {
		t.Skip("timing")
	}
	deep := Limits{MaxDepth: MaxSupportedDepth}
	record := func(n int) Value {
		fields := make([]Field, n)
		for i := range fields {
			fields[i] = Field{Key: fmt.Sprintf("key %d", i), Value: String("a\tb")}
		}
		r, err := NewRecord(fields...)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	nested := func(n int) Value {
		var v Value = Array{}
		for range n {
			v = Variant{Tag: "Some", Args: []Value{Array{v}}}
		}
		return v
	}
	for _, layout := range []Layout{Pretty, Compact, Minimised} {
		opts := FormatOptions{Layout: layout}
		t.Run(layout.String()+"/many keys", func(t *testing.T) {
			assertLinear(t, 10_000, func(n int) func() {
				v := record(n)
				return func() { mustFormat(t, v, opts) }
			})
		})
		if layout == Pretty {
			continue // its indentation makes the text of deep nesting quadratic
		}
		t.Run(layout.String()+"/deep nesting", func(t *testing.T) {
			assertLinear(t, 1_000, func(n int) func() {
				v := nested(n)
				return func() { mustFormat(t, v, FormatOptions{Layout: layout, Limits: deep}) }
			})
		})
	}
}

func mustFormat(t *testing.T, v Value, opts FormatOptions) {
	if _, err := FormatValue(v, opts); err != nil {
		t.Fatal(err)
	}
}
