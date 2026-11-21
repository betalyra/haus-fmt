package haus

import (
	"encoding/hex"
	"slices"
	"sync"
	"unicode/utf8"
)

// writeLines writes values built in code in the compact or minimised layout
// (spec §11): each top-level value on a line of its own, followed by a comma
// in a stream of two or more. These layouts make no decisions about lines,
// so the values are written as they are checked, without building a syntax
// tree; the checks are the pretty layout's, in its order (writeCheck), so a
// value that can't be written fails with the same error in every layout.
func writeLines(vs []Value, lim Limits, minimised bool) ([]byte, error) {
	if len(vs) == 0 {
		return nil, nil // an empty file
	}
	buf := lineBuffers.Get().(*[]byte)
	w := lineWriter{writeCheck: writeCheck{lim: lim}, b: (*buf)[:0], minimised: minimised}
	stream := len(vs) > 1
	for i, v := range vs {
		w.start(i, stream)
		if err := w.value(v, 0); err != nil {
			lineBuffers.Put(buf)
			return nil, err
		}
		if stream {
			w.b = append(w.b, ',')
		}
		w.b = append(w.b, '\n')
	}
	if cap(w.b) > maxPooledBuffer {
		return w.b, nil // too large to keep: the caller's
	}
	text := slices.Clone(w.b)
	*buf = w.b[:0]
	lineBuffers.Put(buf)
	return text, nil
}

// lineBuffers keeps the buffers writeLines writes into, so that a buffer
// grows only the first few times; the caller gets a copy of exactly the
// text's length.
var lineBuffers = sync.Pool{New: func() any { return new([]byte) }}

// maxPooledBuffer is the room of the largest buffer kept in lineBuffers.
const maxPooledBuffer = 4 << 20

// lineWriter writes values on one line, in the compact layout (a space
// after ':' and ',' and inside braces) or the minimised one (no spaces).
type lineWriter struct {
	writeCheck
	b         []byte
	minimised bool
}

// separator writes the comma between two entries.
func (w *lineWriter) separator() {
	if w.minimised {
		w.b = append(w.b, ',')
	} else {
		w.b = append(w.b, ", "...)
	}
}

func (w *lineWriter) value(v Value, depth int) error {
	if err := w.count(); err != nil {
		return err
	}
	switch v := v.(type) {
	case String:
		var ok bool
		if w.b, ok = appendQuotedValid(w.b, string(v)); !ok {
			return w.invalidString()
		}
		if err := w.length(string(v), CodeStringTooLong, "string"); err != nil {
			return err
		}
	case Number:
		text := v.String()
		if err := w.number(text); err != nil {
			return err
		}
		w.b = append(w.b, text...)
	case Bytes:
		if err := w.bytes(v); err != nil {
			return err
		}
		w.b = append(w.b, `x"`...)
		w.b = hex.AppendEncode(w.b, v)
		w.b = append(w.b, '"')
	case Array:
		if err := w.enter(v, depth); err != nil {
			return err
		}
		if err := w.items('[', ']', v, depth); err != nil {
			return err
		}
		w.guard.pop()
	case Record:
		if err := w.enter(v, depth); err != nil {
			return err
		}
		if err := w.fields(v, depth); err != nil {
			return err
		}
		w.guard.pop()
	case Variant:
		if err := w.tag(v.Tag); err != nil {
			return err
		}
		w.b = append(w.b, v.Tag.name...)
		if len(v.Args) == 0 {
			return nil
		}
		if r, ok := v.Args[0].(Record); ok && len(v.Args) == 1 {
			// Tag { … }: the record is the payload's one level, and one
			// value written.
			if err := w.enter(r, depth); err != nil {
				return err
			}
			if err := w.count(); err != nil {
				return err
			}
			if !w.minimised {
				w.b = append(w.b, ' ')
			}
			if err := w.fields(r, depth); err != nil {
				return err
			}
			w.guard.pop()
			return nil
		}
		if err := w.enter(v, depth); err != nil {
			return err
		}
		if err := w.items('(', ')', v.Args, depth); err != nil {
			return err
		}
		w.guard.pop()
	default:
		return w.unknownValue(v)
	}
	return nil
}

// items writes the elements of an array or the arguments of a payload, in
// the container at depth.
func (w *lineWriter) items(open, closer byte, vs []Value, depth int) error {
	w.b = append(w.b, open)
	for i, v := range vs {
		if i > 0 {
			w.separator()
		}
		w.path = append(w.path, step{index: i})
		if err := w.value(v, depth+1); err != nil {
			return err
		}
		w.path = w.path[:len(w.path)-1]
	}
	w.b = append(w.b, closer)
	return nil
}

// fields writes the fields of a record (also a record payload) at depth.
func (w *lineWriter) fields(r Record, depth int) error {
	if len(r.fields) == 0 {
		w.b = append(w.b, "{}"...)
		return nil
	}
	w.b = append(w.b, '{')
	if !w.minimised {
		w.b = append(w.b, ' ')
	}
	for i, f := range r.fields {
		if i > 0 {
			w.separator()
		}
		switch {
		case isIdent(f.Key):
			w.b = append(w.b, f.Key...)
		case !utf8.ValidString(f.Key):
			return w.invalidKey()
		default:
			w.b = appendQuoted(w.b, f.Key)
		}
		if err := w.length(f.Key, CodeKeyTooLong, "key"); err != nil {
			return err
		}
		w.b = append(w.b, ':')
		if !w.minimised {
			w.b = append(w.b, ' ')
		}
		w.path = append(w.path, step{key: f.Key, index: -1})
		if err := w.value(f.Value, depth+1); err != nil {
			return err
		}
		w.path = w.path[:len(w.path)-1]
	}
	if !w.minimised {
		w.b = append(w.b, ' ')
	}
	w.b = append(w.b, '}')
	return nil
}
