package schema_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

func parse(t *testing.T, src string) haus.Value {
	t.Helper()
	v, err := haus.Parse([]byte(src))
	if err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	return v
}

func mustSchema(t *testing.T, src string) *schema.Schema {
	t.Helper()
	s, err := schema.Parse([]byte(src), schema.Options{})
	if err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	return s
}

func mustType(t *testing.T, s *schema.Schema, name string) schema.Type {
	t.Helper()
	ty, err := s.Type(name)
	if err != nil {
		t.Fatal(err)
	}
	return ty
}

// The std/time profile, with the vectors of the TypeScript tests, which
// cover every row of spec/std/time.md.
func TestTimeProfile(t *testing.T) {
	valid := [][2]string{
		{"Date", "2026-11-09"}, {"Date", "2024-02-29"}, {"Date", "2000-02-29"}, {"Date", "0000-01-01"}, {"Date", "9999-12-31"},
		{"Time", "00:00:00"}, {"Time", "23:59:59.999999999"},
		{"DateTime", "2026-11-09T14:30:00"}, {"DateTime", "2026-11-09T14:30:00.25"},
		{"Instant", "2026-11-09T14:30:00Z"}, {"Instant", "2026-11-09T14:30:00+01:00"}, {"Instant", "2026-11-09T14:30:00.5-23:59"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon]"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Atlantis]"},
		{"ZonedDateTime", "2027-03-29T10:00:00+05:00[Europe/Lisbon]"},
		{"ZonedDateTime", "2026-11-09T14:30:00Z[+01:00]"},
		{"ZonedDateTime", "2026-11-09T14:30:00-05:00[America/Port-au-Prince]"},
		{"Duration", "PT30S"}, {"Duration", "P1Y2M3W4DT5H6M7.5S"}, {"Duration", "-PT1H"}, {"Duration", "PT0S"},
		{"Duration", "PT0.000S"}, {"Duration", "P1DT0.5S"}, {"Duration", "PT0.5S"}, {"Duration", "PT0.05S"},
		{"Duration", "-PT0.001S"}, {"Duration", "-P10D"},
		{"Duration", "P4294967295Y"}, {"Duration", "PT9007199254740991S"}, {"Duration", "P104249991374D"},
		{"YearMonth", "2026-11"},
		{"TimeZone", "Europe/Lisbon"}, {"TimeZone", "Europe/Z"}, {"TimeZone", "UTC"}, {"TimeZone", "Etc/GMT+1"}, {"TimeZone", "-03:30"},
	}
	for _, c := range valid {
		if err := schema.CheckTime(c[0], c[1]); err != nil {
			t.Errorf("%s %q: %v", c[0], c[1], err)
		}
	}
	nines := strings.Repeat("9", 400)
	invalid := [][3]string{
		{"Date", "2026-02-30", "2026-02 has no day 30"},
		{"Date", "2026-02-29", "2026 is not a leap year"},
		{"Date", "1900-02-29", "1900 is not a leap year"},
		{"Date", "2026-13-01", "month 13 doesn't exist"},
		{"Date", "2026-00-10", "month 00 doesn't exist"},
		{"Date", "20261109", "write it like 2026-11-09"},
		{"Date", "+12026-11-09", "write it like"},
		{"Date", "2026-W45-1", "write it like"},
		{"Date", "2026-313", "write it like"},
		{"Time", "14:30", "write it like 14:30:00"},
		{"Time", "24:00:00", "24:00 is not allowed"},
		{"Time", "23:59:60", "leap seconds (:60) are not allowed"},
		{"Time", "12:60:00", "minute 60 doesn't exist"},
		{"Time", "12:00:00.1234567890", "write it like"},
		{"DateTime", "2026-11-09t14:30:00", "write it like"},
		{"DateTime", "2026-11-09 14:30:00", "write it like"},
		{"DateTime", "2026-11-09T14:30:00Z", "write it like"},
		{"Instant", "2026-11-09T14:30:00", "write it like 2026-11-09T14:30:00Z"},
		{"Instant", "2026-11-09T14:30:00z", "write it like"},
		{"Instant", "2026-11-09T14:30:00-00:00", "-00:00 is not allowed; write Z"},
		{"Instant", "2026-11-09T14:30:00+24:00", "offset +24:00 is out of range"},
		{"Instant", "2016-12-31T23:59:60Z", "leap seconds"},
		{"ZonedDateTime", "2027-03-29T10:00:00[Europe/Lisbon]", "write it like"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00", "write it like"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00[!Europe/Lisbon]", "not an IANA zone name"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/Lisbon][u-ca=iso8601]", "write it like"},
		{"ZonedDateTime", "2027-03-29T10:00:00+01:00[Europe/../etc]", "not an IANA zone name"},
		{"Duration", "P", "at least one component"},
		{"Duration", "PT", "at least one component"},
		{"Duration", "P1DT", "T must be followed"},
		{"Duration", "+PT1H", "write it like"},
		{"Duration", "PT1.5H", "write it like"},
		{"Duration", "p1d", "write it like"},
		{"Duration", "P4294967296Y", "too large"},
		{"Duration", "P104249991375D", "below 2^53 seconds"},
		{"Duration", "PT9007199254740992S", "below 2^53 seconds"},
		{"Duration", "P" + nines + "Y", "too large"},
		{"Duration", "PT" + nines + "S", "below 2^53 seconds"},
		{"Duration", "P01D", "leading zero"},
		{"Duration", "PT00S", "leading zero"},
		{"Duration", "PT01.5S", "leading zero"},
		{"Duration", "-P0D", "a duration leaves out components that are zero"},
		{"Duration", "-PT0S", "a zero duration has no sign"},
		{"Duration", "-PT0.000S", "a zero duration has no sign"},
		{"Duration", "-P0Y0M", "a duration leaves out components that are zero"},
		{"Duration", "P0D", "a duration leaves out components that are zero"},
		{"Duration", "P1DT0S", "a duration leaves out components that are zero"},
		{"Duration", "P0Y1D", "a duration leaves out components that are zero"},
		{"Duration", "PT1H0M", "a duration leaves out components that are zero"},
		{"Duration", "PT1M0.0S", "a duration leaves out components that are zero"},
		{"Duration", "P1DT0.00S", "a duration leaves out components that are zero"},
		{"Duration", "P1Y0W", "a duration leaves out components that are zero"},
		{"Duration", "PT0H1S", "a duration leaves out components that are zero"},
		{"Duration", "PT0M0S", "a duration leaves out components that are zero"},
		// Z is the offset letter, not a zone name.
		{"TimeZone", "Z", "offset letter"},
		{"ZonedDateTime", "2026-11-09T14:30:00Z[Z]", "offset letter"},
		{"ZonedDateTime", "2026-11-09T14:30:00+00:00[Z]", "offset letter"},
		{"YearMonth", "2026-13", "month 13 doesn't exist"},
		{"YearMonth", "2026-1", "write it like"},
		{"TimeZone", "europe lisbon", "not an IANA zone name"},
		{"TimeZone", "/Lisbon", "not an IANA zone name"},
		{"TimeZone", strings.Repeat("a", 256), "not an IANA zone name"},
		{"TimeZone", "Europe//Lisbon", "not an IANA zone name"},
	}
	for _, c := range invalid {
		err := schema.CheckTime(c[0], c[1])
		if err == nil || !strings.Contains(err.Error(), c[2]) {
			t.Errorf("%s %q: got %v, want %q", c[0], c[1], err, c[2])
		}
	}
}

