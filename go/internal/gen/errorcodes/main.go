// Command errorcodes writes error_codes.go from spec/errors.haus. Run it with
// `go generate` in the go/ directory.
package main

import (
	"fmt"
	"os"

	"github.com/betalyra/haus-fmt/go/internal/errorcodes"
)

func main() {
	src, err := os.ReadFile("../spec/errors.haus")
	if err != nil {
		fail(err)
	}
	out, err := errorcodes.Generate(src)
	if err != nil {
		fail(err)
	}
	if err := os.WriteFile("error_codes.go", out, 0o644); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "errorcodes:", err)
	os.Exit(1)
}
