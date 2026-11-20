package haus

// Byte classes for the scanners of the parser and the writers. Text is
// UTF-8, so the characters spec §4 doesn't allow raw are found by their
// bytes: a C1 control starts with the lead byte c1Lead, a bidi control with
// bidiLead, and the scanners look closer only at those bytes.

// The UTF-8 bytes of the characters that may not appear raw (spec §4).
const (
	// c1Lead starts U+0080–U+00BF; c1Lead followed by 0x80–0x9F is a C1
	// control, U+0080–U+009F.
	c1Lead   = 0xC2
	c1Second = 0x9F // the last second byte of a C1 control
	// bidiLead starts U+2000–U+2FFF. The bidi controls are U+202A–U+202E
	// (bidiLead 0x80 0xAA–0xAE) and U+2066–U+2069 (bidiLead 0x81 0xA6–0xA9).
	bidiLead = 0xE2
	del      = 0x7F // DEL, a control character
)

// rawCharCode returns the code for a character at s[i] that may not appear
// raw where it is (spec §4): a control character other than tab and line
// feed, a carriage return not followed by a line feed, or a bidirectional
// control. It returns "" for any other character.
func rawCharCode(s string, i int) ErrorCode {
	c := s[i]
	switch {
	case c == '\t' || c == '\n':
		return ""
	case c == '\r':
		if i+1 < len(s) && s[i+1] == '\n' {
			return ""
		}
		return CodeLoneCarriageReturn
	case c < 0x20 || c == del:
		return CodeControlCharacter
	case c == c1Lead:
		if i+1 < len(s) && s[i+1] >= 0x80 && s[i+1] <= c1Second {
			return CodeControlCharacter
		}
	case c == bidiLead:
		if i+2 < len(s) {
			c1, c2 := s[i+1], s[i+2]
			if c1 == 0x80 && c2 >= 0xAA && c2 <= 0xAE || c1 == 0x81 && c2 >= 0xA6 && c2 <= 0xA9 {
				return CodeBidiControl
			}
		}
	}
	return ""
}

// needsEscape reports whether a character is never written raw in a string:
// control characters, bidi controls, and the line and paragraph separators.
func needsEscape(r rune) bool {
	return r < 0x20 || r >= del && r <= 0x9f || r >= 0x202A && r <= 0x202E ||
		r >= 0x2066 && r <= 0x2069 || r == 0x2028 || r == 0x2029
}

// rawCheck marks the bytes that need a closer look in text that may hold
// any other character (comments, block strings): control characters other
// than tab, and the first bytes of C1 controls and of bidi controls.
var rawCheck = byteTable("\x7f\xC2\xE2", true)

// stringStop marks the bytes that end a plain run in a "…" string: rawCheck,
// tab, line feed, quote and backslash.
var stringStop = byteTable("\x7f\xC2\xE2\t\n\"\\", true)

// commentStop marks the bytes that end a plain run in a block comment.
var commentStop = byteTable("\x7f\xC2\xE2*/", true)

// quoteStop marks the bytes that end a run a writer copies as it is into a
// "…" string: control characters (tab and line feed too), quote, backslash,
// DEL and every byte of a multi-byte character (which may need an escape,
// or not be UTF-8).
var quoteStop = func() (t [256]bool) {
	t = byteTable("\t\n\"\\\x7f", true)
	for c := 0x80; c < 0x100; c++ {
		t[c] = true
	}
	return t
}()

// byteTable marks the bytes of set, and the control characters but tab and
// line feed if controls is true.
func byteTable(set string, controls bool) (t [256]bool) {
	if controls {
		for c := 0; c < 0x20; c++ {
			t[c] = c != '\t' && c != '\n'
		}
	}
	for i := 0; i < len(set); i++ {
		t[set[i]] = true
	}
	return t
}

// plainRun returns the end of the run of bytes from s[i] that stop doesn't
// mark.
func plainRun(s string, i int, stop *[256]bool) int {
	for i < len(s) && !stop[s[i]] {
		i++
	}
	return i
}
