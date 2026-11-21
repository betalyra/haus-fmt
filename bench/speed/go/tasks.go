package speed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
	gojson "github.com/goccy/go-json"

	"github.com/betalyra/haus-fmt/bench/speed/go/jsontypes"
)

// Inputs are the inputs of one source, prepared and checked once.
type Inputs struct {
	Corpus *Corpus
	// Types holds each document's type, looked up once.
	Types []schema.Type
	// Values holds each haus document, parsed; JSONValues each JSON
	// document, read by encoding/json into any.
	Values     []haus.Value
	JSONValues []any
	// Decoded holds each document decoded with its type (Type.Decode):
	// what the typed haus write writes.
	Decoded []haus.Value
	// JSONSchema is the source's JSON Schema; Typed the typed JSON
	// baselines, per library: the documents decoded into the Go types
	// generated from it.
	JSONSchema *jsontypes.File
	Typed      []*JSONTyped
}

var (
	minimised = haus.FormatOptions{Layout: haus.Minimised}
	compact   = haus.FormatOptions{Layout: haus.Compact}
)

// Prepare reads a source's documents, looks up their types, and decodes
// them with the typed JSON baselines.
func Prepare(c *Corpus) (*Inputs, error) {
	if len(c.Documents) == 0 {
		return nil, fmt.Errorf("%s: no documents: run convert first", c.Source)
	}
	s, err := schema.Parse(c.Schema, schema.Options{})
	if err != nil {
		return nil, fmt.Errorf("%s schema: %w", c.Source, err)
	}
	in := &Inputs{Corpus: c}
	types := map[string]schema.Type{}
	for _, d := range c.Documents {
		t, ok := types[d.Root]
		if !ok {
			if t, err = s.Type(d.Root); err != nil {
				return nil, fmt.Errorf("%s: %w", d.ID, err)
			}
			types[d.Root] = t
		}
		v, err := haus.Parse(d.Haus)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", d.ID, err)
		}
		var j any
		if err := json.Unmarshal(d.JSON, &j); err != nil {
			return nil, fmt.Errorf("%s: encoding/json: %w", d.ID, err)
		}
		var g any
		if err := gojson.Unmarshal(d.JSON, &g); err != nil {
			return nil, fmt.Errorf("%s: go-json: %w", d.ID, err)
		}
		decoded, err := t.Decode(v)
		if err != nil {
			return nil, fmt.Errorf("%s: decode as %s: %w", d.ID, d.Root, err)
		}
		in.Types = append(in.Types, t)
		in.Values = append(in.Values, v)
		in.JSONValues = append(in.JSONValues, j)
		in.Decoded = append(in.Decoded, decoded)
	}
	if in.JSONSchema, err = jsontypes.ReadFile(c.JSONSchema); err != nil {
		return nil, err
	}
	if in.Typed, err = prepareTyped(c, in.JSONSchema); err != nil {
		return nil, err
	}
	return in, nil
}

// Check runs the checks before timing, and returns the number of documents
// encoding/json writes back as another document through any (exact
// numbers; member order aside), and the checks of the typed JSON
// baselines.
func (in *Inputs) Check() (jsonNotStable int, typed TypedBaselines, err error) {
	if jsonNotStable, err = in.checkUntyped(); err != nil {
		return 0, typed, err
	}
	typed, err = in.checkTyped()
	return jsonNotStable, typed, err
}

