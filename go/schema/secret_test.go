package schema_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// TestGenericDecoderHidesSecrets: decoding with a schema, without a host
// type, gives a secret hidden in a haus.Secret (spec §15,
// "decode.secret.generic-decoders"): printing, logging and encoding/json
// show <redacted>; the writers, canonical form and hash refuse it; encoding
// with the schema writes it in full.
func TestGenericDecoderHidesSecrets(t *testing.T) {
	s, err := schema.Parse([]byte("type Config = { name: String, key: Secret String }"), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	ty, _ := s.Type("Config")
	text := `{ name: "a", key: "hunter2" }`
	decoded := map[string]haus.Value{}
	if decoded["Parse"], err = ty.Parse([]byte(text)); err != nil {
		t.Fatal(err)
	}
	v, _ := haus.Parse([]byte(text))
	if decoded["Decode"], err = ty.Decode(v); err != nil {
		t.Fatal(err)
	}
	if decoded["FromJSON"], err = ty.FromJSON([]byte(`{"name": "a", "key": "hunter2"}`)); err != nil {
		t.Fatal(err)
	}
	for how, out := range decoded {
		key, _ := out.(haus.Record).Get("key")
		secret, ok := key.(haus.Secret)
		if !ok || secret.Reveal() != haus.String("hunter2") || key.Kind() != haus.KindSecret {
			t.Fatalf("%s: the key is %T, not a revealable haus.Secret", how, key)
		}
		var logged bytes.Buffer
		slog.New(slog.NewTextHandler(&logged, nil)).Info("config", "key", key, "config", out)
		j, _ := json.Marshal(key)
		shown := []string{fmt.Sprint(out), fmt.Sprintf("%v %+v %#v %s %q", key, out, out, key, key), logged.String(), string(j)}
		for _, s := range shown {
			if strings.Contains(s, "hunter2") {
				t.Errorf("%s: the secret shows: %s", how, s)
			}
		}
		// The writers that don't apply the schema refuse it, without showing it.
		_, e1 := haus.FormatValue(out, haus.DefaultFormatOptions())
		_, e2 := haus.Canonical(out)
		_, e3 := haus.Hash(out)
		_, e4 := haus.ToHausJSON(out)
		for _, err := range []error{e1, e2, e3, e4} {
			if code, _ := codeAndPath(err); code != haus.CodeCannotEncode || strings.Contains(err.Error(), "hunter2") {
				t.Errorf("%s: a writer gives %v, want cannot-encode", how, err)
			}
		}
		if haus.Equals(out, out) {
			t.Errorf("%s: a value with a secret is equal to itself", how)
		}
		// With the schema, it is written in full: decode, encode, decode.
		enc, err := ty.Encode(out)
		if err != nil {
			t.Fatal(err)
		}
		written, err := haus.FormatValue(enc, haus.DefaultFormatOptions())
		if err != nil || !strings.Contains(string(written), `"hunter2"`) {
			t.Errorf("%s: encoded as %s (%v)", how, written, err)
		}
		if formatted, err := ty.Format(out, haus.DefaultFormatOptions()); err != nil || string(formatted) != string(written) {
			t.Errorf("%s: Format gives %s (%v)", how, formatted, err)
		}
		if j, err := ty.ToJSON(out); err != nil || !strings.Contains(string(j), `"hunter2"`) {
			t.Errorf("%s: ToJSON gives %s (%v)", how, j, err)
		}
	}
}

// TestSecretsInStreams: a stream decoder hides secrets too.
func TestSecretsInStreams(t *testing.T) {
	s, err := schema.Parse([]byte("type Keys = Stream (Secret String)"), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	ty, _ := s.Type("Keys")
	for v, err := range ty.DecodeStream(strings.NewReader(`"a", "b",`), haus.StreamOptions{}) {
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := v.(haus.Secret); !ok {
			t.Errorf("got %T", v)
		}
	}
}
