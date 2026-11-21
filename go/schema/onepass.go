package schema

import (
	"slices"

	haus "github.com/betalyra/haus-fmt/go"
)

// Parse reads text that holds exactly one value and decodes it with the
// type, with the default limits: the value and the error of [haus.Parse]
// followed by [Type.Decode].
func (t Type) Parse(src []byte) (haus.Value, error) {
	return t.ParseWith(src, DecodeOptions{})
}

// ParseWith is [Type.Parse] with options, whose limits are those of both
// the parser and decoding: [haus.ParseWith] followed by [Type.DecodeWith].
// Parts of the value an Any keeps are not checked again: values the parser
// returns are within the limits they were read with.
func (t Type) ParseWith(src []byte, opts DecodeOptions) (haus.Value, error) {
	v, err := haus.ParseWith(src, opts.Limits)
	if err != nil {
		// A text that doesn't hold one value is wrong as a whole: the
		// error is at the value's root, $ (spec §15).
		if e, ok := err.(*haus.Error); ok && e.Code == haus.CodeNotOneValue && e.Path == "" {
			e.Path = "$"
		}
		return nil, err
	}
	if t.t == nil {
		return nil, newError(haus.CodeUnknownType, "a zero Type: get one with Schema.Type")
	}
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		return nil, err
	}
	w := newWalker(lim, v, nil)
	w.codecs = opts.Codecs
	w.plain = opts.Codecs.none()
	// A text of n bytes holds at most n values, so CheckValue's node limit
	// can't be reached either.
	w.parsed = len(src) <= lim.MaxNodes
	out, _, err := w.value(v, t.t)
	w.release()
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Format encodes v with the type and writes the result as a file holding
// it alone, with opts.Limits the limits of both: the text and the error of
// [Type.Encode] followed by [haus.FormatValue]. In the compact and
// minimised layouts the value is written as it is checked, in one pass,
// without building the encoded value. A negative indent or width fails
// with [haus.ErrInvalidOptions] before v is looked at.
func (t Type) Format(v haus.Value, opts haus.FormatOptions) ([]byte, error) {
	if err := opts.Check(); err != nil {
		return nil, err
	}
	if text, ok := t.formatOnePass(v, opts); ok {
		return text, nil
	}
	// The pretty layout, and every error: two passes, which say which
	// error comes first.
	out, err := t.EncodeWith(v, DecodeOptions{Limits: opts.Limits})
	if err != nil {
		return nil, err
	}
	return haus.FormatValue(out, opts)
}

// formatOnePass writes v as Format does, in one pass, for the compact and
// minimised layouts; false means it didn't (an error, or a check left to
// the two passes).
func (t Type) formatOnePass(v haus.Value, opts haus.FormatOptions) ([]byte, bool) {
	if t.t == nil || opts.Layout == haus.Pretty {
		return nil, false
	}
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		return nil, false
	}
	w := newWalker(lim, v, nil)
	defer w.release()
	w.encoding, w.writing, w.minimised = true, true, opts.Layout == haus.Minimised
	if _, _, err := w.value(v, t.t); err != nil || w.tooLong {
		return nil, false
	}
	w.b = append(w.b, '\n')
	if cap(w.b) > maxPooledBuffer {
		text := w.b
		w.b = nil // too large to keep: the caller's
		return text, true
	}
	return slices.Clone(w.b), true
}