func (in *Inputs) checkUntyped() (jsonNotStable int, err error) {
	c := in.Corpus
	for i, d := range c.Documents {
		v := in.Values[i]
		// FormatValue writes a file: the value and a line feed.
		written, err := haus.FormatValue(v, minimised)
		if err != nil {
			return 0, fmt.Errorf("%s: %w", d.ID, err)
		}
		if !bytes.Equal(written, append(bytes.Clone(d.Haus), '\n')) {
			return 0, fmt.Errorf("%s: haus Parse → FormatValue (minimised) is not the same text", d.ID)
		}
		pretty, err := haus.Parse(d.Pretty)
		if err != nil {
			return 0, fmt.Errorf("%s (pretty): %w", d.ID, err)
		}
		if again, err := haus.FormatValue(pretty, minimised); err != nil || !bytes.Equal(again, written) {
			return 0, fmt.Errorf("%s: the pretty text reads as another value", d.ID)
		}
		back, err := json.Marshal(in.JSONValues[i])
		if err != nil {
			return 0, fmt.Errorf("%s: encoding/json: %w", d.ID, err)
		}
		a, err := haus.ImportJSON(back)
		if err != nil {
			return 0, fmt.Errorf("%s: %w", d.ID, err)
		}
		b, err := haus.ImportJSON(d.JSON)
		if err != nil {
			return 0, fmt.Errorf("%s: %w", d.ID, err)
		}
		if !haus.Equals(a, b) {
			jsonNotStable++
		}
	}
	stream, err := haus.ParseAll(c.AllHaus)
	if err != nil {
		return 0, fmt.Errorf("all.haus: %w", err)
	}
	if len(stream) != len(in.Values) {
		return 0, fmt.Errorf("all.haus holds %d values, not %d", len(stream), len(in.Values))
	}
	for i, v := range stream {
		if !haus.Equals(v, in.Values[i]) {
			return 0, fmt.Errorf("all.haus: value %d is another value than %s", i, c.Documents[i].ID)
		}
	}
	written, err := haus.FormatValues(in.Values, minimised)
	if err != nil {
		return 0, err
	}
	if len(in.Values) > 1 && !bytes.Equal(written, c.AllHaus) {
		return 0, fmt.Errorf("all.haus isn't what FormatValues (minimised) writes for the documents")
	}
	var array, goArray []any
	if err := json.Unmarshal(c.AllJSON, &array); err != nil {
		return 0, fmt.Errorf("all.json: %w", err)
	}
	if len(array) != len(in.Values) {
		return 0, fmt.Errorf("all.json holds %d documents, not %d", len(array), len(in.Values))
	}
	if err := gojson.Unmarshal(c.AllJSON, &goArray); err != nil || len(goArray) != len(in.Values) {
		return 0, fmt.Errorf("all.json: go-json reads another array (%v)", err)
	}
	return jsonNotStable, nil
}

// TypedBaselines are the checks of the typed JSON baselines: the shape of
// typedBaselines in speed-typescript.json, with the mutated documents made
// and each library's round trip.
type TypedBaselines struct {
	// Versions of the JSON libraries.
	Versions map[string]string `json:"versions"`
	// Mutated documents made (Mutations), and those every Go baseline
	// rejected, by kind.
	Mutated  map[string]int `json:"mutated"`
	Rejected map[string]int `json:"rejected"`
	// TypedWriteOtherText counts the documents whose typed haus write isn't
	// the document's text (members in the schema's order, members it
	// doesn't list dropped); JSONWriterOtherText those whose encoding/json
	// write of the Go types isn't the document's JSON.
	TypedWriteOtherText int `json:"typedWriteOtherText"`
	JSONWriterOtherText int `json:"jsonWriterOtherText"`
	// RoundTrip is each library's typed round trip.
	RoundTrip map[string]RoundTrip `json:"roundTrip"`
}

// libVersions are the JSON libraries' versions: Go's for encoding/json, the
// module's for go-json.
func libVersions() map[string]string {
	v := map[string]string{jsontypes.EncodingJSON: runtime.Version(), jsontypes.GoJSON: "unknown"}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, d := range info.Deps {
			if d.Path == "github.com/goccy/go-json" {
				v[jsontypes.GoJSON] = d.Version
			}
		}
	}
	return v
}

