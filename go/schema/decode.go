package schema

import (
	"errors"
	"fmt"
	"io"
	"iter"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/internal/hooks"
)

// Decoding with a schema (spec §15). The result is a haus value: the one an
// encoder writes back, with floats in their one spelling, integers in
// decimal (-0 as 0), and the fields an open record ignores left out. Parts
// the type keeps as they are share memory with the input.

var (
	recordOwned = hooks.RecordOwned.(func([]haus.Field) haus.Record)
	numberLit   = hooks.NumberLit.(func(string) haus.Number)
)

// stepsPerValue is the work budget of one decode: steps per value of the
// input, after a start of budgetStart (spec §9.8).
const (
	stepsPerValue = 16
	budgetStart   = 1024
)

// Type is a named type of a [Schema], without parameters: what a whole
// value (or, for a Stream definition, each value of a stream) is decoded
// with. The zero Type is not usable; get one with [Schema.Type].
type Type struct {
	t      *typ
	name   string
	stream bool
}

// DecodeOptions configure decoding and encoding.
type DecodeOptions struct {
	// Limits are the limits of the reader (spec §7): the depth limit, and
	// the limits raw values (an Any, an unknown tag) are checked against.
	// Zero fields take their defaults.
	Limits haus.Limits
	// Codecs run after the schema of the types they are for (spec §13.4),
	// and may reject more values. Nil: none.
	Codecs *Codecs
}

// Type returns the definition called name, which must have no parameters:
// unknown-type if there is none, wrong-arity if it has parameters.
func (s *Schema) Type(name string) (Type, error) {
	i, ok := s.byName[name]
	if !ok {
		return Type{}, newError(haus.CodeUnknownType, "the schema has no type %s", quote(name))
	}
	d := s.definitions[i]
	if len(d.Params) > 0 {
		return Type{}, newError(haus.CodeWrongArity, "%s needs arguments, so it can't describe a whole file", name)
	}
	return Type{t: &typ{kind: kRef, inst: d.template}, name: name, stream: d.template.stream}, nil
}

// Name returns the type's name in the schema.
func (t Type) Name() string { return t.name }

// IsStream reports whether the type is a Stream definition, type Events =
// Stream Event: it describes a file, each of whose values [Type.Decode]
// decodes as an Event.
func (t Type) IsStream() bool { return t.stream }

// Decode decodes v with the type named name. See [Type.Decode].
func (s *Schema) Decode(name string, v haus.Value) (haus.Value, error) {
	t, err := s.Type(name)
	if err != nil {
		return nil, err
	}
	return t.Decode(v)
}

// Decode decodes v with the type, with the default limits, and returns the
// value an encoder writes back (spec §15), or the first error: an
// *haus.Error with the code and the path of the failing value
// ($.items[2].price). An error inside a Secret is invalid-secret, at the
// secret. For a Stream definition, v is one value of the stream.
func (t Type) Decode(v haus.Value) (haus.Value, error) {
	return t.DecodeWith(v, DecodeOptions{})
}

// DecodeWith is [Type.Decode] with options.
func (t Type) DecodeWith(v haus.Value, opts DecodeOptions) (haus.Value, error) {
	return t.run(v, opts, false, nil)
}

// Encode checks a value built in code against the type and returns the
// value to write (spec §15): what Decode gives for it. Besides Decode's
// errors, it detects a value that contains itself (cyclic-value), strings
// and keys that aren't UTF-8 (cannot-encode), and values that share nodes
// so much that writing them would take more than [haus.MaxNodes] nodes
// (too-many-nodes).
func (t Type) Encode(v haus.Value) (haus.Value, error) {
	return t.EncodeWith(v, DecodeOptions{})
}

// EncodeWith is [Type.Encode] with options.
func (t Type) EncodeWith(v haus.Value, opts DecodeOptions) (haus.Value, error) {
	return t.run(v, opts, true, nil)
}

// DecodeAll decodes the values of a file with the type: each one, on its
// own, with the type a Stream definition holds; any other type expects
// exactly one value (not-one-value). An error's path starts with the value's
// index for a stream: $[3].total.
func (t Type) DecodeAll(values []haus.Value) ([]haus.Value, error) {
	if !t.stream {
		if len(values) != 1 {
			return nil, newError(haus.CodeNotOneValue, "%s is not a Stream: expected one value, found %d", t.name, len(values))
		}
		v, err := t.Decode(values[0])
		return []haus.Value{v}, err
	}
	out := make([]haus.Value, len(values))
	for i, v := range values {
		d, err := t.run(v, DecodeOptions{}, false, []step{{index: i}})
		if err != nil {
			return nil, err
		}
		out[i] = d
	}
	return out, nil
}

