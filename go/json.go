package haus

import (
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// JSON (spec §16): a strict reader of I-JSON that keeps numbers exact, a
// writer, and the two forms that need no schema, the JSON import (§16.1)
// and self-describing JSON (§16.2). Schema-based JSON (§16.3) is in package
// schema, which reads JSON with the same reader through internal hooks.
//
// The reader turns JSON into the haus value the import gives (§16.1):
// objects are records, arrays arrays, strings strings, numbers numbers with
// their literal normalized, true, false and null the tags True, False and
// None. Since JSON has no other tags, the other forms read that value
// without losing anything of the JSON: a variant in it is a JSON literal.

// jsonMode is what a JSON text is read for: it sets the nesting limit and
// which checks happen while reading.
type jsonMode uint8

const (
	// jsonImport is the import (§16.1): nesting up to d, and the string
	// limits of §7 checked on every string and member name.
	jsonImport jsonMode = iota
	// jsonSchema is schema-based JSON (§16.3): nesting up to 4·d+1; the
	// limits are checked on the value read with the type.
	jsonSchema
	// jsonSelfDescribing is self-describing JSON (§16.2): nesting up to
	// 4·d+2 (the envelope), and raw DEL, C1 and bidi controls rejected.
	jsonSelfDescribing
)

// jsonDepth is the JSON nesting a mode reads (spec §16, "Limits"): a form
// can take up to four JSON levels for one haus level (Tag { … } is
// {"_tag": …, "_args": [{"_rec": {…}}]}), one more for a number
// ({"_num": …}), and one more for the envelope.
func jsonDepth(mode jsonMode, lim Limits) int {
	switch mode {
	case jsonSchema:
		return 4*lim.MaxDepth + 1
	case jsonSelfDescribing:
		return 4*lim.MaxDepth + 2
	}
	return lim.MaxDepth
}

var (
	jsonTrue  Value = Variant{Tag: "True"}
	jsonFalse Value = Variant{Tag: "False"}
	jsonNull  Value = Variant{Tag: "None"}
)

// jsonReader reads one JSON text by recursive descent, over bytes.
type jsonReader struct {
	src      string
	pos      int
	lim      Limits
	mode     jsonMode
	maxDepth int
	depth    int
}

// parseJSON reads one JSON text (RFC 8259, restricted to I-JSON, RFC 7493)
// for mode, within lim (already resolved). A leading byte order mark is
// skipped if bom.
func parseJSON(src string, lim Limits, mode jsonMode, skipBOM bool) (Value, error) {
	r := jsonReader{src: src, lim: lim, mode: mode, maxDepth: jsonDepth(mode, lim)}
	if !utf8.ValidString(src) {
		return nil, r.fail(invalidUTF8(src), CodeInvalidUTF8, "invalid UTF-8")
	}
	if skipBOM && strings.HasPrefix(src, bom) {
		r.pos = len(bom)
	}
	r.ws()
	v, err := r.value()
	if err != nil {
		return nil, err
	}
	r.ws()
	if r.pos < len(r.src) {
		return nil, r.syntax("the end of the JSON text", "unexpected text after the JSON value")
	}
	return v, nil
}

func (r *jsonReader) fail(pos int, code ErrorCode, format string, args ...any) error {
	line, col := position(r.src, pos)
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Line: line, Column: col}
}

// syntax is text that isn't JSON: expected should be here.
func (r *jsonReader) syntax(expected, reason string) error {
	found := describeChar(r.src, r.pos)
	return &Error{Code: CodeJSONSyntax, Message: reason + ", found " + found,
		Line: r.line(), Column: r.column(), Expected: expected, Found: found}
}

func (r *jsonReader) line() int   { l, _ := position(r.src, r.pos); return l }
func (r *jsonReader) column() int { _, c := position(r.src, r.pos); return c }

func (r *jsonReader) ws() {
	for r.pos < len(r.src) {
		switch r.src[r.pos] {
		case ' ', '\t', '\n', '\r':
			r.pos++
		default:
			return
		}
	}
}

