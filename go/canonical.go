package haus

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"hash"
	"slices"
	"strings"
	"unicode/utf8"
)

// Canonical returns the canonical form of a value (spec §12): one exact text,
// so that two values are equal exactly when their canonical forms are
// identical. Records are sorted by key, numbers normalized and in decimal,
// and there is no whitespace outside strings.
//
// It fails only for values built in code that have no text: a tag that
// isn't [A-Z][A-Za-z0-9_]* (invalid-tag), a string or key that isn't UTF-8
// (cannot-encode), a value that contains itself (cyclic-value), or nesting
// deeper than [MaxSupportedDepth] (nesting-too-deep).
func Canonical(v Value) (string, error) {
	b, err := AppendCanonical(nil, v)
	return string(b), err
}

// AppendCanonical appends the canonical form of a value to b. See [Canonical].
func AppendCanonical(b []byte, v Value) ([]byte, error) {
	w := canonicalWriter{b: b, check: true}
	err := w.value(v, 0)
	return w.b, err
}

// Equals reports whether two values are equal (spec §2): numbers by their
// normalized literals, strings by code points, records by their sets of keys
// whatever the order, variants by tag and arguments.
//
// Values nested deeper than [MaxSupportedDepth] compare unequal, which ends
// the comparison of values that contain themselves.
func Equals(a, b Value) bool {
	return equals(a, b, 0)
}

func equals(a, b Value, depth int) bool {
	if depth > MaxSupportedDepth {
		return false
	}
	eq := func(x, y Value) bool { return equals(x, y, depth+1) }
	switch a := a.(type) {
	case Number:
		b, ok := b.(Number)
		return ok && a.String() == b.String()
	case String:
		b, ok := b.(String)
		return ok && a == b
	case Bytes:
		b, ok := b.(Bytes)
		return ok && bytes.Equal(a, b)
	case Array:
		b, ok := b.(Array)
		return ok && (sameItems(a, b) || slices.EqualFunc(a, b, eq))
	case Record:
		b, ok := b.(Record)
		if !ok || a.Len() != b.Len() {
			return false
		}
		for _, f := range a.fields {
			if w, ok := b.Get(f.Key); !ok || !eq(f.Value, w) {
				return false
			}
		}
		return true
	case Variant:
		b, ok := b.(Variant)
		return ok && a.Tag == b.Tag && (sameItems(a.Args, b.Args) || slices.EqualFunc(a.Args, b.Args, eq))
	}
	return false
}

// sameItems reports whether two slices are the same items in memory, and so
// equal without looking at them.
func sameItems(a, b []Value) bool {
	return len(a) > 0 && len(a) == len(b) && &a[0] == &b[0]
}

// Compare orders values by the bytes of their canonical forms, shorter first
// when one is a prefix of the other (spec §12). It is a total order
// consistent with [Equals], for sorting; it is not numeric order (10 sorts
// before 9). It returns -1, 0 or +1.
func Compare(a, b Value) int {
	wa := canonicalWriter{}
	_ = wa.value(a, 0) // writes what it can of a value without text
	wb := canonicalWriter{}
	_ = wb.value(b, 0)
	return bytes.Compare(wa.b, wb.b)
}

// Hash returns the SHA-256 digest of the canonical form of a value, as 64
// lowercase hex digits (spec §12). It fails as [Canonical] does.
func Hash(v Value) (string, error) {
	h := NewHasher()
	if err := h.Add(v); err != nil {
		return "", err
	}
	return h.Sum(), nil
}

// HashAll returns the hash of a list of values, such as a whole file or
// stream (spec §12): the SHA-256 digest of their canonical forms joined by
// ",". A list of one value hashes like the value, and the empty list to the
// digest of the empty text.
func HashAll(vs []Value) (string, error) {
	h := NewHasher()
	for _, v := range vs {
		if err := h.Add(v); err != nil {
			return "", err
		}
	}
	return h.Sum(), nil
}

// Hasher computes [HashAll] value by value, as a stream is read: memory
// stays bounded by the largest value, and the hash of the values added so
// far is available at any time. The zero Hasher is not usable; call
// [NewHasher].
type Hasher struct {
	h   hash.Hash
	n   int
	buf []byte
}

// NewHasher returns a Hasher of the empty list.
func NewHasher() *Hasher {
	return &Hasher{h: sha256.New()}
}

