package main

// Codecs: the application chooses Go types for named haus types. Each one
// takes the value the schema decoded, so the schema's rules always run,
// and encodes back to it, so the haus text never changes (spec §13.4).

import (
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/geo"
	"github.com/betalyra/haus-fmt/go/ext/money"
	"github.com/betalyra/haus-fmt/go/schema"
)

// Amount is integer cents, as payment APIs want them.
type Amount struct {
	Cents *big.Int
	// Currency is an ISO 4217 code: three letters A–Z.
	Currency string
}

// cents: Money(44.40, EUR) ↔ Amount{4440, "EUR"}. More than 2 decimal
// places, or a currency that isn't ISO-shaped (the iso profile, which
// money.Iso checks), is an error.
var cents = schema.NewCodec(money.MoneyID,
	func(v haus.Value) (Amount, error) {
		m, err := money.Iso.Decode(v)
		if err != nil {
			return Amount{}, err
		}
		amount := m.(money.Money)
		r, _ := new(big.Rat).SetString(amount.Amount.String())
		r.Mul(r, big.NewRat(100, 1))
		if !r.IsInt() {
			return Amount{}, fmt.Errorf("%s has more than 2 decimal places", amount.Amount)
		}
		return Amount{Cents: r.Num(), Currency: string(amount.Currency)}, nil
	},
	func(a Amount) (haus.Value, error) {
		n, err := haus.ParseNumber(decimal(a.Cents, 2))
		if err != nil {
			return nil, err
		}
		return money.Iso.Encode(money.Money{Amount: n, Currency: money.Currency(a.Currency)})
	})

// decimal writes n / 10^scale with scale decimal places: 4440 → 44.40.
func decimal(n *big.Int, scale int) string {
	digits := new(big.Int).Abs(n).String()
	if len(digits) <= scale {
		digits = strings.Repeat("0", scale-len(digits)+1) + digits
	}
	sign := ""
	if n.Sign() < 0 {
		sign = "-"
	}
	return sign + digits[:len(digits)-scale] + "." + digits[len(digits)-scale:]
}

// geoJSON is GeoJSON order: LatLng(38.7223, -9.1393) ↔ [-9.1393, 38.7223].
// The swap happens here, once, on top of the wgs84 profile (geo.Wgs84).
var geoJSON = schema.NewCodec(geo.LatLngID,
	func(v haus.Value) ([2]float64, error) {
		p, err := geo.Wgs84.Decode(v)
		if err != nil {
			return [2]float64{}, err
		}
		return [2]float64{p.(geo.LatLng).Lng, p.(geo.LatLng).Lat}, nil
	},
	func(lngLat [2]float64) (haus.Value, error) {
		return geo.Wgs84.Encode(geo.LatLng{Lat: lngLat[1], Lng: lngLat[0]})
	})

// date: std/time types take codecs too, Date("2026-11-09") ↔ a time.Time
// at midnight UTC.
var date = schema.NewCodec("std/time#Date",
	func(v haus.Value) (time.Time, error) {
		// The std/time profile already ran: this can't fail for a valid Date.
		text, _ := v.(haus.Variant).Args[0].(haus.String)
		return time.Parse(time.DateOnly, string(text))
	},
	func(t time.Time) (haus.Value, error) {
		if y := t.Year(); y < 0 || y > 9999 {
			return nil, errors.New("the year is outside 0000–9999")
		}
		return haus.Variant{Tag: "Date", Args: []haus.Value{haus.String(t.Format(time.DateOnly))}}, nil
	})
