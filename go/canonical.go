package haus

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
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
// longer than a writer's limits still has a canonical form, and any depth
// works: the value is walked with a stack of its own, not the call stack,
// so the depth is bounded only by memory. Besides that it fails only for
// what Go lets code build past the constructors: a nil [Value], the zero
// [Tag] or a [String] that isn't valid UTF-8 (cannot-encode), and a value
// that contains itself (cyclic-value).
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
// Any depth works: the values are walked with a stack of their own, not the
// call stack, so the depth is bounded only by memory. A value built in code
// that contains itself, which is no haus value, compares unequal.
func Equals(a, b Value) bool {
	var stack []equalsFrame
	for {
		var f equalsFrame
		switch x := a.(type) {
		case Number:
			y, ok := b.(Number)
			if !ok || x.String() != y.String() {
				return false
			}
		case String:
			if y, ok := b.(String); !ok || x != y {
				return false
			}
		case Bytes:
			if y, ok := b.(Bytes); !ok || !bytes.Equal(x, y) {
				return false
			}
		case Array:
			y, ok := b.(Array)
			if !ok || len(x) != len(y) {
				return false
			}
			if !sameItems(x, y) {
				f = equalsFrame{as: x, bs: y}
			}
		case Record:
			y, ok := b.(Record)
			if !ok || x.Len() != y.Len() {
				return false
			}
			f = equalsFrame{ra: x, rb: y, record: true}
		case Variant:
			y, ok := b.(Variant)
			if !ok || x.Tag != y.Tag || len(x.Args) != len(y.Args) {
				return false
			}
			if !sameItems(x.Args, y.Args) {
				f = equalsFrame{as: x.Args, bs: y.Args}
			}
		default:
			return false
		}
		if f.len() > 0 {
			f.id, _ = idOf(a)
			stack = append(stack, f)
			if deepCycle(len(stack), func(i int) containerID { return stack[i].id }) {
				return false
			}
		}
		// The next pair to compare: the next item of the innermost container
		// not done.
		for {
			if len(stack) == 0 {
				return true
			}
			top := &stack[len(stack)-1]
			if top.i < top.len() {
				if top.record {
					field := top.ra.fields[top.i]
					w, ok := top.rb.Get(field.Key)
					if !ok {
						return false
					}
					a, b = field.Value, w
				} else {
					a, b = top.as[top.i], top.bs[top.i]
				}
				top.i++
				break
			}
			stack = stack[:len(stack)-1]
		}
	}
}

// equalsFrame is a pair of containers being compared by [Equals], and the
// index of the next item to compare.
type equalsFrame struct {
	as, bs []Value // arrays or arguments
	ra, rb Record  // records, if record
	record bool
	i      int
	id     containerID // the first container's
}

func (f *equalsFrame) len() int {
	if f.record {
		return f.ra.Len()
	}
	return len(f.as)
}