// checkTyped checks the typed tasks: the typed haus write reads back as the
// same values; every Go baseline accepted every document (Prepare) and
// writes back the members the schema lists with the same values (counting
// what the Go types change: RoundTrip); and which mutated documents the Go
// baselines reject.
func (in *Inputs) checkTyped() (TypedBaselines, error) {
	c := in.Corpus
	out := TypedBaselines{Versions: libVersions(), Mutated: map[string]int{}, Rejected: map[string]int{}, RoundTrip: map[string]RoundTrip{}}
	for i, d := range c.Documents {
		text, err := in.typedWrite(i)
		if err != nil {
			return out, fmt.Errorf("%s: typed haus write: %w", d.ID, err)
		}
		back, err := haus.Parse(text)
		if err != nil {
			return out, fmt.Errorf("%s: the typed haus write doesn't parse: %w", d.ID, err)
		}
		if again, err := in.Types[i].Decode(back); err != nil || !haus.Equals(again, in.Decoded[i]) {
			return out, fmt.Errorf("%s: the typed haus write doesn't read back as the same values", d.ID)
		}
		// The one-pass calls the tasks time give what the two passes give.
		enc, err := in.Types[i].Encode(in.Decoded[i])
		if err != nil {
			return out, fmt.Errorf("%s: Type.Encode: %w", d.ID, err)
		}
		if two, err := haus.FormatValue(enc, minimised); err != nil || !bytes.Equal(two, text) {
			return out, fmt.Errorf("%s: Type.Format isn't Type.Encode + FormatValue", d.ID)
		}
		if parsed, err := in.Types[i].Parse(d.Haus); err != nil || !haus.Equals(parsed, in.Decoded[i]) {
			return out, fmt.Errorf("%s: Type.Parse isn't haus.Parse + Type.Decode", d.ID)
		}
		if !bytes.Equal(text, append(bytes.Clone(d.Haus), '\n')) {
			out.TypedWriteOtherText++
		}
	}
	for _, t := range in.Typed {
		rt, err := t.checkRoundTrip(c, in.JSONSchema)
		if err != nil {
			return out, err
		}
		out.RoundTrip[t.Lib] = rt
	}
	out.JSONWriterOtherText = out.RoundTrip[jsontypes.EncodingJSON].OtherText
	mutated, err := Mutations(c, in.JSONSchema, 5)
	if err != nil {
		return out, err
	}
	for _, k := range MutationKinds {
		out.Mutated[k], out.Rejected[k] = 0, 0
	}
	for _, m := range mutated {
		out.Mutated[m.Kind]++
		all := true
		for _, t := range in.Typed {
			_, err := t.Codecs[m.Doc].Decode(m.JSON)
			all = all && err != nil
		}
		if all {
			out.Rejected[m.Kind]++
		}
	}
	return out, nil
}

// typedWrite is the typed haus write of document i: Type.Format, minimised,
// which checks the value against the type as it writes it (the text and
// errors of Type.Encode followed by FormatValue, in one pass).
func (in *Inputs) typedWrite(i int) ([]byte, error) {
	return in.Types[i].Format(in.Decoded[i], minimised)
}

// Task is one timed task: what it is, and its body, one iteration of the
// library calls, which returns a size (for the checksum).
type Task struct {
	ID     string
	Group  string // parse, typed, write
	Input  string // corpus, per doc
	Format string // json, haus
	Impl   string
	// Bytes are those read (parse, typed) or written (write) per iteration.
	Bytes int64
	Run   func() (int, error)
}

// Bench is the task as a testing.B benchmark.
func (t Task) Bench(b *testing.B) {
	b.SetBytes(t.Bytes)
	b.ReportAllocs()
	for b.Loop() {
		if _, err := t.Run(); err != nil {
			b.Fatal(err)
		}
	}
}

func sum[T any](xs []T, size func(T) int) (n int64) {
	for _, x := range xs {
		n += int64(size(x))
	}
	return n
}

// writtenBytes is the size of what write writes for each value.
func writtenBytes[T any](xs []T, write func(T) ([]byte, error)) (int64, error) {
	var n int64
	for _, x := range xs {
		b, err := write(x)
		if err != nil {
			return 0, err
		}
		n += int64(len(b))
	}
	return n, nil
}

// indexes are 0…n-1, for writtenBytes over documents.
func indexes(n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = i
	}
	return out
}

// slug is a library's name in a task ID: encoding-json, goccy-go-json.
func slug(lib string) string { return strings.ReplaceAll(lib, "/", "-") }

// The JSON libraries' untyped calls, by name: encoding/json first (the
// report's baseline is the first JSON task of a group).
type untyped struct {
	name      string
	unmarshal func([]byte, any) error
	marshal   func(any) ([]byte, error)
}

