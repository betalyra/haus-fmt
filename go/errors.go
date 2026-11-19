package haus

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

//go:generate go run ./internal/gen/errorcodes

// ErrorCode names the mistake an [Error] reports (spec §17): a lowercase
// kebab-case code such as "payload-newline", the same in every binding.
// The codes are the constants Code…, generated from spec/errors.haus.
type ErrorCode string

// ErrorCategory is the part of the catalogue a code belongs to (spec §17).
type ErrorCategory string

// Info returns the catalogue's entry for the code: its category, what it
// means, and the usual fix. ok is false for a code that isn't in the catalogue.
func (c ErrorCode) Info() (info ErrorInfo, ok bool) {
	info, ok = errorCatalogue[c]
	return info, ok
}

// Hint returns the catalogue's fix for the code, or "" if it has none.
func (c ErrorCode) Hint() string { return errorCatalogue[c].Fix }

// Docs returns the URL that documents the code.
func (c ErrorCode) Docs() string { return "https://haus-fmt.org/docs/errors#" + string(c) }

// ErrorInfo is one entry of the error catalogue.
type ErrorInfo struct {
	Category ErrorCategory
	Means    string
	Fix      string
}

// ErrorCodes returns every code of the catalogue, in its order.
func ErrorCodes() []ErrorCode { return append([]ErrorCode(nil), errorCodeList...) }

// Error is an error reported by this package. Every Error has a [ErrorCode]
// from the catalogue (spec §17). An error in text has a 1-based Line and
// Column, counted in code points (spec §8); both are 0 for an error without a
// place in text. Use [errors.As] to get at it:
//
//	var e *haus.Error
//	if errors.As(err, &e) && e.Code == haus.CodePayloadNewline { … }
type Error struct {
	Code    ErrorCode
	Message string // for people, without the position
	// File is the file the error is in, for an error in a schema file or
	// a package (package schema); "" otherwise. It is part of the text of
	// [Error.Error], not of the JSON form.
	File   string
	Line   int    // 1-based; 0 if the error has no place in text
	Column int    // 1-based, in code points; 0 if the error has no place in text
	Path   string // the place in a value, such as $.items[2]; "" if none
	// Expected and Found describe what should be there and what is, where
	// that is natural; otherwise "".
	Expected string
	Found    string
	// Hint is a concrete fix. Empty means the catalogue's fix for the code.
	Hint string
}

// Error returns "file:line:column: message [code]", leaving out the parts
// it doesn't have.
func (e *Error) Error() string {
	var b strings.Builder
	if e.File != "" {
		b.WriteString(e.File)
		b.WriteString(":")
		if e.Line == 0 {
			b.WriteString(" ")
		}
	}
	if e.Line > 0 {
		fmt.Fprintf(&b, "%d:%d: ", e.Line, e.Column)
	}
	if e.Path != "" {
		b.WriteString(e.Path)
		b.WriteString(": ")
	}
	b.WriteString(e.Message)
	b.WriteString(" [")
	b.WriteString(string(e.Code))
	b.WriteString("]")
	return b.String()
}

// MarshalJSON writes the error's JSON form (spec §17): code, message, line,
// column, path, expected, found, hint and docs, leaving out members that
// don't apply.
func (e *Error) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	member := func(name, value string) {
		if b.Len() > 1 {
			b.WriteString(",")
		}
		b.WriteString(strconv.Quote(name))
		b.WriteByte(':')
		b.WriteString(value)
	}
	str := func(s string) string {
		var sb bytes.Buffer
		enc := json.NewEncoder(&sb)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(s) // a string always encodes
		return strings.TrimSuffix(sb.String(), "\n")
	}
	member("code", str(string(e.Code)))
	member("message", str(e.Message))
	if e.Line > 0 {
		member("line", strconv.Itoa(e.Line))
		member("column", strconv.Itoa(e.Column))
	}
	if e.Path != "" {
		member("path", str(e.Path))
	}
	if e.Expected != "" {
		member("expected", str(e.Expected))
	}
	if e.Found != "" {
		member("found", str(e.Found))
	}
	if hint := e.hint(); hint != "" {
		member("hint", str(hint))
	}
	member("docs", str(e.Code.Docs()))
	b.WriteByte('}')
	return b.Bytes(), nil
}

func (e *Error) hint() string {
	if e.Hint != "" {
		return e.Hint
	}
	return e.Code.Hint()
}

func newError(code ErrorCode, msg string) *Error {
	return &Error{Code: code, Message: msg}
}

// quoteForMessage quotes text for an error message: control, bidi and
// line-separator characters are escaped, and long text is cut to 40
// characters (spec §9).
func quoteForMessage(s string) string {
	const maxChars = 40
	var b strings.Builder
	b.WriteByte('"')
	n := 0
	for i, r := range s {
		if n == maxChars {
			b.WriteString("…")
			break
		}
		n++
		switch {
		case r == utf8.RuneError && !strings.HasPrefix(s[i:], "\uFFFD"):
			b.WriteString(`\u{FFFD}`)
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case needsEscape(r):
			writeUnicodeEscape(&b, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// describeChar names the character at s[i] for a message: 'x', U+0007, or
// end of input.
func describeChar(s string, i int) string {
	if i >= len(s) {
		return "end of input"
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	if r == utf8.RuneError || needsEscape(r) || r == ' ' || r == '\uFEFF' {
		return fmt.Sprintf("U+%04X", r)
	}
	return "'" + string(r) + "'"
}