// DecodeStream reads a stream from r and decodes each value with the type
// as it is read (spec §6, §15); the type must be a Stream definition, or
// it decodes each value as itself. An error's path starts with the value's
// index: $[3].total. The iteration stops after the first error.
func (t Type) DecodeStream(r io.Reader, opts haus.StreamOptions) iter.Seq2[haus.Value, error] {
	return func(yield func(haus.Value, error) bool) {
		reader := haus.NewStreamReader(r, opts)
		i := 0
		for v, err := range reader.All() {
			if err != nil {
				yield(nil, err)
				return
			}
			d, err := t.run(v, DecodeOptions{Limits: opts.Limits}, false, []step{{index: i}})
			if !yield(d, err) || err != nil {
				return
			}
			i++
		}
	}
}

func (t Type) run(v haus.Value, opts DecodeOptions, encoding bool, prefix []step) (haus.Value, error) {
	if t.t == nil {
		return nil, newError(haus.CodeUnknownType, "a zero Type: get one with Schema.Type")
	}
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		return nil, err
	}
	w := walker{lim: lim, encoding: encoding, budget: budgetStart, root: v, codecs: opts.Codecs,
		path: make([]step, len(prefix), 16), prefix: len(prefix)}
	copy(w.path, prefix)
	out, _, err := w.value(v, t.t)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// resolveLimits fills in the default limits and checks the depth limit.
func resolveLimits(l haus.Limits) (haus.Limits, error) {
	d := haus.DefaultLimits()
	pick := func(v, def int) int {
		if v <= 0 {
			return def
		}
		return v
	}
	r := haus.Limits{
		MaxDepth:        pick(l.MaxDepth, d.MaxDepth),
		MaxNumberLength: pick(l.MaxNumberLength, d.MaxNumberLength),
		MaxExponent:     pick(l.MaxExponent, d.MaxExponent),
		MaxStringLength: pick(l.MaxStringLength, d.MaxStringLength),
		MaxValueLength:  pick(l.MaxValueLength, d.MaxValueLength),
	}
	if r.MaxDepth > haus.MaxSupportedDepth {
		return r, newError(haus.CodeUnsupportedDepth, "MaxDepth %d is more than the supported maximum, %d", r.MaxDepth, haus.MaxSupportedDepth)
	}
	return r, nil
}

// step is one step of a path (spec §15): a key, or an index.
type step struct {
	key   string
	index int // -1 for a key
}

// pathString writes a path from $: .key for an identifier, ["key"] with the
// key as a string in canonical form otherwise, [i] for an index.
func pathString(steps []step) string {
	var b strings.Builder
	b.WriteByte('$')
	for _, s := range steps {
		switch {
		case s.index >= 0:
			b.WriteByte('[')
			b.WriteString(strconv.Itoa(s.index))
			b.WriteByte(']')
		case isIdent(s.key):
			b.WriteByte('.')
			b.WriteString(s.key)
		default:
			k, _ := haus.Canonical(haus.String(s.key))
			b.WriteByte('[')
			b.WriteString(k)
			b.WriteByte(']')
		}
	}
	return b.String()
}

// walker decodes (or, encoding, checks) one value with a type.
type walker struct {
	lim      haus.Limits
	encoding bool
	reading  bool // v is JSON read as by the import: schema-based JSON (§16.3)
	codecs   *Codecs
	root     haus.Value
	path     []step
	prefix   int // steps of path before the root: a stream's index
	depth    int
	nodes    int
	steps    int
	budget   int
}

func (w *walker) fail(code haus.ErrorCode, format string, args ...any) error {
	return &haus.Error{Code: code, Message: fmt.Sprintf(format, args...), Path: pathString(w.path)}
}

// child decodes v with t one level deeper, at the step s.
func (w *walker) child(s step, v haus.Value, t *typ) (haus.Value, bool, error) {
	w.path = append(w.path, s)
	return w.nest(v, t, 1)
}