func (r *jsonReader) value() (Value, error) {
	if r.pos >= len(r.src) {
		return nil, r.syntax("a JSON value", "unexpected end of the JSON text, expected a value")
	}
	switch c := r.src[r.pos]; {
	case c == '{':
		return r.object()
	case c == '[':
		return r.array()
	case c == '"':
		s, err := r.str(CodeStringTooLong)
		if err != nil {
			return nil, err
		}
		return String(s), nil
	case c == '-' || isDigit(c):
		return r.number()
	case strings.HasPrefix(r.src[r.pos:], "true"):
		r.pos += 4
		return jsonTrue, nil
	case strings.HasPrefix(r.src[r.pos:], "false"):
		r.pos += 5
		return jsonFalse, nil
	case strings.HasPrefix(r.src[r.pos:], "null"):
		r.pos += 4
		return jsonNull, nil
	}
	return nil, r.syntax("a JSON value", "expected a JSON value")
}

// enter starts an object or array at r.pos.
func (r *jsonReader) enter() error {
	if r.depth >= r.maxDepth {
		return r.fail(r.pos, CodeNestingTooDeep, "JSON nesting deeper than %d levels", r.maxDepth)
	}
	r.depth++
	r.pos++
	r.ws()
	return nil
}

func (r *jsonReader) object() (Value, error) {
	if err := r.enter(); err != nil {
		return nil, err
	}
	if r.pos < len(r.src) && r.src[r.pos] == '}' {
		r.pos++
		r.depth--
		return Record{}, nil
	}
	var fields []Field
	var index map[string]struct{}
	for {
		if r.pos >= len(r.src) || r.src[r.pos] != '"' {
			return nil, r.syntax("a member name", "expected a member name (a string)")
		}
		at := r.pos
		key, err := r.str(CodeKeyTooLong)
		if err != nil {
			return nil, err
		}
		dup := false
		if index != nil {
			_, dup = index[key]
			index[key] = struct{}{}
		} else {
			for i := range fields {
				if fields[i].Key == key {
					dup = true
					break
				}
			}
		}
		if dup {
			return nil, r.fail(at, CodeDuplicateKey, "duplicate member name %s", quoteForMessage(key))
		}
		r.ws()
		if r.pos >= len(r.src) || r.src[r.pos] != ':' {
			return nil, r.syntax("':'", "expected ':' after the member name")
		}
		r.pos++
		r.ws()
		v, err := r.value()
		if err != nil {
			return nil, err
		}
		fields = append(fields, Field{Key: key, Value: v})
		if index == nil && len(fields) >= indexFrom {
			index = make(map[string]struct{}, 2*len(fields))
			for _, f := range fields {
				index[f.Key] = struct{}{}
			}
		}
		r.ws()
		if r.pos < len(r.src) && r.src[r.pos] == ',' {
			r.pos++
			r.ws()
			continue
		}
		if r.pos < len(r.src) && r.src[r.pos] == '}' {
			r.pos++
			r.depth--
			return recordOwned(fields), nil
		}
		return nil, r.syntax("',' or '}'", "expected ',' or '}'")
	}
}

func (r *jsonReader) array() (Value, error) {
	if err := r.enter(); err != nil {
		return nil, err
	}
	items := Array{}
	if r.pos < len(r.src) && r.src[r.pos] == ']' {
		r.pos++
		r.depth--
		return items, nil
	}
	for {
		v, err := r.value()
		if err != nil {
			return nil, err
		}
		items = append(items, v)
		r.ws()
		if r.pos < len(r.src) && r.src[r.pos] == ',' {
			r.pos++
			r.ws()
			continue
		}
		if r.pos < len(r.src) && r.src[r.pos] == ']' {
			r.pos++
			r.depth--
			return items, nil
		}
		return nil, r.syntax("',' or ']'", "expected ',' or ']'")
	}
}