var untypedLibs = []untyped{
	{jsontypes.EncodingJSON, json.Unmarshal, json.Marshal},
	{jsontypes.GoJSON, gojson.Unmarshal, gojson.Marshal},
}

// Tasks returns the tasks, in the order of the TypeScript and Rust
// benchmarks; in each group, encoding/json into any comes first (the
// report's baseline), then go-json, then the typed JSON baselines. Bytes
// are those of the text read or written: the documents' files when
// reading, and what each writer writes (haus's FormatValue ends a file with
// a line feed; json.Marshal escapes <, > and & and sorts a map's members;
// the Go types write the members the schema lists, in its order).
func (in *Inputs) Tasks() ([]Task, error) {
	c := in.Corpus
	docs := c.Documents
	hausBytes := sum(docs, func(d Document) int { return len(d.Haus) })
	jsonBytes := sum(docs, func(d Document) int { return len(d.JSON) })
	formatWith := func(o haus.FormatOptions) func(haus.Value) ([]byte, error) {
		return func(v haus.Value) ([]byte, error) { return haus.FormatValue(v, o) }
	}
	minimisedBytes, err := writtenBytes(in.Values, formatWith(minimised))
	if err != nil {
		return nil, err
	}
	compactBytes, err := writtenBytes(in.Values, formatWith(compact))
	if err != nil {
		return nil, err
	}
	typedWriteBytes, err := writtenBytes(indexes(len(docs)), in.typedWrite)
	if err != nil {
		return nil, err
	}
	corpusStream, err := haus.FormatValues(in.Values, minimised)
	if err != nil {
		return nil, err
	}

	var parse, typed, write []Task
	for _, l := range untypedLibs {
		parse = append(parse,
			Task{ID: "parse-corpus-" + slug(l.name), Group: "parse", Input: "corpus", Format: "json",
				Impl: l.name + " Unmarshal into any", Bytes: int64(len(c.AllJSON)),
				Run: func() (int, error) {
					var x []any
					err := l.unmarshal(c.AllJSON, &x)
					return len(x), err
				}})
	}
	parse = append(parse, Task{ID: "parse-corpus-haus", Group: "parse", Input: "corpus", Format: "haus",
		Impl: "haus.ParseAll", Bytes: int64(len(c.AllHaus)),
		Run: func() (int, error) {
			vs, err := haus.ParseAll(c.AllHaus)
			return len(vs), err
		}})
	for _, l := range untypedLibs {
		parse = append(parse, Task{ID: "parse-doc-" + slug(l.name), Group: "parse", Input: "per doc", Format: "json",
			Impl: l.name + " Unmarshal into any", Bytes: jsonBytes,
			Run: func() (int, error) {
				n := 0
				for _, d := range docs {
					var x any
					if err := l.unmarshal(d.JSON, &x); err != nil {
						return 0, err
					}
					if x != nil {
						n++
					}
				}
				return n, nil
			}})
	}
	parse = append(parse, Task{ID: "parse-doc-haus", Group: "parse", Input: "per doc", Format: "haus",
		Impl: "haus.Parse", Bytes: hausBytes,
		Run: func() (int, error) {
			n := 0
			for _, d := range docs {
				v, err := haus.Parse(d.Haus)
				if err != nil {
					return 0, err
				}
				if v != nil {
					n++
				}
			}
			return n, nil
		}})

	typed = append(typed, Task{ID: "typed-corpus-haus", Group: "typed", Input: "corpus", Format: "haus",
		Impl: "haus.ParseAll + Type.Decode", Bytes: int64(len(c.AllHaus)),
		Run: func() (int, error) {
			vs, err := haus.ParseAll(c.AllHaus)
			if err != nil {
				return 0, err
			}
			for i, v := range vs {
				if _, err := in.Types[i].Decode(v); err != nil {
					return 0, err
				}
			}
			return len(vs), nil
		}})
	for _, t := range in.Typed {
		typed = append(typed, Task{ID: "typed-doc-" + slug(t.Lib), Group: "typed", Input: "per doc", Format: "json",
			Impl: t.Lib + " Unmarshal into the Go types", Bytes: jsonBytes,
			Run: func() (int, error) {
				n := 0
				for i, d := range docs {
					v, err := t.Codecs[i].Decode(d.JSON)
					if err != nil {
						return 0, err
					}
					if v != nil {
						n++
					}
				}
				return n, nil
			}})
	}
	typed = append(typed, Task{ID: "typed-doc-haus", Group: "typed", Input: "per doc", Format: "haus",
		Impl: "haus Type.Parse (haus.Parse + Type.Decode)", Bytes: hausBytes,
		Run: func() (int, error) {
			for i, d := range docs {
				if _, err := in.Types[i].Parse(d.Haus); err != nil {
					return 0, err
				}
			}
			return len(docs), nil
		}})

	for _, l := range untypedLibs {
		corpusMarshal, err := l.marshal(in.JSONValues)
		if err != nil {
			return nil, err
		}
		write = append(write, Task{ID: "write-corpus-" + slug(l.name), Group: "write", Input: "corpus", Format: "json",
			Impl: l.name + " Marshal of any", Bytes: int64(len(corpusMarshal)),
			Run: func() (int, error) {
				b, err := l.marshal(in.JSONValues)
				return len(b), err
			}})
	}
	write = append(write, Task{ID: "write-corpus-haus", Group: "write", Input: "corpus", Format: "haus",
		Impl: "haus.FormatValues (minimised, a stream)", Bytes: int64(len(corpusStream)),
		Run: func() (int, error) {
			b, err := haus.FormatValues(in.Values, minimised)
			return len(b), err
		}})
	for _, l := range untypedLibs {
		marshalBytes, err := writtenBytes(in.JSONValues, l.marshal)
		if err != nil {
			return nil, err
		}
		write = append(write, Task{ID: "write-doc-" + slug(l.name), Group: "write", Input: "per doc", Format: "json",
			Impl: l.name + " Marshal of any", Bytes: marshalBytes,
			Run: func() (int, error) {
				n := 0
				for _, x := range in.JSONValues {
					b, err := l.marshal(x)
					if err != nil {
						return 0, err
					}
					n += len(b)
				}
				return n, nil
			}})
	}
	for _, t := range in.Typed {
		encode := func(i int) ([]byte, error) { return t.Codecs[i].Encode(t.Values[i]) }
		typedBytes, err := writtenBytes(indexes(len(docs)), encode)
		if err != nil {
			return nil, err
		}
		write = append(write, Task{ID: "write-doc-typed-" + slug(t.Lib), Group: "write", Input: "per doc", Format: "json",
			Impl: t.Lib + " Marshal of the Go types", Bytes: typedBytes,
			Run: func() (int, error) {
				n := 0
				for i := range docs {
					b, err := encode(i)
					if err != nil {
						return 0, err
					}
					n += len(b)
				}
				return n, nil
			}})
	}
	write = append(write,
		Task{ID: "write-doc-haus-minimised", Group: "write", Input: "per doc", Format: "haus",
			Impl: "haus.FormatValue (minimised)", Bytes: minimisedBytes,
			Run: func() (int, error) { return formatEach(in.Values, minimised) }},
		Task{ID: "write-doc-haus-compact", Group: "write", Input: "per doc", Format: "haus",
			Impl: "haus.FormatValue (compact)", Bytes: compactBytes,
			Run: func() (int, error) { return formatEach(in.Values, compact) }},
		Task{ID: "write-doc-haus-typed", Group: "write", Input: "per doc", Format: "haus",
			Impl: "haus Type.Format minimised (typed: Type.Encode + FormatValue in one pass)", Bytes: typedWriteBytes,
			Run: func() (int, error) {
				n := 0
				for i := range docs {
					b, err := in.typedWrite(i)
					if err != nil {
						return 0, err
					}
					n += len(b)
				}
				return n, nil
			}})
	return append(append(parse, typed...), write...), nil
}

func formatEach(vs []haus.Value, o haus.FormatOptions) (int, error) {
	n := 0
	for _, v := range vs {
		b, err := haus.FormatValue(v, o)
		if err != nil {
			return 0, err
		}
		n += len(b)
	}
	return n, nil
}