// nest decodes v with t one level deeper; on success it drops the last
// pop steps of the path.
func (w *walker) nest(v haus.Value, t *typ, pop int) (haus.Value, bool, error) {
	if w.depth >= w.lim.MaxDepth {
		code := haus.CodeNestingTooDeep
		// Only a value built in code can contain itself; at the depth limit
		// is where every such value ends up.
		if err := haus.CheckValue(w.root, haus.Limits{MaxDepth: haus.MaxSupportedDepth}); codeOf(err) == haus.CodeCyclicValue {
			code = haus.CodeCyclicValue
		}
		if code == haus.CodeCyclicValue {
			return nil, false, w.fail(code, "the value contains itself, so it has no finite text")
		}
		return nil, false, w.fail(code, "nesting deeper than %d levels", w.lim.MaxDepth)
	}
	w.nodes++
	if w.nodes > haus.MaxNodes {
		return nil, false, w.fail(haus.CodeTooManyNodes, "the value has more than %d nodes", haus.MaxNodes)
	}
	w.budget += stepsPerValue
	w.depth++
	out, changed, err := w.value(v, t)
	w.depth--
	if err == nil {
		w.path = w.path[:len(w.path)-pop]
	}
	return out, changed, err
}

// value decodes v with t. changed is false when the result is v itself.
func (w *walker) value(v haus.Value, t *typ) (haus.Value, bool, error) {
	w.steps++
	if w.steps > w.budget {
		return nil, false, w.fail(haus.CodeStepBudget,
			"decode budget of %d steps exceeded (a schema doing more work than the input justifies)", w.budget)
	}
	rt := resolve(t)
	var (
		out     haus.Value
		changed bool
		err     error
	)
	if w.reading {
		out, err = w.readJSON(v, rt, t)
		changed = true
	} else {
		out, changed, err = w.resolved(v, rt, t)
	}
	if err != nil || w.codecs == nil || len(w.codecs.byID) == 0 {
		return out, changed, err
	}
	// A codec applies wherever its type occurs, also behind other names.
	for x := t; ; x = x.inst.body {
		if codec := w.codecs.forType(x); codec != nil {
			if out, changed, err = w.applyCodec(codec, out, changed); err != nil {
				return out, changed, err
			}
		}
		if x.kind != kRef {
			return out, changed, nil
		}
	}
}

func (w *walker) resolved(v haus.Value, rt, t *typ) (haus.Value, bool, error) {
	switch rt.kind {
	case kTime:
		return w.time(v, rt.name, t)
	case kArray:
		a, ok := v.(haus.Array)
		if !ok {
			return w.mismatch(v, t)
		}
		var out haus.Array
		for i, x := range a {
			y, changed, err := w.child(step{index: i}, x, rt.elem)
			if err != nil {
				return nil, false, err
			}
			if changed && out == nil {
				out = make(haus.Array, len(a))
				copy(out, a[:i])
			}
			if out != nil {
				out[i] = y
			}
		}
		if out != nil {
			return out, true, nil
		}
		return v, false, nil
	case kMap:
		r, ok := v.(haus.Record)
		if !ok {
			return w.mismatch(v, t)
		}
		return w.mapEntries(r, rt.elem)
	case kMaybe:
		x, ok := v.(haus.Variant)
		switch {
		case ok && x.Tag == "None" && len(x.Args) == 0:
			return v, false, nil
		case ok && x.Tag == "Some" && len(x.Args) == 1:
			y, changed, err := w.child(step{index: 0}, x.Args[0], rt.elem)
			if err != nil || !changed {
				return v, false, err
			}
			return haus.Variant{Tag: "Some", Args: []haus.Value{y}}, true, nil
		}
		return nil, false, w.fail(notCase(v, "None", "Some"), "expected None or Some(…) (%s), found %s", describe(t), found(v))
	case kSecret:
		return w.secret(v, rt.elem)
	case kRecord:
		r, ok := v.(haus.Record)
		if !ok {
			return w.mismatch(v, t)
		}
		return w.record(r, rt.rec)
	case kVariant:
		return w.variant(v, rt.vrt, t)
	case kParam:
		return v, false, nil
	}
	return w.builtin(v, rt.kind, t)
}

func (w *walker) mismatch(v haus.Value, t *typ) (haus.Value, bool, error) {
	return nil, false, w.fail(haus.CodeTypeMismatch, "expected %s, found %s", describe(t), found(v))
}