// number reads a JSON number token and normalizes it (spec §2). Its length
// and exponent are checked against the number limits (§16, "Limits").
func (r *jsonReader) number() (Value, error) {
	start, i, s := r.pos, r.pos, r.src
	digits := func() bool {
		j := i
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		return i > j
	}
	if s[i] == '-' {
		i++
	}
	switch {
	case i < len(s) && s[i] == '0':
		i++
	case !digits():
		r.pos = i
		return nil, r.syntax("a digit", "invalid number")
	}
	if i < len(s) && s[i] == '.' {
		i++
		if !digits() {
			r.pos = i
			return nil, r.syntax("a digit", "invalid number: expected a digit after '.'")
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if !digits() {
			r.pos = i
			return nil, r.syntax("a digit", "invalid number: expected a digit in the exponent")
		}
	}
	r.pos = i
	_, norm, e := scanNumber(s[start:i], 0, &r.lim)
	if e != nil {
		return nil, r.fail(start+e.pos, e.code, "%s", e.msg)
	}
	return Number{lit: norm}, nil
}

// str reads a string token at r.pos (a '"'). Its length is checked only by
// the import: the other forms count the haus value (§16, "Limits"), and a
// JSON string can be a member name of the form, a number or base64.
func (r *jsonReader) str(tooLong ErrorCode) (string, error) {
	start := r.pos
	s := r.src
	i := start + 1
	strict := r.mode == jsonSelfDescribing
	// The plain run: no escapes, so the string is a slice of the text.
	for i < len(s) {
		c := s[i]
		if c == '"' || c == '\\' || c < 0x20 || strict && rawControl(s, i) != "" {
			break
		}
		i++
	}
	var out string
	if i < len(s) && s[i] == '"' {
		out = s[start+1 : i]
		i++
	} else {
		b := []byte(s[start+1 : i])
		for {
			if i >= len(s) {
				return "", r.fail(start, CodeUnterminatedString, "unterminated string")
			}
			c := s[i]
			switch {
			case c == '"':
				i++
			case c == '\\':
				var err error
				if b, i, err = r.escape(b, i); err != nil {
					return "", err
				}
				continue
			case c < 0x20:
				return "", r.fail(i, CodeControlCharacter, "raw control character U+%04X in a string (write it as an escape)", c)
			case strict && rawControl(s, i) == CodeControlCharacter:
				rr, _ := utf8.DecodeRuneInString(s[i:])
				return "", r.fail(i, CodeControlCharacter, "raw control character U+%04X in a string (write it as an escape)", rr)
			case strict && rawControl(s, i) == CodeBidiControl:
				rr, _ := utf8.DecodeRuneInString(s[i:])
				return "", r.fail(i, CodeBidiControl, "raw bidirectional control U+%04X in a string (write it as an escape)", rr)
			default:
				b = append(b, c)
				i++
				continue
			}
			break
		}
		out = string(b)
	}
	r.pos = i
	if r.mode == jsonImport && len(out) > r.lim.MaxStringLength && utf8.RuneCountInString(out) > r.lim.MaxStringLength {
		what := "string"
		if tooLong == CodeKeyTooLong {
			what = "member name"
		}
		return "", r.fail(start, tooLong, "a %s longer than the limit of %d characters", what, r.lim.MaxStringLength)
	}
	return out, nil
}

// rawControl reports whether s[i] starts DEL, a C1 control or a bidi
// control, which self-describing JSON doesn't allow raw (§16): its code, or
// "".
func rawControl(s string, i int) ErrorCode {
	switch c := s[i]; {
	case c == 0x7F:
		return CodeControlCharacter
	case c == 0xC2 && i+1 < len(s) && s[i+1] >= 0x80 && s[i+1] <= 0x9F:
		return CodeControlCharacter
	case c == 0xE2 && i+2 < len(s):
		switch {
		case s[i+1] == 0x80 && s[i+2] >= 0xAA && s[i+2] <= 0xAE, // U+202A–U+202E
			s[i+1] == 0x81 && s[i+2] >= 0xA6 && s[i+2] <= 0xA9: // U+2066–U+2069
			return CodeBidiControl
		}
	}
	return ""
}

// escape reads the escape at s[i] (a backslash) and appends what it stands
// for to b.
func (r *jsonReader) escape(b []byte, i int) (out []byte, next int, err error) {
	s := r.src
	if i+1 >= len(s) {
		return nil, 0, r.fail(i, CodeInvalidEscape, "invalid escape at the end of the text")
	}
	switch s[i+1] {
	case '"':
		return append(b, '"'), i + 2, nil
	case '\\':
		return append(b, '\\'), i + 2, nil
	case '/':
		return append(b, '/'), i + 2, nil
	case 'b':
		return append(b, '\b'), i + 2, nil
	case 'f':
		return append(b, '\f'), i + 2, nil
	case 'n':
		return append(b, '\n'), i + 2, nil
	case 'r':
		return append(b, '\r'), i + 2, nil
	case 't':
		return append(b, '\t'), i + 2, nil
	case 'u':
	default:
		return nil, 0, r.fail(i, CodeInvalidEscape, "invalid escape \\%s", describeChar(s, i+1))
	}
	unit, ok := hex4(s, i+2)
	if !ok {
		return nil, 0, r.fail(i+2, CodeInvalidUnicodeEscape, "expected four hex digits after \\u")
	}
	switch {
	case unit >= 0xDC00 && unit <= 0xDFFF:
		return nil, 0, r.fail(i, CodeUnpairedSurrogate, "an unpaired surrogate in a \\u escape")
	case unit >= 0xD800 && unit <= 0xDBFF:
		low, ok := rune(-1), false
		if strings.HasPrefix(s[i+6:], `\u`) {
			// A \u after a high surrogate is an escape like any other: four hex digits first.
			if low, ok = hex4(s, i+8); !ok {
				return nil, 0, r.fail(i+8, CodeInvalidUnicodeEscape, "expected four hex digits after \\u")
			}
		}
		if !ok || low < 0xDC00 || low > 0xDFFF {
			return nil, 0, r.fail(i, CodeUnpairedSurrogate, "an unpaired surrogate in a \\u escape")
		}
		return utf8.AppendRune(b, 0x10000+(unit-0xD800)<<10+(low-0xDC00)), i + 12, nil
	}
	return utf8.AppendRune(b, unit), i + 6, nil
}

func hex4(s string, i int) (rune, bool) {
	if i+4 > len(s) {
		return 0, false
	}
	var u rune
	for _, c := range []byte(s[i : i+4]) {
		if !isHexDigit(c) {
			return 0, false
		}
		u = u<<4 | rune(hexValue(c))
	}
	return u, true
}

// ── writing JSON ─────────────────────────────────────────────

const lowerHex = "0123456789abcdef"

// appendJSONString appends s as a JSON string. Besides '"' and '\', it
// escapes what writers must (§16): every character below U+0020, DEL, C1
// controls, bidi controls and U+2028 and U+2029. s must be valid UTF-8.
func appendJSONString(b []byte, s string) []byte {
	b = append(b, '"')
	start := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			if c >= 0x20 && c != '"' && c != '\\' && c != 0x7F {
				i++
				continue
			}
			b = append(b, s[start:i]...)
			switch c {
			case '"':
				b = append(b, '\\', '"')
			case '\\':
				b = append(b, '\\', '\\')
			case '\n':
				b = append(b, '\\', 'n')
			case '\r':
				b = append(b, '\\', 'r')
			case '\t':
				b = append(b, '\\', 't')
			default:
				b = appendU4(b, rune(c))
			}
			i++
			start = i
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if needsEscape(r) {
			b = append(b, s[start:i]...)
			b = appendU4(b, r)
			start = i + size
		}
		i += size
	}
	b = append(b, s[start:]...)
	return append(b, '"')
}

