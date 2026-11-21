// Package jsontypes holds the JSON baselines of the typed tasks: Go types
// generated from each source's JSON Schema (corpus/<source>.schema.json, the
// schema the TypeScript validators are built from), decoded and encoded by
// a JSON library. cmd/jsontypes writes them, one package per library and
// source, to gen/ (git-ignored), and each registers its root types here.
//
// It also reads the schema files (with their members in order), for the
// generator and for the checks before timing.
package jsontypes

import "sort"

// The JSON libraries the types are generated for.
const (
	EncodingJSON = "encoding/json"
	GoJSON       = "goccy/go-json"
)

// Libs are the libraries, in the order of the tasks.
var Libs = []string{EncodingJSON, GoJSON}

// Codec decodes and encodes one root type with one library.
type Codec struct {
	// Decode unmarshals a document into a new value of the type and returns
	// a pointer to it.
	Decode func([]byte) (any, error)
	// Encode marshals a value Decode returned.
	Encode func(any) ([]byte, error)
}

// Source is the generated types of one source, for one library.
type Source struct {
	// SchemaSHA256 is the SHA-256 of the schema file they were generated
	// from (hex), to tell stale types.
	SchemaSHA256 string
	Roots        map[string]Codec
}

var sources = map[[2]string]Source{}

// Register registers a source's types (from the generated packages' init).
func Register(lib, source string, s Source) { sources[[2]string{lib, source}] = s }

// Lookup returns a source's types for a library.
func Lookup(lib, source string) (Source, bool) {
	s, ok := sources[[2]string{lib, source}]
	return s, ok
}

// Registered lists the sources with types, as "lib source".
func Registered() []string {
	var out []string
	for k := range sources {
		out = append(out, k[0]+" "+k[1])
	}
	sort.Strings(out)
	return out
}
