package main

// The schema-file fuzzer (`main.ts --schema-check`): lines `HEX`, a schema
// file's bytes as hex. Each is read by schema.Parse (which imports std/time
// and packages, but no files, and is given no packages): `ok` if it is a
// valid schema file (spec §14), or `err <line> <column> <code> <reason>`, the
// position of the error (0 0 for none) and its code (spec §17).

import (
	"errors"
	"fmt"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

func checkLine(line string) string {
	_, err := schema.Parse(unhex(line), schema.Options{})
	if err == nil {
		return "ok"
	}
	var e *haus.Error
	if !errors.As(err, &e) {
		return "err 0 0 - " + err.Error()
	}
	return fmt.Sprintf("err %d %d %s %s", e.Line, e.Column, e.Code, e.Message)
}