func appendU4(b []byte, r rune) []byte {
	return append(b, '\\', 'u', lowerHex[r>>12&0xF], lowerHex[r>>8&0xF], lowerHex[r>>4&0xF], lowerHex[r&0xF])
}

// appendSelfDescribing appends the self-describing form of v (§16.2),
// without the envelope. v must be valid (see [CheckValue]).
func appendSelfDescribing(b []byte, v Value) []byte {
	switch v := v.(type) {
	case String:
		return appendJSONString(b, string(v))
	case Number:
		b = append(b, `{"_num":"`...)
		b = append(b, v.String()...)
		return append(b, `"}`...)
	case Bytes:
		b = append(b, `{"_bytes":"`...)
		b = hex.AppendEncode(b, v)
		return append(b, `"}`...)
	case Array:
		return appendSelfDescribingItems(b, v)
	case Record:
		b = append(b, `{"_rec":{`...)
		for i, f := range v.fields {
			if i > 0 {
				b = append(b, ',')
			}
			b = appendJSONString(b, f.Key)
			b = append(b, ':')
			b = appendSelfDescribing(b, f.Value)
		}
		return append(b, "}}"...)
	case Variant:
		b = append(b, `{"_tag":`...)
		b = appendJSONString(b, v.Tag)
		if len(v.Args) > 0 {
			b = append(b, `,"_args":`...)
			b = appendSelfDescribingItems(b, v.Args)
		}
		return append(b, '}')
	}
	return b
}

func appendSelfDescribingItems(b []byte, items []Value) []byte {
	b = append(b, '[')
	for i, x := range items {
		if i > 0 {
			b = append(b, ',')
		}
		b = appendSelfDescribing(b, x)
	}
	return append(b, ']')
}

// ── self-describing JSON (§16.2) ─────────────────────────────

