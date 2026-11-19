package main

// The schema fuzzer (`main.ts --schema`): lines `SUITE TYPE HEX` (a value's
// haus text as hex UTF-8). The value is decoded with the type of the schema
// file SUITE (test-suite/schema or fuzz/schema) by package schema, and what
// was decoded is encoded again: `ok <canonical form>` (the value an encoder
// writes back, spec §15), or `err <place> <code> <reason>`, the place as
// `$.items[2].price` and the code of spec §17 (`-` for none).

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/betalyra/haus-fmt/go/schema"
)

// loaded is a schema file of the fuzzers, or why schema.Parse rejects it.
type loaded struct {
	schema *schema.Schema
	err    error
}

// schemas reads every schema file of the directories (relative to the
// checkout), by suite name: the file's name without .schema.haus.
func schemas(dirs ...string) (map[string]loaded, error) {
	out := map[string]loaded{}
	for _, dir := range dirs {
		entries, err := os.ReadDir(filepath.Join(root, dir))
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			name, ok := strings.CutSuffix(e.Name(), ".schema.haus")
			if !ok {
				continue
			}
			text, err := os.ReadFile(filepath.Join(root, dir, e.Name()))
			if err != nil {
				return nil, err
			}
			s, err := schema.Parse(text, schema.Options{})
			out[name] = loaded{s, err}
		}
	}
	return out, nil
}

// typeOf is the type a line names, or the line to print instead.
func typeOf(suites map[string]loaded, suite, name string) (schema.Type, string) {
	l, ok := suites[suite]
	switch {
	case !ok:
		return schema.Type{}, "crash no schema " + suite
	case l.err != nil:
		return schema.Type{}, "err $ - the schema is rejected: " + l.err.Error()
	}
	t, err := l.schema.Type(name)
	if err != nil {
		return schema.Type{}, "crash no type " + suite + "." + name
	}
	return t, ""
}

func schemaLines() (func(string) string, error) {
	suites, err := schemas("test-suite/schema", "fuzz/schema")
	if err != nil {
		return nil, err
	}
	return func(line string) string {
		parts := strings.Split(line, " ")
		if len(parts) != 3 {
			return "err $ - bad line"
		}
		t, bad := typeOf(suites, parts[0], parts[1])
		if bad != "" {
			return bad
		}
		v, bad := single(unhex(parts[2]))
		if bad != "" {
			return bad
		}
		return roundtrip(t, v, schema.DecodeOptions{})
	}, nil
}
