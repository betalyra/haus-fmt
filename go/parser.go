package haus

import (
	"fmt"
	"slices"
	"strings"
	"sync"
	"unicode/utf8"
)

// Parse reads text that must hold exactly one value (spec §6), with the
// default limits. Two or more values, or none, fail with the code
// not-one-value.
func Parse(src []byte) (Value, error) {
	return ParseWith(src, Limits{})
}

// ParseWith is [Parse] with the given limits.
func ParseWith(src []byte, limits Limits) (Value, error) {
	vs, err := ParseAllWith(src, limits)
	if err != nil {
		return nil, err
	}
	if len(vs) != 1 {
		return nil, &Error{Code: CodeNotOneValue,
			Message:  fmt.Sprintf("expected exactly one value, found %d", len(vs)),
			Expected: "one value", Found: fmt.Sprintf("%d values", len(vs))}
	}
	return vs[0], nil
}

// ParseAll reads a file (spec §1, §6): zero or more top-level values,
// separated by commas, with an optional comma after the last. The text must
// be UTF-8; a leading byte order mark is skipped. The default limits apply.
func ParseAll(src []byte) ([]Value, error) {
	return ParseAllWith(src, Limits{})
}

// ParseAllWith is [ParseAll] with the given limits.
func ParseAllWith(src []byte, limits Limits) ([]Value, error) {
	lim, err := limits.resolve()
	if err != nil {
		return nil, err
	}
	p := newParser(string(src), lim, false)
	defer p.release()
	vs, _, err := p.file()
	return vs, err
}

// parser is a recursive-descent parser over one complete text. It reads
// bytes by index; the text is valid UTF-8 (checked first), so multi-byte
// characters only need a look where they could be a control or bidi
// character. Strings, keys, tags and numbers are slices of the text where
// they need no decoding.
type parser struct {
	src   string
	pos   int
	lim   Limits
	depth int
	keep  bool // also build the syntax tree, with comments, for the formatter

	fileStart bool // src starts the file: a byte order mark at src[0] is skipped, and #haus after it is a version directive
	line, col int  // the position of src[0] in the whole input, 1-based

	// Scratch stacks, the innermost container's entries last: the fields
	// of the records and the items of the arrays and payloads being read.
	// A container's entries are copied out at its closer, into a slice of
	// their exact length. used is the most entries either has held.
	fields []Field
	items  []Value
	used   int
}

// parsers keeps parsers for reuse, so that their scratch stacks don't grow
// anew for every text.
var parsers = sync.Pool{New: func() any { return new(parser) }}

// maxPooledScratch is the most entries a scratch stack of a parser that
// goes back to the pool may have room for.
const maxPooledScratch = 4096

func newParser(src string, lim Limits, keep bool) *parser {
	p := parsers.Get().(*parser)
	*p = parser{src: src, lim: lim, keep: keep, fileStart: true, line: 1, col: 1,
		fields: p.fields[:0], items: p.items[:0]}
	return p
}

// release returns p to the pool, its scratch stacks cleared of the values
// they held. p must not be used after.
func (p *parser) release() {
	if cap(p.fields) > maxPooledScratch || cap(p.items) > maxPooledScratch {
		return
	}
	used := max(p.used, len(p.fields), len(p.items))
	clear(p.fields[:min(used, cap(p.fields))])
	clear(p.items[:min(used, cap(p.items))])
	*p = parser{fields: p.fields[:0], items: p.items[:0]}
	parsers.Put(p)
}

// popScratch takes a container's entries, from base, off a scratch stack,
// as a slice of their exact length (nil for none), and records in used the
// most entries the stack has held.
func popScratch[T any](stack *[]T, base int, used *int) []T {
	if len(*stack) == base {
		return nil
	}
	entries := slices.Clone((*stack)[base:])
	*used = max(*used, len(*stack))
	*stack = (*stack)[:base]
	return entries
}

