package haus

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
	"testing/iotest"
)

// readStream reads all values of src with a StreamReader over r(src).
func readStream(src []byte, opts StreamOptions, r func(io.Reader) io.Reader) ([]Value, error) {
	var vs []Value
	for v, err := range NewStreamReader(r(bytes.NewReader(src)), opts).All() {
		if err != nil {
			return vs, err
		}
		vs = append(vs, v)
	}
	return vs, nil
}

var readers = map[string]func(io.Reader) io.Reader{
	"whole":    func(r io.Reader) io.Reader { return r },
	"one byte": iotest.OneByteReader,
}

func TestStreamValidSuite(t *testing.T) {
	for _, name := range suiteFiles(t, "valid", ".haus") {
		src := readSuite(t, "valid", name+".haus")
		want, err := ParseAll(src)
		if err != nil {
			t.Fatal(err)
		}
		for rn, r := range readers {
			got, err := readStream(src, StreamOptions{}, r)
			if err != nil {
				t.Errorf("%s (%s): %v", name, rn, err)
				continue
			}
			if !Equals(Array(got), Array(want)) {
				t.Errorf("%s (%s): got %d values, want %d", name, rn, len(got), len(want))
			}
		}
	}
}

// TestStreamInvalidSuite: a stream reader rejects each invalid file with
// the same code, at the same place, as when the whole input is parsed.
func TestStreamInvalidSuite(t *testing.T) {
	for _, name := range suiteFiles(t, "invalid", ".haus") {
		src := readSuite(t, "invalid", name+".haus")
		_, whole := ParseAll(src)
		for rn, r := range readers {
			_, err := readStream(src, StreamOptions{}, r)
			var e, w *Error
			if !errors.As(err, &e) || !errors.As(whole, &w) {
				t.Errorf("%s (%s): got %v, want %v", name, rn, err, whole)
				continue
			}
			if e.Code != w.Code || e.Line != w.Line || e.Column != w.Column {
				t.Errorf("%s (%s): got %v, want %v", name, rn, e, w)
			}
		}
	}
}

func TestStreamStrict(t *testing.T) {
	cases := []struct {
		src  string
		n    int
		code ErrorCode
	}{
		{"", 0, ""},
		{"// only a comment\n", 0, ""},
		{"1,", 1, ""},
		{"1, 2,\n// after the last\n", 2, ""},
		{"1, 2", 1, CodeStreamTruncated},
		{"1, 2 // no comma\n", 1, CodeStreamTruncated},
		{"{ a: 1 }", 0, CodeStreamTruncated},
	}
	for _, c := range cases {
		vs, err := readStream([]byte(c.src), StreamOptions{Strict: true}, readers["whole"])
		var e *Error
		switch {
		case c.code == "" && err != nil:
			t.Errorf("%q: %v", c.src, err)
		case c.code != "" && (!errors.As(err, &e) || e.Code != c.code):
			t.Errorf("%q: got %v, want %s", c.src, err, c.code)
		case len(vs) != c.n:
			t.Errorf("%q: got %d values, want %d", c.src, len(vs), c.n)
		}
	}
	// Without strict mode, the last value needs no comma.
	vs, err := readStream([]byte("1, 2"), StreamOptions{}, readers["whole"])
	if err != nil || len(vs) != 2 {
		t.Errorf("1, 2: %v %v", vs, err)
	}
}

func TestStreamValueLength(t *testing.T) {
	lim := Limits{MaxValueLength: 10}
	ok := "1234567890,  12345678," // the second value is 10 characters with its spaces
	if _, err := readStream([]byte(ok), StreamOptions{Limits: lim}, readers["one byte"]); err != nil {
		t.Errorf("%q: %v", ok, err)
	}
	if _, err := ParseAllWith([]byte(ok), lim); err != nil {
		t.Errorf("%q: %v", ok, err)
	}
	// Characters, not bytes: ten é are ten characters.
	text := `"` + strings.Repeat("é", 8) + `",`
	if _, err := readStream([]byte(text), StreamOptions{Limits: lim}, readers["one byte"]); err != nil {
		t.Errorf("%q: %v", text, err)
	}
	for _, bad := range []string{"1, 12345678901,", "1, [1,2,3,4,5]", "1, /* a long comment */ 2"} {
		_, err := readStream([]byte(bad), StreamOptions{Limits: lim}, readers["one byte"])
		var e *Error
		if !errors.As(err, &e) || e.Code != CodeValueTooLong {
			t.Errorf("%q: got %v, want value-too-long", bad, err)
		}
		// The whole text is already in memory: the limit is the stream
		// reader's alone (spec §7).
		if _, err := ParseAllWith([]byte(bad), lim); err != nil {
			t.Errorf("%q (whole): %v, want no error", bad, err)
		}
	}
}

func TestStreamHash(t *testing.T) {
	src := []byte("1, \"a\", Order { id: 0xFF },")
	h := NewHasher()
	for v, err := range ParseStream(bytes.NewReader(src)) {
		if err != nil {
			t.Fatal(err)
		}
		if err := h.Add(v); err != nil {
			t.Fatal(err)
		}
	}
	vs, _ := ParseAll([]byte(`1,"a",Order{id:255}`))
	want, _ := HashAll(vs)
	if h.Sum() != want || h.Count() != 3 {
		t.Errorf("got %s, want %s", h.Sum(), want)
	}
}

// TestStreamErrorSticky: after an error, Next keeps returning it.
func TestStreamErrorSticky(t *testing.T) {
	r := NewStreamReader(strings.NewReader("1, ]"), StreamOptions{})
	if _, err := r.Next(); err != nil {
		t.Fatal(err)
	}
	_, err1 := r.Next()
	_, err2 := r.Next()
	if err1 == nil || err1 != err2 {
		t.Errorf("%v, %v", err1, err2)
	}
	if _, err := NewStreamReader(strings.NewReader("1"), StreamOptions{Limits: Limits{MaxDepth: MaxSupportedDepth + 1}}).Next(); err == nil {
		t.Error("an unsupported depth is accepted")
	}
}
