package haus

import (
	"errors"
	"fmt"
	"io"
	"iter"
	"strings"
)

// StreamOptions configure a [StreamReader].
type StreamOptions struct {
	// Limits apply to each value; MaxValueLength bounds how much of the
	// input is held at once. Zero fields take their defaults.
	Limits Limits
	// Strict requires a comma after the last value (spec §6), so that a
	// stream cut off after a complete-looking value is reported, with the
	// code stream-truncated, instead of read as valid.
	Strict bool
}

// StreamReader reads the top-level values of a file or stream (spec §6) one
// at a time from an [io.Reader]. Memory stays bounded by the largest value.
// Errors carry the line and column in the whole input, and have the same
// codes as when the whole input is parsed at once.
//
//	r := haus.NewStreamReader(conn, haus.StreamOptions{Strict: true})
//	for v, err := range r.All() {
//		if err != nil { … }
//		…
//	}
type StreamReader struct {
	r     io.Reader
	opts  StreamOptions
	lim   Limits
	err   error // sticky: returned by every later call
	buf   []byte
	start int  // start of the current value in buf
	pos   int  // how far the scanner has read
	eof   bool // r has no more input
	first bool // the current value is the first of the stream
	chars int  // characters of the current value so far
	line  int  // position of buf[start] in the whole input
	col   int
	scan  scanState
}

// NewStreamReader returns a reader of the values in r.
func NewStreamReader(r io.Reader, opts StreamOptions) *StreamReader {
	s := &StreamReader{r: r, opts: opts, first: true, line: 1, col: 1}
	s.lim, s.err = opts.Limits.resolve()
	return s
}

// ParseStream returns an iterator over the values in r, with the default
// options. It stops after the first error.
func ParseStream(r io.Reader) iter.Seq2[Value, error] {
	return NewStreamReader(r, StreamOptions{}).All()
}

// All returns an iterator over the values that remain, which stops after
// the first error.
func (s *StreamReader) All() iter.Seq2[Value, error] {
	return func(yield func(Value, error) bool) {
		for {
			v, err := s.Next()
			if errors.Is(err, io.EOF) {
				return
			}
			if !yield(v, err) || err != nil {
				return
			}
		}
	}
}

// Next returns the next value, or [io.EOF] when there are no more. After
// an error, it returns that error again.
func (s *StreamReader) Next() (Value, error) {
	if s.err != nil {
		return nil, s.err
	}
	v, err := s.next()
	if err != nil {
		s.err = err
	}
	return v, err
}

const readSize = 64 << 10

func (s *StreamReader) next() (Value, error) {
	for {
		comma, err := s.findComma()
		if err != nil {
			return nil, err
		}
		if comma >= 0 {
			v, err := s.parse(s.buf[s.start : comma+1])
			if err != nil {
				return nil, err
			}
			s.advance(comma + 1)
			if v == nil {
				continue // only whitespace and comments: impossible before a comma, but harmless
			}
			return v, nil
		}
		if !s.eof {
			if err := s.fill(); err != nil {
				return nil, err
			}
			continue
		}
		// The rest of the input, after the last comma.
		rest := s.buf[s.start:]
		if len(rest) == 0 {
			return nil, io.EOF
		}
		v, err := s.parse(rest)
		if err != nil {
			return nil, err
		}
		s.advance(len(s.buf))
		if v == nil {
			return nil, io.EOF
		}
		if s.opts.Strict {
			line, col := s.line, s.col
			return nil, &Error{Code: CodeStreamTruncated, Line: line, Column: col,
				Message:  "the stream ends without a comma after its last value, which may be cut off",
				Expected: "','", Found: "end of input"}
		}
		return v, nil
	}
}

// fill reads more input, keeping the current value.
func (s *StreamReader) fill() error {
	if s.start > 0 && s.start >= len(s.buf)/2 {
		n := copy(s.buf, s.buf[s.start:])
		s.buf = s.buf[:n]
		s.pos -= s.start
		s.start = 0
	}
	if cap(s.buf)-len(s.buf) < readSize {
		nb := make([]byte, len(s.buf), 2*cap(s.buf)+readSize)
		copy(nb, s.buf)
		s.buf = nb
	}
	n, err := s.r.Read(s.buf[len(s.buf):cap(s.buf)])
	s.buf = s.buf[:len(s.buf)+n]
	if errors.Is(err, io.EOF) {
		s.eof = true
		return nil
	}
	return err
}

// parse parses one value's text: whitespace and comments, at most one value,
// and the comma after it, if any. It returns nil if there is no value.
func (s *StreamReader) parse(chunk []byte) (Value, error) {
	p := newParser(string(chunk), s.lim, false)
	defer p.release()
	p.fileStart = s.first
	p.line, p.col = s.line, s.col
	vs, _, err := p.file()
	if err != nil {
		return nil, err
	}
	switch len(vs) {
	case 0:
		return nil, nil
	case 1:
		return vs[0], nil
	}
	// Two values: the scanner found no comma between them, so the parser
	// reported missing-comma already. Not reached.
	return nil, fmt.Errorf("haus: internal error: %d values between two commas", len(vs))
}

