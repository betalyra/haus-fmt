package money_test

import (
	"errors"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/money"
	"github.com/betalyra/haus-fmt/go/internal/vectors"
	"github.com/betalyra/haus-fmt/go/schema"
)

const dir = "../../../extensions/money"

func TestIsoVectors(t *testing.T) {
	accepted, rejected := vectors.Run(t, dir, dir+"/profiles/iso.vectors.haus",
		map[string]schema.Codec{"Money": money.Iso, "Currency": money.IsoCurrency})
	t.Logf("iso: %d Accept, %d Reject", accepted, rejected)
}

func TestIsoEncodeChecksTheRule(t *testing.T) {
	_, err := money.Iso.Encode(money.Money{Amount: haus.NumberFromInt(1), Currency: "Eur"})
	var e *haus.Error
	if !errors.As(err, &e) || e.Code != haus.CodeCannotEncode {
		t.Errorf("got %v", err)
	}
}

// TestCodecsRunInsideOut: with codecs for Money and Currency, the
// Currency's codec runs first and its rejection is at the currency's own
// place (spec §13.4), in a haus value and in schema-based JSON alike.
func TestCodecsRunInsideOut(t *testing.T) {
	packages, err := schema.NewExplicit().Package(dir)
	if err != nil {
		t.Fatal(err)
	}
	s, err := schema.Parse([]byte(`import @haus-fmt/money@1 (Money)
type Order = { total: Money, lines: Array Money }`), schema.Options{Packages: packages})
	if err != nil {
		t.Fatal(err)
	}
	order, _ := s.Type("Order")
	m, _ := s.Type("Money")
	both, _ := schema.NewCodecs(money.Iso, money.IsoCurrency)
	onlyMoney, _ := schema.NewCodecs(money.Iso)
	cases := []struct {
		ty           schema.Type
		codecs       *schema.Codecs
		text, json   string
		path, inJSON string
	}{
		{m, both, "Money(1, Eur)", `{"_tag": "Money", "values": ["1", {"_tag": "Eur"}]}`, "$[1]", "$.values[1]"},
		{m, onlyMoney, "Money(1, Eur)", `{"_tag": "Money", "values": ["1", {"_tag": "Eur"}]}`, "$", "$"},
		{order, both, "{ total: Money(1, EUR), lines: [Money(2, EUR), Money(3, Eur)] }",
			`{"total": {"_tag": "Money", "values": ["1", {"_tag": "EUR"}]}, "lines": [{"_tag": "Money", "values": ["2", {"_tag": "EUR"}]}, {"_tag": "Money", "values": ["3", {"_tag": "Eur"}]}]}`,
			"$.lines[1][1]", "$.lines[1].values[1]"},
	}
	for _, c := range cases {
		opts := schema.DecodeOptions{Codecs: c.codecs}
		v, err := haus.Parse([]byte(c.text))
		if err != nil {
			t.Fatal(err)
		}
		_, err = c.ty.DecodeWith(v, opts)
		var e *haus.Error
		if !errors.As(err, &e) || e.Code != haus.CodeTypeMismatch || e.Path != c.path {
			t.Errorf("decode %s: got %v, want the place %s", c.text, err, c.path)
		}
		_, err = c.ty.FromJSONWith([]byte(c.json), opts)
		if !errors.As(err, &e) || e.Code != haus.CodeTypeMismatch || e.Path != c.inJSON {
			t.Errorf("read %s: got %v, want the place %s", c.json, err, c.inJSON)
		}
	}
}
