package speed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
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
}

var (
	minimised = haus.FormatOptions{Layout: haus.Minimised}
	compact   = haus.FormatOptions{Layout: haus.Compact}
)

// Prepare reads a source's documents and looks up their types.
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
		in.Types = append(in.Types, t)
		in.Values = append(in.Values, v)
		in.JSONValues = append(in.JSONValues, j)
	}
	return in, nil
}

// Check runs the checks before timing, and returns the number of documents
// encoding/json writes back as another document through any (exact
// numbers; member order aside).
func (in *Inputs) Check() (jsonNotStable int, err error) {
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
		if _, err := in.Types[i].Decode(v); err != nil {
			return 0, fmt.Errorf("%s: decode as %s: %w", d.ID, d.Root, err)
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
	var array []any
	if err := json.Unmarshal(c.AllJSON, &array); err != nil {
		return 0, fmt.Errorf("all.json: %w", err)
	}
	if len(array) != len(in.Values) {
		return 0, fmt.Errorf("all.json holds %d documents, not %d", len(array), len(in.Values))
	}
	return jsonNotStable, nil
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

// Tasks returns the tasks, in the order of the TypeScript and Rust
// benchmarks. Bytes are those of the text read or written: the documents'
// files when reading, and what each writer writes (haus's FormatValue ends
// a file with a line feed; json.Marshal escapes <, > and & and sorts
// members).
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
	marshalBytes, err := writtenBytes(in.JSONValues, json.Marshal)
	if err != nil {
		return nil, err
	}
	corpusMarshal, err := json.Marshal(in.JSONValues)
	if err != nil {
		return nil, err
	}
	corpusStream, err := haus.FormatValues(in.Values, minimised)
	if err != nil {
		return nil, err
	}
	return []Task{
		{ID: "parse-corpus-json", Group: "parse", Input: "corpus", Format: "json",
			Impl: "json.Unmarshal (any)", Bytes: int64(len(c.AllJSON)),
			Run: func() (int, error) {
				var x []any
				err := json.Unmarshal(c.AllJSON, &x)
				return len(x), err
			}},
		{ID: "parse-corpus-haus", Group: "parse", Input: "corpus", Format: "haus",
			Impl: "haus.ParseAll", Bytes: int64(len(c.AllHaus)),
			Run: func() (int, error) {
				vs, err := haus.ParseAll(c.AllHaus)
				return len(vs), err
			}},
		{ID: "parse-doc-json", Group: "parse", Input: "per doc", Format: "json",
			Impl: "json.Unmarshal (any)", Bytes: jsonBytes,
			Run: func() (int, error) {
				n := 0
				for _, d := range docs {
					var x any
					if err := json.Unmarshal(d.JSON, &x); err != nil {
						return 0, err
					}
					if x != nil {
						n++
					}
				}
				return n, nil
			}},
		{ID: "parse-doc-haus", Group: "parse", Input: "per doc", Format: "haus",
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
			}},
		{ID: "typed-corpus-haus", Group: "typed", Input: "corpus", Format: "haus",
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
			}},
		{ID: "typed-doc-haus", Group: "typed", Input: "per doc", Format: "haus",
			Impl: "haus.Parse + Type.Decode", Bytes: hausBytes,
			Run: func() (int, error) {
				for i, d := range docs {
					v, err := haus.Parse(d.Haus)
					if err != nil {
						return 0, err
					}
					if _, err := in.Types[i].Decode(v); err != nil {
						return 0, err
					}
				}
				return len(docs), nil
			}},
		{ID: "write-corpus-json", Group: "write", Input: "corpus", Format: "json",
			Impl: "json.Marshal", Bytes: int64(len(corpusMarshal)),
			Run: func() (int, error) {
				b, err := json.Marshal(in.JSONValues)
				return len(b), err
			}},
		{ID: "write-corpus-haus", Group: "write", Input: "corpus", Format: "haus",
			Impl: "haus.FormatValues (minimised, a stream)", Bytes: int64(len(corpusStream)),
			Run: func() (int, error) {
				b, err := haus.FormatValues(in.Values, minimised)
				return len(b), err
			}},
		{ID: "write-doc-json", Group: "write", Input: "per doc", Format: "json",
			Impl: "json.Marshal", Bytes: marshalBytes,
			Run: func() (int, error) {
				n := 0
				for _, x := range in.JSONValues {
					b, err := json.Marshal(x)
					if err != nil {
						return 0, err
					}
					n += len(b)
				}
				return n, nil
			}},
		{ID: "write-doc-haus-minimised", Group: "write", Input: "per doc", Format: "haus",
			Impl: "haus.FormatValue (minimised)", Bytes: minimisedBytes,
			Run: func() (int, error) { return formatEach(in.Values, minimised) }},
		{ID: "write-doc-haus-compact", Group: "write", Input: "per doc", Format: "haus",
			Impl: "haus.FormatValue (compact)", Bytes: compactBytes,
			Run: func() (int, error) { return formatEach(in.Values, compact) }},
	}, nil
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
