package schema

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"iter"
	"math"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/internal/floats"
	"github.com/betalyra/haus-fmt/go/internal/hooks"
)

// Decoding with a schema (spec §15). The result is a haus value: the one an
// encoder writes back, with floats in their one spelling, integers in
// decimal (-0 as 0), and the fields an open record ignores left out. Parts
// the type keeps as they are share memory with the input.

var (
	recordOwned  = hooks.RecordOwned.(func([]haus.Field) haus.Record)
	recordFields = hooks.RecordFields.(func(haus.Record) []haus.Field)
	numberLit    = hooks.NumberLit.(func(string) haus.Number)
	appendQuoted = hooks.AppendQuoted.(func([]byte, string) ([]byte, bool))
	appendLine   = hooks.AppendLine.(func([]byte, haus.Value, haus.Limits, bool, int) ([]byte, error))
	checkWritten = hooks.CheckWritten.(func(haus.Value, haus.Limits) error)
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
// value an encoder writes back (spec §15), the value of each Secret type
// hidden in a [haus.Secret] ([Type.Encode] writes it in full), or the
// first error: an
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
// so much that writing them would take more than [haus.Limits.MaxNodes] values
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
			e := newError(haus.CodeNotOneValue, "%s is not a Stream: expected one value, found %d", t.name, len(values))
			e.Path = "$"
			return nil, e
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
	w := newWalker(lim, v, prefix)
	w.encoding, w.codecs = encoding, opts.Codecs
	w.plain = !encoding && opts.Codecs.none()
	out, _, err := w.value(v, t.t)
	w.release()
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
		MaxNodes:        pick(l.MaxNodes, d.MaxNodes),
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
	// parsed is set when v is what the parser read with lim from a text of
	// at most lim.MaxNodes bytes: its raw parts pass haus.CheckValue.
	parsed bool
	// plain is set when decoding without codecs (not encoding, reading
	// JSON or writing): scalars decoded as they are take a shorter way.
	plain  bool
	codecs *Codecs
	root   haus.Value
	path   []step
	prefix int // steps of path before the root: a stream's index
	depth  int
	nodes  int
	steps  int
	budget int
	// writing (with encoding) also appends the value the walk returns to
	// b, in the compact or minimised layout, as it is checked (see
	// Type.Format); the returned values are then not built. Any error makes
	// the caller start again in two passes, which gives the exact error, so
	// a writing walk may give up wherever a check is easier to leave to them
	// (errTwoPasses).
	writing   bool
	minimised bool
	b         []byte
	// tooLong is set when a writing walk wrote a string, key, tag or byte
	// string longer than the string limit: the two passes report it.
	tooLong bool
}

// writeTag writes a tag, noting one longer than the string limit.
func (w *walker) writeTag(tag string) {
	if len(tag) > w.lim.MaxStringLength {
		w.tooLong = true
	}
	w.b = append(w.b, tag...)
}

// writeLength notes a string or key longer than the string limit, in code
// points.
func (w *walker) writeLength(s string) {
	if len(s) > w.lim.MaxStringLength && utf8.RuneCountInString(s) > w.lim.MaxStringLength {
		w.tooLong = true
	}
}

// errTwoPasses is what a writing walk gives up with where the value is
// left to Type.Encode and haus.FormatValue.
var errTwoPasses = errors.New("schema: left to encoding and writing in two passes")

// walkers keeps walkers for reuse, so that their paths and buffers don't
// grow anew for every value.
var walkers = sync.Pool{New: func() any { return new(walker) }}

// The most room a pooled walker's path and buffer may have.
const (
	maxPooledPath   = 1024
	maxPooledBuffer = 4 << 20
)

// newWalker returns a walker from the pool for a walk of root, its path
// starting with prefix.
func newWalker(lim haus.Limits, root haus.Value, prefix []step) *walker {
	w := walkers.Get().(*walker)
	path, b := w.path[:0], w.b[:0]
	if cap(path) < 16 {
		path = make([]step, 0, 16)
	}
	*w = walker{lim: lim, budget: budgetStart, root: root, path: append(path, prefix...), prefix: len(prefix), b: b}
	return w
}