// Schemas the spec rejects (§13.3, §14), each with its code.
func TestSchemaErrors(t *testing.T) {
	cases := []struct{ src, code string }{
		{"type A = { x Int }", "schema-syntax"},
		{"type A = Strin", "unknown-type"},
		{"type A = Array", "wrong-arity"},
		{"type A = Int Int", "wrong-arity"},
		{"type A = { x: a }", "unknown-parameter"},
		{"type A a a = a", "invalid-parameter"},
		{"type A = _", "underscore-type"},
		{"type A = Int\ntype A = String", "duplicate-type"},
		{"type Int = String", "redefine-prelude"},
		{"type Stream = String", "redefine-prelude"},
		{"type A = { x: Int, x: String }", "duplicate-field"},
		{"type B = { x: Int }\ntype A = { x: String, ...B }", "duplicate-field"},
		{"type A = < X | X >", "duplicate-tag"},
		{"type B = < X >\ntype A = < ...B | X >", "duplicate-tag"},
		{"type B = { x: Int }\ntype A = < ...B >", "invalid-spread"},
		{"type B a = < X a >\ntype A = < ...B >", "invalid-spread"},
		{"type A = < ...String >", "invalid-spread"},
		{"type E = Stream Int\ntype A = < ...E >", "invalid-spread"},
		{"type A = < ...Nope >", "unknown-type"},
		{"type A = { ...A }", "spread-cycle"},
		{"type A = Array (Stream Int)", "misplaced-stream"},
		{"type E = Stream Int\ntype A = Array E", "misplaced-stream"},
		{"type A = Secret A", "unguarded-recursion"},
		{"type Id a = a\ntype A = Id A", "unguarded-recursion"},
		{"type L a = < Nil | Cons a (L (Array a)) >", "growing-recursion"},
		{"type A = { @deprecated(1) x: Int }", "attribute-arguments"},
		{"type A = { @deprecated() x: Int }", "attribute-arguments"},
		{"type A = { @deprecated(\"x\" x: Int }", "missing-comma"}, // after a value, a comma or ")" is missing, as in Lean
		{"@deprecated(\"a\"\ntype A = Int", "missing-comma"},
		{"type A = { @deprecated(\"\\q\") x: Int }", "invalid-escape"},
		{"/* never closed\ntype A = Int", "unterminated-comment"},
		{"// a \x1b[2J comment\ntype A = Int", "control-character"},
		{"// a \u202e comment\ntype A = Int", "bidi-control"},
		{"type A = Int\r", "lone-carriage-return"},
		{"type A = \xff", "invalid-utf8"},
		{"type A = { \"x: Int }", "unterminated-string"},
		{"type A = " + strings.Repeat("Array (", 200) + "Int" + strings.Repeat(")", 200), "type-too-deep"},
		{"import std/money (Money)\ntype A = Money", "unknown-module"},
		{"import std/geo (LatLng)\ntype A = LatLng", "unknown-module"},
		{"import std/time (Clock)\ntype A = Clock", "unknown-import"},
		{"import std/time (Date, Date)\ntype A = Date", "duplicate-import"},
		{"import std/time (Date)\ntype Date = Int", "duplicate-type"},
		{"import ./common (A)\ntype B = A", "import-unavailable"},
		{"import @acme/common (A)\ntype B = A", "import-unavailable"},
		// A file path has no '~' (grammar path): the module ends before it.
		{"import ./a~b (A)\ntype B = A", "schema-syntax"},
		{"import ../x~y (A)\ntype B = A", "schema-syntax"},
		// A package module is read with its version, which isn't a major.
		{"import @a/b@1~x (A)\ntype B = A", "import-version"},
		{"import @Acme/common (A)\ntype B = A", "unknown-module"},
		{"import acme (A)\ntype B = A", "schema-syntax"},
		{"type A = { ...r }", "row-parameter"},
		{"type A = closed < >", "closed-empty-variant"},
	}
	for _, c := range cases {
		_, err := schema.Parse([]byte(c.src), schema.Options{})
		code, _ := codeAndPath(err)
		if string(code) != c.code {
			t.Errorf("%q: got %v, want %s", c.src, err, c.code)
		}
		var e *haus.Error
		if err != nil && (!asError(err, &e) || e.Line == 0) {
			t.Errorf("%q: no position: %v", c.src, err)
		}
	}
}

