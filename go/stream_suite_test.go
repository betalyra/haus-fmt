package haus

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// streamCase is a case of the stream suite (test-suite/README.md, "Stream
// suite"): the text, the reader's value limit and strict mode, and the
// values read or the code of the error.
type streamCase struct {
	text   string
	max    int
	strict bool
	values []Value
	code   string
	// line and column are the error's place, when the case gives it (1-based); 0 otherwise.
	line, column int
	// whole is the values of parsing the text whole (ParseAll, default
	// limits), when the case gives them; nil otherwise.
	whole []Value
}

func toStreamCase(t *testing.T, v Value) streamCase {
	t.Helper()
	r, _ := v.(Record)
	text, _ := r.Get("text")
	limit, _ := r.Get("maxValueLength")
	strict, _ := r.Get("strict")
	result, _ := r.Get("result")
	s, okText := text.(String)
	n, okMax := limit.(Number)
	res, okResult := result.(Variant)
	limitValue, err := strconv.Atoi(n.String())
	if !okText || !okMax || !okResult || err != nil || len(res.Args) != 1 {
		t.Fatalf("not a case: %v", v)
	}
	c := streamCase{text: string(s), max: limitValue, strict: Equals(strict, Variant{Tag: MustTag("True")})}
	if whole, ok := r.Get("whole"); ok {
		w, okWhole := whole.(Variant)
		if !okWhole || w.Tag.String() != "Ok" || len(w.Args) != 1 {
			t.Fatalf("not a whole result: %v", whole)
		}
		c.whole, okWhole = w.Args[0].(Array)
		if !okWhole {
			t.Fatalf("not a whole result: %v", whole)
		}
	}
	switch arg := res.Args[0].(type) {
	case Array:
		if res.Tag.String() == "Ok" {
			c.values = arg
			return c
		}
	case String:
		if res.Tag.String() == "Err" {
			c.code = string(arg)
			c.line, c.column = placeOf(t, r)
			return c
		}
	}
	t.Fatalf("not a result: %v", result)
	return c
}

// chunks reads its pieces one per call.
type chunks []string

func (c *chunks) Read(p []byte) (int, error) {
	for len(*c) > 0 && (*c)[0] == "" {
		*c = (*c)[1:]
	}
	if len(*c) == 0 {
		return 0, io.EOF
	}
	n := copy(p, (*c)[0])
	(*c)[0] = (*c)[0][n:]
	return n, nil
}

// placeOf reads a case's optional line and column (both or neither).
func placeOf(t *testing.T, r Record) (line, column int) {
	t.Helper()
	l, okLine := r.Get("line")
	c, okColumn := r.Get("column")
	if okLine != okColumn {
		t.Fatalf("a case with only one of line and column: %v", r)
	}
	if !okLine {
		return 0, 0
	}
	ln, okL := l.(Number)
	cn, okC := c.(Number)
	line, errL := strconv.Atoi(ln.String())
	column, errC := strconv.Atoi(cn.String())
	if !okL || !okC || errL != nil || errC != nil {
		t.Fatalf("not a place: %v", r)
	}
	return line, column
}

// readCase reads the pieces as one stream: the values, or the error's code
// and place.
func readCase(c streamCase, pieces []string) (values []Value, code string, line, column int) {
	src := chunks(append([]string(nil), pieces...))
	r := NewStreamReader(&src, StreamOptions{Limits: Limits{MaxValueLength: c.max}, Strict: c.strict})
	for v, err := range r.All() {
		if err != nil {
			var e *Error
			if errors.As(err, &e) {
				return nil, string(e.Code), e.Line, e.Column
			}
			return nil, err.Error(), 0, 0
		}
		values = append(values, v)
	}
	return values, "", 0, 0
}

// streamSplits gives the text whole, one character at a time, and in two pieces split at every character.
func streamSplits(text string) map[string][]string {
	out := map[string][]string{"whole": {text}}
	var chars []string
	for i, ch := range text {
		chars = append(chars, string(ch))
		out[fmt.Sprintf("split at byte %d", i)] = []string{text[:i], text[i:]}
	}
	out["by character"] = chars
	return out
}