// fail returns an error at byte offset pos.
func (p *parser) fail(pos int, code ErrorCode, format string, args ...any) error {
	line, col := position(p.src, pos)
	if line == 1 {
		col += p.col - 1
	}
	line += p.line - 1
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Line: line, Column: col}
}

// failFound is fail with Expected and Found filled in.
func (p *parser) failFound(pos int, code ErrorCode, expected string) error {
	err := p.fail(pos, code, "expected %s, found %s", expected, describeChar(p.src, pos)).(*Error)
	err.Expected = expected
	err.Found = describeChar(p.src, pos)
	return err
}

// position returns the 1-based line and column (in code points) of byte
// offset pos (spec §8).
func position(s string, pos int) (line, col int) {
	pos = min(pos, len(s))
	before := s[:pos]
	start := strings.LastIndexByte(before, '\n') + 1
	return 1 + strings.Count(before, "\n"), 1 + utf8.RuneCountInString(before[start:])
}

// invalidUTF8 returns the offset of the first byte of s that isn't part of
// a valid UTF-8 sequence.
func invalidUTF8(s string) int {
	for i := 0; i < len(s); {
		if s[i] < utf8.RuneSelf {
			i++
			continue
		}
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			return i
		}
		i += n
	}
	return len(s)
}

const bom = "\uFEFF"

// file parses the whole text: a sequence of top-level values.
func (p *parser) file() ([]Value, *fileNode, error) {
	if !utf8.ValidString(p.src) {
		return nil, nil, p.fail(invalidUTF8(p.src), CodeInvalidUTF8, "invalid UTF-8")
	}
	if p.fileStart && strings.HasPrefix(p.src, bom) {
		p.pos = len(bom)
	}
	if p.fileStart && strings.HasPrefix(p.src[p.pos:], "#haus") {
		return nil, nil, p.fail(p.pos, CodeVersionDirective,
			"the file starts with a version directive: it needs a newer version of haus")
	}
	var values []Value
	var syn *fileNode
	var g gap
	gp := p.gap(&g)
	if p.keep {
		syn = &fileNode{}
	}
	if err := p.ws(gp); err != nil {
		return nil, nil, err
	}
	var prev *item
	for p.pos < len(p.src) {
		if p.src[p.pos] == ',' {
			return nil, nil, p.expectedValue(p.pos)
		}
		var it *item
		if p.keep {
			it = newItem(prev, &g)
		}
		v, n, err := p.value()
		if err != nil {
			return nil, nil, err
		}
		values = append(values, v)
		if p.keep {
			it.val = n
			syn.items = append(syn.items, it)
			prev = it
		}
		if err := p.ws(gp); err != nil {
			return nil, nil, err
		}
		if p.pos >= len(p.src) {
			break
		}
		if p.src[p.pos] != ',' {
			return nil, nil, p.afterValue(v, 0, 0)
		}
		p.pos++
		g.run = 0
		if err := p.ws(gp); err != nil {
			return nil, nil, err
		}
	}
	if p.keep {
		syn.dangling, _, _ = closeItems(prev, &g)
	}
	return values, syn, nil
}

// gap returns g when the parser keeps comments, and nil otherwise.
func (p *parser) gap(g *gap) *gap {
	if p.keep {
		return g
	}
	return nil
}

func (p *parser) rawCharError(i int, code ErrorCode, where string) error {
	switch code {
	case CodeLoneCarriageReturn:
		return p.fail(i, code, "a carriage return not followed by a line feed")
	case CodeBidiControl:
		return p.fail(i, code, "a raw bidirectional control character, %s, %s", describeChar(p.src, i), where)
	}
	return p.fail(i, code, "a raw control character, %s, %s", describeChar(p.src, i), where)
}