// notCase is the code for a value that isn't one of the cases of a closed
// variant with the tags (Bool, Maybe): a known tag with the wrong payload, an
// unknown tag, or not a variant at all.
func notCase(v haus.Value, tags ...string) haus.ErrorCode {
	x, ok := v.(haus.Variant)
	switch {
	case !ok:
		return haus.CodeTypeMismatch
	case x.Tag == tags[0] || x.Tag == tags[1]:
		return haus.CodeWrongPayload
	}
	return haus.CodeUnknownTag
}

// secret decodes v as item, and replaces any error inside by one at the
// secret itself, with its type only (spec §15): messages quote values, keys
// and tags of the data, and paths may name keys.
func (w *walker) secret(v haus.Value, item *typ) (haus.Value, bool, error) {
	at := len(w.path)
	depth := w.depth
	out, changed, err := w.value(v, item)
	if err != nil {
		w.path, w.depth = w.path[:at], depth
		return nil, false, w.fail(haus.CodeInvalidSecret, "expected %s (a Secret: the value is not shown)", describe(item))
	}
	return out, changed, nil
}

func (w *walker) text(s string) error {
	if w.encoding && !utf8.ValidString(s) {
		return w.fail(haus.CodeCannotEncode, "a string that isn't valid UTF-8")
	}
	return nil
}

func (w *walker) builtin(v haus.Value, k kind, t *typ) (haus.Value, bool, error) {
	switch k {
	case kAny:
		return w.raw(v)
	case kString:
		if s, ok := v.(haus.String); ok {
			return v, false, w.text(string(s))
		}
	case kBytes:
		if _, ok := v.(haus.Bytes); ok {
			return v, false, nil
		}
	case kBool:
		if x, ok := v.(haus.Variant); ok {
			switch {
			case (x.Tag == "True" || x.Tag == "False") && len(x.Args) == 0:
				return v, false, nil
			case x.Tag == "True" || x.Tag == "False":
				return nil, false, w.fail(haus.CodeWrongPayload, "expected %s, found %s with a payload", describe(t), found(v))
			}
			return nil, false, w.fail(haus.CodeUnknownTag, "expected %s (True or False), found %s", describe(t), found(v))
		}
	case kFloat32, kFloat64:
		if x, ok := v.(haus.Variant); ok && len(x.Args) == 0 && (x.Tag == "NaN" || x.Tag == "Infinity" || x.Tag == "NegInfinity") {
			return v, false, nil
		}
		if n, ok := v.(haus.Number); ok {
			return w.float(n, k)
		}
	case kDecimal:
		if n, ok := v.(haus.Number); ok {
			return v, false, w.number(n)
		}
	default: // the integer types
		if n, ok := v.(haus.Number); ok {
			return w.integer(v, n, k)
		}
	}
	return w.mismatch(v, t)
}

// number checks a number built in code against the number limits.
func (w *walker) number(n haus.Number) error {
	if !w.encoding {
		return nil
	}
	if err := haus.CheckValue(n, w.lim); err != nil {
		return w.fail(codeOf(err), "%s", messageOf(err))
	}
	return nil
}

// ranges are the ranges of the fixed-size integer types.
var ranges = map[kind]struct {
	bits   int
	signed bool
}{
	kInt8: {8, true}, kInt16: {16, true}, kInt32: {32, true}, kInt64: {64, true},
	kUInt8: {8, false}, kUInt16: {16, false}, kUInt32: {32, false}, kUInt64: {64, false},
}

func (w *walker) integer(v haus.Value, n haus.Number, k kind) (haus.Value, bool, error) {
	if err := w.number(n); err != nil {
		return nil, false, err
	}
	text := n.String()
	digits := strings.TrimPrefix(text, "-")
	if digits == "" || strings.IndexFunc(digits, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return nil, false, w.fail(haus.CodeNotAnInteger, "expected a whole number (%s), found %s", builtinNames[k], short(text))
	}
	zero := strings.Trim(digits, "0") == ""
	if k != kInt {
		r := ranges[k]
		var err error
		switch {
		case zero:
		case r.signed:
			_, err = strconv.ParseInt(text, 10, r.bits)
		case text[0] == '-':
			err = strconv.ErrRange
		default:
			_, err = strconv.ParseUint(text, 10, r.bits)
		}
		if err != nil {
			lo, hi := intRange(r.bits, r.signed)
			return nil, false, w.fail(haus.CodeOutOfRange, "%s is out of range for %s (%s to %s)", short(text), builtinNames[k], lo, hi)
		}
	}
	if zero && text != "0" {
		return numberLit("0"), true, nil // -0 is 0 (spec §15)
	}
	return v, false, nil
}

