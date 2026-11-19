package haus

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// addJSONSeeds adds the JSON of the JSON suite and of valid/*.jsonl.
func addJSONSeeds(f *testing.F) {
	for _, name := range []string{"import.cases.haus", "self-describing.cases.haus", "schema-based.cases.haus"} {
		src, err := os.ReadFile(filepath.Join(suite, "json", name))
		if err != nil {
			continue
		}
		values, _ := ParseAll(src)
		for _, v := range values {
			if x, ok := v.(Variant); ok && len(x.Args) == 1 {
				if r, ok := x.Args[0].(Record); ok {
					if j, ok := r.Get("json"); ok {
						f.Add([]byte(j.(String)))
					}
				}
			}
		}
	}
	paths, _ := filepath.Glob(filepath.Join(suite, "valid", "*.jsonl"))
	for _, p := range paths {
		if b, err := os.ReadFile(p); err == nil {
			for _, line := range strings.SplitAfter(string(b), "\n") {
				f.Add([]byte(line))
			}
		}
	}
}

// FuzzJSON: the JSON readers never panic and report positioned errors with
// catalogue codes; what the import reads round-trips through
// self-describing JSON, and what the self-describing reader accepts is
// written back as JSON that reads to the same value (one form per value).
func FuzzJSON(f *testing.F) {
	addJSONSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		check := func(err error) {
			var e *Error
			if !errors.As(err, &e) {
				t.Fatalf("not an *Error: %v", err)
			}
			if _, ok := e.Code.Info(); !ok {
				t.Fatalf("code %q is not in the catalogue", e.Code)
			}
			if e.Line == 0 && e.Path == "" {
				t.Fatalf("an error without a place: %v", err)
			}
		}
		roundTrip := func(v Value) {
			out, err := ToHausJSON(v)
			if err != nil {
				t.Fatalf("write %v: %v", v, err)
			}
			back, err := FromHausJSON(out)
			if err != nil {
				t.Fatalf("read back %s: %v", out, err)
			}
			if !Equals(back, v) {
				t.Fatalf("%s reads back to another value", out)
			}
			again, _ := ToHausJSON(back)
			if string(again) != string(out) {
				t.Fatalf("two forms: %s and %s", out, again)
			}
		}
		if v, err := ImportJSON(data); err != nil {
			check(err)
		} else {
			roundTrip(v)
		}
		if v, err := FromHausJSON(data); err != nil {
			check(err)
		} else {
			roundTrip(v)
		}
		if vs, err := FromHausJSONLines(data); err != nil {
			check(err)
		} else {
			for _, v := range vs {
				roundTrip(v)
			}
		}
	})
}
