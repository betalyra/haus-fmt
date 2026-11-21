package haus

import (
	"fmt"
	"math/big"
	"strings"
)

// numError is a mistake in a number literal, at byte offset pos.
type numError struct {
	code ErrorCode
	msg  string
	pos  int
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// isWordChar reports whether c can continue an identifier or tag: [A-Za-z0-9_].
func isWordChar(c byte) bool { return wordChars[c] }

// wordChars marks [A-Za-z0-9_].
var wordChars = func() (t [256]bool) {
	for c := range t {
		t[c] = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
	}
	return t
}()

func isHexDigit(c byte) bool { return isDigit(c) || (c|0x20) >= 'a' && (c|0x20) <= 'f' }

// isWordByte reports whether c may not directly follow a number (grammar:
// "A number must not be directly followed by [A-Za-z0-9_.]").
func isWordByte(c byte) bool {
	return isDigit(c) || c == '_' || c == '.' || (c|0x20) >= 'a' && (c|0x20) <= 'z'
}

// scanNumber reads the number literal that starts at s[pos] (a '-' or a
// digit, or a '+' or '.' to report). It returns the end of the literal and
// its normalized text (spec §2), which is a slice of s when the literal is
// already normalized. Every error is at the literal's first character
// (spec §8). With lim nil no limits apply: a number built in code is checked
// for validity only (spec §11, "Values built in code").
func scanNumber(s string, pos int, lim *Limits) (end int, norm string, err *numError) {
	end, norm, err = scanLiteral(s, pos, lim)
	if err != nil {
		err.pos = pos
	}
	return end, norm, err
}

func scanLiteral(s string, pos int, lim *Limits) (end int, norm string, err *numError) {
	start := pos
	bad := func(at int, format string, args ...any) (int, string, *numError) {
		return 0, "", &numError{code: CodeInvalidNumber, msg: fmt.Sprintf(format, args...), pos: at}
	}
	if pos < len(s) && (s[pos] == '+' || s[pos] == '.') {
		return bad(pos, "a number can't start with '%c'", s[pos])
	}
	neg := false
	if pos < len(s) && s[pos] == '-' {
		neg = true
		pos++
	}
	if pos >= len(s) || !isDigit(s[pos]) {
		return bad(pos, "expected a digit after '-', found %s", describeChar(s, pos))
	}
	// digits reads digit ('_'? digit)* and returns the end, or the place of
	// a misplaced '_'.
	digits := func(i int, ok func(byte) bool) (int, *numError) {
		for {
			i++
			if i < len(s) && s[i] == '_' {
				if i+1 >= len(s) || !ok(s[i+1]) {
					return 0, &numError{code: CodeInvalidNumber, msg: "'_' must stand between two digits", pos: i}
				}
				i++
				continue
			}
			if i >= len(s) || !ok(s[i]) {
				return i, nil
			}
		}
	}
	if s[pos] == '0' && pos+1 < len(s) {
		switch c := s[pos+1]; c {
		case 'x', 'b':
			isDig := isHexDigit
			base := 16
			if c == 'b' {
				isDig = func(c byte) bool { return c == '0' || c == '1' }
				base = 2
			}
			i := pos + 2
			if i >= len(s) || !isDig(s[i]) {
				return bad(i, "expected a digit after '0%c', found %s", c, describeChar(s, i))
			}
			j, e := digits(i, isDig)
			if e != nil {
				return 0, "", e
			}
			if j < len(s) && isWordByte(s[j]) {
				return bad(j, "a number can't be followed directly by %s", describeChar(s, j))
			}
			if lim != nil && j-start > lim.MaxNumberLength {
				return 0, "", tooLong(start, j-start, lim)
			}
			text := strings.ReplaceAll(s[i:j], "_", "")
			if lim != nil && base == 16 && len(text) > maxHexDigits(lim.MaxNumberLength) {
				return 0, "", &numError{code: CodeNumberTooLong, pos: start,
					msg: fmt.Sprintf("a hex literal with %d hex digits, more than the limit of %d",
						len(text), maxHexDigits(lim.MaxNumberLength))}
			}
			n, _ := new(big.Int).SetString(text, base)
			norm = n.String()
			if neg {
				norm = "-" + norm
			}
			return j, norm, nil
		case 'X', 'B':
			return bad(pos+1, "the prefix is lowercase: '0%c', not '0%c'", c|0x20, c)
		default:
			if isDigit(c) || c == '_' {
				return bad(pos, "a number can't have a leading zero")
			}
		}
	}
	// int frac? exp?
	i := pos
	if s[i] == '0' {
		i++
	} else {
		j, e := digits(i, isDigit)
		if e != nil {
			return 0, "", e
		}
		i = j
	}
	if i < len(s) && s[i] == '.' {
		if i+1 >= len(s) || !isDigit(s[i+1]) {
			return bad(i, "expected a digit after '.', found %s", describeChar(s, i+1))
		}
		j, e := digits(i+1, isDigit)
		if e != nil {
			return 0, "", e
		}
		i = j
	}
	mantEnd := i
	expStart, expDigits := -1, -1
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		expStart = i
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if i >= len(s) || !isDigit(s[i]) {
			return bad(i, "expected a digit in the exponent, found %s", describeChar(s, i))
		}
		expDigits = i
		j, e := digits(i, isDigit)
		if e != nil {
			return 0, "", e
		}
		i = j
	}
	if i < len(s) && isWordByte(s[i]) {
		return bad(i, "a number can't be followed directly by %s", describeChar(s, i))
	}
	if lim != nil && i-start > lim.MaxNumberLength {
		return 0, "", tooLong(start, i-start, lim)
	}
	if expStart < 0 {
		if strings.IndexByte(s[start:i], '_') < 0 {
			return i, s[start:i], nil
		}
		return i, strings.ReplaceAll(s[start:i], "_", ""), nil
	}
	// Normalize the exponent: no '+', no leading zeros, no '-' on zero.
	expNeg := s[expDigits-1] == '-'
	ed := s[expDigits:i]
	if strings.IndexByte(ed, '_') >= 0 {
		ed = strings.ReplaceAll(ed, "_", "")
	}
	ed = strings.TrimLeft(ed, "0")
	if ed == "" {
		ed = "0"
		expNeg = false
	}
	if lim != nil && (len(ed) > 9 || atoi(ed) > lim.MaxExponent) {
		return 0, "", &numError{code: CodeExponentTooLarge, pos: start,
			msg: fmt.Sprintf("the exponent is larger than the limit of %d", lim.MaxExponent)}
	}
	mant := s[start:mantEnd]
	if strings.IndexByte(mant, '_') >= 0 {
		mant = strings.ReplaceAll(mant, "_", "")
	}
	sign := ""
	if expNeg {
		sign = "-"
	}
	// Already normalized: the text is mantissa, 'e', exponent as written.
	if s[expStart] == 'e' && len(mant) == mantEnd-start && i-expStart-1 == len(sign)+len(ed) {
		return i, s[start:i], nil
	}
	return i, mant + "e" + sign + ed, nil
}

func tooLong(start, n int, lim *Limits) *numError {
	return &numError{code: CodeNumberTooLong, pos: start,
		msg: fmt.Sprintf("a number literal of %d characters, more than the limit of %d", n, lim.MaxNumberLength)}
}

// atoi converts at most 9 decimal digits.
func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}
