package haus

import (
	"testing"
)

// TestEqualitySuite runs equality/cases.haus (spec §2, §12): Equals and
// the sign of Compare, in both directions.
func TestEqualitySuite(t *testing.T) {
	vs, err := ParseAll(readSuite(t, "equality", "cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d cases", len(vs))
	if len(vs) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range vs {
		r, _ := v.(Record)
		a, okA := r.Get("a")
		b, okB := r.Get("b")
		equal, _ := r.Get("equal")
		order, _ := r.Get("order")
		eq, okEqual := equal.(Variant)
		o, okOrder := order.(Number)
		if !okA || !okB || !okEqual || !okOrder {
			t.Fatalf("not a case: %v", v)
		}
		wantEqual := eq.Tag == "True"
		n, _ := o.BigInt()
		wantOrder := int(n.Int64())
		name := mustCanonical(t, a) + " and " + mustCanonical(t, b)
		if got := Equals(a, b); got != wantEqual {
			t.Errorf("%s: Equals(a, b) = %v, want %v", name, got, wantEqual)
		}
		if got := Equals(b, a); got != wantEqual {
			t.Errorf("%s: Equals(b, a) = %v, want %v", name, got, wantEqual)
		}
		if got := sign(Compare(a, b)); got != wantOrder {
			t.Errorf("%s: Compare(a, b) = %d, want %d", name, got, wantOrder)
		}
		if got := sign(Compare(b, a)); got != -wantOrder {
			t.Errorf("%s: Compare(b, a) = %d, want %d", name, got, -wantOrder)
		}
	}
}

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	}
	return 0
}
