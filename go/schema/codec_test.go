package schema_test

import (
	"errors"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// counting returns a codec for id that keeps the value, and counts its runs.
func counting(id string, runs *int) schema.Codec {
	return schema.NewCodec(id,
		func(v haus.Value) (haus.Value, error) { *runs++; return v, nil },
		func(v haus.Value) (haus.Value, error) { return v, nil })
}

// rejecting returns a codec for id that rejects every value, and every host
// value it is given to encode.
func rejecting(id string) schema.Codec {
	return schema.NewCodec(id,
		func(haus.Value) (haus.Value, error) { return nil, errors.New("not this one") },
		func(haus.Value) (haus.Value, error) { return nil, errors.New("can't write this one") })
}

func decodeWithCodecs(t *testing.T, ty schema.Type, text string, c *schema.Codecs) (haus.Value, error) {
	t.Helper()
	v, err := haus.Parse([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	return ty.DecodeWith(v, schema.DecodeOptions{Codecs: c})
}

func failsWith(t *testing.T, err error, code haus.ErrorCode, path string) {
	t.Helper()
	var e *haus.Error
	if !errors.As(err, &e) || e.Code != code || e.Path != path {
		t.Errorf("got %v, want %s at %s", err, code, path)
	}
}

// TestPreludeAndStdCodecs: a codec for a type of the prelude or of std/time
// runs wherever the type occurs, in a package's types too (spec §13.4).
func TestPreludeAndStdCodecs(t *testing.T) {
	s := officialSchema(t, "import @haus-fmt/money (Money)\nimport std/time (Instant)\n"+
		"type Root = { price: Decimal, total: Money, at: Instant }")
	root, _ := s.Type("Root")
	var decimals, instants int
	c, err := schema.NewCodecs(counting("prelude#Decimal", &decimals), counting("std/time#Instant", &instants))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeWithCodecs(t, root, `{ price: 1.5, total: Money(2.50, EUR), at: Instant("2026-11-25T10:00:00Z") }`, c); err != nil {
		t.Fatal(err)
	}
	if decimals != 2 || instants != 1 {
		t.Errorf("the Decimal codec ran %d times (want 2: price and Money's amount), the Instant codec %d (want 1)", decimals, instants)
	}
	if got := s.UnusedCodecs(c); len(got) != 0 {
		t.Errorf("unused: %v", got)
	}
	// A rejection is at the place of the codec's type.
	reject, _ := schema.NewCodecs(rejecting("prelude#Decimal"))
	_, err = decodeWithCodecs(t, root, `{ price: 1.5, total: Money(2.50, EUR), at: Instant("2026-11-25T10:00:00Z") }`, reject)
	failsWith(t, err, haus.CodeCodecRejected, "$.price")
}

// TestCodecOfTheDecodedType: decoding a value as Currency runs the codec
// for Currency (spec §13.4).
func TestCodecOfTheDecodedType(t *testing.T) {
	s := officialSchema(t, "import @haus-fmt/money (Currency)\ntype Root = Currency")
	cur, _ := s.Type("Currency")
	reject, _ := schema.NewCodecs(rejecting(currency))
	_, err := decodeWithCodecs(t, cur, "CHF", reject)
	failsWith(t, err, haus.CodeCodecRejected, "$")
}

// TestOneCodecPerID: two codecs for one id are a mistake of the
// configuration (spec §13.4).
func TestOneCodecPerID(t *testing.T) {
	var runs int
	if _, err := schema.NewCodecs(counting(currency, &runs), counting(currency, &runs)); err == nil {
		t.Error("two codecs for one id were accepted")
	}
}

// TestCodecRejectingInsideASecret: invalid-secret at the secret (spec §13.4).
func TestCodecRejectingInsideASecret(t *testing.T) {
	s := officialSchema(t, "import @haus-fmt/money (Currency)\ntype Root = { key: Secret Currency }")
	root, _ := s.Type("Root")
	reject, _ := schema.NewCodecs(rejecting(currency))
	_, err := decodeWithCodecs(t, root, "{ key: CHF }", reject)
	failsWith(t, err, haus.CodeInvalidSecret, "$.key")
	if strings.Contains(err.Error(), "CHF") {
		t.Errorf("the error shows the secret: %v", err)
	}
}

// TestCodecEncodeRejection: a codec that can't write a host value fails
// with cannot-encode at the codec's type's place (spec §13.4).
func TestCodecEncodeRejection(t *testing.T) {
	s := officialSchema(t, "import @haus-fmt/money (Currency)\ntype Root = Currency")
	cur, _ := s.Type("Currency")
	_, err := schema.EncodeFrom[haus.Value](cur, haus.Variant{Tag: haus.MustTag("CHF")}, rejecting(currency))
	failsWith(t, err, haus.CodeCannotEncode, "$")
}

// TestUnusedCodecs: a codec whose id no type has is pointed out, once per
// id, at no place (spec §13.4, "A codec that matches no type").
func TestUnusedCodecs(t *testing.T) {
	s := officialSchema(t, "import @haus-fmt/money (Currency)\ntype Root = { c: Currency }")
	var runs int
	c, _ := schema.NewCodecs(
		counting("@haus-fmt/money@2#Money", &runs),
		counting(money, &runs), // a type of an imported package, though not imported by name
		counting(currency, &runs),
		counting("prelude#Int", &runs),
		counting("std/time#Date", &runs),
		counting("prelude#Price", &runs),
	)
	var got []string
	for _, w := range s.UnusedCodecs(c) {
		if w.Code != haus.CodeUnusedCodec || w.Line != 0 || w.Path != "" {
			t.Errorf("not an unused-codec warning at no place: %+v", w)
		}
		got = append(got, w.Message)
	}
	want := []string{"@haus-fmt/money@2#Money", "prelude#Price"}
	if len(got) != len(want) {
		t.Fatalf("got %q, want warnings for %v", got, want)
	}
	for i := range want {
		if !strings.Contains(got[i], want[i]) {
			t.Errorf("got %q, want a warning for %s", got[i], want[i])
		}
	}
	if len(s.UnusedCodecs(nil)) != 0 {
		t.Error("warnings without codecs")
	}
}
