// Package money has the codecs of the profile @haus-fmt/money/iso for the
// types of the schema package @haus-fmt/money (extensions/money): Money,
// an exact amount with a currency, and Currency, a bare tag.
//
// The schema fixes the shape; the profile's rule, which these codecs check,
// is that a currency is three capital letters A–Z, the shape of an ISO 4217
// code (extensions/money/profiles/iso.md). Whether the code is assigned is
// not checked.
//
// The schema itself is found like any package's (spec §13.3), for example
// in node_modules or given with [schema.Explicit]:
//
//	s, err := schema.Load("order.schema.haus", schema.Options{Packages: schema.NodeModules{}})
//	codecs, _ := schema.NewCodecs(money.Iso, money.IsoCurrency)
//	v, err := order.DecodeWith(value, schema.DecodeOptions{Codecs: codecs})
package money

import (
	"fmt"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// The ids of the package's types (spec §13.3).
const (
	MoneyID    = "@haus-fmt/money@1#Money"
	CurrencyID = "@haus-fmt/money@1#Currency"
)

// Money is a value of the type Money: Money(19.90, EUR). Amount keeps its
// scale (19.90 is not 19.9).
type Money struct {
	Amount   haus.Number
	Currency Currency
}

// Currency is an ISO-shaped currency code: EUR.
type Currency string

// Iso is the codec of the iso profile for Money, with the host type
// [Money]: it accepts a Money whose currency is three letters A–Z, and any
// amount.
var Iso = schema.NewCodec(MoneyID, decodeMoney, encodeMoney)

// IsoCurrency is the codec of the iso profile for Currency, with the host
// type [Currency]: a tag of three letters A–Z, without a payload.
var IsoCurrency = schema.NewCodec(CurrencyID, decodeCurrency, encodeCurrency)

func decodeMoney(v haus.Value) (Money, error) {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag != "Money" || len(x.Args) != 2 {
		return Money{}, rejected("expected Money(amount, currency)")
	}
	amount, ok := x.Args[0].(haus.Number)
	if !ok {
		return Money{}, rejected("expected a Decimal amount")
	}
	c, err := decodeCurrency(x.Args[1])
	if err != nil {
		return Money{}, err
	}
	return Money{amount, c}, nil
}

func encodeMoney(m Money) (haus.Value, error) {
	c, err := encodeCurrency(m.Currency)
	if err != nil {
		return nil, err
	}
	return haus.Variant{Tag: "Money", Args: []haus.Value{m.Amount, c}}, nil
}

func decodeCurrency(v haus.Value) (Currency, error) {
	x, ok := v.(haus.Variant)
	switch {
	case !ok:
		return "", rejected("a currency is a tag")
	case len(x.Args) > 0:
		return "", rejected(fmt.Sprintf("the currency %s has a payload; a currency is three letters A–Z (ISO 4217)", x.Tag))
	case !isISO(x.Tag):
		return "", rejected(fmt.Sprintf("%s is not a currency: three letters A–Z (ISO 4217)", short(x.Tag)))
	}
	return Currency(x.Tag), nil
}

func encodeCurrency(c Currency) (haus.Value, error) {
	if !isISO(string(c)) {
		return nil, &haus.Error{Code: haus.CodeCannotEncode,
			Message: fmt.Sprintf("%q is not a currency: three letters A–Z (ISO 4217)", short(string(c)))}
	}
	return haus.Variant{Tag: string(c)}, nil
}

// isISO reports whether s is three capital letters A–Z.
func isISO(s string) bool {
	return len(s) == 3 && upper(s[0]) && upper(s[1]) && upper(s[2])
}

func upper(c byte) bool { return c >= 'A' && c <= 'Z' }

// short is at most 20 bytes of a tag, for messages.
func short(s string) string {
	if len(s) > 20 {
		return s[:20] + "…"
	}
	return s
}

func rejected(msg string) error {
	return &haus.Error{Code: haus.CodeTypeMismatch, Message: msg}
}