// selfDescribing reads the value of a self-describing form (no envelope),
// read as JSON into j, at nesting depth. Errors have the path of the JSON
// member, after prefix (a path from $, or "" for $).
type selfDescribing struct {
	lim    Limits
	prefix string
	path   []step
}

func (s *selfDescribing) fail(code ErrorCode, format string, args ...any) error {
	p := pathString(s.path)
	if s.prefix != "" {
		p = s.prefix + p[1:]
	}
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Path: p}
}

func (s *selfDescribing) push(st step) { s.path = append(s.path, st) }
func (s *selfDescribing) pop()         { s.path = s.path[:len(s.path)-1] }
func key(k string) step                { return step{key: k, index: -1} }

// envelope reads {"_haus": 1, "_value": …}.
func (s *selfDescribing) envelope(j Value) (Value, error) {
	r, ok := j.(Record)
	var h, v Value
	var hasH, hasV bool
	if ok && r.Len() == 2 {
		h, hasH = r.Get("_haus")
		v, hasV = r.Get("_value")
	}
	if !hasH || !hasV {
		return nil, s.fail(CodeHausJSONForm, `expected the envelope {"_haus": 1, "_value": …}, found %s`, describeJSON(j))
	}
	if n, ok := h.(Number); !ok || n.lit != "1" {
		s.push(key("_haus"))
		return nil, s.fail(CodeHausJSONVersion, "expected version 1 of self-describing JSON in '_haus', found %s", describeJSON(h))
	}
	s.push(key("_value"))
	return s.value(v, 0)
}

func (s *selfDescribing) deeper(depth int) (int, error) {
	if depth >= s.lim.MaxDepth {
		return 0, s.fail(CodeNestingTooDeep, "nesting deeper than %d levels", s.lim.MaxDepth)
	}
	return depth + 1, nil
}

func (s *selfDescribing) value(j Value, depth int) (Value, error) {
	switch j := j.(type) {
	case String:
		if len(j) > s.lim.MaxStringLength && utf8.RuneCountInString(string(j)) > s.lim.MaxStringLength {
			return nil, s.fail(CodeStringTooLong, "a string longer than the limit of %d characters", s.lim.MaxStringLength)
		}
		return j, nil
	case Array:
		d, err := s.deeper(depth)
		if err != nil {
			return nil, err
		}
		return s.items(j, d)
	case Record:
		return s.object(j, depth)
	}
	return nil, s.fail(CodeHausJSONForm, "expected the self-describing form of a haus value, found %s", describeJSON(j))
}

func (s *selfDescribing) items(items []Value, depth int) (Array, error) {
	out := make(Array, len(items))
	for i, x := range items {
		s.push(step{index: i})
		v, err := s.value(x, depth)
		if err != nil {
			return nil, err
		}
		s.pop()
		out[i] = v
	}
	return out, nil
}

// object reads {"_rec": …}, {"_num": …}, {"_bytes": …}, {"_tag": …} or
// {"_tag": …, "_args": […]}.
func (s *selfDescribing) object(r Record, depth int) (Value, error) {
	f := r.fields
	switch {
	case len(f) == 1 && f[0].Key == "_rec":
		return s.record(f[0].Value, depth)
	case len(f) == 1 && f[0].Key == "_num":
		s.push(key("_num"))
		text, ok := f[0].Value.(String)
		if !ok || !isNormalized(string(text)) {
			return nil, s.fail(CodeHausJSONNumber, "expected a normalized number literal in '_num', found %s", describeJSON(f[0].Value))
		}
		if code, msg := numberLimits(string(text), s.lim); code != "" {
			return nil, s.fail(code, "%s", msg)
		}
		s.pop()
		return Number{lit: string(text)}, nil
	case len(f) == 1 && f[0].Key == "_bytes":
		s.push(key("_bytes"))
		digits, ok := f[0].Value.(String)
		if !ok || len(digits)%2 != 0 || strings.IndexFunc(string(digits), func(c rune) bool {
			return (c < '0' || c > '9') && (c < 'a' || c > 'f')
		}) >= 0 {
			return nil, s.fail(CodeHausJSONBytes, "expected two lowercase hex digits per byte in '_bytes'")
		}
		if len(digits) > s.lim.MaxStringLength {
			return nil, s.fail(CodeStringTooLong, "a byte string longer than the limit of %d characters", s.lim.MaxStringLength)
		}
		b, _ := hex.DecodeString(string(digits))
		s.pop()
		return Bytes(b), nil
	case len(f) == 1 && f[0].Key == "_tag":
		tag, err := s.tag(f[0].Value)
		if err != nil {
			return nil, err
		}
		return Variant{Tag: tag}, nil
	case len(f) == 2 && (f[0].Key == "_tag" && f[1].Key == "_args" || f[0].Key == "_args" && f[1].Key == "_tag"):
		t, a := f[0].Value, f[1].Value
		if f[0].Key == "_args" {
			t, a = a, t
		}
		tag, err := s.tag(t)
		if err != nil {
			return nil, err
		}
		return s.variant(tag, a, depth)
	}
	return nil, s.fail(CodeHausJSONForm, "expected the self-describing form of a haus value, found %s", describeJSON(r))
}

