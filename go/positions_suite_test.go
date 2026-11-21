package haus

import (
	"errors"
	"fmt"
	"testing"
)

// TestPositionsSuite runs positions/cases.haus (spec §8): each text, parsed
// whole (as a single document when the case says document: True), fails
// with the code at the line and column (1-based, columns in code points).
func TestPositionsSuite(t *testing.T) {
	vs, err := ParseAll(readSuite(t, "positions", "cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d cases", len(vs))
	if len(vs) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range vs {
		r, _ := v.(Record)
		text, _ := r.Get("text")
		code, _ := r.Get("code")
		line, _ := r.Get("line")
		column, _ := r.Get("column")
		s, okText := text.(String)
		c, okCode := code.(String)
		l, okLine := line.(Number)
		col, okCol := column.(Number)
		if !okText || !okCode || !okLine || !okCol {
			t.Fatalf("not a case: %v", v)
		}
		want := fmt.Sprintf("%s at %s:%s", c, l, col)
		var err error
		if doc, _ := r.Get("document"); Equals(doc, Variant{Tag: MustTag("True")}) {
			_, err = Parse([]byte(s)) // a single document
		} else {
			_, err = ParseAll([]byte(s))
		}
		var e *Error
		if !errors.As(err, &e) {
			t.Errorf("%q: got %v, want %s", string(s), err, want)
			continue
		}
		if got := fmt.Sprintf("%s at %d:%d", e.Code, e.Line, e.Column); got != want {
			t.Errorf("%q: got %s (%v), want %s", string(s), got, err, want)
		}
	}
}
