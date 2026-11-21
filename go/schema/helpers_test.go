package schema_test

import (
	"os"
	"path/filepath"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
)

// withLayout is the default format options in a layout.
func withLayout(l haus.Layout) haus.FormatOptions {
	o := haus.DefaultFormatOptions()
	o.Layout = l
	return o
}

// write creates a file and its directories, for tests on every platform.
func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}