func asError(err error, e **haus.Error) bool {
	x, ok := err.(*haus.Error)
	*e = x
	return ok
}

func TestSpreads(t *testing.T) {
	s := mustSchema(t, `
type UserEvent = < UserCreated { id: Int } | UserRenamed { id: Int, to: String } >
type AppEvent = closed < ...UserEvent | Heartbeat >
type ServerEvent = < ...UserEvent >
type Base = { id: Int }
type Person = closed { ...Base, name: String }
type Alias = Base
type Again = { ...Alias, more?: Int }
`)
	app := mustType(t, s, "AppEvent")
	for _, ok := range []string{"Heartbeat", "UserCreated { id: 1 }", "UserRenamed { id: 1, to: \"x\" }"} {
		if _, err := app.Decode(parse(t, ok)); err != nil {
			t.Errorf("AppEvent %s: %v", ok, err)
		}
	}
	if _, err := app.Decode(parse(t, "Other")); err == nil {
		t.Error("AppEvent is closed")
	}
	if v, err := mustType(t, s, "ServerEvent").Decode(parse(t, "Other(1)")); err != nil || canonical(t, v) != "Other(1)" {
		t.Errorf("ServerEvent is open: %v %v", v, err)
	}
	if _, err := mustType(t, s, "Person").Decode(parse(t, "{ id: 1, name: \"a\", x: 1 }")); err == nil {
		t.Error("Person is closed")
	}
	if v, err := mustType(t, s, "Again").Decode(parse(t, "{ id: 1, more: 2, x: 1 }")); err != nil || canonical(t, v) != "{id:1,more:2}" {
		t.Errorf("Again: %v %v", v, err)
	}
}