func intRange(bits int, signed bool) (lo, hi string) {
	if signed {
		return strconv.FormatInt(-1<<(bits-1), 10), strconv.FormatInt(1<<(bits-1)-1, 10)
	}
	return "0", strconv.FormatUint(1<<bits-1, 10)
}

// float rounds a number to the nearest float of the type, directly from
// its exact decimal value, and writes it in its one spelling (spec §15).
func (w *walker) float(n haus.Number, k kind) (haus.Value, bool, error) {
	if err := w.number(n); err != nil {
		return nil, false, err
	}
	bits := 64
	if k == kFloat32 {
		bits = 32
	}
	text := n.String()
	f, err := strconv.ParseFloat(text, bits)
	if err != nil && !errors.Is(err, strconv.ErrRange) || math.IsInf(f, 0) {
		return nil, false, w.fail(haus.CodeOutOfRange, "%s is too large for %s", short(text), builtinNames[k])
	}
	spelled := formatFloat(f, bits)
	if spelled == text {
		return n, false, nil
	}
	return numberLit(spelled), true, nil
}

// raw checks a value kept as it is (an Any, an unknown tag): one a writer
// takes, within the limits (spec §9.8).
func (w *walker) raw(v haus.Value) (haus.Value, bool, error) {
	err := haus.CheckValue(v, w.lim)
	if err == nil {
		w.nodes++
		return v, false, nil
	}
	e, _ := err.(*haus.Error)
	if e == nil {
		return nil, false, w.fail(haus.CodeTypeMismatch, "%v", err)
	}
	code := e.Code
	if code == haus.CodeCannotEncode && !w.encoding {
		code = haus.CodeTypeMismatch
	}
	return nil, false, &haus.Error{Code: code, Message: e.Message, Path: pathString(w.path) + strings.TrimPrefix(e.Path, "$")}
}

func (w *walker) time(v haus.Value, name string, t *typ) (haus.Value, bool, error) {
	x, ok := v.(haus.Variant)
	if !ok || x.Tag != name {
		return w.mismatch(v, t)
	}
	var s haus.String
	if len(x.Args) == 1 {
		s, ok = x.Args[0].(haus.String)
	}
	if len(x.Args) != 1 || !ok {
		return nil, false, w.fail(haus.CodeTypeMismatch, "write %s(\"…\") with one string", name)
	}
	if err := w.text(string(s)); err != nil {
		return nil, false, err
	}
	if err := CheckTime(name, string(s)); err != nil {
		w.path = append(w.path, step{index: 0})
		return nil, false, w.fail(haus.CodeInvalidTime, "%v", err)
	}
	return v, false, nil
}

func (w *walker) key(k string) error {
	if w.encoding && !utf8.ValidString(k) {
		return w.fail(haus.CodeCannotEncode, "a key that isn't valid UTF-8")
	}
	return nil
}

func (w *walker) mapEntries(r haus.Record, elem *typ) (haus.Value, bool, error) {
	var out []haus.Field
	i := 0
	for k, x := range r.All() {
		if err := w.key(k); err != nil {
			return nil, false, err
		}
		y, changed, err := w.child(step{key: k, index: -1}, x, elem)
		if err != nil {
			return nil, false, err
		}
		if changed && out == nil {
			out = r.Fields()[:i:i]
			out = append(make([]haus.Field, 0, r.Len()), out...)
		}
		if out != nil {
			out = append(out, haus.Field{Key: k, Value: y})
		}
		i++
	}
	if out != nil {
		return recordOwned(out), true, nil
	}
	return r, false, nil
}