// ws skips whitespace and comments. When g is not nil, it records the
// comments and line breaks in g.
func (p *parser) ws(g *gap) error {
	s := p.src
	i := p.pos
	for i < len(s) {
		switch s[i] {
		case ' ', '\t':
			i++
		case '\n':
			i++
			g.lineBreak()
		case '\r':
			if i+1 < len(s) && s[i+1] == '\n' {
				i += 2
				g.lineBreak()
				continue
			}
			p.pos = i
			return p.rawCharError(i, CodeLoneCarriageReturn, "")
		case '/':
			start := i
			var err error
			switch {
			case i+1 < len(s) && s[i+1] == '/':
				i, err = p.lineComment(i)
			case i+1 < len(s) && s[i+1] == '*':
				i, err = p.blockComment(i)
			default:
				return p.fail(i, CodeStraySlash, "a '/' that doesn't start a comment")
			}
			if err != nil {
				return err
			}
			if g != nil {
				text := s[start:i]
				if strings.IndexByte(text, '\r') >= 0 {
					text = strings.ReplaceAll(text, "\r\n", "\n")
				}
				g.comments = append(g.comments, comment{text: text, nl: g.nl})
				g.nl, g.run = 0, 0
			}
		default:
			p.pos = i
			return nil
		}
	}
	p.pos = i
	return nil
}

// lineComment reads a // comment from s[i] and returns its end: the line
// break or the end of input.
func (p *parser) lineComment(i int) (int, error) {
	s := p.src
	for i += 2; i < len(s); i++ {
		c := s[i]
		if c == '\n' {
			return i, nil
		}
		if !rawCheck[c] {
			continue
		}
		if c == '\r' && i+1 < len(s) && s[i+1] == '\n' {
			return i, nil
		}
		if code := rawCharCode(s, i); code != "" {
			return 0, p.rawCharError(i, code, "in a comment")
		}
	}
	return i, nil
}

// blockComment reads a nested /* */ comment from s[i] and returns its end.
func (p *parser) blockComment(i int) (int, error) {
	s := p.src
	start := i
	depth := 0
	for i < len(s) {
		c := s[i]
		if !commentStop[c] {
			i++
			continue
		}
		switch {
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			depth++
			i += 2
		case c == '*' && i+1 < len(s) && s[i+1] == '/':
			depth--
			i += 2
			if depth == 0 {
				return i, nil
			}
		case c != '*' && c != '/':
			if code := rawCharCode(s, i); code != "" {
				return 0, p.rawCharError(i, code, "in a comment")
			}
			i++
		default:
			i++
		}
	}
	return 0, p.fail(start, CodeUnterminatedComment, "a /* comment that is never closed")
}

// unclosed reports the end of input inside the bracket opened at open.
func (p *parser) unclosed(open int, closer byte) error {
	err := p.fail(open, CodeUnclosedBracket, "'%c' is never closed: the input ends before its '%c'", p.src[open], closer).(*Error)
	err.Expected = fmt.Sprintf("'%c'", closer)
	err.Found = "end of input"
	return err
}

// enter starts a record, array or payload at pos, one level deeper.
func (p *parser) enter(pos int) error {
	p.depth++
	if p.depth > p.lim.MaxDepth {
		return p.fail(pos, CodeNestingTooDeep, "nesting deeper than the limit of %d", p.lim.MaxDepth)
	}
	return nil
}

// expectedValue reports what stands at pos where a value must be.
func (p *parser) expectedValue(pos int) error {
	return p.failFound(pos, CodeExpectedValue, "a value")
}

// afterValue reports what stands at p.pos after a value, where a comma or
// the closer (0 at the top level) must be. open is the opening bracket.
func (p *parser) afterValue(v Value, open int, closer byte) error {
	i := p.pos
	s := p.src
	if i >= len(s) {
		return p.unclosed(open, closer)
	}
	expected := "','"
	if closer != 0 {
		expected = fmt.Sprintf("',' or '%c'", closer)
	}
	switch s[i] {
	case '}', ']', ')':
		if closer == 0 {
			return p.fail(i, CodeUnexpectedCloser, "a closing '%c' without an opening bracket", s[i])
		}
		return p.fail(i, CodeUnexpectedCloser, "expected '%c', found '%c'", closer, s[i])
	case '(', '{':
		if v, ok := v.(Variant); ok && len(v.Args) == 0 {
			err := p.failFound(i, CodePayloadNewline, expected).(*Error)
			err.Message = fmt.Sprintf("the payload of %s must start on its line: expected %s, found '%c'", v.Tag, expected, s[i])
			return err
		}
	}
	return p.failFound(i, CodeMissingComma, expected)
}