// advance moves past a value whose text ends at end, keeping the position.
func (s *StreamReader) advance(end int) {
	text := s.buf[s.start:end]
	if i := strings.LastIndexByte(string(text), '\n'); i >= 0 {
		s.line += strings.Count(string(text), "\n")
		s.col = 1 + countChars(text[i+1:])
	} else {
		s.col += countChars(text)
	}
	s.start = end
	s.pos = max(s.pos, end)
	s.first = false
	s.chars = 0
	s.scan = scanState{}
}

func countChars(b []byte) int {
	n := 0
	for _, c := range b {
		if c&0xC0 != 0x80 {
			n++
		}
	}
	return n
}

// scanMode is what the scanner is inside of.
type scanMode uint8

const (
	inCode scanMode = iota
	inLineComment
	inBlockComment
	inString
	inBlockString
	inBytes
)

// scanState is the state of the scanner that finds the top-level commas. It
// only needs to know where strings, comments and brackets are; the parser
// checks everything else. On valid input it agrees with the parser, and on
// invalid input it never ends a construct before the parser would, so the
// text it hands the parser holds the first error.
type scanState struct {
	mode     scanMode
	depth    int  // open brackets
	comments int  // nesting of block comments
	blanks   bool // in a block string: the line so far is spaces and tabs
	opening  bool // in a block string: still on the line of the opening """
	word     bool // the previous byte is [A-Za-z0-9_]
}

// findComma scans for the next top-level comma and returns its offset in
// buf, or -1 if more input is needed (or there is none).
func (s *StreamReader) findComma() (int, error) {
	b := s.buf
	st := &s.scan
	limit := s.lim.MaxValueLength
	i := s.pos
	if s.first && s.start == 0 && i == 0 && len(b) >= 3 && string(b[:3]) == bom {
		i = 3 // the byte order mark is not part of the first value
	}
	for ; i < len(b); i++ {
		c := b[i]
		if !s.eof && i+3 > len(b) {
			break // keep up to three bytes of lookahead
		}
		if c&0xC0 != 0x80 {
			s.chars++
		}
		next := byte(0)
		if i+1 < len(b) {
			next = b[i+1]
		}
		switch st.mode {
		case inCode:
			word := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
			switch c {
			case ',':
				if st.depth == 0 {
					s.pos = i
					s.chars--
					return i, nil
				}
			case '{', '[', '(':
				st.depth++
			case '}', ']', ')':
				st.depth = max(st.depth-1, 0)
			case '/':
				switch next {
				case '/':
					st.mode = inLineComment
					i++
					s.chars++
				case '*':
					st.mode, st.comments = inBlockComment, 1
					i++
					s.chars++
				}
			case '"':
				if next == '"' && i+2 < len(b) && b[i+2] == '"' {
					st.mode, st.blanks, st.opening = inBlockString, false, true
					i += 2
					s.chars += 2
				} else {
					st.mode = inString
				}
			case 'x':
				if !st.word && next == '"' {
					st.mode = inBytes
					i++
					s.chars++
					word = false
				}
			}
			st.word = word
		case inLineComment:
			if c == '\n' {
				st.mode = inCode
			}
		case inBlockComment:
			switch {
			case c == '/' && next == '*':
				st.comments++
				i++
				s.chars++
			case c == '*' && next == '/':
				st.comments--
				i++
				s.chars++
				if st.comments == 0 {
					st.mode, st.word = inCode, false
				}
			}
		case inString:
			switch c {
			case '\\':
				if next == '"' || next == '\\' {
					i++
					s.chars++
				}
			case '"', '\n':
				st.mode, st.word = inCode, false
			}
		case inBlockString:
			switch {
			case c == '\n':
				st.blanks, st.opening = true, false
			case c == ' ' || c == '\t':
			case c == '\\':
				st.blanks = false
				if next == '"' || next == '\\' {
					i++
					s.chars++
				}
			case c == '"' && next == '"' && i+2 < len(b) && b[i+2] == '"' && st.blanks && !st.opening:
				st.mode, st.word = inCode, false
				i += 2
				s.chars += 2
			default:
				st.blanks = false
			}
		case inBytes:
			if c == '"' || c == '\n' {
				st.mode, st.word = inCode, false
			}
		}
		if s.chars > limit {
			// At the first character counted: after the previous comma, or
			// the first of the stream, after a byte order mark (spec §7).
			col := s.col
			if s.first && s.start == 0 && len(b) >= 3 && string(b[:3]) == bom {
				col++
			}
			return -1, &Error{Code: CodeValueTooLong, Line: s.line, Column: col,
				Message: fmt.Sprintf("a top-level value of more than %d characters", limit)}
		}
	}
	s.pos = i
	return -1, nil
}
