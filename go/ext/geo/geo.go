// Package geo has the codecs of the profile @haus-fmt/geo/wgs84 for the
// types of the schema package @haus-fmt/geo (extensions/geo): LatLng, a
// point, and BBox, a box, in degrees of WGS 84, latitude first.
//
// The schema fixes the shape; the profile's rule, which these codecs check,
// is on the decoded floats (extensions/geo/profiles/wgs84.md): −90 ≤ lat ≤
// 90 and −180 ≤ lng ≤ 180, so NaN and the infinities are rejected, and a
// box's south-west corner is not north of its north-east one. Negative
// zero is kept, and nothing is normalised.
package geo

import (
	"fmt"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// The ids of the package's types (spec §13.3).
const (
	LatLngID = "@haus-fmt/geo@1#LatLng"
	BBoxID   = "@haus-fmt/geo@1#BBox"
)

// LatLng is a point: LatLng(38.7223, -9.1393) is Lisbon.
type LatLng struct {
	Lat, Lng float64
}

// BBox is a box from its south-west corner SW to its north-east corner NE.
// A box with SW.Lng > NE.Lng crosses the antimeridian.
type BBox struct {
	SW, NE LatLng
}

// Wgs84 is the codec of the wgs84 profile for LatLng, with the host type
// [LatLng].
var Wgs84 = schema.NewCodec(LatLngID, decodeLatLng, encodeLatLng)

// Wgs84BBox is the codec of the wgs84 profile for BBox, with the host type
// [BBox]. It checks both corners itself.
var Wgs84BBox = schema.NewCodec(BBoxID, decodeBBox, encodeBBox)

func decodeLatLng(v haus.Value) (LatLng, error) {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag != "LatLng" || len(x.Args) != 2 {
		return LatLng{}, rejected("expected LatLng(lat, lng)")
	}
	lat, ok1 := float(x.Args[0])
	lng, ok2 := float(x.Args[1])
	if !ok1 || !ok2 {
		return LatLng{}, rejected("a latitude and a longitude are finite numbers")
	}
	p := LatLng{lat, lng}
	if msg := p.problem(); msg != "" {
		return LatLng{}, rejected(msg)
	}
	return p, nil
}

func encodeLatLng(p LatLng) (haus.Value, error) {
	if msg := p.problem(); msg != "" {
		return nil, &haus.Error{Code: haus.CodeCannotEncode, Message: msg}
	}
	return haus.Variant{Tag: "LatLng", Args: []haus.Value{haus.FloatValue(p.Lat), haus.FloatValue(p.Lng)}}, nil
}

func decodeBBox(v haus.Value) (BBox, error) {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag != "BBox" || len(x.Args) != 2 {
		return BBox{}, rejected("expected BBox(sw, ne)")
	}
	sw, err := decodeLatLng(x.Args[0])
	if err != nil {
		return BBox{}, err
	}
	ne, err := decodeLatLng(x.Args[1])
	if err != nil {
		return BBox{}, err
	}
	b := BBox{sw, ne}
	if msg := b.problem(); msg != "" {
		return BBox{}, rejected(msg)
	}
	return b, nil
}

func encodeBBox(b BBox) (haus.Value, error) {
	if msg := b.problem(); msg != "" {
		return nil, &haus.Error{Code: haus.CodeCannotEncode, Message: msg}
	}
	sw, err := encodeLatLng(b.SW)
	if err != nil {
		return nil, err
	}
	ne, err := encodeLatLng(b.NE)
	if err != nil {
		return nil, err
	}
	return haus.Variant{Tag: "BBox", Args: []haus.Value{sw, ne}}, nil
}

// float is a decoded Float64: a number in its one spelling, which reads
// back to the same float. NaN and the infinities are tags.
func float(v haus.Value) (float64, bool) {
	n, ok := v.(haus.Number)
	if !ok {
		return 0, false
	}
	return n.Float64()
}

// problem says why p breaks the rule, or "". NaN fails every comparison.
func (p LatLng) problem() string {
	switch {
	case !(p.Lat >= -90 && p.Lat <= 90):
		return fmt.Sprintf("latitude %s is outside −90 to 90", haus.FormatFloat(p.Lat, 64))
	case !(p.Lng >= -180 && p.Lng <= 180):
		return fmt.Sprintf("longitude %s is outside −180 to 180", haus.FormatFloat(p.Lng, 64))
	}
	return ""
}

func (b BBox) problem() string {
	if msg := b.SW.problem(); msg != "" {
		return "south-west corner: " + msg
	}
	if msg := b.NE.problem(); msg != "" {
		return "north-east corner: " + msg
	}
	if b.SW.Lat > b.NE.Lat {
		return fmt.Sprintf("the south-west corner (latitude %s) is north of the north-east one (%s)",
			haus.FormatFloat(b.SW.Lat, 64), haus.FormatFloat(b.NE.Lat, 64))
	}
	return ""
}

func rejected(msg string) error {
	return &haus.Error{Code: haus.CodeCodecRejected, Message: msg}
}