// value parses the value at p.pos.
func (p *parser) value() (Value, *node, error) {
	s := p.src
	if p.pos >= len(s) {
		return nil, nil, p.expectedValue(p.pos)
	}
	c := s[p.pos]
	switch {
	case c == '{':
		r, n, err := p.record()
		return r, n, err
	case c == '[':
		return p.array()
	case c == '"':
		if strings.HasPrefix(s[p.pos:], `"""`) {
			return p.blockString()
		}
		start := p.pos
		str, err := p.basicString(CodeStringTooLong)
		if err != nil {
			return nil, nil, err
		}
		v := String(str)
		if p.keep {
			return v, &node{val: v, text: s[start:p.pos]}, nil
		}
		return v, nil, nil
	case c == '-' || c == '+' || c == '.' || isDigit(c):
		start := p.pos
		end, norm, e := scanNumber(s, p.pos, &p.lim)
		if e != nil {
			return nil, nil, p.fail(e.pos, e.code, "%s", e.msg)
		}
		p.pos = end
		v := Number{lit: norm}
		if p.keep {
			return v, &node{val: v, text: s[start:end]}, nil
		}
		return v, nil, nil
	case c >= 'A' && c <= 'Z':
		return p.variant()
	case c == 'x' && p.pos+1 < len(s) && s[p.pos+1] == '"':
		return p.bytes()
	case c >= 'a' && c <= 'z' || c == '_':
		start := p.pos
		word := s[start:p.identEnd(start)]
		switch word {
		case "null":
			return nil, nil, p.fail(start, CodeNullLiteral, "null is not a value: haus has no null")
		case "true", "false":
			return nil, nil, p.fail(start, CodeBooleanLiteral, "%s is not a value: booleans are the tags True and False", word)
		}
		return nil, nil, p.fail(start, CodeBareIdentifier,
			"a lowercase word, %s, where a value must be", quoteForMessage(word))
	}
	return nil, nil, p.expectedValue(p.pos)
}

// identEnd returns the end of the identifier that starts at s[i].
func (p *parser) identEnd(i int) int {
	s := p.src
	for i++; i < len(s) && isWordChar(s[i]); i++ {
	}
	return i
}

