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

// revealed is v with every secret a decoder hid in it revealed, for tests
// that compare decoded values with the expected ones.
func revealed(v haus.Value) haus.Value {
	switch v := v.(type) {
	case haus.Secret:
		return revealed(v.Reveal())
	case haus.Array:
		out := make(haus.Array, len(v))
		for i, x := range v {
			out[i] = revealed(x)
		}
		return out
	case haus.Record:
		fields := make([]haus.Field, 0, v.Len())
		for k, x := range v.All() {
			fields = append(fields, haus.Field{Key: k, Value: revealed(x)})
		}
		r, _ := haus.NewRecord(fields...)
		return r
	case haus.Variant:
		args := make([]haus.Value, len(v.Args))
		for i, x := range v.Args {
			args[i] = revealed(x)
		}
		return haus.Variant{Tag: v.Tag, Args: args}
	}
	return v
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
