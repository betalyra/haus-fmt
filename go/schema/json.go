package schema

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"iter"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/internal/hooks"
)

// Schema-based JSON (spec §16.3): the values of a type written as the JSON
// a JSON consumer expects, and read back with the type. Reading parses the
// JSON as the import does (§16.1) and walks that value with the type, as
// decoding walks haus values (§15), so that every rule of decoding, the
// work budget and codecs apply alike; the result is the decoded value, the
// one an encoder writes back.

var (
	parseSchemaJSON      = hooks.ParseSchemaJSON.(func(string, haus.Limits, bool) (haus.Value, error))
	selfDescribing       = hooks.SelfDescribing.(func(haus.Value, haus.Limits, int, string) (haus.Value, error))
	selfDescribingArgs   = hooks.SelfDescribingArgs.(func(string, haus.Value, haus.Limits, int, string) (haus.Value, error))
	appendSelfDescribing = hooks.AppendSelfDescribing.(func([]byte, haus.Value) []byte)
	appendJSONString     = hooks.AppendJSONString.(func([]byte, string) []byte)
	jsonLines            = hooks.JSONLines.(func(io.Reader, int, func(string, int) (haus.Value, error)) iter.Seq2[haus.Value, error])
)

var (
	noneValue haus.Value = haus.Variant{Tag: "None"}
	nanValue  haus.Value = haus.Variant{Tag: "NaN"}
	infValue  haus.Value = haus.Variant{Tag: "Infinity"}
	ninfValue haus.Value = haus.Variant{Tag: "NegInfinity"}
)

// ── the API ──────────────────────────────────────────────────

// ToJSON writes v as the type's schema-based JSON (spec §16.3), on one line
// without spaces. v is checked and encoded as [Type.Encode] does first, so
// it can be a value built in code; what an open record doesn't list is left
// out. A value of a record case with a field named _tag or _args has no
// schema-based form (no-json-form).
func (t Type) ToJSON(v haus.Value) ([]byte, error) {
	return t.AppendJSON(nil, v, DecodeOptions{})
}

// AppendJSON appends the schema-based JSON of v to dst, with options (see
// [Type.ToJSON]).
func (t Type) AppendJSON(dst []byte, v haus.Value, opts DecodeOptions) ([]byte, error) {
	out, err := t.run(v, opts, true, nil)
	if err != nil {
		return dst, err
	}
	jw := jsonWriter{b: dst}
	if err := jw.value(out, t.t); err != nil {
		return dst, err
	}
	return jw.b, nil
}

// FromJSON reads the type's schema-based JSON (spec §16.3) with the default
// limits, and returns the decoded value: what [Type.Decode] gives for the
// haus value the JSON stands for. The rules of decoding apply (§15): open
// records ignore members they don't list, a tag an open variant doesn't
// list reads as an unknown value. Errors in the JSON text have its
// position; errors in the value have the path of the JSON member, such as
// $.items[2].price.
func (t Type) FromJSON(data []byte) (haus.Value, error) {
	return t.FromJSONWith(data, DecodeOptions{})
}

// FromJSONWith is [Type.FromJSON] with options. The limits apply to the
// value read (spec §16, "Limits"); the JSON nesting is limited to 4·d+1
// for the depth limit d.
func (t Type) FromJSONWith(data []byte, opts DecodeOptions) (haus.Value, error) {
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		return nil, err
	}
	return t.fromJSON(string(data), lim, opts, true, nil)
}

func (t Type) fromJSON(text string, lim haus.Limits, opts DecodeOptions, skipBOM bool, prefix []step) (haus.Value, error) {
	if t.t == nil {
		return nil, newError(haus.CodeUnknownType, "a zero Type: get one with Schema.Type")
	}
	j, err := parseSchemaJSON(text, lim, skipBOM)
	if err != nil {
		return nil, err
	}
	w := walker{lim: lim, reading: true, budget: budgetStart, root: j, codecs: opts.Codecs,
		path: make([]step, len(prefix), 16), prefix: len(prefix)}
	copy(w.path, prefix)
	out, _, err := w.value(j, t.t)
	return out, err
}