// record parses { … } at p.pos.
func (p *parser) record() (Record, *node, error) {
	open := p.pos
	if err := p.enter(open); err != nil {
		return Record{}, nil, err
	}
	p.pos++
	base := len(p.fields) // this record's fields are p.fields[base:]
	var index map[string]int
	var syn *node
	var g gap
	gp := p.gap(&g)
	if p.keep {
		syn = &node{}
	}
	if err := p.ws(gp); err != nil {
		return Record{}, nil, err
	}
	var prev *item
	s := p.src
	for {
		if p.pos >= len(s) {
			return Record{}, nil, p.unclosed(open, '}')
		}
		if s[p.pos] == '}' {
			p.pos++
			p.depth--
			r := Record{fields: popScratch(&p.fields, base, &p.used), index: index}
			if p.keep {
				syn.val = r
				syn.dangling, syn.sameLine, syn.closeNL = closeItems(prev, &g)
			}
			return r, syn, nil
		}
		keyAt := p.pos
		key, err := p.key()
		if err != nil {
			return Record{}, nil, err
		}
		// Duplicate keys: a scan for small records, a map for larger ones.
		fields := p.fields[base:]
		if index != nil {
			if _, dup := index[key]; dup {
				return Record{}, nil, p.duplicateKey(keyAt, key)
			}
			index[key] = len(fields)
		} else {
			for _, f := range fields {
				if f.Key == key {
					return Record{}, nil, p.duplicateKey(keyAt, key)
				}
			}
			if len(fields)+1 >= indexFrom {
				index = make(map[string]int, 2*indexFrom)
				for i, f := range fields {
					index[f.Key] = i
				}
				index[key] = len(fields)
			}
		}
		var it *item
		if p.keep {
			it = newItem(prev, &g)
			it.keyed, it.key = true, key
		}
		if err := p.ws(gp); err != nil {
			return Record{}, nil, err
		}
		if p.pos >= len(s) || s[p.pos] != ':' {
			err := p.failFound(p.pos, CodeMissingColon, "':'").(*Error)
			err.Message = fmt.Sprintf("expected ':' after the key %s, found %s", quoteForMessage(key), err.Found)
			return Record{}, nil, err
		}
		p.pos++
		g.run = 0
		if err := p.ws(gp); err != nil {
			return Record{}, nil, err
		}
		v, n, err := p.value()
		if err != nil {
			return Record{}, nil, err
		}
		p.fields = append(p.fields, Field{Key: key, Value: v})
		if p.keep {
			// Comments between the key and the value move above the entry,
			// after its blank line.
			if len(g.comments) > 0 {
				g.comments[0].nl = max(g.comments[0].nl, blankNL(it.blank))
				it.blank = false
			}
			it.leading = append(it.leading, g.comments...)
			g = gap{}
			it.val = n
			syn.items = append(syn.items, it)
			prev = it
		}
		if err := p.ws(gp); err != nil {
			return Record{}, nil, err
		}
		if p.pos < len(s) && s[p.pos] == ',' {
			p.pos++
			g.run = 0
			if err := p.ws(gp); err != nil {
				return Record{}, nil, err
			}
			continue
		}
		if p.pos < len(s) && s[p.pos] == '}' {
			continue
		}
		return Record{}, nil, p.afterValue(v, open, '}')
	}
}

func (p *parser) duplicateKey(pos int, key string) error {
	return p.fail(pos, CodeDuplicateKey, "the key %s is already in this record", quoteForMessage(key))
}

// key parses a record key at p.pos: an identifier or a "…" string.
func (p *parser) key() (string, error) {
	s := p.src
	i := p.pos
	c := s[i]
	switch {
	case c >= 'a' && c <= 'z' || c == '_':
		end := p.identEnd(i)
		p.pos = end
		key := s[i:end]
		if len(key) > p.lim.MaxStringLength {
			return "", p.fail(i, CodeKeyTooLong, "a key longer than the limit of %d characters", p.lim.MaxStringLength)
		}
		return key, nil
	case c == '"':
		if strings.HasPrefix(s[i:], `"""`) {
			return "", p.fail(i, CodeBlockStringKey, `a block string (""") can't be a key`)
		}
		return p.basicString(CodeKeyTooLong)
	case c >= 'A' && c <= 'Z':
		word := s[i:p.identEnd(i)]
		return "", p.fail(i, CodeUppercaseKey,
			"the key %s starts with a capital letter: quote it, or start it with a lowercase letter", quoteForMessage(word))
	}
	return "", p.failFound(i, CodeExpectedKey, "a key")
}

// array parses [ … ] at p.pos.
func (p *parser) array() (Value, *node, error) {
	vs, syn, err := p.sequence(']')
	if err != nil {
		return nil, nil, err
	}
	a := Array(vs)
	if p.keep {
		syn.val = a
	}
	return a, syn, nil
}

