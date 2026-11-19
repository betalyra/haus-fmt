package haus

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"iter"
	"strconv"
	"unicode/utf8"
)

// JSON Lines (spec §16, "Streams"): one JSON text per value, each followed
// by a line feed. Readers accept a missing line feed after the last value
// and CR LF line ends; an empty line is an error. A byte order mark is
// ignored only at the start of the stream.

// jsonLines reads the lines of r and converts each with convert(line,
// index, first). maxLine bounds a line's characters (value-too-long); 0 is
// no bound, for input that is held whole already. Errors in a line's text
// get the line's number; errors with a path get the index of the line's
// value first, $[3].
func jsonLines(r io.Reader, maxLine int, convert func(line string, i int) (Value, error)) iter.Seq2[Value, error] {
	return func(yield func(Value, error) bool) {
		br := bufio.NewReaderSize(r, 64<<10)
		var buf []byte
		for n := 0; ; n++ {
			buf = buf[:0]
			eof := false
			for {
				chunk, err := br.ReadSlice('\n')
				buf = append(buf, chunk...)
				if maxLine > 0 && len(buf) > 4*maxLine+1 {
					yield(nil, lineTooLong(n, maxLine))
					return
				}
				if err == nil {
					break
				}
				if errors.Is(err, bufio.ErrBufferFull) {
					continue
				}
				if errors.Is(err, io.EOF) {
					eof = true
					break
				}
				yield(nil, err)
				return
			}
			if eof && len(buf) == 0 {
				return
			}
			line := bytes.TrimSuffix(buf, []byte("\n"))
			line = bytes.TrimSuffix(line, []byte("\r"))
			if maxLine > 0 && len(line) > maxLine && utf8.RuneCount(line) > maxLine {
				yield(nil, lineTooLong(n, maxLine))
				return
			}
			if len(line) == 0 {
				yield(nil, &Error{Code: CodeJSONSyntax, Message: "an empty line in JSON Lines", Line: n + 1, Column: 1,
					Expected: "a JSON value", Found: "end of line"})
				return
			}
			v, err := convert(string(line), n)
			if err != nil {
				yield(nil, inLine(err, n))
				return
			}
			if !yield(v, nil) || eof {
				return
			}
		}
	}
}

func lineTooLong(n, maxLine int) error {
	return &Error{Code: CodeValueTooLong, Message: "a line longer than the limit of " + strconv.Itoa(maxLine) + " characters",
		Line: n + 1, Column: 1}
}

// inLine places an error of line n (0-based) in the whole stream.
func inLine(err error, n int) error {
	var e *Error
	if !errors.As(err, &e) {
		return err
	}
	c := *e
	switch {
	case c.Line > 0:
		c.Line += n
	case c.Path != "":
		c.Path = "$[" + strconv.Itoa(n) + "]" + c.Path[1:]
	default:
		c.Path = "$[" + strconv.Itoa(n) + "]"
	}
	return &c
}

// JSONLinesOptions configure the readers of JSON Lines.
type JSONLinesOptions struct {
	// Limits apply to each value. MaxValueLength bounds the characters of
	// one line, and so the memory a reader holds (value-too-long). Zero
	// fields take their defaults.
	Limits Limits
}

// ReadHausJSONLines reads self-describing JSON Lines from r (spec §16): an
// envelope per line. It holds one line at a time, at most
// opts.Limits.MaxValueLength characters. The iteration stops after the
// first error.
func ReadHausJSONLines(r io.Reader, opts JSONLinesOptions) iter.Seq2[Value, error] {
	return readJSONLines(r, opts, true, func(lim Limits, line string, i int) (Value, error) {
		return fromHausJSON(line, lim, i == 0, "")
	})
}

// ReadImportJSONLines reads JSON Lines from r with the JSON import (spec
// §16.1), as [ReadHausJSONLines] reads self-describing JSON.
func ReadImportJSONLines(r io.Reader, opts JSONLinesOptions) iter.Seq2[Value, error] {
	return readJSONLines(r, opts, true, func(lim Limits, line string, i int) (Value, error) {
		return parseJSON(line, lim, jsonImport, i == 0)
	})
}

func readJSONLines(r io.Reader, opts JSONLinesOptions, bounded bool, read func(Limits, string, int) (Value, error)) iter.Seq2[Value, error] {
	lim, err := opts.Limits.resolve()
	if err != nil {
		return func(yield func(Value, error) bool) { yield(nil, err) }
	}
	maxLine := 0
	if bounded {
		maxLine = lim.MaxValueLength
	}
	return jsonLines(r, maxLine, func(line string, i int) (Value, error) { return read(lim, line, i) })
}

// collect reads all values of seq, or the first error.
func collect(seq iter.Seq2[Value, error]) ([]Value, error) {
	var out []Value
	for v, err := range seq {
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

// FromHausJSONLines reads a whole text of self-describing JSON Lines (spec
// §16): every value, or the first error. The value limit doesn't apply, as
// the text is held whole already (spec §7).
func FromHausJSONLines(data []byte) ([]Value, error) {
	return collect(readJSONLines(bytes.NewReader(data), JSONLinesOptions{}, false, func(lim Limits, line string, i int) (Value, error) {
		return fromHausJSON(line, lim, i == 0, "")
	}))
}

// ImportJSONLines reads a whole text of JSON Lines with the JSON import
// (spec §16.1).
func ImportJSONLines(data []byte) ([]Value, error) {
	return collect(readJSONLines(bytes.NewReader(data), JSONLinesOptions{}, false, func(lim Limits, line string, i int) (Value, error) {
		return parseJSON(line, lim, jsonImport, i == 0)
	}))
}

// ToHausJSONLines writes values as self-describing JSON Lines (spec §16):
// an envelope per value, each followed by a line feed. An error names the
// value's index in its path, $[3].
func ToHausJSONLines(values []Value) ([]byte, error) {
	var out []byte
	for i, v := range values {
		var err error
		if out, err = AppendHausJSON(out, v, Limits{}); err != nil {
			return nil, inLine(err, i)
		}
		out = append(out, '\n')
	}
	return out, nil
}