// variant reads the _args of tag.
func (s *selfDescribing) variant(tag string, args Value, depth int) (Value, error) {
	s.push(key("_args"))
	items, ok := args.(Array)
	if !ok || len(items) == 0 {
		return nil, s.fail(CodeHausJSONForm, "'_args' must be a non-empty array (a tag without arguments has no '_args')")
	}
	if r, ok := items[0].(Record); ok && len(items) == 1 && r.Len() == 1 && r.fields[0].Key == "_rec" {
		// Tag { … } is one level, as in the parser.
		s.push(step{index: 0})
		rec, err := s.record(r.fields[0].Value, depth)
		if err != nil {
			return nil, err
		}
		s.pop()
		s.pop()
		return Variant{Tag: tag, Args: []Value{rec}}, nil
	}
	d, err := s.deeper(depth)
	if err != nil {
		return nil, err
	}
	out, err := s.items(items, d)
	if err != nil {
		return nil, err
	}
	s.pop()
	return Variant{Tag: tag, Args: out}, nil
}

func (s *selfDescribing) record(fields Value, depth int) (Value, error) {
	s.push(key("_rec"))
	r, ok := fields.(Record)
	if !ok {
		return nil, s.fail(CodeHausJSONForm, "expected the fields of a record (an object), found %s", describeJSON(fields))
	}
	d, err := s.deeper(depth)
	if err != nil {
		return nil, err
	}
	out := make([]Field, len(r.fields))
	for i, f := range r.fields {
		if len(f.Key) > s.lim.MaxStringLength && utf8.RuneCountInString(f.Key) > s.lim.MaxStringLength {
			return nil, s.fail(CodeKeyTooLong, "a key longer than the limit of %d characters", s.lim.MaxStringLength)
		}
		s.push(key(f.Key))
		v, err := s.value(f.Value, d)
		if err != nil {
			return nil, err
		}
		s.pop()
		out[i] = Field{Key: f.Key, Value: v}
	}
	s.pop()
	return recordOwned(out), nil
}