func TestWarnings(t *testing.T) {
	s := mustSchema(t, `@deprecated("use B")
type A = Int
@since("1.2")
type B = { a: A, @deprecated n?: Int }`)
	var got []string
	for _, w := range s.Warnings() {
		got = append(got, fmt.Sprintf("%d:%d %s", w.Line, w.Column, w.Code))
	}
	want := []string{"3:1 unknown-attribute", "4:15 deprecated"}
	if strings.Join(got, ", ") != strings.Join(want, ", ") {
		t.Errorf("warnings %v, want %v", got, want)
	}
	defs := s.Definitions()
	if len(defs) != 2 || !defs[0].Deprecated || defs[0].Why != "use B" || defs[0].ID != "A" {
		t.Errorf("definitions %+v", defs)
	}
}

func TestDocComments(t *testing.T) {
	s := mustSchema(t, "// An order.\n// Two lines.\ntype Order = { id: Int }\n\n// not this\n\ntype B = Int")
	if d := s.Definitions(); d[0].Doc != "An order.\nTwo lines." || d[1].Doc != "" {
		t.Errorf("docs %q %q", d[0].Doc, d[1].Doc)
	}
}

func TestTypeErrors(t *testing.T) {
	s := mustSchema(t, "type P a = { x: a }\ntype E = Stream Int")
	if _, err := s.Type("Nope"); codeOfErr(err) != "unknown-type" {
		t.Errorf("unknown: %v", err)
	}
	if _, err := s.Type("P"); codeOfErr(err) != "wrong-arity" {
		t.Errorf("generic: %v", err)
	}
	e := mustType(t, s, "E")
	if !e.IsStream() {
		t.Error("E is a stream")
	}
	vs, err := e.DecodeAll([]haus.Value{parse(t, "1"), parse(t, "0x10")})
	if err != nil || canonical(t, haus.Array(vs)) != "[1,16]" {
		t.Errorf("DecodeAll: %v %v", vs, err)
	}
	_, err = e.DecodeAll([]haus.Value{parse(t, "1"), parse(t, "\"x\"")})
	if _, path := codeAndPath(err); path != "$[1]" {
		t.Errorf("DecodeAll error at %s: %v", path, err)
	}
	var got []string
	for v, err := range e.DecodeStream(strings.NewReader("1, 2, x\"00\","), haus.StreamOptions{}) {
		if err != nil {
			code, path := codeAndPath(err)
			got = append(got, string(code)+" "+path)
			break
		}
		got = append(got, canonical(t, v))
	}
	if strings.Join(got, ";") != "1;2;type-mismatch $[2]" {
		t.Errorf("DecodeStream: %v", got)
	}
}

func codeOfErr(err error) string {
	code, _ := codeAndPath(err)
	return string(code)
}

// Values built in code that contain themselves are cyclic-value when
// encoded (spec §9.8), deep ones nesting-too-deep, and either inside a
// Secret is invalid-secret, at the secret.
func TestEncodeCycles(t *testing.T) {
	s := mustSchema(t, "type Tree = { name: String, children: Array Tree }\ntype List = Array Any\ntype Box = { key: Secret Tree }")
	inner := haus.Array{nil}
	tree, _ := haus.NewRecord(haus.Field{Key: "name", Value: haus.String("a")}, haus.Field{Key: "children", Value: inner})
	inner[0] = tree
	if _, err := mustType(t, s, "Tree").Encode(tree); codeOfErr(err) != "cyclic-value" {
		t.Errorf("tree: %v", err)
	}
	if _, err := mustType(t, s, "Tree").Decode(tree); codeOfErr(err) != "cyclic-value" {
		t.Errorf("tree, decoded: %v", err)
	}
	list := haus.Array{haus.String("x"), nil}
	list[1] = list
	if _, err := mustType(t, s, "List").Encode(list); codeOfErr(err) != "cyclic-value" {
		t.Errorf("list: %v", err)
	}
	box, _ := haus.NewRecord(haus.Field{Key: "key", Value: tree})
	_, err := mustType(t, s, "Box").Encode(box)
	if code, path := codeAndPath(err); code != "invalid-secret" || path != "$.key" {
		t.Errorf("secret: %v", err)
	}
	// Deep, acyclic.
	var deep haus.Value = haus.Array{}
	for range 300 {
		r, _ := haus.NewRecord(haus.Field{Key: "name", Value: haus.String("n")}, haus.Field{Key: "children", Value: haus.Array{deep}})
		deep = r
	}
	if _, err := mustType(t, s, "Tree").Encode(deep); codeOfErr(err) != "nesting-too-deep" {
		t.Errorf("deep: %v", err)
	}
	// Invalid UTF-8 can't be written.
	bad, _ := haus.NewRecord(haus.Field{Key: "name", Value: haus.String("\xff")}, haus.Field{Key: "children", Value: haus.Array{}})
	if _, err := mustType(t, s, "Tree").Encode(bad); codeOfErr(err) != "cannot-encode" {
		t.Errorf("utf-8: %v", err)
	}
}

