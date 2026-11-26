package main

// The parser fuzzer's modes (`main.ts`, `main.ts --canonical`) and the
// formatter fuzzer's (`main.ts --format`): DIR/00000.haus … DIR/{N-1}.haus,
// one line each.
//
//   - parse (no flag): `ok <values>` in the test-suite JSON encoding, or
//     `err <line> <column> <code> <reason>` (the error code of spec §17);
//   - --stream: the same through the stream reader, the input in chunks (see
//     chunks);
//   - --canonical: `ok` and the canonical form of each value (spec §12), a
//     JSON array of strings;
//   - --format STYLE [--indent N] [--width N]: `ok` and haus.Format's output
//     as a JSON string;
//   - --write STYLE [--indent N] [--width N]: `ok {"values": [...], "file":
//     ...}`, each value written alone by haus.FormatValue (without the line
//     break after it) and all of them by haus.FormatValues, as JSON strings;
//     an encoding error is `err 0 0 <code> <reason>`.
//
// With --format or --write, `--stream` anywhere before DIR says the file is a
// stream (spec §11, FormatOptions.Stream): a comma after a single value too,
// in the output of --format and in --write's "file".

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"

	haus "github.com/betalyra/haus-fmt/go"
)

func files(args []string, out *bufio.Writer) error {
	if len(args) < 2 {
		return errors.New(usage)
	}
	dir, count := args[len(args)-2], args[len(args)-1]
	n, err := strconv.Atoi(count)
	if err != nil {
		return errors.New(usage)
	}
	one, err := fileMode(args[:len(args)-2])
	if err != nil {
		return err
	}
	for i := range n {
		src, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%05d.haus", i)))
		if err != nil {
			return err
		}
		fmt.Fprintln(out, one(src, i))
	}
	return nil
}

func fileMode(flags []string) (func([]byte, int) string, error) {
	// `--stream` alone is the stream reader; with --format or --write, anywhere
	// before DIR, the file is a stream: moved after the mode's other flags,
	// where formatOptions reads it.
	if len(flags) > 1 && slices.Contains(flags, "--stream") {
		flags = append(slices.DeleteFunc(slices.Clone(flags), func(f string) bool { return f == "--stream" }), "--stream")
	}
	switch {
	case len(flags) == 0:
		return func(src []byte, _ int) string { return suiteLine(haus.ParseAll(src)) }, nil
	case len(flags) == 1 && flags[0] == "--stream":
		return func(src []byte, i int) string { return suiteLine(streamed(src, i)) }, nil
	case len(flags) == 1 && flags[0] == "--canonical":
		return func(src []byte, _ int) string { return canonicalLine(haus.ParseAll(src)) }, nil
	case len(flags) >= 2 && flags[0] == "--write":
		opts, err := formatOptions(flags[1:])
		if err != nil {
			return nil, err
		}
		return func(src []byte, _ int) string { return writeLine(src, opts) }, nil
	case len(flags) >= 2 && flags[0] == "--format":
		opts, err := formatOptions(flags[1:])
		if err != nil {
			return nil, err
		}
		return func(src []byte, _ int) string { return formatLine(src, opts) }, nil
	}
	return nil, errors.New(usage)
}

// formatOptions reads `STYLE [--indent N] [--width N] [--stream]`, the
// indent and width taken literally (0 included), 2 and 80 when not given;
// `--stream`: the file is a stream (spec §11).
func formatOptions(flags []string) (haus.FormatOptions, error) {
	layout, err := layoutOf(flags[0])
	if err != nil {
		return haus.FormatOptions{}, err
	}
	opts := haus.DefaultFormatOptions()
	opts.Layout = layout
	for rest := flags[1:]; len(rest) > 0; {
		if rest[0] == "--stream" {
			opts.Stream = true
			rest = rest[1:]
			continue
		}
		if len(rest) < 2 {
			return opts, errors.New(usage)
		}
		v, err := strconv.Atoi(rest[1])
		switch {
		case err != nil:
			return opts, errors.New(usage)
		case rest[0] == "--indent":
			opts.Indent = v
		case rest[0] == "--width":
			opts.Width = v
		default:
			return opts, errors.New(usage)
		}
		rest = rest[2:]
	}
	return opts, nil
}

func layoutOf(name string) (haus.Layout, error) {
	switch name {
	case "pretty":
		return haus.Pretty, nil
	case "compact":
		return haus.Compact, nil
	case "minimised":
		return haus.Minimised, nil
	}
	return 0, fmt.Errorf("unknown style %s: pretty, compact or minimised", name)
}