// deepCycle reports whether the container entered last, at depth n (the
// last of n ids on the path from the root), is already on the path: a value
// built in code that contains itself. It looks only at depths that are
// powers of two from 1024 on, which costs O(1) per level in all and finds
// every cycle by twice the depth where it ends: below a cycle the path
// repeats with its period.
func deepCycle(n int, id func(i int) containerID) bool {
	if n < 1024 || n&(n-1) != 0 {
		return false
	}
	last := id(n - 1)
	for i := range n - 1 {
		if id(i) == last {
			return true
		}
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
// too-many-nodes for a value over the node limit. The error is at $ for either
// value; its message says which (spec §12).
func Compare(a, b Value) (int, error) {
	ca, err := AppendCanonical(nil, a)
	if err != nil {
		return 0, operand(err, "first")
	}
	cb, err := AppendCanonical(nil, b)
	if err != nil {
		return 0, operand(err, "second")
	}
	return bytes.Compare(ca, cb), nil
}

// operand says in the message of err which operand of [Compare] it is about.
func operand(err error, which string) error {
	if e := (*Error)(nil); errors.As(err, &e) {
		e.Message = "the " + which + " value: " + e.Message
	}
	return err
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

// canonicalWriter writes the canonical form, within the node limit.
type canonicalWriter struct {
	b        []byte
	maxNodes int
	nodes    int
	stack    []canonicalFrame // the containers being written, kept for the next value
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
	return w.value(v)
}

// count counts one more value written, against the node limit.
func (w *canonicalWriter) count() error {
	w.nodes++
	if w.nodes > w.maxNodes {
		return tooManyNodes(w.maxNodes, w.place())
	}
	return nil
}

// place is the place of the value being written: $, or $[i] in [HashAll].
func (w *canonicalWriter) place() string {
	if w.index >= 0 {
		return "$[" + strconv.Itoa(w.index) + "]"
	}
	return "$"
}

// canonicalFrame is a container being written: its items (or its fields,
// sorted by key), the next one to write, and its closing bracket.
type canonicalFrame struct {
	items  []Value
	fields []Field
	i      int
	close  byte
	id     containerID // the container's, to find one that contains itself
}

func (f *canonicalFrame) len() int { return len(f.items) + len(f.fields) }

// value writes v with a stack of its own rather than recursion, so that any
// depth works (spec §12): the depth is bounded only by memory.
func (w *canonicalWriter) value(v Value) error {
	stack := w.stack[:0]
	defer func() { w.stack = stack[:0] }()
	for {
		if err := w.count(); err != nil {
			return err
		}
		var f canonicalFrame
		switch x := v.(type) {
		case Number:
			w.b = append(w.b, x.String()...)
		case String:
			if !utf8.ValidString(string(x)) {
				return newError(CodeCannotEncode, "a string that isn't valid UTF-8")
			}
			w.b = appendQuoted(w.b, string(x))
		case Bytes:
			w.b = append(w.b, `x"`...)
			w.b = hex.AppendEncode(w.b, x)
			w.b = append(w.b, '"')
		case Array:
			w.b = append(w.b, '[')
			f = canonicalFrame{items: x, close: ']'}
		case Record:
			f = w.openRecord(x)
		case Variant:
			if x.Tag.IsZero() {
				return newError(CodeCannotEncode, "a variant with the zero Tag, which holds no tag")
			}
			w.b = append(w.b, x.Tag.name...)
			switch {
			case len(x.Args) == 0:
			case len(x.Args) == 1 && isRecord(x.Args[0]):
				// Tag { … }: the record is a value of its own (spec §7).
				if err := w.count(); err != nil {
					return err
				}
				f = w.openRecord(x.Args[0].(Record))
			default:
				w.b = append(w.b, '(')
				f = canonicalFrame{items: x.Args, close: ')'}
			}
		case Secret:
			return &Error{Code: CodeCannotEncode, Path: w.place(), Message: secretRefused}
		case nil:
			return newError(CodeCannotEncode, "a nil value")
		default:
			return newError(CodeCannotEncode, "an unknown kind of value")
		}
		switch {
		case f.close == 0:
		case f.len() == 0:
			w.b = append(w.b, f.close)
		default:
			f.id, _ = idOf(v)
			stack = append(stack, f)
			if deepCycle(len(stack), func(i int) containerID { return stack[i].id }) {
				return &Error{Code: CodeCyclicValue, Path: w.place(), Message: "the value contains itself, so it has no finite text"}
			}
		}
		// The next value to write: the next item of the innermost container
		// not done, after its closing brackets.
		for {
			if len(stack) == 0 {
				return nil
			}
			top := &stack[len(stack)-1]
			if top.i < top.len() {
				if top.i > 0 {
					w.b = append(w.b, ',')
				}
				if top.fields != nil {
					field := top.fields[top.i]
					if err := w.key(field.Key); err != nil {
						return err
					}
					v = field.Value
				} else {
					v = top.items[top.i]
				}
				top.i++
				break
			}
			w.b = append(w.b, top.close)
			stack = stack[:len(stack)-1]
		}
	}
}

func isRecord(v Value) bool {
	_, ok := v.(Record)
	return ok
}

// openRecord writes the { of a record and returns its frame, with its
// fields sorted by key.
func (w *canonicalWriter) openRecord(r Record) canonicalFrame {
	fields := r.fields
	if !slices.IsSortedFunc(fields, compareKeys) {
		fields = slices.Clone(fields)
		slices.SortFunc(fields, compareKeys)
	}
	w.b = append(w.b, '{')
	if fields == nil {
		fields = []Field{}
	}
	return canonicalFrame{fields: fields, close: '}'}
}

// key writes a record key and its colon.
func (w *canonicalWriter) key(k string) error {
	if isIdent(k) {
		w.b = append(w.b, k...)
	} else {
		if !utf8.ValidString(k) {
			return newError(CodeCannotEncode, "a key that isn't valid UTF-8")
		}
		w.b = appendQuoted(w.b, k)
	}
	w.b = append(w.b, ':')
	return nil
}

// compareKeys orders keys by their UTF-8 bytes, which is code point order.
func compareKeys(a, b Field) int { return strings.Compare(a.Key, b.Key) }
