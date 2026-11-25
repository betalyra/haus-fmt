package haus

import (
	"fmt"
	"log/slog"
)

// Secret is the value of a Secret type (spec §15) as a decoder that applies
// a schema gives it, such as schema.Type.Decode: the value is hidden, and
// only [Secret.Reveal] gives it out. Printed, formatted, logged or converted
// to JSON with encoding/json it shows <redacted>.
//
// A secret is not a value of the format: the text has none, and the parser
// never gives one. Writers that don't apply the secret's schema refuse it,
// with cannot-encode and a message that doesn't show it: [FormatValue],
// [ToHausJSON], [Canonical], [Hash], [CheckValue]. Encoding with
// the schema (schema.Type.Encode, Format, ToJSON) writes the value in full,
// so decoding and encoding again keeps it. [Equals] finds a secret equal to
// nothing.
type Secret struct {
	// A pointer, which fmt shows as an address where it can't call Format
	// (a secret inside a Record's unexported fields).
	hidden *hiddenValue
}

type hiddenValue struct{ value Value }

// NewSecret hides v.
func NewSecret(v Value) Secret { return Secret{&hiddenValue{v}} }

// Reveal returns the hidden value; nil for the zero Secret.
func (s Secret) Reveal() Value {
	if s.hidden == nil {
		return nil
	}
	return s.hidden.value
}

// Kind returns KindSecret.
func (Secret) Kind() Kind { return KindSecret }

func (Secret) isValue() {}

const redacted = "<redacted>"

// String returns <redacted>.
func (Secret) String() string { return redacted }

// GoString returns <redacted>, for %#v.
func (Secret) GoString() string { return redacted }

// Format writes <redacted> for every verb.
func (Secret) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte(redacted)) }

// MarshalJSON writes "<redacted>".
func (Secret) MarshalJSON() ([]byte, error) { return []byte(`"` + redacted + `"`), nil }

// MarshalText writes <redacted>.
func (Secret) MarshalText() ([]byte, error) { return []byte(redacted), nil }

// LogValue logs <redacted> with log/slog.
func (Secret) LogValue() slog.Value { return slog.StringValue(redacted) }

// secretRefused is the message of the writers' cannot-encode for a secret.
const secretRefused = "a Secret, which is written only with its schema (schema.Type.Encode): its value is not shown"
