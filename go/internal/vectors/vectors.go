// Package vectors runs the test vectors of a profile (spec §13.3,
// "Profiles"): extensions/*/profiles/*.vectors.haus.
package vectors

import (
	"errors"
	"os"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// Run loads the package's schema.haus from dir and checks every vector of
// file with the codecs, by type name:
//
//   - Accept: value (haus text of type) is accepted, and encoding what the
//     codec decoded writes exactly output, or value when there is none.
//   - Reject: value is valid for the schema of type, and the codec rejects
//     it with type-mismatch, at the value.
//
// It returns the number of Accept and Reject vectors.
func Run(t *testing.T, dir, file string, codecs map[string]schema.Codec) (accepted, rejected int) {
	t.Helper()
	s, err := schema.Load(dir+"/schema.haus", schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	vectors, err := haus.ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	all := make([]schema.Codec, 0, len(codecs))
	for _, c := range codecs {
		all = append(all, c)
	}
	set, err := schema.NewCodecs(all...)
	if err != nil {
		t.Fatal(err)
	}
	for _, v := range vectors {
		x := v.(haus.Variant)
		r := x.Args[0].(haus.Record)
		get := func(k string) string {
			s, _ := r.Get(k)
			text, _ := s.(haus.String)
			return string(text)
		}
		name, text := get("type"), get("value")
		ty, err := s.Type(name)
		if err != nil {
			t.Fatal(err)
		}
		codec := codecs[name]
		if codec == nil || codec.TypeID() != ty.ID() {
			t.Fatalf("no codec for %s (%s)", name, ty.ID())
		}
		value, err := haus.Parse([]byte(text))
		if err != nil {
			t.Fatalf("%s: %v", text, err)
		}
		switch x.Tag {
		case "Accept":
			accepted++
			host, err := schema.DecodeAs[any](ty, value, codec)
			if err != nil {
				t.Errorf("%s: rejected: %v", text, err)
				continue
			}
			encoded, err := codec.Encode(host)
			if err != nil {
				t.Errorf("%s: encode: %v", text, err)
				continue
			}
			encoded, err = ty.EncodeWith(encoded, schema.DecodeOptions{Codecs: set})
			if err != nil {
				t.Errorf("%s: encode: %v", text, err)
				continue
			}
			out, err := haus.FormatValue(encoded, haus.DefaultFormatOptions())
			if err != nil {
				t.Fatal(err)
			}
			want := get("output")
			if want == "" {
				want = text
			}
			if got := strings.TrimSuffix(string(out), "\n"); got != want {
				t.Errorf("%s: encodes to %s, want %s", text, got, want)
			}
		case "Reject":
			rejected++
			if _, err := ty.Decode(value); err != nil {
				t.Errorf("%s: not valid for the schema: %v", text, err)
			}
			// With the type's own codec, at the value; with all of them, a
			// codec of a part may reject it first, at the part.
			if _, err := schema.DecodeAs[any](ty, value, codec); !isMismatch(err, "$") {
				t.Errorf("%s: got %v, want type-mismatch at $", text, err)
			}
			if _, err := ty.DecodeWith(value, schema.DecodeOptions{Codecs: set}); !isMismatch(err, "") {
				t.Errorf("%s: got %v, want type-mismatch", text, err)
			}
		default:
			t.Fatalf("unknown vector %s", x.Tag)
		}
	}
	return accepted, rejected
}

// isMismatch reports whether err is type-mismatch, at path unless "".
func isMismatch(err error, path string) bool {
	var e *haus.Error
	return errors.As(err, &e) && e.Code == haus.CodeTypeMismatch && (path == "" || e.Path == path || e.Path == "")
}