// readStreamSuite reads the cases of a file of the stream suite, from
// HAUS_STREAM_SUITE when set.
func readStreamSuite(t *testing.T, name string) []Value {
	t.Helper()
	dir := os.Getenv("HAUS_STREAM_SUITE")
	if dir == "" {
		dir = filepath.Join(suite, "stream")
	}
	src, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	vs, err := ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	return vs
}

// TestStreamSuite runs the stream suite (spec §6, §7). HAUS_STREAM_SUITE
// names another directory holding the suite's file.
func TestStreamSuite(t *testing.T) {
	vs := readStreamSuite(t, "limits.cases.haus")
	if len(vs) != 32 {
		t.Errorf("%d cases, want 32", len(vs))
	}
	places := 0
	for _, v := range vs {
		c := toStreamCase(t, v)
		name := fmt.Sprintf("%q max %d strict %v", c.text, c.max, c.strict)
		for how, pieces := range streamSplits(c.text) {
			values, code, line, column := readCase(c, pieces)
			same := code == c.code && len(values) == len(c.values) &&
				(c.line == 0 || line == c.line && column == c.column)
			for i := 0; same && i < len(values); i++ {
				same = Equals(values[i], c.values[i])
			}
			if !same {
				t.Errorf("%s, %s: %v %q at %d:%d", name, how, values, code, line, column)
			}
		}
		if c.line > 0 {
			places++
		}
	}
	t.Logf("%d cases with a place", places)
	if places == 0 {
		t.Error("no cases with a place")
	}
}

// sameValueList reports whether two lists hold equal values (spec §2).
func sameValueList(a, b []Value) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !Equals(a[i], b[i]) {
			return false
		}
	}
	return true
}

func canonicalList(t *testing.T, vs []Value) string {
	t.Helper()
	parts := make([]string, len(vs))
	for i, v := range vs {
		parts[i] = mustCanonical(t, v)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// TestStreamSuiteWhole parses the cases with `whole` as one text: the value
// limit applies to stream readers only (spec §7).
func TestStreamSuiteWhole(t *testing.T) {
	vs := readStreamSuite(t, "limits.cases.haus")
	n := 0
	for _, v := range vs {
		c := toStreamCase(t, v)
		if c.whole == nil {
			continue
		}
		n++
		got, err := ParseAll([]byte(c.text))
		if err != nil {
			t.Errorf("%q: %v, want %s", c.text, err, canonicalList(t, c.whole))
		} else if !sameValueList(got, c.whole) {
			t.Errorf("%q: got %s, want %s", c.text, canonicalList(t, got), canonicalList(t, c.whole))
		}
	}
	t.Logf("%d cases with whole", n)
	if n == 0 {
		t.Error("no cases with whole")
	}
}

// TestDocumentSuite runs stream/document.cases.haus: a single document
// (spec §6), read with Parse.
func TestDocumentSuite(t *testing.T) {
	vs := readStreamSuite(t, "document.cases.haus")
	t.Logf("%d cases", len(vs))
	if len(vs) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range vs {
		r, _ := v.(Record)
		text, _ := r.Get("text")
		result, _ := r.Get("result")
		s, okText := text.(String)
		res, okResult := result.(Variant)
		if !okText || !okResult || len(res.Args) != 1 {
			t.Fatalf("not a case: %v", v)
		}
		var want string
		if code, ok := res.Args[0].(String); res.Tag.String() == "Err" && ok {
			want = "Err " + string(code)
		} else if res.Tag.String() == "Ok" {
			want = "Ok " + mustCanonical(t, res.Args[0])
		} else {
			t.Fatalf("not a result: %v", result)
		}
		doc, err := Parse([]byte(s))
		got := "Err " + string(errorCode(err))
		if err == nil {
			got = "Ok " + mustCanonical(t, doc)
		}
		if got != want {
			t.Errorf("%q: got %s (%v), want %s", string(s), got, err, want)
		}
	}
}