// Add adds a value to the list. It fails as [Canonical] does, and then
// leaves the Hasher unchanged.
func (h *Hasher) Add(v Value) error {
	w := canonicalWriter{b: h.buf[:0], check: true}
	if h.n > 0 {
		w.b = append(w.b, ',')
	}
	if err := w.value(v, 0); err != nil {
		return err
	}
	h.h.Write(w.b)
	h.buf = w.b
	h.n++
	return nil
}

// Count returns the number of values added.
func (h *Hasher) Count() int { return h.n }

// Sum returns the hash of the values added so far, as 64 lowercase hex
// digits. It doesn't change the Hasher.
func (h *Hasher) Sum() string {
	return hex.EncodeToString(h.h.Sum(nil))
}

// canonicalWriter writes the canonical form. With check, it fails for values
// without text; without, it writes what it can.
type canonicalWriter struct {
	b     []byte
	check bool
	guard cycleGuard
}

// enter starts the container v at depth. Also without check, the depth
// limit ends a value that contains itself.
func (w *canonicalWriter) enter(v Value, depth int) error {
	if depth >= MaxSupportedDepth {
		return w.guard.depthError(v, MaxSupportedDepth)
	}
	w.guard.push(v)
	return nil
}

func (w *canonicalWriter) value(v Value, depth int) error {
	switch v := v.(type) {
	case Number:
		w.b = append(w.b, v.String()...)
	case String:
		if !utf8.ValidString(string(v)) && w.check {
			return w.fail(newError(CodeCannotEncode, "a string that isn't valid UTF-8"))
		}
		w.b = appendQuoted(w.b, string(v))
	case Bytes:
		w.b = append(w.b, `x"`...)
		w.b = hex.AppendEncode(w.b, v)
		w.b = append(w.b, '"')
	case Array:
		if err := w.enter(v, depth); err != nil {
			return err
		}
		w.b = append(w.b, '[')
		for i, e := range v {
			if i > 0 {
				w.b = append(w.b, ',')
			}
			if err := w.value(e, depth+1); err != nil {
				return err
			}
		}
		w.b = append(w.b, ']')
		w.guard.pop()
	case Record:
		return w.record(v, depth)
	case Variant:
		if !isTag(v.Tag) && w.check {
			return w.fail(newError(CodeInvalidTag, "the tag "+quoteForMessage(v.Tag)+" isn't [A-Z][A-Za-z0-9_]*"))
		}
		w.b = append(w.b, v.Tag...)
		if len(v.Args) == 0 {
			return nil
		}
		if r, ok := v.Args[0].(Record); ok && len(v.Args) == 1 {
			return w.record(r, depth)
		}
		if err := w.enter(v, depth); err != nil {
			return err
		}
		w.b = append(w.b, '(')
		for i, a := range v.Args {
			if i > 0 {
				w.b = append(w.b, ',')
			}
			if err := w.value(a, depth+1); err != nil {
				return err
			}
		}
		w.b = append(w.b, ')')
		w.guard.pop()
	default:
		if w.check {
			return w.fail(newError(CodeCannotEncode, "a nil value"))
		}
	}
	return nil
}

func (w *canonicalWriter) record(r Record, depth int) error {
	if err := w.enter(r, depth); err != nil {
		return err
	}
	defer w.guard.pop()
	fields := r.fields
	if !slices.IsSortedFunc(fields, compareKeys) {
		fields = slices.Clone(fields)
		slices.SortFunc(fields, compareKeys)
	}
	w.b = append(w.b, '{')
	for i, f := range fields {
		if i > 0 {
			w.b = append(w.b, ',')
		}
		if isIdent(f.Key) {
			w.b = append(w.b, f.Key...)
		} else {
			if !utf8.ValidString(f.Key) && w.check {
				return w.fail(newError(CodeCannotEncode, "a key that isn't valid UTF-8"))
			}
			w.b = appendQuoted(w.b, f.Key)
		}
		w.b = append(w.b, ':')
		if err := w.value(f.Value, depth+1); err != nil {
			return err
		}
	}
	w.b = append(w.b, '}')
	return nil
}

// compareKeys orders keys by their UTF-8 bytes, which is code point order.
func compareKeys(a, b Field) int { return strings.Compare(a.Key, b.Key) }

func (w *canonicalWriter) fail(err *Error) error {
	if w.check {
		return err
	}
	return nil
}
