// Package uuid has the codec of the profile @haus-fmt/uuid/rfc9562 for the
// type of the schema package @haus-fmt/uuid (extensions/uuid): Uuid, a
// universally unique identifier, Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57").
//
// The schema fixes the shape; the profile's rule, which the codec checks, is
// the text form of RFC 9562 in lowercase (extensions/uuid/profiles/rfc9562.md):
// 32 digits 0–9, a–f in groups 8-4-4-4-12, joined by hyphens. Any version
// and variant is accepted, the nil and the max UUID too. The text is the
// UUID's one spelling, so the codec keeps the value.
//
// The schema itself is given like any package's (spec §13.3), with
// [schema.Explicit]:
//
//	packages, err := schema.NewExplicit().Package("schemas/uuid")
//	s, err := schema.Load("user.schema.haus", schema.Options{Packages: packages})
//	codecs, _ := schema.NewCodecs(uuid.Rfc9562)
//	v, err := user.DecodeWith(value, schema.DecodeOptions{Codecs: codecs})
package uuid

import (
	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// ID is the id of the package's type Uuid (spec §13.3).
const ID = "@haus-fmt/uuid@1#Uuid"

// UUID is a UUID as its text: 0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57.
type UUID string

// Rfc9562 is the codec of the rfc9562 profile for Uuid, with the host type
// [UUID]: the text, checked.
var Rfc9562 = schema.NewCodec(ID, decodeUUID, encodeUUID)

// rejected says what the profile takes; it doesn't quote the text, which can be anything.
const rejected = "not a UUID of the rfc9562 profile: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens"

func decodeUUID(v haus.Value) (UUID, error) {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag.String() != "Uuid" || len(x.Args) != 1 {
		return "", &haus.Error{Code: haus.CodeCodecRejected, Message: "expected Uuid(text)"}
	}
	text, ok := x.Args[0].(haus.String)
	if !ok || !Valid(string(text)) {
		return "", &haus.Error{Code: haus.CodeCodecRejected, Message: rejected}
	}
	return UUID(text), nil
}

func encodeUUID(u UUID) (haus.Value, error) {
	if !Valid(string(u)) {
		return nil, &haus.Error{Code: haus.CodeCannotEncode, Message: rejected}
	}
	return haus.Variant{Tag: haus.MustTag("Uuid"), Args: []haus.Value{haus.String(u)}}, nil
}

// Valid reports whether the rfc9562 profile accepts s: 36 bytes, hyphens at
// 8, 13, 18 and 23, and 0–9, a–f everywhere else.
func Valid(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
				return false
			}
		}
	}
	return true
}
