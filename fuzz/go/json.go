package main

// The JSON fuzzer (`main.ts --json`), `--json MODE FILE`, one case a line:
//
//   - write: `SUITE TYPE HEX` (haus text): decode with the type, Type.ToJSON,
//     schema-based JSON (spec §16.3);
//   - read: `SUITE TYPE HEX` (JSON): Type.FromJSON, encode: the canonical form;
//   - haus-json-write: `HEX` (haus text): haus.ToHausJSON, self-describing
//     JSON in its envelope (§16.2);
//   - haus-json-read: `HEX` (JSON): haus.FromHausJSON, the canonical form;
//   - import: `HEX` (JSON): haus.ImportJSON (§16.1), the canonical form.
//
// Errors are `err <place> <code> <reason>`: the place in the value
// (`$.items[2].price`, `$` for an error in the text) and the code (spec §17;
// `-` for an input that isn't one value). Encoding what was read must work,
// so an encoding error there is `crash …`.

import (
	"fmt"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

func jsonLines(mode string) (func(string) string, error) {
	suites, err := schemas("test-suite/schema", "fuzz/schema", "test-suite/json", "fuzz/json")
	if err != nil {
		return nil, err
	}
	typed := func(line string, one func(schema.Type, []byte) string) string {
		parts := strings.Split(line, " ")
		if len(parts) != 3 {
			return "crash bad line for " + mode
		}
		t, bad := typeOf(suites, parts[0], parts[1])
		if bad != "" {
			return bad
		}
		return one(t, unhex(parts[2]))
	}
	switch mode {
	case "write":
		return func(line string) string { return typed(line, writeJSON) }, nil
	case "read":
		return func(line string) string { return typed(line, readJSON) }, nil
	case "haus-json-write":
		return func(line string) string {
			v, bad := single(unhex(line))
			if bad != "" {
				return bad
			}
			return okOr(haus.ToHausJSON(v))
		}, nil
	case "haus-json-read":
		return func(line string) string { return canonicalOr(haus.FromHausJSON(unhex(line))) }, nil
	case "import":
		return func(line string) string { return canonicalOr(haus.ImportJSON(unhex(line))) }, nil
	}
	return nil, fmt.Errorf("unknown JSON mode %s: write, read, haus-json-write, haus-json-read or import", mode)
}

func writeJSON(t schema.Type, data []byte) string {
	v, bad := single(data)
	if bad != "" {
		return bad
	}
	decoded, err := t.Decode(v)
	if err != nil {
		return placed(err)
	}
	return okOr(t.ToJSON(decoded))
}

func readJSON(t schema.Type, data []byte) string {
	read, err := t.FromJSON(data)
	if err != nil {
		return placed(err)
	}
	encoded, err := t.Encode(read)
	if err != nil {
		return "crash encoding what was read failed: " + err.Error()
	}
	return canonicalOr(encoded, nil)
}

func okOr(out []byte, err error) string {
	if err != nil {
		return placed(err)
	}
	return "ok " + string(out)
}

func canonicalOr(v haus.Value, err error) string {
	if err != nil {
		return placed(err)
	}
	c, err := haus.Canonical(v)
	if err != nil {
		return placed(err)
	}
	return "ok " + c
}