// Nothing of a secret's value shows in an error (spec §15), also through
// the keys of a Map or an Any inside it.
func TestSecretErrors(t *testing.T) {
	s := mustSchema(t, "type Vault = { keys: Secret (Map Int), raw: Secret Any }")
	vault := mustType(t, s, "Vault")
	leaky, _ := haus.NewRecord(haus.Field{Key: "keys", Value: parse(t, "{}")},
		haus.Field{Key: "raw", Value: haus.Array{haus.String("sk-live-123 hunter2")}})
	for _, v := range []haus.Value{parse(t, `{ keys: { "sk-live-123": "hunter2" }, raw: 1 }`), leaky} {
		_, err := vault.DecodeWith(v, schema.DecodeOptions{Limits: haus.Limits{MaxStringLength: 10}})
		code, path := codeAndPath(err)
		j, _ := json.Marshal(err)
		if code != "invalid-secret" || strings.Contains(err.Error(), "sk-live") || strings.Contains(err.Error(), "hunter2") ||
			bytes.Contains(j, []byte("hunter2")) {
			t.Errorf("%v at %s", err, path)
		}
	}
	secret := schema.NewSecret("hunter2")
	var buf bytes.Buffer
	slog.New(slog.NewTextHandler(&buf, nil)).Info("x", "key", secret)
	j, _ := json.Marshal(map[string]any{"key": secret})
	for _, shown := range []string{secret.String(), fmt.Sprintf("%v %+v %#v %s %q", secret, secret, secret, secret, secret), buf.String(), string(j)} {
		if strings.Contains(shown, "hunter2") || !strings.Contains(shown, "redacted") {
			t.Errorf("shown: %s", shown)
		}
	}
	if secret.Reveal() != "hunter2" {
		t.Error("Reveal")
	}
	// In an unexported field fmt can't call Format: it shows the pointer, not the value.
	type config struct {
		name string
		key  schema.Secret[string]
	}
	held := config{name: "prod", key: secret}
	if shown := fmt.Sprintf("%v %+v %#v", held, held, held); strings.Contains(shown, "hunter2") {
		t.Errorf("shown: %s", shown)
	}
	var zero schema.Secret[string]
	if zero.Reveal() != "" || zero.String() != "<redacted>" {
		t.Error("the zero Secret")
	}
}

func TestCodecs(t *testing.T) {
	s := mustSchema(t, "import std/time (Instant)\ntype At = Instant\ntype Even = Int\ntype Pair = { a: Even, at: At }")
	even := schema.NewCodec("Even", func(v haus.Value) (int64, error) {
		n, _ := v.(haus.Number).BigInt()
		if n.Bit(0) != 0 {
			return 0, fmt.Errorf("odd")
		}
		return n.Int64(), nil
	}, func(n int64) (haus.Value, error) { return haus.NumberFromInt(n), nil })
	codecs, err := schema.NewCodecs(even)
	if err != nil {
		t.Fatal(err)
	}
	pair := mustType(t, s, "Pair")
	opts := schema.DecodeOptions{Codecs: codecs}
	if _, err := pair.DecodeWith(parse(t, `{ a: 2, at: Instant("2026-11-13T10:00:00Z") }`), opts); err != nil {
		t.Errorf("even: %v", err)
	}
	_, err = pair.DecodeWith(parse(t, `{ a: 3, at: Instant("2026-11-13T10:00:00Z") }`), opts)
	if code, path := codeAndPath(err); code != "codec-rejected" || path != "$.a" {
		t.Errorf("odd: %v", err)
	}
	// Without codecs, 3 is an Int.
	if _, err := pair.Decode(parse(t, `{ a: 3, at: Instant("2026-11-13T10:00:00Z") }`)); err != nil {
		t.Errorf("no codecs: %v", err)
	}
	at := mustType(t, s, "At")
	tm, err := schema.DecodeAs[time.Time](at, parse(t, `Instant("2026-11-13T10:00:00.250+01:00")`), schema.InstantTime)
	if err != nil || !tm.Equal(time.Date(2026, 11, 13, 9, 0, 0, 250e6, time.UTC)) {
		t.Errorf("InstantTime: %v %v", tm, err)
	}
	v, err := schema.EncodeFrom(at, tm, schema.InstantTime)
	if err != nil || canonical(t, v) != `Instant("2026-11-13T10:00:00.25+01:00")` {
		t.Errorf("InstantTime encode: %v %v", v, err)
	}
	if _, err := schema.NewCodecs(even, even); err == nil {
		t.Error("two codecs for one type")
	}
}

