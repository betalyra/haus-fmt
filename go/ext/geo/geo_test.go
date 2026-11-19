package geo_test

import (
	"errors"
	"math"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/ext/geo"
	"github.com/betalyra/haus-fmt/go/internal/vectors"
	"github.com/betalyra/haus-fmt/go/schema"
)

const dir = "../../../extensions/geo"

func TestWgs84Vectors(t *testing.T) {
	accepted, rejected := vectors.Run(t, dir, dir+"/profiles/wgs84.vectors.haus",
		map[string]schema.Codec{"LatLng": geo.Wgs84, "BBox": geo.Wgs84BBox})
	t.Logf("wgs84: %d Accept, %d Reject", accepted, rejected)
}

func TestWgs84EncodeChecksTheRule(t *testing.T) {
	for _, x := range []any{
		geo.LatLng{Lat: math.NaN()},
		geo.LatLng{Lng: 181},
		geo.BBox{SW: geo.LatLng{Lat: 1}, NE: geo.LatLng{Lat: 0}},
	} {
		codec := geo.Wgs84
		if _, ok := x.(geo.BBox); ok {
			codec = geo.Wgs84BBox
		}
		_, err := codec.Encode(x)
		var e *haus.Error
		if !errors.As(err, &e) || e.Code != haus.CodeCannotEncode {
			t.Errorf("%v: got %v", x, err)
		}
	}
	v, err := geo.Wgs84.Encode(geo.LatLng{Lat: math.Copysign(0, -1), Lng: 0})
	if err != nil {
		t.Fatal(err)
	}
	if s, _ := haus.Canonical(v); s != "LatLng(-0,0)" {
		t.Errorf("negative zero: %s", s)
	}
}