// sequence parses the values of an array, or the arguments of a payload,
// from the opening bracket at p.pos to the closer.
func (p *parser) sequence(closer byte) ([]Value, *node, error) {
	open := p.pos
	if err := p.enter(open); err != nil {
		return nil, nil, err
	}
	p.pos++
	base := len(p.items) // the values read so far are p.items[base:]
	var syn *node
	var g gap
	gp := p.gap(&g)
	if p.keep {
		syn = &node{}
	}
	if err := p.ws(gp); err != nil {
		return nil, nil, err
	}
	var prev *item
	s := p.src
	for {
		if p.pos >= len(s) {
			return nil, nil, p.unclosed(open, closer)
		}
		if s[p.pos] == closer {
			if closer == ')' && len(p.items) == base {
				return nil, nil, p.fail(open, CodeEmptyPayload, "empty parentheses after a tag: write the tag alone")
			}
			p.pos++
			p.depth--
			values := popScratch(&p.items, base, &p.used)
			if p.keep {
				syn.dangling, syn.sameLine, syn.closeNL = closeItems(prev, &g)
			}
			return values, syn, nil
		}
		var it *item
		if p.keep {
			it = newItem(prev, &g)
		}
		v, n, err := p.value()
		if err != nil {
			return nil, nil, err
		}
		p.items = append(p.items, v)
		if p.keep {
			it.val = n
			syn.items = append(syn.items, it)
			prev = it
		}
		if err := p.ws(gp); err != nil {
			return nil, nil, err
		}
		if p.pos < len(s) && s[p.pos] == ',' {
			p.pos++
			g.run = 0
			if err := p.ws(gp); err != nil {
				return nil, nil, err
			}
			continue
		}
		if p.pos < len(s) && s[p.pos] == closer {
			continue
		}
		return nil, nil, p.afterValue(v, open, closer)
	}
}

// variant parses a tag at p.pos and its payload, if one follows on the
// same line.
func (p *parser) variant() (Value, *node, error) {
	s := p.src
	start := p.pos
	end := p.identEnd(start)
	tag := s[start:end]
	if len(tag) > p.lim.MaxStringLength {
		return nil, nil, p.fail(start, CodeTagTooLong, "a tag longer than the limit of %d characters", p.lim.MaxStringLength)
	}
	j := end
	for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
		j++
	}
	if j >= len(s) || s[j] != '(' && s[j] != '{' {
		p.pos = end
		v := Variant{Tag: tag}
		if p.keep {
			return v, &node{val: v}, nil
		}
		return v, nil, nil
	}
	p.pos = j
	if s[j] == '{' {
		r, rn, err := p.record()
		if err != nil {
			return nil, nil, err
		}
		v := Variant{Tag: tag, Args: []Value{r}}
		if p.keep {
			rn.val = v
			rn.form = formBraces
		}
		return v, rn, nil
	}
	args, syn, err := p.sequence(')')
	if err != nil {
		return nil, nil, err
	}
	v := Variant{Tag: tag, Args: args}
	if p.keep {
		syn.val = v
		syn.form = formParens
		if len(args) == 1 && args[0].Kind() == KindRecord {
			syn = mergeRecordArg(syn)
		}
	}
	return v, syn, nil
}

// basicString parses a "…" string at p.pos and returns its value. code is
// the error for a string over the length limit.
func (p *parser) basicString(tooLong ErrorCode) (string, error) {
	s := p.src
	start := p.pos
	i := start + 1
	var b []byte // the value, once an escape needs decoding
	plain := i   // start of the current run of plain characters
	for {
		i = plainRun(s, i, &stringStop)
		if i >= len(s) {
			return "", p.fail(start, CodeUnterminatedString, "a string without its closing '\"'")
		}
		switch c := s[i]; c {
		case '"':
			var v string
			if b == nil {
				v = s[plain:i]
			} else {
				v = string(append(b, s[plain:i]...))
			}
			p.pos = i + 1
			if len(v) > p.lim.MaxStringLength {
				if n := utf8.RuneCountInString(v); n > p.lim.MaxStringLength {
					return "", p.fail(start, tooLong, "a string of %d characters, more than the limit of %d", n, p.lim.MaxStringLength)
				}
			}
			return v, nil
		case '\\':
			if b == nil {
				b = make([]byte, 0, i-plain+16)
			}
			b = append(b, s[plain:i]...)
			var err error
			b, i, err = p.escape(b, i)
			if err != nil {
				return "", err
			}
			plain = i
		case '\n':
			return "", p.fail(i, CodeStringLineBreak, `a line break in a "…" string: write \n, or use a """ block string`)
		case '\r':
			// A carriage return in a "…" string is a control character, also
			// directly before a line feed (spec §4, "Which error").
			return "", p.rawCharError(i, CodeControlCharacter, "in a string: write it as an escape")
		default:
			if code := rawCharCode(s, i); code != "" || c == '\t' {
				if code == "" {
					code = CodeControlCharacter
				}
				return "", p.rawCharError(i, code, "in a string: write it as an escape")
			}
			i++
		}
	}
}