// ToJSONLines writes values as JSON Lines (spec §16, "Streams"): the
// schema-based JSON of each, followed by a line feed. For a Stream
// definition each value is one of the stream. An error's path starts with
// the value's index, $[3].total.
func (t Type) ToJSONLines(values []haus.Value) ([]byte, error) {
	var out []byte
	for i, v := range values {
		var err error
		if out, err = t.AppendJSON(out, v, DecodeOptions{}); err != nil {
			return nil, atIndex(err, i)
		}
		out = append(out, '\n')
	}
	return out, nil
}

// FromJSONLines reads a whole text of JSON Lines with the type (see
// [Type.ReadJSONLines]): every value, or the first error.
func (t Type) FromJSONLines(data []byte) ([]haus.Value, error) {
	var out []haus.Value
	for v, err := range t.readJSONLines(bytes.NewReader(data), DecodeOptions{}, false) {
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

// ReadJSONLines reads JSON Lines from r (spec §16, "Streams"), each line
// the schema-based JSON of a value of the type (of a stream's value, for a
// Stream definition). It holds one line at a time, at most
// opts.Limits.MaxValueLength characters (value-too-long). Errors in a
// line's text have the line's number; errors in a value have a path that
// starts with its index, $[3].total. The iteration stops after the first
// error.
func (t Type) ReadJSONLines(r io.Reader, opts DecodeOptions) iter.Seq2[haus.Value, error] {
	return t.readJSONLines(r, opts, true)
}

func (t Type) readJSONLines(r io.Reader, opts DecodeOptions, bounded bool) iter.Seq2[haus.Value, error] {
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		return func(yield func(haus.Value, error) bool) { yield(nil, err) }
	}
	maxLine := 0
	if bounded {
		maxLine = lim.MaxValueLength
	}
	return jsonLines(r, maxLine, func(line string, i int) (haus.Value, error) {
		return t.fromJSON(line, lim, opts, i == 0, nil)
	})
}

// atIndex puts the index of a stream's value before an error's path.
func atIndex(err error, i int) error {
	e, ok := err.(*haus.Error)
	if !ok {
		return err
	}
	c := *e
	p := strings.TrimPrefix(c.Path, "$")
	c.Path = pathString([]step{{index: i}}) + p
	return &c
}

// ── reading ──────────────────────────────────────────────────

// readJSON reads the JSON j (as the import reads it) with the type t, whose
// resolved form is rt.
func (w *walker) readJSON(j haus.Value, rt, t *typ) (haus.Value, error) {
	switch rt.kind {
	case kString:
		if s, ok := j.(haus.String); ok {
			return s, w.length(string(s), haus.CodeStringTooLong, "string")
		}
		return w.jsonMismatch(j, t, "a string")
	case kTime:
		s, ok := j.(haus.String)
		if !ok {
			return w.jsonMismatch(j, t, "a string")
		}
		if err := CheckTime(rt.name, string(s)); err != nil {
			return nil, w.fail(haus.CodeInvalidTime, "%v", err)
		}
		return haus.Variant{Tag: rt.name, Args: []haus.Value{s}}, nil
	case kBytes:
		s, ok := j.(haus.String)
		if !ok {
			return w.jsonMismatch(j, t, "a string in base64 with padding")
		}
		b, ok := fromBase64(string(s))
		if !ok {
			return nil, w.fail(haus.CodeInvalidBase64, "expected base64 with padding (RFC 4648 §4), found %s", describeJSON(j))
		}
		if 2*len(b) > w.lim.MaxStringLength {
			return nil, w.fail(haus.CodeStringTooLong, "a byte string of %d bytes, more than the limit of %d characters", len(b), w.lim.MaxStringLength)
		}
		return haus.Bytes(b), nil
	case kBool:
		if x, ok := j.(haus.Variant); ok && (x.Tag == "True" || x.Tag == "False") {
			return j, nil
		}
		return w.jsonMismatch(j, t, "true or false")
	case kInt8, kInt16, kInt32, kUInt8, kUInt16, kUInt32:
		if n, ok := j.(haus.Number); ok {
			out, _, err := w.integer(n, n, rt.kind)
			return out, err
		}
		return w.jsonMismatch(j, t, "a number")
	case kInt, kInt64, kUInt64:
		if s, ok := j.(haus.String); ok {
			return w.intString(string(s), rt.kind)
		}
		return w.jsonMismatch(j, t, "a string of a decimal integer")
	case kFloat32, kFloat64:
		switch x := j.(type) {
		case haus.Number:
			out, _, err := w.float(j, x, rt.kind)
			return out, err
		case haus.String:
			switch x {
			case "NaN":
				return nanValue, nil
			case "Infinity":
				return infValue, nil
			case "-Infinity":
				return ninfValue, nil
			}
		}
		return w.jsonMismatch(j, t, `a number, "NaN", "Infinity" or "-Infinity"`)
	case kDecimal:
		if s, ok := j.(haus.String); ok {
			return w.decimalString(string(s))
		}
		return w.jsonMismatch(j, t, "a string of a number")
	case kAny:
		return selfDescribing(j, w.lim, w.depth, pathString(w.path))
	case kArray:
		a, ok := j.(haus.Array)
		if !ok {
			return w.jsonMismatch(j, t, "an array")
		}
		out := make(haus.Array, len(a))
		for i, x := range a {
			y, _, err := w.child(step{index: i}, x, rt.elem)
			if err != nil {
				return nil, err
			}
			out[i] = y
		}
		return out, nil
	case kMap:
		r, ok := j.(haus.Record)
		if !ok {
			return w.jsonMismatch(j, t, "an object")
		}
		out := make([]haus.Field, 0, r.Len())
		for k, x := range r.All() {
			w.path = append(w.path, step{key: k, index: -1})
			if err := w.length(k, haus.CodeKeyTooLong, "key"); err != nil {
				return nil, err
			}
			y, _, err := w.nest(x, rt.elem, 1)
			if err != nil {
				return nil, err
			}
			out = append(out, haus.Field{Key: k, Value: y})
		}
		return recordOwned(out), nil
	case kMaybe:
		return w.readMaybe(j, rt, t)
	case kSecret:
		out, _, err := w.secret(j, rt.elem)
		return out, err
	case kRecord:
		r, ok := j.(haus.Record)
		if !ok {
			return w.jsonMismatch(j, t, "an object")
		}
		return w.readRecord(r, rt.rec, false)
	case kVariant:
		return w.readVariant(j, rt.vrt, t)
	}
	// A type parameter: only in the template of a generic type, which
	// values aren't read with.
	return j, w.imported(j, w.depth)
}

func (w *walker) jsonMismatch(j haus.Value, t *typ, form string) (haus.Value, error) {
	return nil, w.fail(haus.CodeTypeMismatch, "expected %s (%s), found %s", describe(t), form, describeJSON(j))
}

// length checks a string or key of the value read against the string
// limit, counted in characters after escapes (§16, "Limits").
func (w *walker) length(s string, code haus.ErrorCode, what string) error {
	if len(s) > w.lim.MaxStringLength && utf8.RuneCountInString(s) > w.lim.MaxStringLength {
		return w.fail(code, "a %s longer than the limit of %d characters", what, w.lim.MaxStringLength)
	}
	return nil
}

// intString reads Int, Int64 and UInt64, written as a string of a decimal
// integer: -?(0|[1-9][0-9]*), "-0" being 0.
func (w *walker) intString(s string, k kind) (haus.Value, error) {
	if !isDecimalInteger(s) {
		code := haus.CodeInvalidNumber
		if isJSONNumber(s) {
			code = haus.CodeNotAnInteger
		}
		return nil, w.fail(code, "expected a decimal integer in a string (%s), found %s", builtinNames[k], quote(shortText(s)))
	}
	// A sized type checks its range: a number too long for the limit is out
	// of range for it.
	if k == kInt && len(s) > w.lim.MaxNumberLength {
		return nil, w.fail(haus.CodeNumberTooLong, "a number of %d characters, more than the limit of %d", len(s), w.lim.MaxNumberLength)
	}
	n := numberLit(s)
	out, _, err := w.integer(n, n, k)
	return out, err
}

// decimalString reads a Decimal: a JSON number literal in a string,
// normalized (spec §2).
func (w *walker) decimalString(s string) (haus.Value, error) {
	if !isJSONNumber(s) {
		return nil, w.fail(haus.CodeInvalidNumber, "expected a number literal in a string (Decimal), found %s", quote(shortText(s)))
	}
	n := numberLit(normalizeJSONNumber(s))
	if err := haus.CheckValue(n, w.lim); err != nil {
		return nil, w.fail(codeOf(err), "%s", messageOf(err))
	}
	return n, nil
}

func (w *walker) readMaybe(j haus.Value, rt, t *typ) (haus.Value, error) {
	if rt.jsonNull {
		if isNull(j) {
			return noneValue, nil
		}
		// Some(x) is one level deeper than the JSON shows.
		y, _, err := w.nest(j, rt.elem, 0)
		if err != nil {
			return nil, err
		}
		return haus.Variant{Tag: "Some", Args: []haus.Value{y}}, nil
	}
	r, ok := j.(haus.Record)
	if !ok {
		return w.jsonMismatch(j, t, `{"_tag": "None"} or {"_tag": "Some", "value": …}`)
	}
	tag, err := w.tagMember(r)
	if err != nil {
		return nil, err
	}
	switch tag {
	case "None":
		if err := w.onlyMembers(r, ""); err != nil {
			return nil, err
		}
		return noneValue, nil
	case "Some":
		x, err := w.member(r, "value", tag)
		if err != nil {
			return nil, err
		}
		y, _, err := w.child(step{key: "value", index: -1}, x, rt.elem)
		if err != nil {
			return nil, err
		}
		return haus.Variant{Tag: "Some", Args: []haus.Value{y}}, nil
	}
	return nil, w.fail(haus.CodeUnknownTag, "%s is not allowed here: expected None or Some", quote(tag))
}

// tagMember returns the "_tag" of an object: missing-member without one,
// invalid-tag if it isn't a string or isn't a tag (§16.3), at the object.
func (w *walker) tagMember(r haus.Record) (string, error) {
	j, ok := r.Get("_tag")
	if !ok {
		return "", w.fail(haus.CodeMissingMember, `expected the member "_tag", found %s`, describeJSON(r))
	}
	s, ok := j.(haus.String)
	if !ok {
		return "", w.fail(haus.CodeInvalidTag, "expected a tag in '_tag', found %s", describeJSON(j))
	}
	if !isTagName(string(s)) {
		return "", w.fail(haus.CodeInvalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found %s", quote(shortText(string(s))))
	}
	return string(s), nil
}

// member returns the member name of an object with "_tag" (and no other).
func (w *walker) member(r haus.Record, name, tag string) (haus.Value, error) {
	x, ok := r.Get(name)
	if !ok {
		return nil, w.fail(haus.CodeMissingMember, `%s needs the member %q`, tag, name)
	}
	return x, w.onlyMembers(r, name)
}

// onlyMembers checks that an object has no members besides "_tag" and
// name (if not "": then a member named "" is unexpected too).
func (w *walker) onlyMembers(r haus.Record, name string) error {
	for k := range r.All() {
		if k != "_tag" && (name == "" || k != name) {
			w.path = append(w.path, step{key: k, index: -1})
			return w.fail(haus.CodeUnexpectedMember, "unexpected member %s", quote(k))
		}
	}
	return nil
}

// readRecord reads an object with a record type; with payload, its "_tag"
// is the case's, not a field.
func (w *walker) readRecord(r haus.Record, rt *recordType, payload bool) (haus.Value, error) {
	var missing []string
	for i := range rt.fields {
		f := &rt.fields[i]
		if f.optional {
			continue
		}
		if _, ok := r.Get(f.key); !ok {
			missing = append(missing, quoteKey(f.key))
		}
	}
	if len(missing) > 0 {
		s := ""
		if len(missing) > 1 {
			s = "s"
		}
		if len(missing) > 5 {
			missing = append(missing[:5], "…")
		}
		return nil, w.fail(haus.CodeMissingField, "missing field%s %s", s, strings.Join(missing, ", "))
	}
	out := make([]haus.Field, 0, min(r.Len(), len(rt.fields)))
	for k, x := range r.All() {
		if payload && k == "_tag" {
			continue
		}
		f := rt.field(k)
		if f == nil {
			if rt.closed {
				w.path = append(w.path, step{key: k, index: -1})
				return nil, w.fail(haus.CodeUnknownField, "%s is not a field of this closed record", quoteKey(k))
			}
			continue
		}
		y, _, err := w.child(step{key: k, index: -1}, x, f.typ)
		if err != nil {
			return nil, err
		}
		out = append(out, haus.Field{Key: f.key, Value: y})
	}
	return recordOwned(out), nil
}

func (w *walker) readVariant(j haus.Value, vt *variantType, t *typ) (haus.Value, error) {
	if vt.enum {
		s, ok := j.(haus.String)
		if !ok {
			return w.jsonMismatch(j, t, "a string")
		}
		if !isTagName(string(s)) {
			return nil, w.fail(haus.CodeInvalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*), one of %s, found %s", tags(vt), quote(shortText(string(s))))
		}
		c := vt.caseOf(string(s))
		if c == nil {
			return nil, w.fail(haus.CodeUnknownTag, "%s is not allowed here: expected %s", quote(string(s)), tags(vt))
		}
		return haus.Variant{Tag: c.tag}, nil
	}
	r, ok := j.(haus.Record)
	if !ok {
		return w.jsonMismatch(j, t, `an object with "_tag"`)
	}
	tag, err := w.tagMember(r)
	if err != nil {
		return nil, err
	}
	c := vt.caseOf(tag)
	if c == nil {
		if !vt.open {
			return nil, w.fail(haus.CodeUnknownTag, "%s is not allowed here: expected %s", quote(tag), tags(vt))
		}
		return w.unknownJSON(tag, r)
	}
	switch c.payload {
	case payloadNone:
		if err := w.onlyMembers(r, ""); err != nil {
			return nil, err
		}
		return haus.Variant{Tag: c.tag}, nil
	case payloadRecord, payloadNamed:
		if err := w.reserved(c); err != nil {
			return nil, err
		}
		// The record's fields beside "_tag", at the variant's level and place.
		var y haus.Value
		if c.payload == payloadRecord {
			y, err = w.readRecord(r, c.rec, true)
		} else {
			fields := make([]haus.Field, 0, r.Len()-1)
			for k, x := range r.All() {
				if k != "_tag" {
					fields = append(fields, haus.Field{Key: k, Value: x})
				}
			}
			y, _, err = w.value(recordOwned(fields), c.named)
		}
		if err != nil {
			return nil, err
		}
		return haus.Variant{Tag: c.tag, Args: []haus.Value{y}}, nil
	}
	if len(c.items) == 1 {
		x, err := w.member(r, "value", tag)
		if err != nil {
			return nil, err
		}
		y, _, err := w.child(step{key: "value", index: -1}, x, c.items[0])
		if err != nil {
			return nil, err
		}
		return haus.Variant{Tag: c.tag, Args: []haus.Value{y}}, nil
	}
	x, err := w.member(r, "values", tag)
	if err != nil {
		return nil, err
	}
	// A wrong payload is at the variant (§15), as in haus text.
	a, ok := x.(haus.Array)
	if !ok {
		return nil, w.fail(haus.CodeWrongPayload, "%s takes %d arguments, as an array in \"values\"; found %s", tag, len(c.items), describeJSON(x))
	}
	if len(a) != len(c.items) {
		return nil, w.fail(haus.CodeWrongPayload, "%s takes %d arguments, found %d", tag, len(c.items), len(a))
	}
	w.path = append(w.path, step{key: "values", index: -1})
	args := make([]haus.Value, len(a))
	for i, x := range a {
		y, _, err := w.child(step{index: i}, x, c.items[i])
		if err != nil {
			return nil, err
		}
		args[i] = y
	}
	w.path = w.path[:len(w.path)-1]
	return haus.Variant{Tag: c.tag, Args: args}, nil
}

// unknownJSON reads a tag an open variant doesn't list (§16.3): the bare
// tag; with "_args" alone, its arguments as self-describing values;
// otherwise its other members as a record payload, by the import.
func (w *walker) unknownJSON(tag string, r haus.Record) (haus.Value, error) {
	if !isTagName(tag) {
		return nil, w.fail(haus.CodeInvalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found %s", quote(shortText(tag)))
	}
	if len(tag) > w.lim.MaxStringLength {
		return nil, w.fail(haus.CodeTagTooLong, "a tag longer than the limit of %d characters", w.lim.MaxStringLength)
	}
	if r.Len() == 1 {
		return haus.Variant{Tag: tag}, nil
	}
	if args, ok := r.Get("_args"); ok && r.Len() == 2 {
		return selfDescribingArgs(tag, args, w.lim, w.depth, pathString(w.path))
	}
	fields := make([]haus.Field, 0, r.Len()-1)
	for k, x := range r.All() {
		if k != "_tag" {
			fields = append(fields, haus.Field{Key: k, Value: x})
		}
	}
	payload := recordOwned(fields)
	if err := w.imported(payload, w.depth); err != nil {
		return nil, err
	}
	return haus.Variant{Tag: tag, Args: []haus.Value{payload}}, nil
}

// imported checks a value the import gave (§16.1) against the limits: its
// strings and keys, and its nesting, for a value at depth (a record payload
// counts as the variant's level).
func (w *walker) imported(v haus.Value, depth int) error {
	switch v := v.(type) {
	case haus.String:
		return w.length(string(v), haus.CodeStringTooLong, "string")
	case haus.Array:
		if len(v) > 0 && depth >= w.lim.MaxDepth {
			return w.fail(haus.CodeNestingTooDeep, "nesting deeper than %d levels", w.lim.MaxDepth)
		}
		for i, x := range v {
			w.path = append(w.path, step{index: i})
			if err := w.imported(x, depth+1); err != nil {
				return err
			}
			w.path = w.path[:len(w.path)-1]
		}
	case haus.Record:
		if v.Len() > 0 && depth >= w.lim.MaxDepth {
			return w.fail(haus.CodeNestingTooDeep, "nesting deeper than %d levels", w.lim.MaxDepth)
		}
		for k, x := range v.All() {
			w.path = append(w.path, step{key: k, index: -1})
			if err := w.length(k, haus.CodeKeyTooLong, "key"); err != nil {
				return err
			}
			if err := w.imported(x, depth+1); err != nil {
				return err
			}
			w.path = w.path[:len(w.path)-1]
		}
	}
	return nil
}

// reserved fails for a record case with a field named _tag or _args, which
// has no schema-based form (§16.3).
func (w *walker) reserved(c *caseType) error {
	if f := reservedField(c); f != "" {
		return w.fail(haus.CodeNoJSONForm, "%s has a field named %s, so it has no schema-based JSON form", c.tag, f)
	}
	return nil
}

// caseRecord returns the record of a record case, or nil.
func caseRecord(c *caseType) *recordType {
	switch c.payload {
	case payloadRecord:
		return c.rec
	case payloadNamed:
		if r := resolve(c.named); r.kind == kRecord {
			return r.rec
		}
	}
	return nil
}

// reservedField returns _tag or _args, if a record case has such a field.
func reservedField(c *caseType) string {
	r := caseRecord(c)
	if r == nil {
		return ""
	}
	for _, f := range r.fields {
		if f.key == "_tag" || f.key == "_args" {
			return f.key
		}
	}
	return ""
}

func isNull(j haus.Value) bool {
	x, ok := j.(haus.Variant)
	return ok && x.Tag == "None"
}

func isTagName(s string) bool {
	if s == "" || s[0] < 'A' || s[0] > 'Z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !isWordByte(c) {
			return false
		}
	}
	return true
}

// isDecimalInteger reports whether s is -?(0|[1-9][0-9]*).
func isDecimalInteger(s string) bool {
	s = strings.TrimPrefix(s, "-")
	if s == "" || s[0] == '0' && len(s) > 1 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// isJSONNumber reports whether s is a JSON number literal (RFC 8259):
// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
func isJSONNumber(s string) bool {
	i := 0
	digits := func() int {
		j := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		return i - j
	}
	if i < len(s) && s[i] == '-' {
		i++
	}
	switch {
	case i < len(s) && s[i] == '0':
		i++
	case digits() == 0:
		return false
	}
	if i < len(s) && s[i] == '.' {
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
}

// normalizeJSONNumber writes a JSON number literal normalized (spec §2):
// the exponent as e, without + and leading zeros, and no - on a zero
// exponent: 1E+05 is 1e5.
func normalizeJSONNumber(s string) string {
	i := strings.IndexAny(s, "eE")
	if i < 0 {
		return s
	}
	exp := s[i+1:]
	neg := strings.HasPrefix(exp, "-")
	exp = strings.TrimLeft(strings.TrimLeft(exp, "+-"), "0")
	if exp == "" {
		return s[:i] + "e0"
	}
	if neg {
		return s[:i] + "e-" + exp
	}
	return s[:i] + "e" + exp
}

// fromBase64 decodes canonical padded base64 (RFC 4648 §4): no
// whitespace, no URL alphabet, zero pad bits.
func fromBase64(s string) ([]byte, bool) {
	if len(s)%4 != 0 {
		return nil, false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !isWordByte(c) && c != '+' && c != '/' && c != '=' || c == '_' {
			return nil, false
		}
	}
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	return b, err == nil
}

// shortText is at most 30 characters of s, for messages.
func shortText(s string) string {
	if utf8.RuneCountInString(s) <= 30 {
		return s
	}
	n := 0
	for i := range s {
		if n == 30 {
			return s[:i] + "…"
		}
		n++
	}
	return s
}

// describeJSON is a short description of JSON (read as the import reads
// it), for messages.
func describeJSON(j haus.Value) string {
	switch j := j.(type) {
	case haus.String:
		return "the string " + quote(shortText(string(j)))
	case haus.Number:
		return "the number " + short(j.String())
	case haus.Array:
		return "an array"
	case haus.Record:
		if j.Len() == 0 {
			return "an empty object"
		}
		return "an object"
	case haus.Variant:
		switch j.Tag {
		case "True":
			return "true"
		case "False":
			return "false"
		}
		return "null"
	}
	return "nothing"
}

// ── writing ──────────────────────────────────────────────────

// jsonWriter writes a decoded value with its type.
type jsonWriter struct {
	b    []byte
	path []step
}

func (jw *jsonWriter) fail(code haus.ErrorCode, format string, args ...any) error {
	return &haus.Error{Code: code, Message: fmt.Sprintf(format, args...), Path: pathString(jw.path)}
}

func (jw *jsonWriter) quoted(s string) {
	jw.b = append(jw.b, '"')
	jw.b = append(jw.b, s...)
	jw.b = append(jw.b, '"')
}

// value writes v, which the type t decoded (or encoded).
func (jw *jsonWriter) value(v haus.Value, t *typ) error {
	rt := resolve(t)
	switch rt.kind {
	case kString:
		if s, ok := v.(haus.String); ok {
			jw.b = appendJSONString(jw.b, string(s))
			return nil
		}
	case kTime:
		if x, ok := v.(haus.Variant); ok && len(x.Args) == 1 {
			if s, ok := x.Args[0].(haus.String); ok {
				jw.b = appendJSONString(jw.b, string(s))
				return nil
			}
		}
	case kBytes:
		if b, ok := v.(haus.Bytes); ok {
			jw.b = append(jw.b, '"')
			jw.b = base64.StdEncoding.AppendEncode(jw.b, b)
			jw.b = append(jw.b, '"')
			return nil
		}
	case kBool:
		if x, ok := v.(haus.Variant); ok {
			if x.Tag == "True" {
				jw.b = append(jw.b, "true"...)
			} else {
				jw.b = append(jw.b, "false"...)
			}
			return nil
		}
	case kInt8, kInt16, kInt32, kUInt8, kUInt16, kUInt32:
		if n, ok := v.(haus.Number); ok {
			jw.b = append(jw.b, n.String()...)
			return nil
		}
	case kInt, kInt64, kUInt64, kDecimal:
		if n, ok := v.(haus.Number); ok {
			jw.quoted(n.String())
			return nil
		}
	case kFloat32, kFloat64:
		switch x := v.(type) {
		case haus.Number:
			jw.b = append(jw.b, x.String()...)
			return nil
		case haus.Variant:
			switch x.Tag {
			case "NaN":
				jw.quoted("NaN")
			case "Infinity":
				jw.quoted("Infinity")
			default:
				jw.quoted("-Infinity")
			}
			return nil
		}
	case kAny:
		jw.b = appendSelfDescribing(jw.b, v)
		return nil
	case kArray:
		if a, ok := v.(haus.Array); ok {
			jw.b = append(jw.b, '[')
			for i, x := range a {
				if i > 0 {
					jw.b = append(jw.b, ',')
				}
				jw.path = append(jw.path, step{index: i})
				if err := jw.value(x, rt.elem); err != nil {
					return err
				}
				jw.path = jw.path[:len(jw.path)-1]
			}
			jw.b = append(jw.b, ']')
			return nil
		}
	case kMap:
		if r, ok := v.(haus.Record); ok {
			jw.b = append(jw.b, '{')
			first := true
			for k, x := range r.All() {
				if err := jw.member(&first, k, x, rt.elem); err != nil {
					return err
				}
			}
			jw.b = append(jw.b, '}')
			return nil
		}
	case kMaybe:
		return jw.maybe(v, rt)
	case kSecret:
		return jw.value(v, rt.elem)
	case kRecord:
		if r, ok := v.(haus.Record); ok {
			jw.b = append(jw.b, '{')
			first := true
			if err := jw.fields(&first, r, rt.rec); err != nil {
				return err
			}
			jw.b = append(jw.b, '}')
			return nil
		}
	case kVariant:
		if x, ok := v.(haus.Variant); ok {
			return jw.variant(x, rt.vrt)
		}
	}
	return jw.fail(haus.CodeCannotEncode, "expected %s, found %s", describe(t), found(v))
}

// member writes "key": value, after a comma unless first.
func (jw *jsonWriter) member(first *bool, k string, x haus.Value, t *typ) error {
	if !*first {
		jw.b = append(jw.b, ',')
	}
	*first = false
	jw.b = appendJSONString(jw.b, k)
	jw.b = append(jw.b, ':')
	jw.path = append(jw.path, step{key: k, index: -1})
	if err := jw.value(x, t); err != nil {
		return err
	}
	jw.path = jw.path[:len(jw.path)-1]
	return nil
}

func (jw *jsonWriter) fields(first *bool, r haus.Record, rt *recordType) error {
	for k, x := range r.All() {
		f := rt.field(k)
		if f == nil {
			continue // ignored by an open record
		}
		if err := jw.member(first, k, x, f.typ); err != nil {
			return err
		}
	}
	return nil
}

func (jw *jsonWriter) maybe(v haus.Value, rt *typ) error {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag != "None" && len(x.Args) != 1 {
		return jw.fail(haus.CodeCannotEncode, "expected None or Some(…), found %s", found(v))
	}
	switch {
	case x.Tag == "None" && rt.jsonNull:
		jw.b = append(jw.b, "null"...)
		return nil
	case x.Tag == "None":
		jw.b = append(jw.b, `{"_tag":"None"}`...)
		return nil
	}
	jw.path = append(jw.path, step{index: 0})
	if rt.jsonNull {
		if err := jw.value(x.Args[0], rt.elem); err != nil {
			return err
		}
	} else {
		jw.b = append(jw.b, `{"_tag":"Some","value":`...)
		if err := jw.value(x.Args[0], rt.elem); err != nil {
			return err
		}
		jw.b = append(jw.b, '}')
	}
	jw.path = jw.path[:len(jw.path)-1]
	return nil
}

func (jw *jsonWriter) variant(x haus.Variant, vt *variantType) error {
	if vt.enum {
		jw.b = appendJSONString(jw.b, x.Tag)
		return nil
	}
	jw.b = append(jw.b, `{"_tag":`...)
	jw.b = appendJSONString(jw.b, x.Tag)
	c := vt.caseOf(x.Tag)
	switch {
	case c == nil && len(x.Args) > 0: // an unknown value
		jw.b = append(jw.b, `,"_args":[`...)
		for i, a := range x.Args {
			if i > 0 {
				jw.b = append(jw.b, ',')
			}
			jw.b = appendSelfDescribing(jw.b, a)
		}
		jw.b = append(jw.b, ']')
	case c == nil, c.payload == payloadNone:
	case c.payload == payloadRecord || c.payload == payloadNamed:
		if f := reservedField(c); f != "" {
			return jw.fail(haus.CodeNoJSONForm, "%s has a field named %s, so it has no schema-based JSON form", c.tag, f)
		}
		r, ok := x.Args[0].(haus.Record)
		if !ok || len(x.Args) != 1 {
			return jw.fail(haus.CodeCannotEncode, "%s takes one argument, a record", c.tag)
		}
		first := false
		if err := jw.fields(&first, r, caseRecord(c)); err != nil {
			return err
		}
	case len(c.items) == 1:
		jw.b = append(jw.b, `,"value":`...)
		jw.path = append(jw.path, step{index: 0})
		if err := jw.value(x.Args[0], c.items[0]); err != nil {
			return err
		}
		jw.path = jw.path[:len(jw.path)-1]
	default:
		jw.b = append(jw.b, `,"values":[`...)
		for i, a := range x.Args {
			if i > 0 {
				jw.b = append(jw.b, ',')
			}
			jw.path = append(jw.path, step{index: i})
			if err := jw.value(a, c.items[i]); err != nil {
				return err
			}
			jw.path = jw.path[:len(jw.path)-1]
		}
		jw.b = append(jw.b, ']')
	}
	jw.b = append(jw.b, '}')
	return nil
}
