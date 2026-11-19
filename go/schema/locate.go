package schema

import (
	"strings"
	"unicode/utf8"
)

// Where each value of a data file is: a tree of spans with the shape of
// the values haus.ParseAll gives for the same text, so that a check can
// point at the value, key or tag it reports. It scans text the parser has
// already accepted, so it only has to find where things start and end;
// anything unexpected gives no locations rather than wrong ones.

// loc is a value's span (byte offsets, end exclusive), and its parts.
type loc struct {
	start, end int
	tagEnd     int        // for a variant, where its tag ends
	items      []*loc     // array items, or a variant's arguments (Tag { … }: one record)
	fields     []fieldLoc // record fields
}

type fieldLoc struct {
	keyStart, keyEnd int
	val              *loc
}

func (l *loc) item(i int) *loc {
	if l == nil || i >= len(l.items) {
		return nil
	}
	return l.items[i]
}

func (l *loc) field(i int) *fieldLoc {
	if l == nil || i >= len(l.fields) {
		return nil
	}
	return &l.fields[i]
}

// locate returns the top-level values of text, which haus.ParseAll accepts,
// or nil.
func locate(text string) []*loc {
	s := scan{b: text}
	if strings.HasPrefix(text, "\uFEFF") {
		s.pos = 3
	}
	var out []*loc
	s.trivia()
	for s.pos < len(s.b) {
		v := s.value()
		if v == nil {
			return nil
		}
		out = append(out, v)
		s.trivia()
		if s.pos < len(s.b) {
			if !s.eat(',') {
				return nil
			}
			s.trivia()
		}
	}
	return out
}

type scan struct {
	b   string
	pos int
}

func (s *scan) peek() byte {
	if s.pos < len(s.b) {
		return s.b[s.pos]
	}
	return 0
}

func (s *scan) eat(c byte) bool {
	if s.peek() == c && s.pos < len(s.b) {
		s.pos++
		return true
	}
	return false
}

func (s *scan) trivia() {
	for s.pos < len(s.b) {
		switch rest := s.b[s.pos:]; {
		case rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r':
			s.pos++
		case strings.HasPrefix(rest, "//"):
			if i := strings.IndexByte(rest, '\n'); i >= 0 {
				s.pos += i
			} else {
				s.pos = len(s.b)
			}
		case strings.HasPrefix(rest, "/*"):
			s.blockComment()
		default:
			return
		}
	}
}

// blockComment skips a block comment, which may nest.
func (s *scan) blockComment() {
	depth := 0
	for s.pos < len(s.b) {
		r := s.b[s.pos:]
		switch {
		case strings.HasPrefix(r, "/*"):
			depth++
			s.pos += 2
		case strings.HasPrefix(r, "*/"):
			depth--
			s.pos += 2
			if depth == 0 {
				return
			}
		default:
			s.pos++
		}
	}
}

func (s *scan) leaf(start int) *loc { return &loc{start: start, end: s.pos, tagEnd: start} }

func (s *scan) value() *loc {
	start := s.pos
	c := s.peek()
	switch {
	case c == '{':
		return s.record()
	case c == '[':
		s.pos++
		items, ok := s.items(']')
		if !ok {
			return nil
		}
		return &loc{start: start, end: s.pos, tagEnd: start, items: items}
	case c == '"':
		s.str()
		return s.leaf(start)
	case c == 'x' && s.pos+1 < len(s.b) && s.b[s.pos+1] == '"':
		i := strings.IndexByte(s.b[s.pos+2:], '"')
		if i < 0 {
			return nil
		}
		s.pos += 2 + i + 1
		return s.leaf(start)
	case c == '-' || c >= '0' && c <= '9':
		s.pos++
		for s.pos < len(s.b) && (isWordByte(s.b[s.pos]) || strings.IndexByte("_.+-", s.b[s.pos]) >= 0) {
			s.pos++
		}
		return s.leaf(start)
	case c >= 'A' && c <= 'Z':
		s.ident()
		tagEnd := s.pos
		for s.peek() == ' ' || s.peek() == '\t' {
			s.pos++
		}
		var args []*loc
		switch s.peek() {
		case '(':
			s.pos++
			var ok bool
			if args, ok = s.items(')'); !ok {
				return nil
			}
		case '{':
			r := s.record()
			if r == nil {
				return nil
			}
			args = []*loc{r}
		default:
			s.pos = tagEnd
		}
		return &loc{start: start, end: s.pos, tagEnd: tagEnd, items: args}
	}
	return nil
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

func (s *scan) ident() {
	for s.pos < len(s.b) && isWordByte(s.b[s.pos]) {
		s.pos++
	}
}

// str skips a string or block string; escapes are skipped whole.
func (s *scan) str() {
	block := strings.HasPrefix(s.b[s.pos:], `"""`)
	if block {
		s.pos += 3
	} else {
		s.pos++
	}
	for s.pos < len(s.b) {
		switch c := s.b[s.pos]; {
		case c == '\\':
			s.pos += 2
		case c == '"' && !block:
			s.pos++
			return
		case c == '"' && strings.HasPrefix(s.b[s.pos:], `"""`):
			s.pos += 3
			return
		default:
			s.pos++
		}
	}
}

// items reads values up to closer, after the opening bracket.
func (s *scan) items(closer byte) ([]*loc, bool) {
	var out []*loc
	s.trivia()
	for s.peek() != closer {
		if s.pos >= len(s.b) {
			return nil, false
		}
		v := s.value()
		if v == nil {
			return nil, false
		}
		out = append(out, v)
		s.trivia()
		if s.eat(',') {
			s.trivia()
		}
	}
	s.pos++
	return out, true
}

func (s *scan) record() *loc {
	start := s.pos
	if !s.eat('{') {
		return nil
	}
	var fields []fieldLoc
	s.trivia()
	for s.peek() != '}' {
		if s.pos >= len(s.b) {
			return nil
		}
		keyStart := s.pos
		if s.peek() == '"' {
			s.str()
		} else {
			s.ident()
		}
		keyEnd := s.pos
		if keyEnd == keyStart {
			return nil
		}
		s.trivia()
		if !s.eat(':') {
			return nil
		}
		s.trivia()
		v := s.value()
		if v == nil {
			return nil
		}
		fields = append(fields, fieldLoc{keyStart, keyEnd, v})
		s.trivia()
		if s.eat(',') {
			s.trivia()
		}
	}
	s.pos++
	return &loc{start: start, end: s.pos, tagEnd: start, fields: fields}
}

// lines gives the line and column of byte offsets (1-based; columns in
// code points, spec §8).
type lines struct {
	text   string
	starts []int
}

func newLines(text string) *lines {
	starts := []int{0}
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' {
			starts = append(starts, i+1)
		}
	}
	return &lines{text, starts}
}

func (l *lines) position(offset int) (line, col int) {
	offset = min(offset, len(l.text))
	lo, hi := 0, len(l.starts)
	for lo+1 < hi {
		mid := (lo + hi) / 2
		if l.starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo + 1, utf8.RuneCountInString(l.text[l.starts[lo]:offset]) + 1
}
