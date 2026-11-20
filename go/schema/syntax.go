package schema

import (
	"fmt"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/internal/hooks"
)

// parseValues parses the arguments of an attribute: values within the file,
// where a byte order mark is a mistake and #haus no version directive.
var parseValues = hooks.ParseValues.(func(string) ([]haus.Value, error))

// The syntax tree of one schema file (spec §14, grammar.ebnf "Schema
// files"), and its parser: a recursive descent over the text with a cursor.
// Positions are byte offsets into the text.

// tyKind is the kind of a type expression.
type tyKind uint8

const (
	tyName    tyKind = iota // a named type applied to arguments: Array Point, Int
	tyParam                 // a type parameter: a
	tyRecord                // { … } or closed { … }
	tyVariant               // < … > or closed < … >
)

// ty is a type expression as written.
type ty struct {
	kind    tyKind
	name    string // tyName, tyParam
	args    []*ty  // tyName
	pos     int
	closed  bool
	fields  []*fieldDef
	cases   []*caseDef
	spreads []spreadDef // ...Name, with how many own entries come before each
}

type fieldDef struct {
	key      string
	optional bool
	ty       *ty
	pos      int
	attrs    []attribute
}

type caseDef struct {
	tag     string
	payload []*ty // Tag A B: positional; Tag { … }: one record
	pos     int
	attrs   []attribute
}

type spreadDef struct {
	name  string
	at    int // own fields or cases before it
	pos   int
	attrs []attribute // rejected: a spread has no attributes
}

// attribute is @name or @name(value, …) (spec §14).
type attribute struct {
	name string
	args []haus.Value
	pos  int
}

type typeDef struct {
	name   string
	params []string
	ty     *ty
	pos    int
	doc    string // the // lines directly above
	attrs  []attribute
}

type nameAt struct {
	name string
	pos  int
}

type importDecl struct {
	module string
	names  []nameAt
	pos    int
}

type file struct {
	imports  []importDecl
	types    []*typeDef
	warnings []*synErr
}

// synErr is a mistake at a byte offset of a file.
type synErr struct {
	pos  int
	code haus.ErrorCode
	msg  string
}

func (e *synErr) Error() string { return e.msg }

func failAt(pos int, code haus.ErrorCode, format string, args ...any) *synErr {
	return &synErr{pos: pos, code: code, msg: fmt.Sprintf(format, args...)}
}

// maxTypeNesting is the deepest nesting of type expressions the parser reads
// (type-too-deep).
const maxTypeNesting = 128

// definedAttributes are the attributes this version defines (spec §14).
var definedAttributes = map[string]bool{"deprecated": true}

type parser struct {
	src   string
	pos   int
	depth int
}

// parseFile parses a schema file and checks what the grammar allows but the
// spec doesn't (§14): duplicate types, fields and tags, prelude names,
// parameters, imports without names or with a version that isn't a major,
// `closed < >`, row parameters and attributes. Spreads, names and arities
// need the other files and are checked when the schema is resolved.
func parseFile(src string) (*file, *synErr) {
	if !utf8.ValidString(src) {
		i := 0
		for i < len(src) {
			r, n := utf8.DecodeRuneInString(src[i:])
			if r == utf8.RuneError && n == 1 {
				break
			}
			i += n
		}
		return nil, failAt(i, haus.CodeInvalidUTF8, "invalid UTF-8")
	}
	p := &parser{src: src}
	if strings.HasPrefix(src, "\uFEFF") {
		p.pos = 3
	}
	f, err := p.file()
	if err != nil {
		return nil, err
	}
	warnings, err := check(f)
	if err != nil {
		return nil, err
	}
	warnings = append(warnings, deprecatedUses(f)...)
	f.warnings = warnings
	for _, d := range f.types {
		at := d.pos
		if len(d.attrs) > 0 {
			at = d.attrs[0].pos
		}
		d.doc = docComment(src, at)
	}
	return f, nil
}

// ── lexical ──────────────────────────────────────────────────

func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func isWord(c byte) bool  { return isUpper(c) || isLower(c) || isDigit(c) || c == '_' }

var keywords = map[string]bool{"type": true, "import": true, "closed": true}

