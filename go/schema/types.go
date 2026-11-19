package schema

import (
	"strings"
)

// Resolved types: what a schema means once its names are looked up, its
// imports loaded and its generic types applied (spec §14, §15). Named types
// are instances, shared by every use; a reference to one is a typ of kind
// kRef, which decoding follows to the instance's resolved body in one step.

// kind is the kind of a resolved type.
type kind uint8

const (
	kString kind = iota + 1
	kBytes
	kBool
	kDecimal
	kInt
	kInt8
	kInt16
	kInt32
	kInt64
	kUInt8
	kUInt16
	kUInt32
	kUInt64
	kFloat32
	kFloat64
	kAny
	kTime    // a std/time type: name
	kArray   // elem
	kMap     // elem
	kMaybe   // elem
	kSecret  // elem
	kRecord  // rec
	kVariant // vrt (Result too, as closed < Err e | Ok a >)
	kRef     // inst: a named type
	kParam   // name: a type parameter, only in the template of a generic type
)

// builtins are the prelude's types without parameters.
var builtins = map[string]kind{
	"String": kString, "Bytes": kBytes, "Bool": kBool, "Decimal": kDecimal,
	"Int": kInt, "Int8": kInt8, "Int16": kInt16, "Int32": kInt32, "Int64": kInt64,
	"UInt8": kUInt8, "UInt16": kUInt16, "UInt32": kUInt32, "UInt64": kUInt64,
	"Float32": kFloat32, "Float64": kFloat64, "Any": kAny,
}

// builtinNames is the name of each builtin kind.
var builtinNames = func() map[kind]string {
	m := map[kind]string{}
	for name, k := range builtins {
		m[k] = name
	}
	return m
}()

// typ is a resolved type.
type typ struct {
	kind kind
	name string // kTime, kParam
	elem *typ   // kArray, kMap, kMaybe, kSecret
	rec  *recordType
	vrt  *variantType
	inst *instance // kRef
	// jsonNull is set for a kMaybe whose schema-based JSON writes None as
	// null (spec §16.3); see markJSONNull.
	jsonNull bool
}

// recordType is { … } or closed { … }.
type recordType struct {
	closed bool
	fields []fieldType
	index  map[string]int // for records with many fields; nil for small ones
}

// indexFrom is the number of fields or cases from which lookups use a map.
const indexFrom = 9

func newRecord(closed bool, fields []fieldType) *recordType {
	r := &recordType{closed: closed, fields: fields}
	if len(fields) >= indexFrom {
		r.index = make(map[string]int, len(fields))
		for i, f := range fields {
			r.index[f.key] = i
		}
	}
	return r
}

// field returns the field key, or nil.
func (r *recordType) field(key string) *fieldType {
	if r.index != nil {
		if i, ok := r.index[key]; ok {
			return &r.fields[i]
		}
		return nil
	}
	for i := range r.fields {
		if r.fields[i].key == key {
			return &r.fields[i]
		}
	}
	return nil
}

type fieldType struct {
	key        string
	optional   bool
	typ        *typ
	deprecated *deprecated
}

// deprecated is @deprecated or @deprecated("why") (spec §14).
type deprecated struct {
	why string
}

// variantType is < … > or closed < … >.
type variantType struct {
	open  bool
	cases []caseType
	index map[string]int
	// enum is set for a closed variant whose tags have no payload: its
	// schema-based JSON is the tag as a string (spec §16.3).
	enum bool
}

func newVariant(open bool, cases []caseType) *variantType {
	v := &variantType{open: open, cases: cases, enum: !open}
	for _, c := range cases {
		if c.payload != payloadNone {
			v.enum = false
		}
	}
	if len(cases) >= indexFrom {
		v.index = make(map[string]int, len(cases))
		for i, c := range cases {
			v.index[c.tag] = i
		}
	}
	return v
}

// caseOf returns the case of tag, or nil: dispatch is one lookup (§9.8).
func (v *variantType) caseOf(tag string) *caseType {
	if v.index != nil {
		if i, ok := v.index[tag]; ok {
			return &v.cases[i]
		}
		return nil
	}
	for i := range v.cases {
		if v.cases[i].tag == tag {
			return &v.cases[i]
		}
	}
	return nil
}

// payloadKind is what a tag takes (spec §15, "Variants").
type payloadKind uint8

const (
	payloadNone       payloadKind = iota // Tag
	payloadRecord                        // Tag { … }: one record
	payloadNamed                         // Tag R, R a named type that is a record: a record case too
	payloadPositional                    // Tag A B: exactly these values
)

type caseType struct {
	tag        string
	payload    payloadKind
	rec        *recordType // payloadRecord
	named      *typ        // payloadNamed
	items      []*typ      // payloadPositional
	deprecated *deprecated
}

// instance is a named type applied to arguments: its body with the
// parameters replaced.
type instance struct {
	name string
	id   string // the type's id (spec §13.3): @haus-fmt/money@1#Money
	args []*typ
	body *typ
	// resolved is body with references followed: never a kRef.
	resolved *typ
	// stream is set for `type Events = Stream Event`: a file of bodies.
	stream bool
	idx    int // its index among the schema's instances
}

// resolve follows references to the type they stand for.
func resolve(t *typ) *typ {
	if t.kind == kRef {
		return t.inst.resolved
	}
	return t
}

// describe is a short description of a type, as in a schema: Array Line,
// Maybe Int, one of A, B (for messages; bounded). Arguments nested deeper
// than a few levels are left out (P (P (P … …) …) …): they can be shared, so
// written in full they could double at every level.
func describe(t *typ) string { return describeAt(t, 0) }

func describeAt(t *typ, depth int) string {
	switch t.kind {
	case kTime, kParam:
		return t.name
	case kArray:
		return "Array " + atom(t.elem, depth)
	case kMap:
		return "Map " + atom(t.elem, depth)
	case kMaybe:
		return "Maybe " + atom(t.elem, depth)
	case kSecret:
		return "Secret " + atom(t.elem, depth)
	case kRecord:
		return "a record"
	case kVariant:
		return tags(t.vrt)
	case kRef:
		if len(t.inst.args) == 0 {
			return t.inst.name
		}
		args := make([]string, len(t.inst.args))
		for i, a := range t.inst.args {
			args[i] = "…"
			if depth < 2 {
				args[i] = atom(a, depth+1)
			}
		}
		s := t.inst.name + " " + strings.Join(args, " ")
		if len(s) > 80 {
			return t.inst.name + " …"
		}
		return s
	}
	return builtinNames[t.kind]
}

func atom(t *typ, depth int) string {
	d := describeAt(t, depth)
	if strings.Contains(d, " ") && !strings.HasPrefix(d, "one of") && d != "a record" && d != "any tag" {
		return "(" + d + ")"
	}
	return d
}

// tags lists the tags of a variant, for messages: one of A, B, or any tag
// for < >.
func tags(v *variantType) string {
	names := make([]string, 0, min(len(v.cases), 7))
	for i, c := range v.cases {
		if i == 6 {
			return "one of " + strings.Join(names, ", ") + ", …"
		}
		names = append(names, c.tag)
	}
	if len(names) == 0 {
		return "any tag"
	}
	return "one of " + strings.Join(names, ", ")
}
