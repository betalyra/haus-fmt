package schema_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// Decoding, encoding, Type.Parse and Type.Format take time linear in the
// input (spec §9.8), also where they fail and Type.Format starts again in
// two passes. Each case runs at n and at 4n; linear time grows about 4×,
// quadratic 16×, and the test asks for less than 8×, the best of a few runs
// counting (as in package haus).

const (
	linearRuns  = 5
	linearTries = 4
	// minRun is the shortest time one measured run lasts.
	minRun = 20 * time.Millisecond
)

func fastest(f func()) time.Duration {
	best := time.Duration(1<<63 - 1)
	for range linearRuns {
		// Repeat the call until the run lasts at least minRun: a clock that
		// ticks coarsely (Windows: every 0.5–15.6 ms) would measure a fast call
		// as 0 and make any ratio huge.
		calls, start := 0, time.Now()
		for calls == 0 || time.Since(start) < minRun {
			f()
			calls++
		}
		best = min(best, time.Since(start)/time.Duration(calls))
	}
	return best
}

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

// linearSchema has a record of many fields (looked up by a map), records in
// an array, a recursive variant for deep nesting, and an Any.
func linearSchema(t *testing.T) *schema.Schema {
	t.Helper()
	var fields []string
	for i := range 40 {
		fields = append(fields, fmt.Sprintf("f%d?: Int", i))
	}
	src := "type Big = { " + strings.Join(fields, ", ") + " }\n" +
		"type Item = { id: Int64, name: String, tags: Array String, on: Bool, x: Float64, kind: < A | B | C >, note?: Maybe String }\n" +
		"type Items = Array Item\n" +
		"type Open = Map Big\n" +
		"type Deep = < Leaf | Node Deep >\n" +
		"type Raw = { any: Any }\n"
	s, err := schema.Parse([]byte(src), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

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

func TestTypedIsLinear(t *testing.T) {
	if testing.Short() {
		t.Skip("timing")
	}
	s := linearSchema(t)
	deep := haus.Limits{MaxDepth: haus.MaxSupportedDepth}
	cases := []struct {
		name, typ string
		n         int
		text      func(n int) string
		limits    haus.Limits
		fails     bool // the text is read, but doesn't decode
	}{
		{"many items", "Items", 2_000, func(n int) string {
			return joined(n, "[", "]", func(i int) string {
				return fmt.Sprintf(`{ id: %d, name: "n%d", tags: ["a", "b"], on: True, x: 1.5, kind: B, note: Some("x"), extra: [1, 2] }`, i, i)
			})
		}, haus.Limits{}, false},
		{"many keys", "Open", 500, func(n int) string {
			return joined(n, "{ ", " }", func(i int) string {
				return fmt.Sprintf("k%d: { f%d: %d, unknown%d: 1, f%d: 2 }", i, i%40, i, i, (i+1)%40)
			})
		}, haus.Limits{}, false},
		// 500 and 2000 levels: at 8000 levels the recursion's stack outgrows the
		// CPU caches of CI runners, which made a linear Format look 9× slower.
		{"deep", "Deep", 500, func(n int) string {
			return strings.Repeat("Node(", n) + "Leaf" + strings.Repeat(")", n)
		}, deep, false},
		{"large any", "Raw", 20_000, func(n int) string {
			return "{ any: " + joined(n, "[", "]", func(i int) string { return fmt.Sprintf(`{ k: "v%d" }`, i) }) + " }"
		}, haus.Limits{}, false},
		{"failing at the end", "Items", 2_000, func(n int) string {
			return joined(n, "[", "]", func(i int) string {
				if i == n-1 {
					return `{ id: 1, name: 2, tags: [], on: True, x: 1, kind: A }`
				}
				return fmt.Sprintf(`{ id: %d, name: "n", tags: [], on: False, x: 0.1, kind: A }`, i)
			})
		}, haus.Limits{}, true},
	}
	for _, c := range cases {
		ty, err := s.Type(c.typ)
		if err != nil {
			t.Fatal(err)
		}
		opts := schema.DecodeOptions{Limits: c.limits}
		check := func(t *testing.T, err error) {
			if (err != nil) != c.fails {
				t.Fatalf("error: %v", err)
			}
		}
		t.Run(c.name+"/Parse", func(t *testing.T) {
			assertLinear(t, c.n, func(n int) func() {
				text := []byte(c.text(n))
				return func() {
					_, err := ty.ParseWith(text, opts)
					check(t, err)
				}
			})
		})
		for _, layout := range []haus.Layout{haus.Minimised, haus.Compact} {
			t.Run(c.name+"/Format "+layout.String(), func(t *testing.T) {
				assertLinear(t, c.n, func(n int) func() {
					v, err := haus.ParseWith([]byte(c.text(n)), c.limits)
					if err != nil {
						t.Fatal(err)
					}
					fopts := withLayout(layout)
					fopts.Limits = c.limits
					return func() {
						_, err := ty.Format(v, fopts)
						check(t, err)
					}
				})
			})
		}
	}
}
