// Package speed is the speed benchmark of the haus Go binding against
// encoding/json, on the corpus `bench convert` exports
// (bench/.out/<source>/corpus/), the same documents the TypeScript and Rust
// benchmarks read. The tasks mirror theirs:
//
//	parse   json.Unmarshal into any          vs  haus.Parse, haus.ParseAll (text → Value, no schema)
//	typed   haus.Parse + schema Type.Decode with the document's type (spec §15, at runtime)
//	write   json.Marshal of the any value    vs  haus.FormatValue minimised and compact, FormatValues (a stream)
//
// each on the whole corpus as one text (all.json, a JSON array; all.haus, a
// haus stream) and on every document on its own (the time is for all of
// them). The benchmarks are testing.B functions: `go test -bench .` runs
// them (and its output feeds benchstat), and cmd/speed times them with
// testing.Benchmark and writes bench/.out/<source>/speed-go.json.
package speed

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	haus "github.com/betalyra/haus-fmt/go"
)

// Document is one document of a source, in the forms that are read.
type Document struct {
	ID string
	// Root is the document's type in the schema.
	Root string
	// Haus is minimised haus (the wire form), Pretty the same pretty, JSON
	// minified JSON.
	Haus, Pretty, JSON []byte
}

// Corpus is one source's export:
//
//	<out>/<source>/corpus/
//	  index.haus             { source, schema, documents: [{ id, root, file }] }
//	  <source>.schema.haus   the schema; root is a type of it
//	  NNNN.haus              document NNNN, minimised haus
//	  NNNN.pretty.haus       the same, pretty
//	  NNNN.json              the same document, minified JSON
//	  all.haus               every document as one haus stream, minimised
//	  all.json               every document as one JSON array, minified
type Corpus struct {
	Source    string
	Schema    []byte
	Documents []Document
	// AllHaus is every document as one haus stream: each item followed by
	// ',' and a line feed. AllJSON is every document as one JSON array.
	AllHaus, AllJSON []byte
}

// BenchDir finds the bench/ directory from dir or one above it: the one
// that holds sources.haus.
func BenchDir(dir string) (string, error) {
	for d := dir; ; {
		if _, err := os.Stat(filepath.Join(d, "sources.haus")); err == nil {
			return d, nil
		}
		up := filepath.Dir(d)
		if up == d {
			return "", fmt.Errorf("no sources.haus in %s or above it", dir)
		}
		d = up
	}
}

// readValue reads the one value of a haus file.
func readValue(path string) (haus.Value, error) {
	text, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	v, err := haus.Parse(text)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return v, nil
}

func field[T haus.Value](v haus.Value, key, path string) (T, error) {
	var zero T
	r, ok := v.(haus.Record)
	if !ok {
		return zero, fmt.Errorf("%s: not a record", path)
	}
	x, ok := r.Get(key)
	if !ok {
		return zero, fmt.Errorf("%s: no %s", path, key)
	}
	t, ok := x.(T)
	if !ok {
		return zero, fmt.Errorf("%s: %s is a %s", path, key, x.Kind())
	}
	return t, nil
}

// Sources returns the names of the corpus sources in the manifest
// (bench/sources.haus), in its order.
func Sources(manifest string) ([]string, error) {
	m, err := readValue(manifest)
	if err != nil {
		return nil, err
	}
	corpus, err := field[haus.Array](m, "corpus", manifest)
	if err != nil {
		return nil, err
	}
	names := make([]string, len(corpus))
	for i, s := range corpus {
		name, err := field[haus.String](s, "name", manifest)
		if err != nil {
			return nil, err
		}
		names[i] = string(name)
	}
	return names, nil
}

// LoadCorpus reads a source's export from the results directory out.
func LoadCorpus(out, source string) (*Corpus, error) {
	dir := filepath.Join(out, source, "corpus")
	indexPath := filepath.Join(dir, "index.haus")
	if _, err := os.Stat(indexPath); errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("no corpus for %s in %s: run `pnpm --filter haus-bench convert` (from typescript/) first", source, dir)
	}
	index, err := readValue(indexPath)
	if err != nil {
		return nil, err
	}
	str := func(v haus.Value, key string) (string, error) {
		s, err := field[haus.String](v, key, indexPath)
		return string(s), err
	}
	read := func(name string) ([]byte, error) { return os.ReadFile(filepath.Join(dir, name)) }
	c := &Corpus{}
	if c.Source, err = str(index, "source"); err != nil {
		return nil, err
	}
	schemaFile, err := str(index, "schema")
	if err != nil {
		return nil, err
	}
	if c.Schema, err = read(schemaFile); err != nil {
		return nil, err
	}
	docs, err := field[haus.Array](index, "documents", indexPath)
	if err != nil {
		return nil, err
	}
	for _, d := range docs {
		var doc Document
		var file string
		if doc.ID, err = str(d, "id"); err != nil {
			return nil, err
		}
		if doc.Root, err = str(d, "root"); err != nil {
			return nil, err
		}
		if file, err = str(d, "file"); err != nil {
			return nil, err
		}
		if doc.Haus, err = read(file + ".haus"); err != nil {
			return nil, err
		}
		if doc.Pretty, err = read(file + ".pretty.haus"); err != nil {
			return nil, err
		}
		if doc.JSON, err = read(file + ".json"); err != nil {
			return nil, err
		}
		c.Documents = append(c.Documents, doc)
	}
	if c.AllHaus, err = read("all.haus"); err != nil {
		return nil, err
	}
	if c.AllJSON, err = read("all.json"); err != nil {
		return nil, err
	}
	return c, nil
}