// release returns w to the pool, without the values it refers to. w must
// not be used after.
func (w *walker) release() {
	if cap(w.path) > maxPooledPath || cap(w.b) > maxPooledBuffer {
		return
	}
	clear(w.path[:cap(w.path)])
	*w = walker{path: w.path[:0], b: w.b[:0]}
	walkers.Put(w)
}

func (w *walker) fail(code haus.ErrorCode, format string, args ...any) error {
	return &haus.Error{Code: code, Message: fmt.Sprintf(format, args...), Path: pathString(w.path)}
}

// child decodes v with t one level deeper, at the step s.
func (w *walker) child(s step, v haus.Value, t *typ) (haus.Value, bool, error) {
	// A scalar decoded as it is takes a shorter way, with the same counts
	// (nest, value): nothing in it can fail or nest.
	if (w.plain || w.writing) && w.depth < w.lim.MaxDepth && w.nodes < w.lim.MaxNodes && w.steps < w.budget+stepsPerValue {
		rt := resolve(t)
		var done bool
		if w.plain {
			done = plainScalar(v, rt)
		} else if done = w.writeScalar(v, rt); done && w.b == nil {
			return nil, false, errTwoPasses
		}
		if done {
			w.nodes++
			w.budget += stepsPerValue
			w.steps++
			return v, false, nil
		}
	}
	w.path = append(w.path, s)
	return w.nest(v, t, 1)
}

// writeScalar writes v as encoding it with rt (resolved) and writing it
// does, if v is a plain scalar of rt (see plainScalar) within the limits,
// and reports whether it did. A string that isn't UTF-8 sets w.b to nil.
func (w *walker) writeScalar(v haus.Value, rt *typ) bool {
	if !plainScalar(v, rt) {
		return false
	}
	switch v := v.(type) {
	case haus.String:
		w.writeLength(string(v))
		var valid bool
		if w.b, valid = appendQuoted(w.b, string(v)); !valid {
			w.b = nil
		}
	case haus.Variant:
		w.writeTag(v.Tag.String())
	case haus.Number:
		text := v.String()
		if len(text) > w.lim.MaxNumberLength || strings.IndexByte(text, 'e') >= 0 {
			return false
		}
		w.b = append(w.b, text...)
	}
	return true
}

// plainScalar reports whether decoding v with rt (resolved) gives v itself
// without looking deeper: a string as a String, a tag of an enum (Bool,
// None of a Maybe), a number as a Decimal or as an integer that is written
// as one (not -0) and in range.
func plainScalar(v haus.Value, rt *typ) bool {
	switch v := v.(type) {
	case haus.String:
		return rt.kind == kString
	case haus.Variant:
		if len(v.Args) > 0 {
			return false
		}
		switch rt.kind {
		case kBool:
			return v.Tag.String() == "True" || v.Tag.String() == "False"
		case kMaybe:
			return v.Tag.String() == "None"
		case kVariant:
			c := rt.vrt.caseOf(v.Tag.String())
			return c != nil && c.payload == payloadNone
		}
	case haus.Number:
		switch rt.kind {
		case kDecimal:
			return true
		case kInt, kInt8, kInt16, kInt32, kInt64, kUInt8, kUInt16, kUInt32, kUInt64:
			return plainInteger(v.String(), rt.kind)
		}
	}
	return false
}

