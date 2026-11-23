package main

// The build fuzzer (`main.ts --build`, fuzz/src/build.ts): each line builds
// a value with the constructors (spec §11, "Values built in code") and
// writes it: `err CODE` if a constructor rejects it, else `ok C H W`, the
// canonical form (hex), the hash and the compact writer's text (hex), each
// `!CODE` if it fails. Go strings are bytes: a lone surrogate's three bytes
// are a String that isn't UTF-8, which only the writers see.
//
// The import fuzzer (`main.ts --imports`, fuzz/src/imports.ts): each line is
// `ENTRY ROOT` (hex; ROOT `-` for none), loaded with schema.Load and no
// packages: `ok OWN IMPORTED` (type names, sorted, joined by `,`; `-` for
// none) or `err CODE`.

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// buildLine builds and writes the value of one line of instructions.
func buildLine(line string) string {
	tokens := strings.Fields(line)
	v, rest, err := buildValue(tokens)
	if err == nil && len(rest) != 0 {
		return "crash: tokens left over"
	}
	if err != nil {
		return "err " + codeOf(err)
	}
	canon := attempt(func() (string, error) {
		c, err := haus.Canonical(v)
		return hex.EncodeToString([]byte(c)), err
	})
	sum := attempt(func() (string, error) { return haus.Hash(v) })
	written := attempt(func() (string, error) {
		b, err := haus.FormatValue(v, haus.FormatOptions{Layout: haus.Compact})
		// The value without the line break FormatValue ends it with, as the other writers write it.
		return hex.EncodeToString(bytes.TrimSuffix(b, []byte("\n"))), err
	})
	return fmt.Sprintf("ok %s %s %s", canon, sum, written)
}

// attempt is f's result, or `!CODE` for its error.
func attempt(f func() (string, error)) string {
	s, err := f()
	if err != nil {
		return "!" + codeOf(err)
	}
	return s
}

func codeOf(err error) string {
	var e *haus.Error
	if errors.As(err, &e) {
		return string(e.Code)
	}
	return "-"
}

// buildValue builds the value the tokens start with, with the constructors,
// and returns the tokens after it.
func buildValue(tokens []string) (haus.Value, []string, error) {
	if len(tokens) == 0 {
		return nil, nil, errors.New("no value")
	}
	parts := strings.Split(tokens[0], ":")
	rest := tokens[1:]
	text := func(h string) string { return string(unhex(h)) }
	count := func(s string) int {
		n, _ := strconv.Atoi(s)
		return n
	}
	switch parts[0] {
	case "n":
		n, err := haus.ParseNumber(text(parts[1]))
		return n, rest, err
	case "s":
		return haus.String(text(parts[1])), rest, nil
	case "b":
		return haus.Bytes(unhex(parts[1])), rest, nil
	case "a":
		items := make(haus.Array, 0, count(parts[1]))
		for range count(parts[1]) {
			v, r, err := buildValue(rest)
			if err != nil {
				return nil, nil, err
			}
			items, rest = append(items, v), r
		}
		return items, rest, nil
	case "r":
		fields := make([]haus.Field, 0, count(parts[1]))
		for range count(parts[1]) {
			key := text(strings.TrimPrefix(rest[0], "k:"))
			v, r, err := buildValue(rest[1:])
			if err != nil {
				return nil, nil, err
			}
			fields, rest = append(fields, haus.Field{Key: key, Value: v}), r
		}
		rec, err := haus.NewRecord(fields...)
		return rec, rest, err
	case "v":
		args := make([]haus.Value, 0, count(parts[2]))
		for range count(parts[2]) {
			v, r, err := buildValue(rest)
			if err != nil {
				return nil, nil, err
			}
			args, rest = append(args, v), r
		}
		tag, err := haus.NewTag(text(parts[1]))
		if err != nil {
			return nil, nil, err
		}
		return haus.Variant{Tag: tag, Args: args}, rest, nil
	}
	return nil, nil, errors.New("bad token " + tokens[0])
}

// importLine loads the entry file of one line.
func importLine(line string) string {
	entry, rootDir, _ := strings.Cut(line, " ")
	opts := schema.Options{}
	if rootDir != "-" {
		opts.Root = string(unhex(rootDir))
	}
	s, err := schema.Load(string(unhex(entry)), opts)
	if err != nil {
		return "err " + codeOf(err)
	}
	names := func(ds []schema.Definition) string {
		var ns []string
		for _, d := range ds {
			ns = append(ns, d.Name)
		}
		slices.Sort(ns)
		if len(ns) == 0 {
			return "-"
		}
		return strings.Join(ns, ",")
	}
	return fmt.Sprintf("ok %s %s", names(s.Definitions()), names(s.Imported()))
}