// escape decodes the escape whose backslash is at s[i], appends its
// character to b, and returns the offset after it.
func (p *parser) escape(b []byte, i int) (out []byte, next int, err error) {
	s := p.src
	if i+1 >= len(s) {
		return nil, 0, p.fail(i, CodeInvalidEscape, "a backslash at the end of the input")
	}
	switch c := s[i+1]; c {
	case '"', '\\':
		return append(b, c), i + 2, nil
	case 'n':
		return append(b, '\n'), i + 2, nil
	case 'r':
		return append(b, '\r'), i + 2, nil
	case 't':
		return append(b, '\t'), i + 2, nil
	case 'u':
		j := i + 2
		if j >= len(s) || s[j] != '{' {
			return nil, 0, p.fail(i, CodeInvalidUnicodeEscape, `a \u escape is written with braces: \u{1F600}`)
		}
		j++
		r := rune(0)
		k := j
		for k < len(s) && isHexDigit(s[k]) && k-j < 7 {
			r = r<<4 | rune(hexValue(s[k]))
			k++
		}
		if k == j || k-j > 6 || k >= len(s) || s[k] != '}' {
			return nil, 0, p.fail(i, CodeInvalidUnicodeEscape, `a \u{…} escape needs 1 to 6 hex digits and a closing '}'`)
		}
		if r > utf8.MaxRune || r >= 0xD800 && r <= 0xDFFF {
			return nil, 0, p.fail(i, CodeInvalidUnicodeEscape, `\u{%s} is not a Unicode scalar value`, s[j:k])
		}
		return utf8.AppendRune(b, r), k + 1, nil
	}
	return nil, 0, p.fail(i, CodeInvalidEscape, `%s doesn't start an escape: use \", \\, \n, \r, \t or \u{…}`,
		quoteForMessage(s[i:i+1+utf8RuneLen(s, i+1)]))
}

func utf8RuneLen(s string, i int) int {
	_, n := utf8.DecodeRuneInString(s[i:])
	return n
}

func hexValue(c byte) byte {
	switch {
	case c <= '9':
		return c - '0'
	case c >= 'a':
		return c - 'a' + 10
	}
	return c - 'A' + 10
}

