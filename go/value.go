package haus

import (
	"iter"
	"math/big"
	"slices"
	"unicode/utf8"
)

// Kind is the kind of a [Value] (spec §1).
type Kind int

// The six kinds of value.
const (
	KindNumber Kind = iota + 1
	KindString
	KindBytes
	KindArray
	KindRecord
	KindVariant
)

// String returns the kind's name in lowercase, such as "record".
func (k Kind) String() string {
	switch k {
	case KindNumber:
		return "number"
	case KindString:
		return "string"
	case KindBytes:
		return "bytes"
	case KindArray:
		return "array"
	case KindRecord:
		return "record"
	case KindVariant:
		return "variant"
	}
	return "invalid"
}

// Value is a haus value (spec §1): a [Number], [String], [Bytes], [Array],
// [Record] or [Variant]. The set is closed: no other type implements Value.
//
// Use a type switch to tell the kinds apart:
//
//	switch v := v.(type) {
//	case haus.Record:
//		name, ok := v.Get("name")
//	case haus.Variant:
//		fmt.Println(v.Tag, len(v.Args))
//	}
type Value interface {
	// Kind reports which of the six kinds the value is.
	Kind() Kind
	isValue()
}

// String is a string value: a sequence of Unicode code points, held as UTF-8.
// The parser only produces valid UTF-8; writers reject a String built in code
// that isn't (code cannot-encode).
type String string

// Bytes is a byte string, written x"0b34ff".
type Bytes []byte

// Array is an ordered sequence of values.
type Array []Value

// Field is one entry of a [Record].
type Field struct {
	Key   string
	Value Value
}

// Record is a set of fields with distinct string keys, in the order they were
// written. Field order is kept for formatting but doesn't take part in
// equality (spec §2). The zero Record is the empty record.
type Record struct {
	fields []Field
	index  map[string]int // nil for small records, which are searched in order
}

// indexFrom is the number of fields from which a Record keeps a hash index;
// smaller records are searched in order. Go maps are seeded at random, as
// spec §7 asks of duplicate-key checks.
const indexFrom = 17

// Number is an exact decimal number (spec §3), kept as its normalized literal
// (spec §2): digit separators removed, the exponent written e and its value,
// and hex and binary literals converted to decimal. Scale and notation are
// part of the value: 1.0 and 1 are different numbers, and so are 1e2 and 100.
//
// The zero Number is 0.
type Number struct {
	lit string
}

// Variant is a tag with zero or more argument values: None, Some(1),
// Circle { r: 1 }. A record payload, Tag { … }, is one Record argument.
//
//	some := haus.Variant{Tag: haus.MustTag("Some"), Args: []haus.Value{haus.NumberFromInt(1)}}
type Variant struct {
	Tag  Tag
	Args []Value
}

// Tag is the tag of a [Variant]: a name that matches [A-Z][A-Za-z0-9_]*
// (spec §4), such as None or EUR. [NewTag] checks the name, so a Tag always
// holds a tag, and a variant with an invalid tag can't be built. Only the
// zero Tag holds none: writers and the canonical form reject a variant with
// it (cannot-encode), as they reject a nil [Value].
//
// Tags are comparable: v.Tag == haus.MustTag("None").
type Tag struct {
	name string
}

// NewTag returns the tag name. It fails with the code invalid-tag if name
// doesn't match [A-Z][A-Za-z0-9_]*. It applies no length limit: a writer
// does (tag-too-long, spec §7).
func NewTag(name string) (Tag, error) {
	if !isTag(name) {
		return Tag{}, newError(CodeInvalidTag, "the tag "+quoteForMessage(name)+" isn't [A-Z][A-Za-z0-9_]*")
	}
	return Tag{name: name}, nil
}

// MustTag is like [NewTag] but panics if name isn't a tag. It is for tags
// known when the program is written, such as MustTag("Some").
func MustTag(name string) Tag {
	t, err := NewTag(name)
	if err != nil {
		panic("haus.MustTag: " + err.Error())
	}
	return t
}

// String returns the tag's name, such as "Some"; "" for the zero Tag.
func (t Tag) String() string { return t.name }

// IsZero reports whether t is the zero Tag, which holds no tag.
func (t Tag) IsZero() bool { return t.name == "" }

// Kind returns KindString.
func (String) Kind() Kind { return KindString }

// Kind returns KindBytes.
func (Bytes) Kind() Kind { return KindBytes }

