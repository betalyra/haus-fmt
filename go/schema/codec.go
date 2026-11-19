package schema

import (
	"fmt"
	"log/slog"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
)

// Codec chooses the host type of a named type without arguments (spec
// §13.4), selected by the type's id. A codec runs after the type's schema:
// it can reject more values, never fewer; it encodes back to the type's
// values, so that decode, encode, decode is the same as decode; and it
// never changes what a value means. Codecs are part of the application,
// not of the schema.
type Codec interface {
	// TypeID is the id of the type the codec is for (spec §13.3):
	// std/time#Instant, @haus-fmt/money@1#Money.
	TypeID() string
	// Decode turns a value the type's schema decoded into the host value,
	// or rejects it. An *haus.Error keeps its code; any other error is
	// type-mismatch.
	Decode(v haus.Value) (any, error)
	// Encode turns a host value back into a value of the type.
	Encode(x any) (haus.Value, error)
}

// NewCodec makes a [Codec] for the type with the id from two functions on
// the host type T.
func NewCodec[T any](id string, decode func(haus.Value) (T, error), encode func(T) (haus.Value, error)) Codec {
	return funcCodec[T]{id, decode, encode}
}

type funcCodec[T any] struct {
	id     string
	decode func(haus.Value) (T, error)
	encode func(T) (haus.Value, error)
}

func (c funcCodec[T]) TypeID() string { return c.id }

func (c funcCodec[T]) Decode(v haus.Value) (any, error) { return c.decode(v) }

func (c funcCodec[T]) Encode(x any) (haus.Value, error) {
	t, ok := x.(T)
	if !ok {
		return nil, newError(haus.CodeCannotEncode, "%s takes a %T, not a %T", c.id, t, x)
	}
	return c.encode(t)
}

// Codecs is a set of codecs, at most one per type id.
type Codecs struct {
	byID map[string]Codec
}

// NewCodecs returns the codecs, which must be for different types.
func NewCodecs(codecs ...Codec) (*Codecs, error) {
	c := &Codecs{byID: map[string]Codec{}}
	for _, codec := range codecs {
		id := codec.TypeID()
		if _, dup := c.byID[id]; dup {
			return nil, fmt.Errorf("two codecs for the type %s", id)
		}
		c.byID[id] = codec
	}
	return c, nil
}

// forType returns the codec for a named type without arguments, or nil.
func (c *Codecs) forType(t *typ) Codec {
	switch {
	case len(c.byID) == 0:
		return nil
	case t.kind == kRef && len(t.inst.args) == 0:
		return c.byID[t.inst.id]
	case t.kind == kTime:
		return c.byID["std/time#"+t.name]
	}
	return nil
}

func (w *walker) applyCodec(codec Codec, v haus.Value, changed bool) (haus.Value, bool, error) {
	if _, err := codec.Decode(v); err != nil {
		code := codeOf(err)
		if code == "" {
			code = haus.CodeTypeMismatch
		}
		return nil, false, w.fail(code, "%s rejects the value: %s", codec.TypeID(), messageOf(err))
	}
	return v, changed, nil
}

// ID returns the type's id (spec §13.3): @haus-fmt/money@1#Money, or
// std/time#Instant for a name that stands for a std/time type.
func (t Type) ID() string {
	if t.t == nil {
		return ""
	}
	return t.t.inst.id
}

// DecodeAs decodes v with the type and then with the codec, which must be
// for the type itself or for the std/time type it stands for, and returns
// the host value.
func DecodeAs[T any](t Type, v haus.Value, codec Codec) (T, error) {
	var zero T
	out, err := t.Decode(v)
	if err != nil {
		return zero, err
	}
	if id := hostID(t); id != codec.TypeID() {
		return zero, fmt.Errorf("the codec is for %s, not for %s", codec.TypeID(), id)
	}
	x, err := codec.Decode(out)
	if err != nil {
		code := codeOf(err)
		if code == "" {
			code = haus.CodeTypeMismatch
		}
		return zero, &haus.Error{Code: code, Message: fmt.Sprintf("%s rejects the value: %s", codec.TypeID(), messageOf(err)), Path: "$"}
	}
	host, ok := x.(T)
	if !ok {
		return zero, fmt.Errorf("the codec for %s gives a %T, not a %T", codec.TypeID(), x, zero)
	}
	return host, nil
}

// EncodeFrom encodes a host value with the codec and checks the result
// against the type, as [Type.Encode] does.
func EncodeFrom[T any](t Type, x T, codec Codec) (haus.Value, error) {
	v, err := codec.Encode(x)
	if err != nil {
		return nil, err
	}
	return t.Encode(v)
}

// hostID is the id a codec for the type is selected by.
func hostID(t Type) string {
	if t.t == nil {
		return ""
	}
	if body := t.t.inst.resolved; body.kind == kTime && t.t.inst.body.kind != kRef {
		return "std/time#" + body.name
	}
	return t.t.inst.id
}

// InstantTime is an opt-in codec from std/time's Instant to time.Time,
// which holds the whole range of the type. It keeps the instant and its
// offset, and drops the spelling (spec §13.4): Z and +00:00 both encode
// as Z, and trailing zeros of a fraction are dropped, so encoding gives a
// value that means the same but is not equal (§2), with another hash.
var InstantTime = NewCodec("std/time#Instant",
	func(v haus.Value) (time.Time, error) {
		text, _ := v.(haus.Variant).Args[0].(haus.String)
		return time.Parse(time.RFC3339Nano, string(text))
	},
	func(t time.Time) (haus.Value, error) {
		if y := t.Year(); y < 0 || y > 9999 {
			return nil, newError(haus.CodeCannotEncode, "the year %d is outside 0000–9999", y)
		}
		return haus.Variant{Tag: "Instant", Args: []haus.Value{haus.String(t.Format(time.RFC3339Nano))}}, nil
	})

// Secret holds a value that must not end up in logs (spec §15), such as an
// API key: printed, formatted, logged or converted to JSON it shows
// <redacted>, and [Secret.Reveal] gives it out. It is the host type of
// Secret a for typed decoding; the data is the same as for a.
type Secret[T any] struct {
	value T
}

// NewSecret wraps a value.
func NewSecret[T any](v T) Secret[T] { return Secret[T]{v} }

// Reveal returns the value.
func (s Secret[T]) Reveal() T { return s.value }

const redacted = "<redacted>"

// String returns <redacted>.
func (Secret[T]) String() string { return redacted }

// GoString returns <redacted>, for %#v.
func (Secret[T]) GoString() string { return redacted }

// Format writes <redacted> for every verb.
func (Secret[T]) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte(redacted)) }

// MarshalJSON writes "<redacted>".
func (Secret[T]) MarshalJSON() ([]byte, error) { return []byte(`"` + redacted + `"`), nil }

// MarshalText writes <redacted>.
func (Secret[T]) MarshalText() ([]byte, error) { return []byte(redacted), nil }

// LogValue logs <redacted> with log/slog.
func (Secret[T]) LogValue() slog.Value { return slog.StringValue(redacted) }