// blockString parses a """ block string at p.pos (spec §4).
func (p *parser) blockString() (Value, *node, error) {
	s := p.src
	start := p.pos
	i := start + 3
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	switch {
	case i >= len(s):
		// Nothing after the opening: no line break, at the block string.
		return nil, nil, p.fail(start, CodeBlockStringOpening, `the opening """ must be followed by a line break`)
	case s[i] == '\n':
		i++
	case s[i] == '\r' && i+1 < len(s) && s[i+1] == '\n':
		i += 2
	default:
		return nil, nil, p.fail(i, CodeBlockStringOpening, `text after the opening """: the content starts on the next line`)
	}
	// The closing """, skipping escaped characters; then the lines before it.
	end := -1
	for j := i; j < len(s); j++ {
		if s[j] == '\\' {
			j++
		} else if s[j] == '"' && strings.HasPrefix(s[j:], `"""`) {
			end = j
			break
		}
	}
	if end < 0 {
		return nil, nil, p.fail(start, CodeUnterminatedBlockString, `a block string without its closing """`)
	}
	type span struct{ from, to int }
	var lines []span
	for at := i; ; {
		nl := strings.IndexByte(s[at:end], '\n')
		if nl < 0 {
			lines = append(lines, span{at, end})
			break
		}
		to := at + nl
		if to > at && s[to-1] == '\r' {
			to--
		}
		lines = append(lines, span{at, to})
		at += nl + 1
	}
	last := lines[len(lines)-1]
	lines = lines[:len(lines)-1]
	indent := s[last.from:last.to]
	if strings.Trim(indent, " \t") != "" {
		return nil, nil, p.fail(end, CodeBlockStringClosing, `the closing """ must stand on a line of its own`)
	}
	p.pos = end + 3
	// Line by line: the indent, then the content in order, raw characters
	// and escapes (spec §4, "Which error": the same order in every binding).
	var b []byte
	for k, l := range lines {
		if k > 0 {
			b = append(b, '\n')
		}
		line := s[l.from:l.to]
		from := l.from
		switch {
		case strings.HasPrefix(line, indent):
			from += len(indent)
		case strings.Trim(line, " \t") == "":
			continue
		default:
			return nil, nil, p.fail(l.from, CodeBlockStringIndent,
				`a line of a block string indented less than its closing """`)
		}
		for j := from; j < l.to; {
			c := s[j]
			if c == '\\' {
				var err error
				b, j, err = p.escape(b, j)
				if err != nil {
					return nil, nil, err
				}
				if j > l.to {
					return nil, nil, p.fail(j, CodeInvalidEscape, "an escape across a line break")
				}
				continue
			}
			if rawCheck[c] {
				if code := rawCharCode(s, j); code != "" {
					// A carriage return that isn't part of a line break is a
					// control character here (spec §4, "Which error").
					if code == CodeLoneCarriageReturn {
						code = CodeControlCharacter
					}
					return nil, nil, p.rawCharError(j, code, "in a block string: write it as an escape")
				}
			}
			run := j + 1
			for run < l.to && s[run] != '\\' && !rawCheck[s[run]] {
				run++
			}
			b = append(b, s[j:run]...)
			j = run
		}
	}
	v := string(b)
	if len(v) > p.lim.MaxStringLength {
		if n := utf8.RuneCountInString(v); n > p.lim.MaxStringLength {
			return nil, nil, p.fail(start, CodeStringTooLong, "a string of %d characters, more than the limit of %d", n, p.lim.MaxStringLength)
		}
	}
	if p.keep {
		return String(v), &node{val: String(v)}, nil
	}
	return String(v), nil, nil
}

// bytes parses a byte string x"…" at p.pos.
func (p *parser) bytes() (Value, *node, error) {
	s := p.src
	start := p.pos
	i := start + 2
	var b []byte
	for {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
			i++
		}
		if i >= len(s) {
			return nil, nil, p.fail(start, CodeUnterminatedBytes, `a byte string without its closing '"'`)
		}
		c := s[i]
		if c == '"' {
			break
		}
		if !isHexDigit(c) {
			return nil, nil, p.bytesNotHex(i)
		}
		if i+1 >= len(s) {
			return nil, nil, p.fail(start, CodeUnterminatedBytes, `a byte string without its closing '"'`)
		}
		d := s[i+1]
		switch {
		case isHexDigit(d):
			b = append(b, hexValue(c)<<4|hexValue(d))
			i += 2
		default:
			return nil, nil, p.fail(i, CodeBytesOddDigits, "a byte with one hex digit: write two hex digits per byte")
		}
	}
	p.pos = i + 1
	if n := i - start - 2; n > p.lim.MaxStringLength {
		return nil, nil, p.fail(start, CodeStringTooLong, "a byte string of %d characters, more than the limit of %d", n, p.lim.MaxStringLength)
	}
	if b == nil {
		b = []byte{}
	}
	v := Bytes(b)
	if p.keep {
		return v, &node{val: v, text: s[start:p.pos]}, nil
	}
	return v, nil, nil
}

func (p *parser) bytesNotHex(i int) error {
	return p.fail(i, CodeBytesNotHex, "%s in a byte string: only hex digits, spaces and tabs", describeChar(p.src, i))
}