// Kind returns KindArray.
func (Array) Kind() Kind { return KindArray }

// Kind returns KindNumber.
func (Number) Kind() Kind { return KindNumber }

// Kind returns KindRecord.
func (Record) Kind() Kind { return KindRecord }

// Kind returns KindVariant.
func (Variant) Kind() Kind { return KindVariant }

func (String) isValue()  {}
func (Bytes) isValue()   {}
func (Array) isValue()   {}
func (Number) isValue()  {}
func (Record) isValue()  {}
func (Variant) isValue() {}

// NewRecord builds a record from fields, in order. It fails with the code
// duplicate-key if two fields have the same key, and cannot-encode for a key
// that isn't valid UTF-8. It applies no length limit: a writer does
// (key-too-long, spec §7).
func NewRecord(fields ...Field) (Record, error) {
	r := Record{fields: slices.Clone(fields)}
	if len(fields) >= indexFrom {
		r.index = make(map[string]int, len(fields))
	}
	for i, f := range r.fields {
		if !utf8.ValidString(f.Key) {
			return Record{}, newError(CodeCannotEncode, "a key that isn't valid UTF-8")
		}
		if r.has(f.Key, i) {
			return Record{}, newError(CodeDuplicateKey, "duplicate key "+quoteForMessage(f.Key))
		}
		if r.index != nil {
			r.index[f.Key] = i
		}
	}
	return r, nil
}

// has reports whether one of the first n fields has the key.
func (r Record) has(key string, n int) bool {
	if r.index != nil {
		_, ok := r.index[key]
		return ok
	}
	for _, f := range r.fields[:n] {
		if f.Key == key {
			return true
		}
	}
	return false
}

// Len returns the number of fields.
func (r Record) Len() int { return len(r.fields) }

// Get returns the value of the field with the key, and whether there is one.
func (r Record) Get(key string) (Value, bool) {
	if r.index != nil {
		i, ok := r.index[key]
		if !ok {
			return nil, false
		}
		return r.fields[i].Value, true
	}
	for _, f := range r.fields {
		if f.Key == key {
			return f.Value, true
		}
	}
	return nil, false
}

// Fields returns a copy of the fields, in order.
func (r Record) Fields() []Field { return slices.Clone(r.fields) }

// All iterates over the fields in order.
func (r Record) All() iter.Seq2[string, Value] {
	return func(yield func(string, Value) bool) {
		for _, f := range r.fields {
			if !yield(f.Key, f.Value) {
				return
			}
		}
	}
}

// ParseNumber reads a number literal (spec §3), such as "19.90", "-1e10",
// "0xFF" or "1_000", normalized as the parser does ("255" for "0xFF"). It
// fails only for text that isn't a number literal (invalid-number): it
// applies no limits (spec §11, "Values built in code"). A number longer than
// the number limit, or with a larger exponent, is still a number; a writer
// with those limits rejects it.
func ParseNumber(literal string) (Number, error) {
	end, norm, e := scanNumber(literal, 0, nil)
	if e != nil {
		return Number{}, newError(e.code, e.msg)
	}
	if end != len(literal) {
		return Number{}, newError(CodeInvalidNumber, "not a number literal: "+quoteForMessage(literal))
	}
	return Number{lit: norm}, nil
}

// NumberFromInt returns the integer n as a Number.
func NumberFromInt(n int64) Number {
	return Number{lit: big.NewInt(n).String()}
}

// NumberFromBigInt returns the integer n as a Number. A nil n is 0.
func NumberFromBigInt(n *big.Int) Number {
	if n == nil {
		return Number{}
	}
	return Number{lit: n.String()}
}

// String returns the normalized literal, as in the canonical form: "255",
// "19.90", "-0", "1e5".
func (n Number) String() string {
	if n.lit == "" {
		return "0"
	}
	return n.lit
}

// IsInteger reports whether the literal has neither a fraction nor an
// exponent. 1e2 and 1.0 are not integers in this sense: notation is part of a
// haus number (spec §2), and whether 1.0 is an integer is up to a schema.
func (n Number) IsInteger() bool {
	for i := 0; i < len(n.lit); i++ {
		if c := n.lit[i]; c == '.' || c == 'e' {
			return false
		}
	}
	return true
}

// BigInt returns the number as a big.Int when [Number.IsInteger] holds.
func (n Number) BigInt() (*big.Int, bool) {
	if !n.IsInteger() {
		return nil, false
	}
	return new(big.Int).SetString(n.String(), 10)
}