// plainInteger reports whether text is an integer of the type k, written as
// decoding writes it: decimal digits, a - only before a nonzero value.
func plainInteger(text string, k kind) bool {
	digits := text
	if text[0] == '-' {
		digits = text[1:]
	}
	if digits == "" || digits[0] == '0' && len(digits) > 1 {
		return false
	}
	for i := 0; i < len(digits); i++ {
		if c := digits[i]; c < '0' || c > '9' {
			return false
		}
	}
	if digits == "0" {
		return text == "0"
	}
	if k == kInt {
		return true
	}
	r := ranges[k]
	var err error
	switch {
	case r.signed:
		_, err = strconv.ParseInt(text, 10, r.bits)
	case text[0] == '-':
		return false
	default:
		_, err = strconv.ParseUint(text, 10, r.bits)
	}
	return err == nil
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
	if w.nodes > w.lim.MaxNodes {
		return nil, false, &haus.Error{Code: haus.CodeTooManyNodes, Path: pathString(w.path[:w.prefix]),
			Message: fmt.Sprintf("the value writes more than %d values, the node limit: its parts share one another", w.lim.MaxNodes)}
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
	if err == nil && w.depth >= w.lim.MaxDepth {
		if w.writing {
			return nil, false, errTwoPasses // out isn't built to look at
		}
		if emptyLevel(out) {
			// An empty record, array or record payload is a level, as when
			// parsing (spec §7), though it has nothing in it to nest.
			return nil, false, w.fail(haus.CodeNestingTooDeep, "nesting deeper than %d levels", w.lim.MaxDepth)
		}
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

// emptyLevel reports whether v is an empty record or array, or a variant
// with an empty record payload (Tag {}): a level of nesting with nothing
// below it.
func emptyLevel(v haus.Value) bool {
	switch v := v.(type) {
	case haus.Array:
		return len(v) == 0
	case haus.Record:
		return v.Len() == 0
	case haus.Variant:
		if len(v.Args) != 1 {
			return false
		}
		r, ok := v.Args[0].(haus.Record)
		return ok && r.Len() == 0
	}
	return false
}

// separator writes the comma between two entries.
func (w *walker) separator() {
	if w.minimised {
		w.b = append(w.b, ',')
	} else {
		w.b = append(w.b, ", "...)
	}
}

// space writes a space in the compact layout.
func (w *walker) space() {
	if !w.minimised {
		w.b = append(w.b, ' ')
	}
}

// writeNumber writes a number literal, which must be within the number
// limit.
func (w *walker) writeNumber(text string) error {
	if len(text) > w.lim.MaxNumberLength {
		return errTwoPasses
	}
	w.b = append(w.b, text...)
	return nil
}

// writeRaw writes a value the walk keeps as it is, with the writer's checks.
func (w *walker) writeRaw(v haus.Value) error {
	b, err := appendLine(w.b, v, w.lim, w.minimised, w.depth)
	if err != nil {
		return errTwoPasses
	}
	w.b = b
	return nil
}

// payloadStart writes what comes between a tag and its one argument a:
// a space before a record payload in the compact layout, which the writers
// write as Tag { … }, and '(' before any other.
func (w *walker) payloadStart(a haus.Value) (record bool) {
	if _, ok := a.(haus.Record); ok {
		w.space()
		return true
	}
	w.b = append(w.b, '(')
	return false
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
		if w.writing {
			w.b = append(w.b, '[')
		}
		var out haus.Array
		for i, x := range a {
			if w.writing && i > 0 {
				w.separator()
			}
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
		if w.writing {
			w.b = append(w.b, ']')
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
		return w.mapEntries(v, r, rt.elem)
	case kMaybe:
		x, ok := v.(haus.Variant)
		switch {
		case ok && x.Tag.String() == "None" && len(x.Args) == 0:
			if w.writing {
				w.writeTag("None")
			}
			return v, false, nil
		case ok && x.Tag.String() == "Some" && len(x.Args) == 1:
			var record bool
			if w.writing {
				w.writeTag("Some")
				record = w.payloadStart(x.Args[0])
			}
			y, changed, err := w.child(step{index: 0}, x.Args[0], rt.elem)
			if w.writing {
				if !record {
					w.b = append(w.b, ')')
				}
				return v, false, err
			}
			if err != nil || !changed {
				return v, false, err
			}
			return haus.Variant{Tag: haus.MustTag("Some"), Args: []haus.Value{y}}, true, nil
		}
		return nil, false, w.fail(notCase(v, "None", "Some"), "expected None or Some(…) (%s), found %s", describe(t), found(v))
	case kSecret:
		return w.secret(v, rt.elem)
	case kRecord:
		r, ok := v.(haus.Record)
		if !ok {
			return w.mismatch(v, t)
		}
		return w.record(v, r, rt.rec)
	case kVariant:
		return w.variant(v, rt.vrt, t)
	case kParam:
		if w.writing {
			return v, false, w.writeRaw(v)
		}
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
	case x.Tag.String() == tags[0] || x.Tag.String() == tags[1]:
		return haus.CodeWrongPayload
	}
	return haus.CodeUnknownTag
}

// secret decodes v as item, and replaces any error inside by one at the
// secret itself, with its type only (spec §15): messages quote values, keys
// and tags of the data, and paths may name keys. Decoding gives the value
// hidden in a [haus.Secret] (spec §15, "decode.secret.generic-decoders");
// encoding and writing take a haus.Secret or a plain value, and give the
// plain value, written in full.
func (w *walker) secret(v haus.Value, item *typ) (haus.Value, bool, error) {
	hidden, wasHidden := v.(haus.Secret)
	if wasHidden {
		v = hidden.Reveal()
	}
	at := len(w.path)
	depth := w.depth
	out, changed, err := w.value(v, item)
	if err == errTwoPasses {
		return nil, false, err
	}
	if err != nil {
		w.path, w.depth = w.path[:at], depth
		return nil, false, w.fail(haus.CodeInvalidSecret, "expected %s (a Secret: the value is not shown)", describe(item))
	}
	if w.encoding || w.writing {
		return out, changed || wasHidden, nil
	}
	return haus.NewSecret(out), true, nil
}

// text checks a string built in code. A writing walk checks it as it
// writes it (writeString).
func (w *walker) text(s string) error {
	if w.encoding && !w.writing && !utf8.ValidString(s) {
		return w.fail(haus.CodeCannotEncode, "a string that isn't valid UTF-8")
	}
	return nil
}

// writeString writes a string, which must be valid UTF-8 (text).
func (w *walker) writeString(s string) error {
	w.writeLength(s)
	var valid bool
	if w.b, valid = appendQuoted(w.b, s); !valid {
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
			if err := w.text(string(s)); err != nil {
				return nil, false, err
			}
			if w.writing {
				return v, false, w.writeString(string(s))
			}
			return v, false, nil
		}
	case kBytes:
		if b, ok := v.(haus.Bytes); ok {
			if w.writing {
				if 2*len(b) > w.lim.MaxStringLength {
					w.tooLong = true
				}
				w.b = append(w.b, `x"`...)
				w.b = hex.AppendEncode(w.b, b)
				w.b = append(w.b, '"')
			}
			return v, false, nil
		}
	case kBool:
		if x, ok := v.(haus.Variant); ok {
			switch {
			case (x.Tag.String() == "True" || x.Tag.String() == "False") && len(x.Args) == 0:
				if w.writing {
					w.writeTag(x.Tag.String())
				}
				return v, false, nil
			case x.Tag.String() == "True" || x.Tag.String() == "False":
				return nil, false, w.fail(haus.CodeWrongPayload, "expected %s, found %s with a payload", describe(t), found(v))
			}
			return nil, false, w.fail(haus.CodeUnknownTag, "expected %s (True or False), found %s", describe(t), found(v))
		}
	case kFloat32, kFloat64:
		if x, ok := v.(haus.Variant); ok && len(x.Args) == 0 && (x.Tag.String() == "NaN" || x.Tag.String() == "Infinity" || x.Tag.String() == "NegInfinity") {
			if w.writing {
				w.writeTag(x.Tag.String())
			}
			return v, false, nil
		}
		if n, ok := v.(haus.Number); ok {
			return w.float(v, n, k)
		}
	case kDecimal:
		if n, ok := v.(haus.Number); ok {
			if err := w.number(v, n); err != nil {
				return nil, false, err
			}
			if w.writing {
				return v, false, w.writeNumber(n.String())
			}
			return v, false, nil
		}
	default: // the integer types
		if n, ok := v.(haus.Number); ok {
			return w.integer(v, n, k)
		}
	}
	return w.mismatch(v, t)
}

// number checks a number built in code, v, against the number limits.
func (w *walker) number(v haus.Value, n haus.Number) error {
	if !w.encoding {
		return nil
	}
	// Within the length limit and without an exponent, it passes.
	if text := n.String(); len(text) <= w.lim.MaxNumberLength && strings.IndexByte(text, 'e') < 0 {
		return nil
	}
	if err := haus.CheckValue(v, w.lim); err != nil {
		return w.fail(codeOf(err), "%s", messageOf(err))
	}
	return nil
}

// ranges are the ranges of the fixed-size integer types.
var ranges = [...]struct {
	bits   int
	signed bool
}{
	kInt8: {8, true}, kInt16: {16, true}, kInt32: {32, true}, kInt64: {64, true},
	kUInt8: {8, false}, kUInt16: {16, false}, kUInt32: {32, false}, kUInt64: {64, false},
}

func (w *walker) integer(v haus.Value, n haus.Number, k kind) (haus.Value, bool, error) {
	if err := w.number(v, n); err != nil {
		return nil, false, err
	}
	text := n.String()
	digits := strings.TrimPrefix(text, "-")
	whole, zero := digits != "", true
	for i := 0; i < len(digits); i++ {
		c := digits[i]
		if c < '0' || c > '9' {
			whole = false
			break
		}
		zero = zero && c == '0'
	}
	if !whole {
		return nil, false, w.fail(haus.CodeNotAnInteger, "expected a whole number (%s), found %s", builtinNames[k], short(text))
	}
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
		if w.writing {
			return v, false, w.writeNumber("0")
		}
		return numberLit("0"), true, nil // -0 is 0 (spec §15)
	}
	if w.writing {
		return v, false, w.writeNumber(text)
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
func (w *walker) float(v haus.Value, n haus.Number, k kind) (haus.Value, bool, error) {
	if err := w.number(v, n); err != nil {
		return nil, false, err
	}
	bits := 64
	if k == kFloat32 {
		bits = 32
	}
	text := n.String()
	f := floats.Parse(text, bits)
	if math.IsInf(f, 0) {
		return nil, false, w.fail(haus.CodeOutOfRange, "%s is too large for %s", short(text), builtinNames[k])
	}
	if w.writing {
		start := len(w.b)
		w.b = floats.Append(w.b, f, bits)
		if len(w.b)-start > w.lim.MaxNumberLength {
			return nil, false, errTwoPasses
		}
		return v, false, nil
	}
	var buf [32]byte
	spelled := floats.Append(buf[:0], f, bits)
	if string(spelled) == text {
		return v, false, nil
	}
	return numberLit(string(spelled)), true, nil
}

// raw checks a value kept as it is (an Any, an unknown tag): one a writer
// takes, within the limits (spec §9.8).
func (w *walker) raw(v haus.Value) (haus.Value, bool, error) {
	if w.parsed {
		// Values the parser read pass with the limits they were read with,
		// and a text of n bytes holds at most n values.
		w.nodes++
		return v, false, nil
	}
	if w.writing {
		// Written with the writer's checks, which take in CheckValue's
		// checks of UTF-8, tags and nesting (at w.depth, deeper than v's
		// own), the rest of CheckValue after; an error is left to the two
		// passes.
		if err := w.writeRaw(v); err != nil {
			return nil, false, err
		}
		if checkWritten(v, w.lim) != nil {
			return nil, false, errTwoPasses
		}
		w.nodes++
		return v, false, nil
	}
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
	if !ok || x.Tag.String() != name {
		return w.mismatch(v, t)
	}
	var s haus.String
	if len(x.Args) == 1 {
		s, ok = x.Args[0].(haus.String)
	}
	if len(x.Args) != 1 || !ok {
		return nil, false, w.fail(haus.CodeTypeMismatch, "write %s(\"…\") with one string", name)
	}
	if w.encoding && !utf8.ValidString(string(s)) {
		return nil, false, w.fail(haus.CodeCannotEncode, "a string that isn't valid UTF-8")
	}
	if err := CheckTime(name, string(s)); err != nil {
		w.path = append(w.path, step{index: 0})
		return nil, false, w.fail(haus.CodeInvalidTime, "%v", err)
	}
	if w.writing {
		w.writeTag(name)
		w.b = append(w.b, '(')
		w.writeLength(string(s))
		w.b, _ = appendQuoted(w.b, string(s))
		w.b = append(w.b, ')')
	}
	return v, false, nil
}

func (w *walker) key(k string) error {
	if w.encoding && !utf8.ValidString(k) {
		return w.fail(haus.CodeCannotEncode, "a key that isn't valid UTF-8")
	}
	return nil
}

// writeKey writes the key of the next of a record's entries, the n-th (from
// 0): written as it is when quote is false, quoted otherwise.
func (w *walker) writeKey(n int, key string, quote bool) {
	if n > 0 {
		w.separator()
	} else {
		w.space()
	}
	w.writeLength(key)
	if quote {
		w.b, _ = appendQuoted(w.b, key)
	} else {
		w.b = append(w.b, key...)
	}
	w.b = append(w.b, ':')
	w.space()
}

// writeClose closes a record of n entries, after its '{'.
func (w *walker) writeClose(n int) {
	if n > 0 {
		w.space()
	}
	w.b = append(w.b, '}')
}

func (w *walker) mapEntries(v haus.Value, r haus.Record, elem *typ) (haus.Value, bool, error) {
	fields := recordFields(r)
	if w.writing {
		w.b = append(w.b, '{')
	}
	var out []haus.Field
	for i := range fields {
		k := fields[i].Key
		if err := w.key(k); err != nil {
			return nil, false, err
		}
		if w.writing {
			w.writeKey(i, k, !isIdent(k))
		}
		y, changed, err := w.child(step{key: k, index: -1}, fields[i].Value, elem)
		if err != nil {
			return nil, false, err
		}
		if changed && out == nil {
			out = append(make([]haus.Field, 0, len(fields)), fields[:i]...)
		}
		if out != nil {
			out = append(out, haus.Field{Key: k, Value: y})
		}
	}
	if w.writing {
		w.writeClose(len(fields))
	}
	if out != nil {
		return recordOwned(out), true, nil
	}
	return v, false, nil
}

// missing returns the error for the fields of rt that r lacks, or nil.
func (w *walker) missing(r haus.Record, rt *recordType) error {
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
	if len(missing) == 0 {
		return nil
	}
	s := ""
	if len(missing) > 1 {
		s = "s"
	}
	if len(missing) > 5 {
		missing = append(missing[:5], "…")
	}
	return w.fail(haus.CodeMissingField, "missing field%s %s", s, strings.Join(missing, ", "))
}

// missingFirst returns the error for the fields of rt that r lacks, if it
// lacks any, instead of err, an error inside r (nil: none so far); at is
// the length of the path at r.
func (w *walker) missingFirst(r haus.Record, rt *recordType, at int, err error) error {
	if rt.required == 0 || err == errTwoPasses {
		return err
	}
	w.path = w.path[:at]
	if m := w.missing(r, rt); m != nil {
		return m
	}
	return err
}

// record decodes r, which is v, with rt. A record that lacks fields fails with
// missing-field before anything inside it is looked at: the fields are
// counted as they are decoded, and an error inside the record gives way to
// missing-field, at the record (path holds at steps there).
func (w *walker) record(v haus.Value, r haus.Record, rt *recordType) (haus.Value, bool, error) {
	at := len(w.path)
	fields := recordFields(r)
	if w.writing {
		w.b = append(w.b, '{')
	}
	var out []haus.Field
	required, written, next := 0, 0, 0
	for i := range fields {
		k := fields[i].Key
		f := rt.fieldAt(k, &next)
		if f == nil {
			if rt.closed {
				if err := w.missingFirst(r, rt, at, nil); err != nil {
					return nil, false, err
				}
				w.path = append(w.path, step{key: k, index: -1})
				return nil, false, w.fail(haus.CodeUnknownField, "%s is not a field of this closed record", quoteKey(k))
			}
			if out == nil && !w.writing {
				out = append(make([]haus.Field, 0, len(fields)), fields[:i]...)
			}
			continue
		}
		// k is a key of the schema, so it is valid UTF-8 (w.key).
		if !f.optional {
			required++
		}
		if w.writing {
			w.writeKey(written, f.written, false)
			written++
		}
		y, changed, err := w.child(step{key: k, index: -1}, fields[i].Value, f.typ)
		if err != nil {
			return nil, false, w.missingFirst(r, rt, at, err)
		}
		if changed && out == nil && !w.writing {
			out = append(make([]haus.Field, 0, len(fields)), fields[:i]...)
		}
		if out != nil {
			out = append(out, haus.Field{Key: k, Value: y})
		}
	}
	if required < rt.required {
		return nil, false, w.missing(r, rt)
	}
	if w.writing {
		w.writeClose(written)
		return v, false, nil
	}
	if out != nil {
		return recordOwned(out), true, nil
	}
	return v, false, nil
}

func (w *walker) variant(v haus.Value, vt *variantType, t *typ) (haus.Value, bool, error) {
	x, ok := v.(haus.Variant)
	if !ok {
		return w.mismatch(v, t)
	}
	c := vt.caseOf(x.Tag.String())
	if c == nil {
		if vt.open {
			return w.raw(v)
		}
		return nil, false, w.fail(haus.CodeUnknownTag, "%s is not allowed here: expected %s", quote(x.Tag.String()), tags(vt))
	}
	switch c.payload {
	case payloadNone:
		if len(x.Args) == 0 {
			if w.writing {
				w.writeTag(x.Tag.String())
			}
			return v, false, nil
		}
		return nil, false, w.fail(haus.CodeWrongPayload, "%s takes no payload", x.Tag.String())
	case payloadRecord, payloadNamed:
		r, ok := oneRecord(x.Args)
		if !ok {
			return nil, false, w.fail(haus.CodeWrongPayload, "%s takes one argument, a record; found %s", x.Tag.String(), foundArgs(x.Args))
		}
		if w.writing {
			w.writeTag(x.Tag.String())
			w.space()
		}
		// Tag { … }: the record is at the variant's level and place.
		var (
			y       haus.Value
			changed bool
			err     error
		)
		if c.payload == payloadRecord {
			y, changed, err = w.record(x.Args[0], r, c.rec)
		} else {
			y, changed, err = w.value(r, c.named)
		}
		if err != nil || !changed || w.writing {
			return v, false, err
		}
		return haus.Variant{Tag: haus.MustTag(x.Tag.String()), Args: []haus.Value{y}}, true, nil
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
			x.Tag.String(), len(c.items), s, strings.Join(described, ", "), len(x.Args))
	}
	record := false
	if w.writing {
		w.writeTag(x.Tag.String())
		if len(x.Args) == 1 {
			record = w.payloadStart(x.Args[0])
		} else {
			w.b = append(w.b, '(')
		}
	}
	var out []haus.Value
	for i, a := range x.Args {
		if w.writing && i > 0 {
			w.separator()
		}
		y, changed, err := w.child(step{index: i}, a, c.items[i])
		if err != nil {
			return nil, false, err
		}
		if changed && out == nil && !w.writing {
			out = make([]haus.Value, len(x.Args))
			copy(out, x.Args[:i])
		}
		if out != nil {
			out[i] = y
		}
	}
	if w.writing {
		if !record {
			w.b = append(w.b, ')')
		}
		return v, false, nil
	}
	if out != nil {
		return haus.Variant{Tag: haus.MustTag(x.Tag.String()), Args: out}, true, nil
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
		return "the string " + `"` + quote(string(v)) + `"`
	case haus.Number:
		return "the number " + short(v.String())
	case haus.Bytes:
		return "bytes"
	case haus.Array:
		return "an array"
	case haus.Record:
		return "a record"
	case haus.Variant:
		return "the tag " + quote(v.Tag.String())
	case haus.Secret:
		return "a Secret"
	}
	return "nothing"
}
