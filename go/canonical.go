package haus

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Canonical returns the canonical form of a value (spec §12): one exact text,
// so that two values are equal exactly when their canonical forms are
// identical. Records are sorted by key, numbers normalized and in decimal,
// and there is no whitespace outside strings.
//
// It applies one limit, the node limit (spec §7, default
// [DefaultMaxNodes]; [CanonicalWith] sets another): a value whose parts
// share one another so much that its canonical form would hold more values
// fails with too-many-nodes. No other limit applies: a value deeper or
// longer than a writer's limits still has a canonical form. Besides that it
// fails only for what Go lets code build past the constructors: a nil
// [Value], the zero [Tag] or a [String] that isn't valid UTF-8
// (cannot-encode), a value that contains itself (cyclic-value), and nesting
// deeper than this binding supports, [MaxSupportedDepth] (nesting-too-deep).
func Canonical(v Value) (string, error) {
	return CanonicalWith(v, Limits{})
}

// CanonicalWith is [Canonical] with the node limit of limits
// ([Limits.MaxNodes]; zero takes the default). The other limits don't apply
// to the canonical form.
func CanonicalWith(v Value, limits Limits) (string, error) {
	w := newCanonicalWriter(nil, limits)
	err := w.top(v)
	return string(w.b), err
}

// AppendCanonical appends the canonical form of a value to b. See [Canonical].
func AppendCanonical(b []byte, v Value) ([]byte, error) {
	w := newCanonicalWriter(b, Limits{})
	err := w.top(v)
	return w.b, err
}

// Equals reports whether two values are equal (spec §2): numbers by their
// normalized literals, strings by code points, records by their sets of keys
// whatever the order, variants by tag and arguments. It compares the values
// themselves, not their canonical forms, so no limit applies.
//
// It compares structurally and applies no node limit: a value built in code
// whose parts share each other heavily (an array holding the same array
// twice, many levels deep) can take very long to compare, as long as writing
// it out would. A parsed value can't share its parts, so it compares in time
// linear in its size.
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
// before 9). It returns -1, 0 or +1, and fails as [Canonical] does: with
// too-many-nodes for a value over the node limit.
func Compare(a, b Value) (int, error) {
	ca, err := AppendCanonical(nil, a)
	if err != nil {
		return 0, err
	}
	cb, err := AppendCanonical(nil, b)
	if err != nil {
		return 0, err
	}
	return bytes.Compare(ca, cb), nil
}

// Hash returns the SHA-256 digest of the canonical form of a value, as 64
// lowercase hex digits (spec §12). It fails as [Canonical] does.
func Hash(v Value) (string, error) {
	return HashWith(v, Limits{})
}

// HashWith is [Hash] with the node limit of limits ([Limits.MaxNodes]).
func HashWith(v Value, limits Limits) (string, error) {
	w := newCanonicalWriter(nil, limits)
	if err := w.top(v); err != nil {
		return "", err
	}
	return w.digest(), nil
}

// HashAll returns the hash of a list of values, such as a whole file (spec
// §12): the SHA-256 digest of their canonical forms joined by ",". A list of
// one value hashes like the value, and the empty list to the digest of the
// empty text. The items of a stream are hashed one by one with [Hash]. The
// node limit applies to each value on its own: too-many-nodes at $[i] for
// the i-th value.
func HashAll(vs []Value) (string, error) {
	return HashAllWith(vs, Limits{})
}

// HashAllWith is [HashAll] with the node limit of limits ([Limits.MaxNodes]).
func HashAllWith(vs []Value, limits Limits) (string, error) {
	w := newCanonicalWriter(nil, limits)
	for i, v := range vs {
		if i > 0 {
			w.b = append(w.b, ',')
		}
		w.index = i
		if err := w.top(v); err != nil {
			return "", err
		}
	}
	return w.digest(), nil
}

// canonicalWriter writes the canonical form, within the node limit and the
// depth this binding supports.
type canonicalWriter struct {
	b        []byte
	maxNodes int
	nodes    int
	guard    cycleGuard
	// index is the place of the value being written among several
	// ([HashAll]): too-many-nodes is at $[index]; -1 for one value, at $.
	index int
}

func newCanonicalWriter(b []byte, limits Limits) canonicalWriter {
	maxNodes := limits.MaxNodes
	if maxNodes <= 0 {
		maxNodes = DefaultMaxNodes
	}
	return canonicalWriter{b: b, maxNodes: maxNodes, index: -1}
}

// digest is the SHA-256 digest of what was written, as 64 lowercase hex digits.
func (w *canonicalWriter) digest() string {
	sum := sha256.Sum256(w.b)
	return hex.EncodeToString(sum[:])
}

// top writes one top-level value, which has the node limit to itself.
func (w *canonicalWriter) top(v Value) error {
	w.nodes = 0
	return w.value(v, 0)
}

// count counts one more value written, against the node limit.
func (w *canonicalWriter) count() error {
	w.nodes++
	if w.nodes > w.maxNodes {
		place := "$"
		if w.index >= 0 {
			place = "$[" + strconv.Itoa(w.index) + "]"
		}
		return tooManyNodes(w.maxNodes, place)
	}
	return nil
}

// enter starts the container v at depth. The depth this binding supports
// ends a value that contains itself (cyclic-value) and bounds the stack.
func (w *canonicalWriter) enter(v Value, depth int) error {
	if depth >= MaxSupportedDepth {
		return w.guard.depthError(v, MaxSupportedDepth)
	}
	w.guard.push(v)
	return nil
}

func (w *canonicalWriter) value(v Value, depth int) error {
	if err := w.count(); err != nil {
		return err
	}
	switch v := v.(type) {
	case Number:
		w.b = append(w.b, v.String()...)
	case String:
		if !utf8.ValidString(string(v)) {
			return newError(CodeCannotEncode, "a string that isn't valid UTF-8")
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
		if v.Tag.IsZero() {
			return newError(CodeCannotEncode, "a variant with the zero Tag, which holds no tag")
		}
		w.b = append(w.b, v.Tag.name...)
		if len(v.Args) == 0 {
			return nil
		}
		if r, ok := v.Args[0].(Record); ok && len(v.Args) == 1 {
			if err := w.count(); err != nil {
				return err
			}
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
		return newError(CodeCannotEncode, "a nil value")
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
			if !utf8.ValidString(f.Key) {
				return newError(CodeCannotEncode, "a key that isn't valid UTF-8")
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