// Relative imports: files next to the importing one, each read once, and
// errors in them reported at the import with their place in the file.
func TestRelativeImports(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "app.schema.haus"), "import ./billing/common (Iban)\nimport ./shared (Address)\ntype Root = { iban: Iban, to: Address }")
	write(t, filepath.Join(dir, "billing", "common.schema.haus"), "import ../shared (Address)\ntype Iban = { number: String, holder: Address }")
	write(t, filepath.Join(dir, "shared.schema.haus"), "type Address = { city: String }")
	s, err := schema.Load(filepath.Join(dir, "app.schema.haus"), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]string{}
	for _, d := range s.Imported() {
		ids[d.Name] = d.ID
	}
	if ids["Iban"] != "billing/common#Iban" || ids["Address"] != "shared#Address" {
		t.Errorf("ids %v", ids)
	}
	if _, err := s.Decode("Root", parse(t, `{ iban: { number: "DE", holder: { city: "Berlin" } }, to: { city: "Paris" } }`)); err != nil {
		t.Error(err)
	}
	write(t, filepath.Join(dir, "shared.schema.haus"), "type Address = { city: Strin }")
	_, err = schema.Load(filepath.Join(dir, "app.schema.haus"), schema.Options{})
	var e *haus.Error
	if !asError(err, &e) || e.Code != "unknown-type" || e.Line != 1 || !strings.Contains(e.Message, "./billing/common (1:1): ../shared (1:24): unknown type Strin") {
		t.Errorf("lifted error: %v", err)
	}
	write(t, filepath.Join(dir, "shared.schema.haus"), "import ./app (Root)\ntype Address = { city: String }")
	if _, err = schema.Load(filepath.Join(dir, "app.schema.haus"), schema.Options{}); codeOfErr(err) != "import-cycle" {
		t.Errorf("cycle: %v", err)
	}
	if _, err := schema.Load(filepath.Join(dir, "missing.schema.haus"), schema.Options{}); codeOfErr(err) != "import-not-found" {
		t.Errorf("missing root: %v", err)
	}
	big := filepath.Join(dir, "big.schema.haus")
	write(t, big, "type A = Int\n"+strings.Repeat("// padding\n", 100_000))
	if _, err := schema.Load(big, schema.Options{}); codeOfErr(err) != "file-too-large" {
		t.Errorf("big: %v", err)
	}
}

// More than MaxFiles schema files is too-many-files.
func TestTooManyFiles(t *testing.T) {
	dir := t.TempDir()
	for i := range schema.MaxFiles + 1 {
		text := fmt.Sprintf("type T%d = Int", i)
		if i < schema.MaxFiles {
			text = fmt.Sprintf("import ./f%d (T%d)\ntype T%d = T%d", i+1, i+1, i, i+1)
		}
		write(t, filepath.Join(dir, fmt.Sprintf("f%d.schema.haus", i)), text)
	}
	if _, err := schema.Load(filepath.Join(dir, "f0.schema.haus"), schema.Options{}); codeOfErr(err) != "too-many-files" {
		t.Errorf("got %v", err)
	}
}

// Decoding shares what it keeps of the input, and builds only what changes.
func TestDecodeKeepsInput(t *testing.T) {
	s := mustSchema(t, "type R = { a: Array String, b: Int, c?: Float64 }")
	v := parse(t, `{ a: ["x", "y"], b: -0, c: 0.10, d: 1 }`)
	out, err := mustType(t, s, "R").Decode(v)
	if err != nil || canonical(t, out) != `{a:["x","y"],b:0,c:0.1}` {
		t.Fatalf("%v %v", out, err)
	}
	in, _ := v.(haus.Record).Get("a")
	got, _ := out.(haus.Record).Get("a")
	if &in.(haus.Array)[0] != &got.(haus.Array)[0] {
		t.Error("an unchanged array is copied")
	}
}