// tag reads a '_tag'; its errors are at the variant, the object that holds it.
func (s *selfDescribing) tag(j Value) (string, error) {
	t, ok := j.(String)
	if !ok || !isTag(string(t)) {
		return "", s.fail(CodeInvalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found %s", describeJSON(j))
	}
	if len(t) > s.lim.MaxStringLength {
		return "", s.fail(CodeTagTooLong, "a tag longer than the limit of %d characters", s.lim.MaxStringLength)
	}
	return string(t), nil
}

// isNormalized reports whether text is a normalized number literal (spec
// §2): -?(0|[1-9][0-9]*)(\.[0-9]+)?(e(0|-?[1-9][0-9]*))?
func isNormalized(text string) bool {
	i, s := 0, text
	digits := func() int {
		j := i
		for i < len(s) && isDigit(s[i]) {
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
	case i < len(s) && s[i] >= '1' && s[i] <= '9':
		digits()
	default:
		return false
	}
	if i < len(s) && s[i] == '.' {
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && s[i] == 'e' {
		i++
		switch {
		case i < len(s) && s[i] == '0':
			i++
		default:
			if i < len(s) && s[i] == '-' {
				i++
			}
			if i >= len(s) || s[i] < '1' || s[i] > '9' {
				return false
			}
			digits()
		}
	}
	return i == len(s)
}

// numberLimits checks a normalized literal against the number limits (§7):
// a code and message, or "".
func numberLimits(text string, lim Limits) (code ErrorCode, msg string) {
	if len(text) > lim.MaxNumberLength {
		return CodeNumberTooLong, fmt.Sprintf("a number of %d characters, more than the limit of %d", len(text), lim.MaxNumberLength)
	}
	if i := strings.IndexByte(text, 'e'); i >= 0 {
		exp := strings.TrimPrefix(text[i+1:], "-")
		if len(exp) > 9 || atoi(exp) > lim.MaxExponent {
			return CodeExponentTooLarge, fmt.Sprintf("an exponent larger than the limit of %d", lim.MaxExponent)
		}
	}
	return "", ""
}

// describeJSON is a short description of a JSON value read as a haus value,
// for messages.
func describeJSON(j Value) string {
	switch j := j.(type) {
	case String:
		return "the string " + quoteForMessage(string(j))
	case Number:
		t := j.String()
		if len(t) > 30 {
			t = t[:30] + "…"
		}
		return "the number " + t
	case Array:
		return "an array"
	case Record:
		if j.Len() == 0 {
			return "an empty object"
		}
		names := make([]string, 0, 3)
		for i, f := range j.fields {
			if i == 3 {
				names = append(names, "…")
				break
			}
			names = append(names, strconv.Quote(f.Key))
		}
		return "an object with " + strings.Join(names, ", ")
	case Variant:
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

// ── the public API ───────────────────────────────────────────

// ImportJSON reads any JSON text as a haus value (spec §16.1), with the
// default limits: an object as a record, an array as an array, a string as
// a string, a number as a number with its literal normalized (1E+05 is
// 1e5, 19.90 stays 19.90), true and false as True and False, and null as
// None. Nothing in the data is special: {"_tag": "A"} is a record.
//
// The JSON must be I-JSON (RFC 7493): UTF-8, no duplicate member names, no
// unpaired surrogates. A leading byte order mark is ignored. Errors have
// the position in the JSON text.
func ImportJSON(data []byte) (Value, error) { return ImportJSONWith(data, Limits{}) }

// ImportJSONWith is [ImportJSON] with limits (spec §7): the depth limit is
// the JSON nesting, and strings and member names count their characters
// after escapes are read.
func ImportJSONWith(data []byte, limits Limits) (Value, error) {
	lim, err := limits.resolve()
	if err != nil {
		return nil, err
	}
	return parseJSON(string(data), lim, jsonImport, true)
}

// ToHausJSON writes v as self-describing JSON (spec §16.2), in its envelope:
// {"_haus":1,"_value":…}, on one line without spaces. It checks v first, as
// [CheckValue] does with the default limits. Strings are written as UTF-8,
// with controls, DEL, C1 and bidi controls and U+2028 and U+2029 escaped.
func ToHausJSON(v Value) ([]byte, error) { return AppendHausJSON(nil, v, Limits{}) }

// AppendHausJSON appends the self-describing JSON of v in its envelope to
// dst, checking v against limits first ([CheckValue]).
func AppendHausJSON(dst []byte, v Value, limits Limits) ([]byte, error) {
	if err := CheckValue(v, limits); err != nil {
		return dst, err
	}
	dst = append(dst, `{"_haus":1,"_value":`...)
	dst = appendSelfDescribing(dst, v)
	return append(dst, '}'), nil
}

// FromHausJSON reads self-describing JSON (spec §16.2) with the default
// limits. The text must be an envelope {"_haus": 1, "_value": …}, and the
// value exactly one of the forms of §16.2 (haus-json-form otherwise): every
// accepted text is the form of exactly one value. Errors in the JSON text
// have its position; errors in the form have the path of the JSON member,
// such as $._value._rec.price._num.
func FromHausJSON(data []byte) (Value, error) { return FromHausJSONWith(data, Limits{}) }

// FromHausJSONWith is [FromHausJSON] with limits (spec §7), counted on the
// haus value read. The JSON nesting is limited to 4·d+2 for the depth
// limit d (spec §16, "Limits").
func FromHausJSONWith(data []byte, limits Limits) (Value, error) {
	lim, err := limits.resolve()
	if err != nil {
		return nil, err
	}
	return fromHausJSON(string(data), lim, true, "")
}

func fromHausJSON(src string, lim Limits, bom bool, prefix string) (Value, error) {
	j, err := parseJSON(src, lim, jsonSelfDescribing, bom)
	if err != nil {
		return nil, err
	}
	s := selfDescribing{lim: lim, prefix: prefix}
	return s.envelope(j)
}
