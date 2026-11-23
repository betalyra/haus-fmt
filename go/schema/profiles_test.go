package schema_test

import (
	"slices"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

const (
	money    = "@haus-fmt/money@1#Money"
	currency = "@haus-fmt/money@1#Currency"
	latLng   = "@haus-fmt/geo@1#LatLng"
	bbox     = "@haus-fmt/geo@1#BBox"
)

func officialSchema(t *testing.T, text string) *schema.Schema {
	t.Helper()
	packages, err := schema.NewExplicit().Package("../../extensions/money")
	if err == nil {
		packages, err = packages.Package("../../extensions/geo")
	}
	if err != nil {
		t.Fatal(err)
	}
	s, err := schema.Parse([]byte(text), schema.Options{Packages: packages})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// codecs returns a codec for each type id, each keeping the value.
func codecs(t *testing.T, ids ...string) *schema.Codecs {
	t.Helper()
	list := make([]schema.Codec, len(ids))
	for i, id := range ids {
		list[i] = schema.NewCodec(id,
			func(v haus.Value) (haus.Value, error) { return v, nil },
			func(v haus.Value) (haus.Value, error) { return v, nil })
	}
	c, err := schema.NewCodecs(list...)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// warned returns the ids the warnings name, each checked for its code and place.
func warned(t *testing.T, warnings []*haus.Error) []string {
	t.Helper()
	ids := []string{}
	for _, w := range warnings {
		if w.Code != haus.CodeMissingCodec || w.Line != 0 || w.Path != "" {
			t.Errorf("not a missing-codec warning at no place: %+v", w)
		}
		ids = append(ids, strings.Fields(w.Message)[0])
	}
	return ids
}

const officialOrder = `import @haus-fmt/money (Money)
import @haus-fmt/geo (LatLng, BBox)
type Order = { total: Money, at?: Maybe LatLng, area: Array BBox }`

func TestMissingCodecs(t *testing.T) {
	s := officialSchema(t, officialOrder)
	order, _ := s.Type("Order")
	cases := []struct {
		codecs *schema.Codecs
		want   []string
	}{
		// Money reaches Currency, and has no rule of its own; BBox reaches LatLng too: once.
		{nil, []string{bbox, latLng, currency}},
		{codecs(t, currency, latLng, bbox), []string{}},
		// A codec for Money covers its Currency.
		{codecs(t, money, latLng, bbox), []string{}},
		// A codec for BBox covers the LatLngs inside it, not the one of `at`.
		{codecs(t, money, bbox), []string{latLng}},
	}
	for _, c := range cases {
		if got := warned(t, order.MissingCodecs(c.codecs)); !slices.Equal(got, c.want) {
			t.Errorf("Type: got %v, want %v", got, c.want)
		}
		if got := warned(t, s.MissingCodecs(c.codecs)); !slices.Equal(got, c.want) {
			t.Errorf("Schema: got %v, want %v", got, c.want)
		}
	}
	w := order.MissingCodecs(nil)[2]
	want := "@haus-fmt/money@1#Currency has profiles (iso), but no codec is set for it: its values are checked for their shape only"
	if w.Message != want {
		t.Errorf("got %q", w.Message)
	}
	// Only a warning: decoding is the same.
	v, _ := haus.Parse([]byte("{ total: Money(1, Eur), area: [] }"))
	if _, err := order.Decode(v); err != nil {
		t.Error(err)
	}
}

func TestMissingCodecsOnlyForWhatIsReached(t *testing.T) {
	// BBox is imported, but no definition uses it.
	s := officialSchema(t, "import @haus-fmt/geo (LatLng, BBox)\ntype Root = { at: LatLng }")
	if got := warned(t, s.MissingCodecs(nil)); !slices.Equal(got, []string{latLng}) {
		t.Errorf("got %v", got)
	}
	bb, _ := s.Type("BBox")
	if got := warned(t, bb.MissingCodecs(nil)); !slices.Equal(got, []string{bbox, latLng}) {
		t.Errorf("BBox: got %v", got)
	}
	// Through generic types, variants, maps and secrets.
	s = officialSchema(t, "import @haus-fmt/money (Currency)\ntype Page a = { items: Array a }\n"+
		"type Root = < A (Page (Map (Secret Currency))) | B >")
	if got := warned(t, s.MissingCodecs(nil)); !slices.Equal(got, []string{currency}) {
		t.Errorf("got %v", got)
	}
	s = officialSchema(t, "import std/time (Date)\ntype Root = { d: Date }")
	if got := s.MissingCodecs(nil); len(got) != 0 {
		t.Errorf("got %v", got)
	}
}