// found names what stands at i, for messages.
func (p *parser) found(i int) string {
	s := p.src
	if i >= len(s) {
		return "end of file"
	}
	j := i
	for j < len(s) && isWord(s[j]) {
		j++
	}
	if j > i {
		return "'" + quote(s[i:j]) + "'"
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	return "'" + quote(string(r)) + "'"
}

func (p *parser) expected(what string) *synErr {
	// A '/' that doesn't start a comment, where whitespace may be: as in data (§14).
	if p.pos < len(p.src) && p.src[p.pos] == '/' {
		return failAt(p.pos, haus.CodeStraySlash, "unexpected '/' (comments are // or /* */)")
	}
	return failAt(p.pos, haus.CodeSchemaSyntax, "expected %s, found %s", what, p.found(p.pos))
}

// rawChar is the error for a raw control or bidirectional character at i in
// a comment (spec §4), or nil.
func (p *parser) rawChar(i int) *synErr {
	s := p.src
	c := s[i]
	switch {
	case c == '\t' || c == '\n':
		return nil
	case c == '\r':
		if i+1 < len(s) && s[i+1] == '\n' {
			return nil
		}
		return failAt(i, haus.CodeLoneCarriageReturn, "a carriage return not followed by a line feed")
	case c < 0x20 || c == 0x7f:
		return failAt(i, haus.CodeControlCharacter, "a raw control character, U+%04X, in a comment", c)
	case c < utf8.RuneSelf:
		return nil
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	switch {
	case r >= 0x80 && r <= 0x9f:
		return failAt(i, haus.CodeControlCharacter, "a raw control character, U+%04X, in a comment", r)
	case r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069:
		return failAt(i, haus.CodeBidiControl, "a raw bidirectional control character, U+%04X, in a comment", r)
	}
	return nil
}

// ws skips whitespace and comments, as in data files (grammar "ws").
func (p *parser) ws() *synErr {
	s := p.src
	for p.pos < len(s) {
		switch c := s[p.pos]; {
		case c == ' ' || c == '\t' || c == '\n':
			p.pos++
		case c == '\r':
			if p.pos+1 < len(s) && s[p.pos+1] == '\n' {
				p.pos += 2
				continue
			}
			return failAt(p.pos, haus.CodeLoneCarriageReturn, "a carriage return not followed by a line feed")
		case c == '/' && p.pos+1 < len(s) && s[p.pos+1] == '/':
			i := p.pos + 2
			for i < len(s) && s[i] != '\n' {
				if s[i] == '\r' && i+1 < len(s) && s[i+1] == '\n' {
					break
				}
				if s[i] < 0x20 || s[i] >= 0x7f {
					if err := p.rawChar(i); err != nil {
						return err
					}
				}
				i++
			}
			p.pos = i
		case c == '/' && p.pos+1 < len(s) && s[p.pos+1] == '*':
			start := p.pos
			depth := 0
			i := p.pos
			for {
				if i >= len(s) {
					return failAt(start, haus.CodeUnterminatedComment, "a /* comment that is never closed")
				}
				switch {
				case strings.HasPrefix(s[i:], "/*"):
					depth++
					i += 2
				case strings.HasPrefix(s[i:], "*/"):
					depth--
					i += 2
				default:
					if s[i] < 0x20 || s[i] >= 0x7f {
						if err := p.rawChar(i); err != nil {
							return err
						}
					}
					i++
				}
				if depth == 0 {
					break
				}
			}
			p.pos = i
		default:
			return nil
		}
	}
	return nil
}

// peekWord returns the word at p.pos, without moving.
func (p *parser) peekWord() string {
	s := p.src
	j := p.pos
	for j < len(s) && isWord(s[j]) {
		j++
	}
	return s[p.pos:j]
}

// word reads a word whose first byte satisfies first, then whitespace.
func (p *parser) word(first func(byte) bool) (w string, ok bool, err *synErr) {
	if p.pos >= len(p.src) || !first(p.src[p.pos]) {
		return "", false, nil
	}
	w = p.peekWord()
	p.pos += len(w)
	return w, true, p.ws()
}

func (p *parser) upper(what string) (name string, pos int, err *synErr) {
	pos = p.pos
	w, ok, err := p.word(isUpper)
	if err != nil {
		return "", 0, err
	}
	if !ok {
		return "", 0, p.expected(what)
	}
	return w, pos, nil
}

// keyword reports whether the keyword w is at p.pos, and reads it.
func (p *parser) keyword(w string) (bool, *synErr) {
	if p.peekWord() != w {
		return false, nil
	}
	p.pos += len(w)
	return true, p.ws()
}

// sym reads the symbol s if it is next.
func (p *parser) sym(s string) (bool, *synErr) {
	if !strings.HasPrefix(p.src[p.pos:], s) {
		return false, nil
	}
	p.pos += len(s)
	return true, p.ws()
}

func (p *parser) need(s string) *synErr {
	ok, err := p.sym(s)
	if err != nil {
		return err
	}
	if !ok {
		return p.expected("'" + s + "'")
	}
	return nil
}

// isParam reports whether a lowercase word can be a type parameter here.
func (p *parser) atParam() bool {
	if p.pos >= len(p.src) || !isLower(p.src[p.pos]) && p.src[p.pos] != '_' {
		return false
	}
	return !keywords[p.peekWord()]
}

// ── structure ────────────────────────────────────────────────

func (p *parser) file() (*file, *synErr) {
	f := &file{}
	if err := p.ws(); err != nil {
		return nil, err
	}
	for p.pos < len(p.src) {
		if p.peekWord() == "import" {
			imp, err := p.importDecl()
			if err != nil {
				return nil, err
			}
			f.imports = append(f.imports, imp)
			continue
		}
		d, err := p.typeDef()
		if err != nil {
			return nil, err
		}
		f.types = append(f.types, d)
	}
	return f, nil
}

func (p *parser) importDecl() (importDecl, *synErr) {
	imp := importDecl{pos: p.pos}
	if _, err := p.keyword("import"); err != nil {
		return imp, err
	}
	s := p.src
	start := p.pos
	switch {
	case strings.HasPrefix(s[p.pos:], "std/"):
		p.pos += 4
		if p.pos >= len(s) || !isLower(s[p.pos]) && s[p.pos] != '_' {
			return imp, p.expected("a module (std/time, @org/name, ./file)")
		}
		p.pos += len(p.peekWord())
	case p.pos < len(s) && (s[p.pos] == '@' || s[p.pos] == '.'):
		p.pos++
		for p.pos < len(s) && (isWord(s[p.pos]) || strings.IndexByte("_.-/@~", s[p.pos]) >= 0) {
			p.pos++
		}
		if p.pos == start+1 {
			p.pos = start
			return imp, p.expected("a module (std/time, @org/name, ./file)")
		}
	default:
		return imp, p.expected("a module (std/time, @org/name, ./file)")
	}
	imp.module = s[start:p.pos]
	if err := p.ws(); err != nil {
		return imp, err
	}
	if err := p.need("("); err != nil {
		return imp, err
	}
	for {
		if p.pos < len(s) && isUpper(s[p.pos]) {
			name, pos, err := p.upper("a type name")
			if err != nil {
				return imp, err
			}
			imp.names = append(imp.names, nameAt{name, pos})
			ok, err := p.sym(",")
			if err != nil {
				return imp, err
			}
			if ok {
				continue
			}
		}
		break
	}
	if err := p.need(")"); err != nil {
		return imp, err
	}
	return imp, nil
}

func (p *parser) typeDef() (*typeDef, *synErr) {
	attrs, err := p.attributes()
	if err != nil {
		return nil, err
	}
	ok, err := p.keyword("type")
	if err != nil {
		return nil, err
	}
	if !ok {
		if len(attrs) > 0 {
			return nil, p.expected("'type' after the attributes")
		}
		return nil, p.expected("'type' or 'import'")
	}
	d := &typeDef{attrs: attrs}
	d.name, d.pos, err = p.upper("a type name")
	if err != nil {
		return nil, err
	}
	for p.atParam() {
		w, _, err := p.word(func(byte) bool { return true })
		if err != nil {
			return nil, err
		}
		d.params = append(d.params, w)
	}
	if err := p.need("="); err != nil {
		return nil, err
	}
	d.ty, err = p.typ()
	return d, err
}

// attributes reads the attributes before a type, field or tag.
func (p *parser) attributes() ([]attribute, *synErr) {
	var attrs []attribute
	for p.pos < len(p.src) && p.src[p.pos] == '@' {
		a, err := p.attribute()
		if err != nil {
			return nil, err
		}
		attrs = append(attrs, a)
	}
	return attrs, nil
}

// attribute reads @name or @name(value, …), whose arguments are haus values
// read by the data parser.
func (p *parser) attribute() (attribute, *synErr) {
	s := p.src
	a := attribute{pos: p.pos}
	p.pos++
	if p.pos >= len(s) || !isLower(s[p.pos]) && s[p.pos] != '_' {
		return a, p.expected("an attribute name after '@': @deprecated")
	}
	a.name = p.peekWord()
	p.pos += len(a.name)
	if p.pos < len(s) && s[p.pos] == '(' {
		end := closingParen(s, p.pos)
		if end < 0 {
			return a, p.unclosedArguments(p.pos, a.name)
		}
		inner := s[p.pos+1 : end]
		values, err := parseValues(inner)
		if err != nil {
			return a, p.dataError(err, p.pos+1, "in the arguments of @"+a.name)
		}
		if len(values) == 0 {
			return a, failAt(p.pos, haus.CodeAttributeArguments, "empty parentheses: write @%s without them", a.name)
		}
		a.args = values
		p.pos = end + 1
		return a, p.ws()
	}
	if err := p.ws(); err != nil {
		return a, err
	}
	if p.pos < len(s) && s[p.pos] == '(' {
		return a, failAt(p.pos, haus.CodeAttributeSpace, "expected '(' right after the attribute's name, without a space")
	}
	return a, nil
}

// unclosedArguments is the error of attribute arguments whose '(' at open
// has no ')': what reading them value by value finds first, as for any
// arguments. A value that isn't one is the data parser's error; after the
// last value, a comma or nothing means the '(' is unclosed, anything else
// that a ',' or ')' is missing.
func (p *parser) unclosedArguments(open int, name string) *synErr {
	inner := p.src[open+1:]
	values, err := parseValues(inner)
	switch {
	case err != nil:
		return p.dataError(err, open+1, "in the arguments of @"+name)
	case len(values) == 0 || strings.HasSuffix(strings.TrimRight(inner, " \t\r\n"), ","):
		return failAt(open, haus.CodeUnclosedBracket, "unclosed '(' of an attribute")
	}
	return failAt(len(p.src), haus.CodeMissingComma, "expected ',' or ')' in the attribute's arguments")
}

// dataError turns an error of the data parser, in text that starts at the
// byte offset base, into an error at its place in the file.
func (p *parser) dataError(err error, base int, where string) *synErr {
	e, ok := err.(*haus.Error)
	if !ok {
		return failAt(base, haus.CodeSchemaSyntax, "%s: %v", where, err)
	}
	pos := base
	if e.Line > 0 {
		pos = offsetOf(p.src, base, e.Line, e.Column)
	}
	return failAt(pos, e.Code, "%s: %s", where, e.Message)
}

// offsetOf returns the byte offset of a 1-based line and column (in code
// points) of the text that starts at base.
func offsetOf(s string, base, line, col int) int {
	i := base
	for l := 1; l < line && i < len(s); i++ {
		if s[i] == '\n' {
			l++
		}
	}
	for c := 1; c < col && i < len(s); c++ {
		_, n := utf8.DecodeRuneInString(s[i:])
		i += n
	}
	return i
}

// closingParen returns the offset of the ')' that matches the '(' at s[i],
// skipping strings, comments and nested brackets, or -1.
func closingParen(s string, i int) int {
	depth := 0
	for i < len(s) {
		switch c := s[i]; {
		case c == '(' || c == '[' || c == '{':
			depth++
			i++
		case c == ')' || c == ']' || c == '}':
			depth--
			if depth == 0 {
				if c == ')' {
					return i
				}
				return -1
			}
			if depth < 0 {
				return -1
			}
			i++
		case strings.HasPrefix(s[i:], `"""`):
			j := i + 3
			for j < len(s) && !strings.HasPrefix(s[j:], `"""`) {
				if s[j] == '\\' {
					j++
				}
				j++
			}
			if j >= len(s) {
				return -1
			}
			i = j + 3
		case c == '"':
			j := i + 1
			for j < len(s) && s[j] != '"' && s[j] != '\n' {
				if s[j] == '\\' {
					j++
				}
				j++
			}
			i = j + 1
		case strings.HasPrefix(s[i:], "//"):
			j := strings.IndexByte(s[i:], '\n')
			if j < 0 {
				return -1
			}
			i += j
		case strings.HasPrefix(s[i:], "/*"):
			nested := 0
			for {
				if i >= len(s) {
					return -1
				}
				if strings.HasPrefix(s[i:], "/*") {
					nested++
					i += 2
				} else if strings.HasPrefix(s[i:], "*/") {
					nested--
					i += 2
					if nested == 0 {
						break
					}
				} else {
					i++
				}
			}
		default:
			i++
		}
	}
	return -1
}

// ── types ────────────────────────────────────────────────────

// enter starts a nested type expression at pos.
func (p *parser) enter(pos int) *synErr {
	p.depth++
	if p.depth > maxTypeNesting {
		return failAt(pos, haus.CodeTypeTooDeep, "types nested deeper than %d levels", maxTypeNesting)
	}
	return nil
}

// typ reads `Name atom+ | atom`. Only parentheses, records and variants
// count as a level of nesting, as in every binding.
func (p *parser) typ() (*ty, *synErr) {
	if p.pos < len(p.src) && isUpper(p.src[p.pos]) {
		name, pos, err := p.upper("a type name")
		if err != nil {
			return nil, err
		}
		t := &ty{kind: tyName, name: name, pos: pos}
		for {
			a, err := p.atom()
			if err != nil {
				return nil, err
			}
			if a == nil {
				return t, nil
			}
			t.args = append(t.args, a)
		}
	}
	a, err := p.atom()
	if err != nil {
		return nil, err
	}
	if a == nil {
		return nil, p.expected("a type")
	}
	return a, nil
}

// atom reads an atom, or returns nil if none starts at p.pos.
func (p *parser) atom() (*ty, *synErr) {
	s := p.src
	if p.pos >= len(s) {
		return nil, nil
	}
	pos := p.pos
	switch c := s[p.pos]; {
	case isUpper(c):
		name, pos, err := p.upper("a type name")
		if err != nil {
			return nil, err
		}
		return &ty{kind: tyName, name: name, pos: pos}, nil
	case c == '(':
		if err := p.enter(pos); err != nil {
			return nil, err
		}
		defer func() { p.depth-- }()
		if _, err := p.sym("("); err != nil {
			return nil, err
		}
		t, err := p.typ()
		if err != nil {
			return nil, err
		}
		return t, p.need(")")
	case c == '{':
		return p.record(false)
	case c == '<':
		return p.variant(false)
	case isLower(c) || c == '_':
		w := p.peekWord()
		if w == "closed" {
			if _, err := p.keyword("closed"); err != nil {
				return nil, err
			}
			switch {
			case p.pos < len(s) && s[p.pos] == '{':
				return p.record(true)
			case p.pos < len(s) && s[p.pos] == '<':
				return p.variant(true)
			}
			return nil, p.expected("'{' or '<' after closed")
		}
		if keywords[w] {
			return nil, nil
		}
		p.pos += len(w)
		return &ty{kind: tyParam, name: w, pos: pos}, p.ws()
	}
	return nil, nil
}

// spread reads ...Name (a lowercase name is read too, for check to reject).
func (p *parser) spread(at int, attrs []attribute) (spreadDef, *synErr) {
	p.pos += 3
	if err := p.ws(); err != nil {
		return spreadDef{}, err
	}
	pos := p.pos
	if p.pos >= len(p.src) || !isUpper(p.src[p.pos]) && !isLower(p.src[p.pos]) && p.src[p.pos] != '_' {
		return spreadDef{}, p.expected("a type name after '...': ...UserEvent")
	}
	name := p.peekWord()
	p.pos += len(name)
	return spreadDef{name: name, at: at, pos: pos, attrs: attrs}, p.ws()
}

func (p *parser) record(closed bool) (*ty, *synErr) {
	t := &ty{kind: tyRecord, closed: closed, pos: p.pos}
	if err := p.enter(p.pos); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	if err := p.need("{"); err != nil {
		return nil, err
	}
	s := p.src
	for {
		if ok, err := p.sym("}"); ok || err != nil {
			return t, err
		}
		attrs, err := p.attributes()
		if err != nil {
			return nil, err
		}
		switch {
		case strings.HasPrefix(s[p.pos:], "..."):
			sp, err := p.spread(len(t.fields), attrs)
			if err != nil {
				return nil, err
			}
			t.spreads = append(t.spreads, sp)
		default:
			f, err := p.field(attrs)
			if err != nil {
				return nil, err
			}
			t.fields = append(t.fields, f)
		}
		ok, err := p.sym(",")
		if err != nil {
			return nil, err
		}
		if !ok {
			return t, p.need("}")
		}
	}
}

func (p *parser) field(attrs []attribute) (*fieldDef, *synErr) {
	s := p.src
	f := &fieldDef{pos: p.pos, attrs: attrs}
	switch {
	case p.pos < len(s) && (isLower(s[p.pos]) || s[p.pos] == '_'):
		f.key = p.peekWord()
		p.pos += len(f.key)
		if err := p.ws(); err != nil {
			return nil, err
		}
	case p.pos < len(s) && s[p.pos] == '"':
		key, err := p.stringLit()
		if err != nil {
			return nil, err
		}
		f.key = key
	default:
		if len(attrs) > 0 {
			return nil, p.expected("a field after the attributes")
		}
		return nil, p.expected("a field name")
	}
	ok, err := p.sym("?")
	if err != nil {
		return nil, err
	}
	f.optional = ok
	if err := p.need(":"); err != nil {
		return nil, err
	}
	f.ty, err = p.typ()
	return f, err
}

// stringLit reads a "…" key: the data grammar's basic string.
func (p *parser) stringLit() (string, *synErr) {
	s := p.src
	start := p.pos
	// `"""` is the key "" and a '"' that no rule takes: the grammar has no block strings.
	if strings.HasPrefix(s[start:], `"""`) {
		p.pos = start + 2
		return "", nil
	}
	i := start + 1
	for i < len(s) && s[i] != '"' && s[i] != '\n' {
		if s[i] == '\\' {
			i++
		}
		i++
	}
	// The string up to its closing '"', or to the line break or end where it
	// stops, which the data parser reports as in data (string-line-break,
	// control-character for a carriage return, unterminated-string).
	v, err := haus.Parse([]byte(s[start:min(i+1, len(s))]))
	if err != nil {
		return "", p.dataError(err, start, "in a field name")
	}
	str, _ := v.(haus.String)
	p.pos = i + 1
	return string(str), p.ws()
}

func (p *parser) variant(closed bool) (*ty, *synErr) {
	t := &ty{kind: tyVariant, closed: closed, pos: p.pos}
	if err := p.enter(p.pos); err != nil {
		return nil, err
	}
	defer func() { p.depth-- }()
	if err := p.need("<"); err != nil {
		return nil, err
	}
	if _, err := p.sym("|"); err != nil {
		return nil, err
	}
	s := p.src
	if ok, err := p.sym(">"); ok || err != nil {
		return t, err
	}
	for {
		attrs, err := p.attributes()
		if err != nil {
			return nil, err
		}
		switch {
		case strings.HasPrefix(s[p.pos:], "..."):
			sp, err := p.spread(len(t.cases), attrs)
			if err != nil {
				return nil, err
			}
			t.spreads = append(t.spreads, sp)
		case p.pos < len(s) && isUpper(s[p.pos]):
			c := &caseDef{attrs: attrs}
			c.tag, c.pos, err = p.upper("a tag")
			if err != nil {
				return nil, err
			}
			for {
				a, err := p.atom()
				if err != nil {
					return nil, err
				}
				if a == nil {
					break
				}
				c.payload = append(c.payload, a)
			}
			t.cases = append(t.cases, c)
		default:
			if len(attrs) > 0 {
				return nil, p.expected("a tag after the attributes")
			}
			return nil, p.expected("a tag")
		}
		ok, err := p.sym("|")
		if err != nil {
			return nil, err
		}
		if !ok {
			return t, p.need(">")
		}
	}
}

// docComment returns the // lines directly above the line of pos.
func docComment(src string, pos int) string {
	before := src[:pos]
	if i := strings.LastIndexByte(before, '\n'); i >= 0 {
		before = before[:i]
	} else {
		return ""
	}
	var lines []string
	for before != "" {
		i := strings.LastIndexByte(before, '\n')
		line := strings.TrimSpace(before[i+1:])
		text, ok := strings.CutPrefix(line, "//")
		if !ok {
			break
		}
		lines = append(lines, strings.TrimPrefix(text, " "))
		if i < 0 {
			break
		}
		before = before[:i]
	}
	for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
		lines[i], lines[j] = lines[j], lines[i]
	}
	return strings.Join(lines, "\n")
}

// ── checks ───────────────────────────────────────────────────

// prelude is the prelude's types and their number of parameters (spec §13).
// A schema can't redefine them.
var prelude = map[string]int{
	"Bool": 0, "Maybe": 1, "Result": 2, "String": 0, "Bytes": 0, "Array": 1, "Map": 1,
	"Int": 0, "Int8": 0, "Int16": 0, "Int32": 0, "Int64": 0,
	"UInt8": 0, "UInt16": 0, "UInt32": 0, "UInt64": 0,
	"Float32": 0, "Float64": 0, "Decimal": 0, "Any": 0, "Secret": 1, "Stream": 1,
}

// check reports what the grammar allows but the spec doesn't (§14), and
// returns the warnings: attributes this version doesn't define.
func check(f *file) (warnings []*synErr, err *synErr) {
	names := map[string]bool{}
	for _, d := range f.types {
		if names[d.name] {
			return nil, failAt(d.pos, haus.CodeDuplicateType, "%s is defined twice", d.name)
		}
		names[d.name] = true
	}
	for _, d := range f.types {
		if _, ok := prelude[d.name]; ok {
			return nil, failAt(d.pos, haus.CodeRedefinePrelude, "%s is a prelude type and can't be redefined", d.name)
		}
	}
	for _, imp := range f.imports {
		if len(imp.names) == 0 {
			return nil, failAt(imp.pos, haus.CodeUnknownImport, "import %s names no type: import %s (Name, …)", quote(imp.module), quote(imp.module))
		}
	}
	for _, imp := range f.imports {
		if why := importVersion(imp.module); why != "" {
			return nil, failAt(imp.pos, haus.CodeImportVersion, "%s", why)
		}
	}
	for _, imp := range f.imports {
		if strings.HasPrefix(imp.module, "@") && !isPackageName(packageOf(imp.module)) {
			return nil, failAt(imp.pos, haus.CodeUnknownModule,
				"unknown module %s: a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)", quote(imp.module))
		}
	}
	for _, d := range f.types {
		seen := map[string]bool{}
		for _, prm := range d.params {
			if strings.HasPrefix(prm, "_") {
				return nil, failAt(d.pos, haus.CodeInvalidParameter, "%s can't be a parameter name: a parameter starts with a lowercase letter", prm)
			}
			if seen[prm] {
				return nil, failAt(d.pos, haus.CodeInvalidParameter, "parameter %s appears twice", prm)
			}
			seen[prm] = true
		}
	}
	for _, d := range f.types {
		if err := checkTy(d.ty); err != nil {
			return nil, err
		}
	}
	eachAttributes(f, func(attrs []attribute) {
		if err != nil {
			return
		}
		var w []*synErr
		w, err = checkAttributes(attrs)
		warnings = append(warnings, w...)
	})
	return warnings, err
}

func checkTy(t *ty) *synErr {
	for _, s := range t.spreads {
		if !isUpper(s.name[0]) {
			return failAt(s.pos, haus.CodeRowParameter,
				"row parameters (...%s) aren't supported; spread a named type instead: ...UserEvent", s.name)
		}
	}
	for _, s := range t.spreads {
		if len(s.attrs) > 0 {
			return failAt(s.attrs[0].pos, haus.CodeAttributeOnSpread,
				"a spread can't have attributes; the fields or tags of %s keep their own", s.name)
		}
	}
	switch t.kind {
	case tyName:
		for _, a := range t.args {
			if err := checkTy(a); err != nil {
				return err
			}
		}
	case tyParam:
		if t.name == "_" {
			return failAt(t.pos, haus.CodeUnderscoreType,
				"types are open by default, so there is no _: write < > for any tag, or use a type parameter")
		}
	case tyRecord:
		seen := map[string]bool{}
		for _, f := range t.fields {
			if seen[f.key] {
				return failAt(f.pos, haus.CodeDuplicateField, "duplicate field %s", quoteKey(f.key))
			}
			seen[f.key] = true
		}
		for _, f := range t.fields {
			if err := checkTy(f.ty); err != nil {
				return err
			}
		}
	case tyVariant:
		if t.closed && len(t.cases) == 0 && len(t.spreads) == 0 {
			return failAt(t.pos, haus.CodeClosedEmptyVariant, "a closed variant needs at least one tag")
		}
		seen := map[string]bool{}
		for _, c := range t.cases {
			if seen[c.tag] {
				return failAt(c.pos, haus.CodeDuplicateTag, "duplicate tag %s", c.tag)
			}
			seen[c.tag] = true
		}
		for _, c := range t.cases {
			for _, a := range c.payload {
				if err := checkTy(a); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// eachAttributes calls f with every list of attributes in the file: of its
// types, fields and tags.
func eachAttributes(file *file, f func([]attribute)) {
	var walk func(t *ty)
	walk = func(t *ty) {
		for _, a := range t.args {
			walk(a)
		}
		for _, fd := range t.fields {
			f(fd.attrs)
			walk(fd.ty)
		}
		for _, c := range t.cases {
			f(c.attrs)
			for _, a := range c.payload {
				walk(a)
			}
		}
	}
	for _, d := range file.types {
		f(d.attrs)
		walk(d.ty)
	}
}

// checkAttributes checks the attributes of one type, field or tag: defined
// ones take the right arguments and are written once. Unknown ones are
// accepted, with a warning (spec §14).
func checkAttributes(attrs []attribute) (warnings []*synErr, err *synErr) {
	for i, a := range attrs {
		if !definedAttributes[a.name] {
			warnings = append(warnings, failAt(a.pos, haus.CodeUnknownAttribute,
				"unknown attribute @%s: this version of haus ignores it", a.name))
			continue
		}
		for _, b := range attrs[:i] {
			if b.name == a.name {
				return nil, failAt(a.pos, haus.CodeAttributeTwice, "@%s is written twice here", a.name)
			}
		}
		if a.name == "deprecated" {
			if _, ok := deprecation(attrs); len(a.args) > 1 || len(a.args) == 1 && !ok {
				return nil, failAt(a.pos, haus.CodeAttributeArguments,
					`@deprecated takes at most one argument, a string: @deprecated("use email")`)
			}
		}
	}
	return warnings, nil
}

// deprecation returns the message of a @deprecated among attrs ("" without
// one), and whether there is one with a string argument or none.
func deprecation(attrs []attribute) (string, bool) {
	for _, a := range attrs {
		if a.name != "deprecated" {
			continue
		}
		switch len(a.args) {
		case 0:
			return "", true
		case 1:
			if s, ok := a.args[0].(haus.String); ok {
				return string(s), true
			}
		}
		return "", false
	}
	return "", false
}

// isDeprecated reports whether attrs mark something deprecated.
func isDeprecated(attrs []attribute) bool {
	for _, a := range attrs {
		if a.name == "deprecated" {
			return true
		}
	}
	return false
}

// deprecatedUses warns about uses of the file's deprecated types outside
// deprecated types, once where each is written (spec §14), spreads included.
func deprecatedUses(f *file) []*synErr {
	deprecated := map[string]string{}
	for _, d := range f.types {
		if isDeprecated(d.attrs) {
			why, _ := deprecation(d.attrs)
			deprecated[d.name] = why
		}
	}
	if len(deprecated) == 0 {
		return nil
	}
	var out []*synErr
	use := func(name string, pos int) {
		why, ok := deprecated[name]
		switch {
		case !ok:
		case why != "":
			out = append(out, failAt(pos, haus.CodeDeprecated, "%s is deprecated: %s", name, why))
		default:
			out = append(out, failAt(pos, haus.CodeDeprecated, "%s is deprecated", name))
		}
	}
	var walk func(t *ty)
	walk = func(t *ty) {
		if t.kind == tyName {
			use(t.name, t.pos)
		}
		for _, s := range t.spreads {
			use(s.name, s.pos)
		}
		for _, a := range t.args {
			walk(a)
		}
		for _, fd := range t.fields {
			walk(fd.ty)
		}
		for _, c := range t.cases {
			for _, a := range c.payload {
				walk(a)
			}
		}
	}
	for _, d := range f.types {
		if _, ok := deprecated[d.name]; !ok {
			walk(d.ty)
		}
	}
	return out
}

// withoutAttributes drops every attribute of the file, as if none were
// written: decoding is the same (spec §15).
func withoutAttributes(f *file) {
	var walk func(t *ty)
	walk = func(t *ty) {
		for _, a := range t.args {
			walk(a)
		}
		for _, fd := range t.fields {
			fd.attrs = nil
			walk(fd.ty)
		}
		for _, c := range t.cases {
			c.attrs = nil
			for _, a := range c.payload {
				walk(a)
			}
		}
	}
	for _, d := range f.types {
		d.attrs = nil
		walk(d.ty)
	}
	f.warnings = nil
}

// importVersion says why the version of a package import (@org/name@1.1)
// isn't a major version, @N without leading zeros (spec §13.3), or "".
func importVersion(module string) string {
	if !strings.HasPrefix(module, "@") {
		return ""
	}
	at := strings.IndexByte(module[1:], '@')
	if at < 0 {
		return ""
	}
	name, version := module[:at+1], module[at+2:]
	end := 0
	for end < len(version) && isDigit(version[end]) {
		end++
	}
	digits, rest := version[:end], version[end:]
	major := strings.TrimLeft(digits, "0")
	if major == "" {
		major = "0"
	}
	switch {
	case digits == "" || rest != "" && rest[0] != '.':
		return fmt.Sprintf("%s@%s: expected a major version after '@', like %s@1", quote(name), quote(version), quote(name))
	case rest != "":
		return fmt.Sprintf("%s@%s: an import names only the major version (%s@%s)", quote(name), quote(version), quote(name), major)
	case len(digits) != len(major):
		return fmt.Sprintf("%s@%s: a major version has no leading zeros (%s@%s)", quote(name), quote(version), quote(name), major)
	}
	return ""
}

// packageOf returns the package a package import names, without its @major.
func packageOf(module string) string {
	if at := strings.IndexByte(module[1:], '@'); at >= 0 {
		return module[:at+1]
	}
	return module
}

// stdTime is the types of std/time (spec §13.2), the only standard module.
var stdTime = map[string]bool{
	"Date": true, "Time": true, "DateTime": true, "Instant": true,
	"ZonedDateTime": true, "Duration": true, "YearMonth": true, "TimeZone": true,
}

// unknownType is the message for an unknown type, with how to import it if
// it is a well-known one.
func unknownType(name string) string {
	switch {
	case name == "Money" || name == "Currency":
		return fmt.Sprintf("unknown type %s (import it with: import @haus-fmt/money (%s), and install @haus-fmt/money with your package manager)", name, name)
	case name == "LatLng" || name == "BBox":
		return fmt.Sprintf("unknown type %s (import it with: import @haus-fmt/geo (%s), and install @haus-fmt/geo with your package manager)", name, name)
	case stdTime[name]:
		return fmt.Sprintf("unknown type %s (import it with: import std/time (%s))", name, name)
	}
	return "unknown type " + quote(name)
}