// suiteJSON is a value in the test suite's JSON encoding (test-suite/README.md).
func suiteJSON(v haus.Value) any {
	switch x := v.(type) {
	case haus.String:
		return string(x)
	case haus.Number:
		return map[string]any{"num": x.String()}
	case haus.Bytes:
		return map[string]any{"bytes": fmt.Sprintf("%x", []byte(x))}
	case haus.Array:
		return mapValues(x, suiteJSON)
	case haus.Record:
		rec := make(map[string]any, x.Len())
		for k, f := range x.All() {
			rec[k] = suiteJSON(f)
		}
		return map[string]any{"rec": rec}
	case haus.Variant:
		if len(x.Args) == 0 {
			return map[string]any{"tag": x.Tag.String()}
		}
		return map[string]any{"tag": x.Tag.String(), "args": mapValues(x.Args, suiteJSON)}
	}
	panic(fmt.Sprintf("not a value: %T", v))
}

func mapValues[T any](vs []haus.Value, f func(haus.Value) T) []T {
	out := make([]T, len(vs))
	for i, v := range vs {
		out[i] = f(v)
	}
	return out
}

// toJSON is JSON without HTML escapes.
func toJSON(x any) string {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(x); err != nil {
		panic(err)
	}
	return string(bytes.TrimSuffix(b.Bytes(), []byte("\n")))
}

// syntaxLine is a parser's error: `err <line> <column> <code> <reason>`.
func syntaxLine(err error) string {
	var e *haus.Error
	if !errors.As(err, &e) {
		return "err 0 0 - " + oneLine(err.Error())
	}
	return fmt.Sprintf("err %d %d %s %s", e.Line, e.Column, e.Code, oneLine(e.Message))
}

func suiteLine(vs []haus.Value, err error) string {
	if err != nil {
		return syntaxLine(err)
	}
	return "ok " + toJSON(mapValues(vs, suiteJSON))
}

func canonicalLine(vs []haus.Value, err error) string {
	if err != nil {
		return syntaxLine(err)
	}
	forms := make([]string, len(vs))
	for i, v := range vs {
		c, err := haus.Canonical(v)
		if err != nil {
			return syntaxLine(err)
		}
		forms[i] = c
	}
	return "ok " + toJSON(forms)
}

// chunks are the pieces of case i, the same in every runner: piece k has
// size sizes[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8
// sequences.
func chunks(src []byte, i int) [][]byte {
	sizes := [...]int{1, 2, 3, 5, 8, 13, 64}
	var out [][]byte
	for k := 0; len(src) > 0; k++ {
		n := min(sizes[(i+k)%len(sizes)], len(src))
		out = append(out, src[:n])
		src = src[n:]
	}
	return out
}

// pieces is a reader that gives at most one piece per Read.
type pieces [][]byte

func (p *pieces) Read(b []byte) (int, error) {
	if len(*p) == 0 {
		return 0, io.EOF
	}
	n := copy(b, (*p)[0])
	if (*p)[0] = (*p)[0][n:]; len((*p)[0]) == 0 {
		*p = (*p)[1:]
	}
	return n, nil
}

func streamed(src []byte, i int) ([]haus.Value, error) {
	var vs []haus.Value
	r := pieces(chunks(src, i))
	for v, err := range haus.NewStreamReader(&r, haus.StreamOptions{}).All() {
		if err != nil {
			return nil, err
		}
		vs = append(vs, v)
	}
	return vs, nil
}

func formatLine(src []byte, opts haus.FormatOptions) string {
	out, err := haus.Format(src, opts)
	if err != nil {
		return syntaxLine(err)
	}
	return "ok " + toJSON(string(out))
}

func writeLine(src []byte, opts haus.FormatOptions) string {
	vs, err := haus.ParseAll(src)
	if err != nil {
		return syntaxLine(err)
	}
	values := make([]string, len(vs))
	for i, v := range vs {
		b, err := haus.FormatValue(v, opts)
		if err != nil {
			return syntaxLine(err)
		}
		values[i] = string(bytes.TrimSuffix(b, []byte("\n")))
	}
	file, err := haus.FormatValues(vs, opts)
	if err != nil {
		return syntaxLine(err)
	}
	return "ok " + toJSON(map[string]any{"values": values, "file": string(file)})
}
