package main

// The std/time fuzzer (`time.ts`): lines `TYPE HEX` (the text as hex UTF-8);
// `ok` if the text is a valid value of the std/time type
// (schema.CheckTime), `no` if not.

import (
	"strings"
	"unicode/utf8"

	"github.com/betalyra/haus-fmt/go/schema"
)

func timeLine(line string) string {
	ty, hexText, _ := strings.Cut(line, " ")
	text := unhex(hexText)
	switch {
	case !utf8.Valid(text):
		return "err invalid UTF-8"
	case schema.CheckTime(ty, string(text)) == nil:
		return "ok"
	}
	return "no"
}
