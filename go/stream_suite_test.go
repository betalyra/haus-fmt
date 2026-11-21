package haus

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
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
	c := streamCase{text: string(s), max: limitValue, strict: Equals(strict, Variant{Tag: "True"})}
	switch arg := res.Args[0].(type) {
	case Array:
		if res.Tag == "Ok" {
			c.values = arg
			return c
		}
	case String:
		if res.Tag == "Err" {
			c.code = string(arg)
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

// readCase reads the pieces as one stream: the values, or the error's code.
func readCase(c streamCase, pieces []string) (values []Value, code string) {
	src := chunks(append([]string(nil), pieces...))
	r := NewStreamReader(&src, StreamOptions{Limits: Limits{MaxValueLength: c.max}, Strict: c.strict})
	for v, err := range r.All() {
		if err != nil {
			var e *Error
			if errors.As(err, &e) {
				return nil, string(e.Code)
			}
			return nil, err.Error()
		}
		values = append(values, v)
	}
	return values, ""
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

// TestStreamSuite runs the stream suite (spec §6, §7). HAUS_STREAM_SUITE
// names another directory holding the suite's file.
func TestStreamSuite(t *testing.T) {
	dir := os.Getenv("HAUS_STREAM_SUITE")
	if dir == "" {
		dir = filepath.Join(suite, "stream")
	}
	src, err := os.ReadFile(filepath.Join(dir, "limits.cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	vs, err := ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	if len(vs) != 21 {
		t.Errorf("%d cases, want 21", len(vs))
	}
	for _, v := range vs {
		c := toStreamCase(t, v)
		name := fmt.Sprintf("%q max %d strict %v", c.text, c.max, c.strict)
		for how, pieces := range streamSplits(c.text) {
			values, code := readCase(c, pieces)
			same := code == c.code && len(values) == len(c.values)
			for i := 0; same && i < len(values); i++ {
				same = Equals(values[i], c.values[i])
			}
			if !same {
				t.Errorf("%s, %s: %v %q", name, how, values, code)
			}
		}
	}
}