func (w *walker) record(r haus.Record, rt *recordType) (haus.Value, bool, error) {
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
		return nil, false, w.fail(haus.CodeMissingField, "missing field%s %s", s, strings.Join(missing, ", "))
	}
	var out []haus.Field
	i := 0
	for k, x := range r.All() {
		f := rt.field(k)
		if f == nil {
			if rt.closed {
				w.path = append(w.path, step{key: k, index: -1})
				return nil, false, w.fail(haus.CodeUnknownField, "%s is not a field of this closed record", quoteKey(k))
			}
			if out == nil {
				out = append(make([]haus.Field, 0, r.Len()), r.Fields()[:i]...)
			}
			i++
			continue
		}
		if err := w.key(k); err != nil {
			return nil, false, err
		}
		y, changed, err := w.child(step{key: k, index: -1}, x, f.typ)
		if err != nil {
			return nil, false, err
		}
		if changed && out == nil {
			out = append(make([]haus.Field, 0, r.Len()), r.Fields()[:i]...)
		}
		if out != nil {
			out = append(out, haus.Field{Key: k, Value: y})
		}
		i++
	}
	if out != nil {
		return recordOwned(out), true, nil
	}
	return r, false, nil
}

func (w *walker) variant(v haus.Value, vt *variantType, t *typ) (haus.Value, bool, error) {
	x, ok := v.(haus.Variant)
	if !ok {
		return w.mismatch(v, t)
	}
	c := vt.caseOf(x.Tag)
	if c == nil {
		if vt.open {
			return w.raw(v)
		}
		return nil, false, w.fail(haus.CodeUnknownTag, "%s is not allowed here: expected %s", quote(x.Tag), tags(vt))
	}
	switch c.payload {
	case payloadNone:
		if len(x.Args) == 0 {
			return v, false, nil
		}
		return nil, false, w.fail(haus.CodeWrongPayload, "%s takes no payload", x.Tag)
	case payloadRecord, payloadNamed:
		r, ok := oneRecord(x.Args)
		if !ok {
			return nil, false, w.fail(haus.CodeWrongPayload, "%s takes one argument, a record; found %s", x.Tag, foundArgs(x.Args))
		}
		// Tag { … }: the record is at the variant's level and place.
		var (
			y       haus.Value
			changed bool
			err     error
		)
		if c.payload == payloadRecord {
			y, changed, err = w.record(r, c.rec)
		} else {
			y, changed, err = w.value(r, c.named)
		}
		if err != nil || !changed {
			return v, false, err
		}
		return haus.Variant{Tag: x.Tag, Args: []haus.Value{y}}, true, nil
	}
	if len(c.items) != len(x.Args) {
		described := make([]string, len(c.items))
		for i, it := range c.items {
			described[i] = describe(it)
		}
		s := "s"
		if len(c.items) == 1 {
			s = ""
		}
		return nil, false, w.fail(haus.CodeWrongPayload, "%s takes %d argument%s (%s), found %d",
			x.Tag, len(c.items), s, strings.Join(described, ", "), len(x.Args))
	}
	var out []haus.Value
	for i, a := range x.Args {
		y, changed, err := w.child(step{index: i}, a, c.items[i])
		if err != nil {
			return nil, false, err
		}
		if changed && out == nil {
			out = make([]haus.Value, len(x.Args))
			copy(out, x.Args[:i])
		}
		if out != nil {
			out[i] = y
		}
	}
	if out != nil {
		return haus.Variant{Tag: x.Tag, Args: out}, true, nil
	}
	return v, false, nil
}

func oneRecord(args []haus.Value) (haus.Record, bool) {
	if len(args) != 1 {
		return haus.Record{}, false
	}
	r, ok := args[0].(haus.Record)
	return r, ok
}

func foundArgs(args []haus.Value) string {
	switch len(args) {
	case 0:
		return "no payload"
	case 1:
		return found(args[0])
	}
	return fmt.Sprintf("%d arguments", len(args))
}

// short is at most 30 characters of a number's text, for messages.
func short(text string) string {
	if utf8.RuneCountInString(text) > 30 {
		return text[:30] + "…"
	}
	return text
}

// found is a short description of a value, for messages.
func found(v haus.Value) string {
	switch v := v.(type) {
	case haus.String:
		if utf8.RuneCountInString(string(v)) > 20 || !utf8.ValidString(string(v)) {
			return "a string"
		}
		return "the string " + strconv.Quote(quote(string(v)))
	case haus.Number:
		return "the number " + short(v.String())
	case haus.Bytes:
		return "bytes"
	case haus.Array:
		return "an array"
	case haus.Record:
		return "a record"
	case haus.Variant:
		return "the tag " + quote(v.Tag)
	}
	return "nothing"
}