// Generic types whose instances could grow without bound (§9.10, the
// expansive-cycle rule: an expanding edge of the parameter graph on a cycle)
// are rejected where the first growing reference is written, before any
// instance is made.
func TestGrowingInstances(t *testing.T) {
	const grow = ": instances could grow without bound"
	for _, c := range []struct {
		schema    string
		line, col int
		message   string
	}{
		{"type P a b = { l: a, r: b }\ntype A a = < X (B (P a a)) | Done >\ntype B a = < Y (A (P a a)) | Stop >\ntype Root = A Int",
			2, 17, "A passes its parameter a to B inside a bigger type, and it comes back (A → B → A)" + grow},
		// Through three definitions, with the growing argument only on the way back.
		{"type P a b = { l: a, r: b }\ntype A a = < X (B a) | Done >\ntype B a = < Y (C a) | Stop >\ntype C a = < Z (A (P a a)) | End >\ntype Root = A Int",
			4, 17, "C passes its parameter a to A inside a bigger type, and it comes back (C → A → B → C)" + grow},
		{"type Pair a b = { l: a, r: b }\ntype T a = < X (T (Pair a a)) | E >",
			2, 17, "T passes its parameter a to itself inside a bigger type" + grow},
		{"type L a = < X (L (Array a)) | E >", 1, 17, "L passes its parameter a to itself inside a bigger type" + grow},
		{"type R a = < X (R { v: a }) | E >", 1, 17, "R passes its parameter a to itself inside a bigger type" + grow},
		// The parameters swap places, and one grows on the way back.
		{"type S a b = < X a (S b (Array a)) | E >",
			1, 21, "S passes its parameter a to itself inside a bigger type, and it comes back (S → S → S)" + grow},
		// One expanding edge on a cycle through three definitions.
		{"type A a = < X (B a) | E >\ntype B b = < Y (C (Array b)) >\ntype C c = < Z (A c) >",
			2, 17, "B passes its parameter b to C inside a bigger type, and it comes back (B → C → A → B)" + grow},
		// Nested references count on their own: the inner one isn't expanding, the outer one is.
		{"type P a b = { l: a, r: b }\ntype W a = < X (W (Maybe (P a a))) | E >",
			2, 17, "W passes its parameter a to itself inside a bigger type" + grow},
		// The second parameter grows, not the first.
		{"type G a b = < X (G a (Array b)) | E >", 1, 19, "G passes its parameter b to itself inside a bigger type" + grow},
	} {
		start := time.Now()
		_, err := schema.Parse([]byte(c.schema), schema.Options{})
		if d := time.Since(start); d > time.Second {
			t.Errorf("took %v", d)
		}
		var e *haus.Error
		if !errors.As(err, &e) || e.Code != haus.CodeGrowingRecursion || e.Line != c.line || e.Column != c.col || e.Message != c.message {
			t.Errorf("%q: got %v", c.schema, err)
		}
	}
	s := mustSchema(t, "type GTree a = { value: a, kids: Forest a }\ntype Forest a = Array (GTree a)\n"+
		"type Swap a b = < S (Pair b a) | E >\ntype Pair a b = { p: Swap a b, q: Swap b a }\ntype Root = GTree (Pair Int String)")
	v, err := haus.Parse([]byte("{ value: { p: E, q: E }, kids: [] }"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Decode("Root", v); err != nil {
		t.Error(err)
	}
}

// Generic types whose instances can't grow without bound, though they pass
// other arguments than their own parameters around a cycle (§9.10).
func TestParametersThatGrowOffAnyCycle(t *testing.T) {
	s := mustSchema(t, `type Node a = { value: a, meta: Meta }
type Meta = { history: Array (Node String) }
type Expr = < Num Int | Call (Apply Expr) >
type Apply a = { f: a, args: Array Expr }
type Swap a b = < S a (Swap b a) | E >
type K a = < X (K Int) | Y a >
type Pair a b = { l: a, r: b }
type A a = < X (B (Pair a a)) >
type B b = < Y b | Z (A Int) >
type Root = { n: Node Int, e: Expr, s: Swap Int String, k: K String, a: A String }`)
	v, err := haus.Parse([]byte(`{ n: { value: 1, meta: { history: [{ value: "x", meta: { history: [] } }] } },
  e: Call({ f: Num(1), args: [Num(2)] }),
  s: S(1, S("a", S(2, E))),
  k: X(X(Y(3))),
  a: X(Y({ l: "p", r: "q" })) }`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Decode("Root", v); err != nil {
		t.Error(err)
	}
	bad, err := haus.Parse([]byte(`{ n: { value: "1", meta: { history: [] } }, e: Num(1), s: E, k: Y("k"), a: X(Z(X(Y({ l: 1, r: 2 })))) }`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Decode("Root", bad); err == nil {
		t.Error("Node Int takes a string")
	}
}

// Arguments nested 30 levels deep in generic types that don't recur, each
// passing its argument twice to the next, make types that would double at
// every level if copied: they compile quickly, and messages describe them
// shortly.
func TestDeeplyNestedArguments(t *testing.T) {
	chain := func(step string) string {
		defs := []string{"type G0 a = { v: a }"}
		for k := 1; k < 30; k++ {
			defs = append(defs, fmt.Sprintf("type G%d a = G%d (%s)", k, k-1, step))
		}
		return strings.Join(append(defs, "type Root = G29 Int"), "\n")
	}
	nested := "type P a b = { l: a, r: b }\ntype Root = " + strings.Repeat("P (", 30) + "P Int Int" + strings.Repeat(") Int", 30)
	for _, text := range []string{"type P a b = { l: a, r: b }\n" + chain("P a a"), chain("{ l: a, r: a }"), chain("< L a | R a >"), nested} {
		start := time.Now()
		s, err := schema.Parse([]byte(text), schema.Options{})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Decode("Root", haus.NumberFromInt(1)); err == nil || len(err.Error()) > 300 {
			t.Errorf("got %v", err)
		}
		if d := time.Since(start); d > time.Second {
			t.Errorf("took %v", d)
		}
	}
}

// A '~' after a file path is a syntax error at the '~' (grammar path), as
// in the reference.
func TestTildeInFilePath(t *testing.T) {
	_, err := schema.Parse([]byte("import ./a~b (A)\ntype B = A"), schema.Options{})
	var e *haus.Error
	if !asError(err, &e) || e.Code != haus.CodeSchemaSyntax || e.Line != 1 || e.Column != 11 {
		t.Errorf("got %v", err)
	}
}

// A typed single document that doesn't hold one value is not-one-value at
// $, as in the other bindings (stream/typed.cases.haus).
func TestTypedNotOneValue(t *testing.T) {
	s := mustSchema(t, "type Point = { x: Int, y: Int }")
	point := mustType(t, s, "Point")
	for _, text := range []string{"{ x: 1, y: 2 }, { x: 1, y: 2 }", "", "// nothing"} {
		_, err := point.Parse([]byte(text))
		if code, path := codeAndPath(err); code != haus.CodeNotOneValue || path != "$" {
			t.Errorf("%q: got %v (path %q)", text, err, path)
		}
	}
	_, err := point.DecodeAll([]haus.Value{})
	if code, path := codeAndPath(err); code != haus.CodeNotOneValue || path != "$" {
		t.Errorf("DecodeAll: got %v (path %q)", err, path)
	}
}

// sharedTree is n levels of [x, x] around [], which encodes and decodes
// 2^(n+1)−1 values with the type Tree.
func sharedTree(n int) haus.Value {
	v := haus.Value(haus.Array{})
	for range n {
		v = haus.Array{v, v}
	}
	return v
}

// TestTooManyNodesPlace: too-many-nodes from encoding or decoding a value
// built in code is at $, the value given, wherever the walk is, and at $[i]
// for the i-th value of a stream (spec §7, §15).
func TestTooManyNodesPlace(t *testing.T) {
	s := mustSchema(t, "type Tree = Array Tree\ntype Root = { a: { b: Tree } }\ntype Trees = Stream Tree")
	inner, err := haus.NewRecord(haus.Field{Key: "b", Value: sharedTree(10)})
	if err != nil {
		t.Fatal(err)
	}
	root, err := haus.NewRecord(haus.Field{Key: "a", Value: inner})
	if err != nil {
		t.Fatal(err)
	}
	opts := schema.DecodeOptions{Limits: haus.Limits{MaxNodes: 100}}
	r := mustType(t, s, "Root")
	if _, err := r.DecodeWith(root, opts); !isAt(err, haus.CodeTooManyNodes, "$") {
		t.Errorf("DecodeWith: %v", err)
	}
	if _, err := r.EncodeWith(root, opts); !isAt(err, haus.CodeTooManyNodes, "$") {
		t.Errorf("EncodeWith: %v", err)
	}
	if testing.Short() {
		return // the default node limit takes a while to reach
	}
	trees := mustType(t, s, "Trees")
	if _, err := trees.DecodeAll([]haus.Value{haus.Array{}, sharedTree(26)}); !isAt(err, haus.CodeTooManyNodes, "$[1]") {
		t.Errorf("DecodeAll: %v", err)
	}
}

// isAt reports whether err has the code and the path.
func isAt(err error, code haus.ErrorCode, path string) bool {
	c, p := codeAndPath(err)
	return c == code && p == path
}
