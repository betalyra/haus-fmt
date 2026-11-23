package main

// The profile fuzzer (`profiles.ts`): lines `TYPE HEX` (a value's haus text
// as hex UTF-8). The value is decoded with the type of its package's schema
// (extensions/money, extensions/geo, extensions/uuid) and the codecs of the
// official profile (ext/money's Iso and IsoCurrency, ext/geo's Wgs84 and
// Wgs84BBox, ext/uuid's Rfc9562), and what
// was decoded is encoded again: `ok <canonical form>`, or
// `err <place> <code> <reason>`. Encoding what was decoded must work, so an
// encoding error is `crash …`.

import (
	"fmt"
	"path/filepath"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/geo"
	"github.com/betalyra/haus-fmt/go/ext/money"
	"github.com/betalyra/haus-fmt/go/ext/uuid"
	"github.com/betalyra/haus-fmt/go/schema"
)

// profiled is a type of a package's schema with its profile's codecs.
type profiled struct {
	ty   schema.Type
	opts schema.DecodeOptions
}

// profileTypes loads each package's schema with its profile's codecs.
func profileTypes() (map[string]profiled, error) {
	out := map[string]profiled{}
	packages := []struct {
		dir    string
		types  []string
		codecs []schema.Codec
	}{
		{"money", []string{"Money", "Currency"}, []schema.Codec{money.Iso, money.IsoCurrency}},
		{"geo", []string{"LatLng", "BBox"}, []schema.Codec{geo.Wgs84, geo.Wgs84BBox}},
		{"uuid", []string{"Uuid"}, []schema.Codec{uuid.Rfc9562}},
	}
	for _, p := range packages {
		s, err := schema.Load(filepath.Join(root, "extensions", p.dir, "schema.haus"), schema.Options{})
		if err != nil {
			return nil, err
		}
		codecs, err := schema.NewCodecs(p.codecs...)
		if err != nil {
			return nil, err
		}
		for _, name := range p.types {
			ty, err := s.Type(name)
			if err != nil {
				return nil, err
			}
			out[name] = profiled{ty, schema.DecodeOptions{Codecs: codecs}}
		}
	}
	return out, nil
}

func profileLines() (func(string) string, error) {
	types, err := profileTypes()
	if err != nil {
		return nil, err
	}
	return func(line string) string {
		name, hexText, _ := strings.Cut(line, " ")
		t, ok := types[name]
		if !ok {
			return "crash no type " + name
		}
		v, bad := single(unhex(hexText))
		if bad != "" {
			return bad
		}
		return roundtrip(t.ty, v, t.opts)
	}, nil
}

// roundtrip decodes v with the type and encodes what it decoded:
// `ok <canonical form>`, `err …`, or `crash …` if encoding fails.
func roundtrip(t schema.Type, v haus.Value, opts schema.DecodeOptions) string {
	decoded, err := t.DecodeWith(v, opts)
	if err != nil {
		return placed(err)
	}
	encoded, err := t.EncodeWith(decoded, opts)
	if err != nil {
		return "crash encoding failed: " + err.Error()
	}
	c, err := haus.Canonical(encoded)
	if err != nil {
		return fmt.Sprintf("crash no canonical form: %v", err)
	}
	return "ok " + c
}
