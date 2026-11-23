// The Go runner of the differential fuzzers (fuzz/README.md): one program
// for every fuzzer, the mode first.
//
//	go-runner [--stream | --canonical] DIR N        the parser, stream reader, canonical form
//	go-runner --format STYLE [--indent N] [--width N] DIR N   haus.Format
//	go-runner --write STYLE [--indent N] [--width N] DIR N    the value writers, haus.FormatValue and FormatValues
//	go-runner --time FILE                            schema.CheckTime
//	go-runner --profile FILE                         the codecs of ext/money and ext/geo
//	go-runner --schema FILE                          decoding with a schema (package schema)
//	go-runner --json MODE FILE                       the JSON mappings
//	go-runner --schema-check FILE                    schema files, as schema.Parse reads them
//	go-runner --build FILE                           values built in code, then written (api.go)
//	go-runner --imports FILE                         relative imports, schema.Load on file trees (api.go)
//
// The modes with DIR N read DIR/00000.haus … DIR/{N-1}.haus, the others a
// FILE of lines; each prints one line per case, as the other bindings'
// runners do (see each mode).
package main

import (
	"bufio"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
)

const usage = "usage: go-runner [--stream | --canonical | --format STYLE [--indent N] [--width N] | --write STYLE [--indent N] [--width N]] DIR N" +
	" | --time FILE | --profile FILE | --schema FILE | --json MODE FILE | --schema-check FILE | --build FILE | --imports FILE"

// root is the checkout this program was built from: the schema files and
// extensions it reads are found there.
var root = func() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}()

func main() {
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	if err := run(os.Args[1:], out); err != nil {
		out.Flush()
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func run(args []string, out *bufio.Writer) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	switch args[0] {
	case "--time":
		return perLine(args[1:], out, timeLine)
	case "--profile":
		return withLines(args[1:], out, profileLines)
	case "--schema":
		return withLines(args[1:], out, schemaLines)
	case "--schema-check":
		return perLine(args[1:], out, checkLine)
	case "--build":
		return perLine(args[1:], out, buildLine)
	case "--imports":
		return perLine(args[1:], out, importLine)
	case "--json":
		if len(args) != 3 {
			return errors.New(usage)
		}
		return withLines(args[2:], out, func() (func(string) string, error) { return jsonLines(args[1]) })
	}
	return files(args, out)
}

// perLine runs one for each line of FILE.
func perLine(args []string, out *bufio.Writer, one func(string) string) error {
	return withLines(args, out, func() (func(string) string, error) { return one, nil })
}

// withLines prepares a function (loading schemas, say), then runs it for
// each non-empty line of FILE and prints its result on a line of its own.
func withLines(args []string, out *bufio.Writer, prepare func() (func(string) string, error)) error {
	if len(args) != 1 {
		return errors.New(usage)
	}
	text, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	one, err := prepare()
	if err != nil {
		return err
	}
	for _, line := range strings.Split(string(text), "\n") {
		if line != "" {
			fmt.Fprintln(out, oneLine(one(line)))
		}
	}
	return nil
}

// unhex is a case's text: hex-encoded bytes.
func unhex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil
	}
	return b
}

// oneLine keeps a result on its line.
func oneLine(s string) string {
	return strings.NewReplacer("\n", " ", "\r", " ").Replace(s)
}

// single is the one value of a case's text, or the line reporting that it
// isn't one value: `err $ - …`.
func single(data []byte) (haus.Value, string) {
	vs, err := haus.ParseAll(data)
	switch {
	case err != nil:
		return nil, "err $ - not a single value: " + err.Error()
	case len(vs) != 1:
		return nil, "err $ - not a single value"
	}
	return vs[0], ""
}

// placed is an error as `err <place> <code> <reason>`: its place in the
// value (`$` for one in the text) and its code (spec §17; `-` for none).
func placed(err error) string {
	var e *haus.Error
	if !errors.As(err, &e) {
		return "err $ - " + err.Error()
	}
	place := e.Path
	if place == "" {
		place = "$"
	}
	return fmt.Sprintf("err %s %s %s", place, e.Code, e.Message)
}
