package speed

import (
	"encoding/json"
	"slices"
	"sort"

	"github.com/betalyra/haus-fmt/bench/speed/go/jsontypes"
)

// Mutated documents for the spot check before timing, made as
// bench/speed/ts/mutate.ts makes them: where the document's JSON Schema
// types a value, at a place where convert's reader rejects it too, so
// haus's typed parse rejects the document:
//
//	type      a typed value replaced by one of another JSON type (a string by 12345, a
//	          number or boolean by "x", an object or array by "x")
//	missing   a required member removed
//	enum      an enum value replaced by one the enum doesn't list
//	format    a date-time or date replaced by "not a date"
//
// The Go types don't reject all of them (encoding/json doesn't check
// required members or enum values): the counts are reported.

// MutationKinds are the kinds of mutation, in order.
var MutationKinds = []string{"type", "missing", "enum", "format"}

type site struct {
	kind  string
	path  []any // keys and indexes
	key   string
	value any
}

// Mutation is a mutated document.
type Mutation struct {
	Kind string
	Doc  int
	JSON []byte
}

type siteFinder struct {
	file  *jsontypes.File
	limit int
	sites []site
}

func (f *siteFinder) count(kind string) int {
	n := 0
	for _, s := range f.sites {
		if s.kind == kind {
			n++
		}
	}
	return n
}

func (f *siteFinder) add(s site) {
	// (not the whole document replaced: too easy to reject)
	if f.count(s.kind) < f.limit && (s.kind == "missing" || len(s.path) > 0) {
		f.sites = append(f.sites, s)
	}
}

func extend(path []any, k any) []any { return append(slices.Clone(path), k) }

func (f *siteFinder) walk(schema *jsontypes.Node, v any, path []any, depth int) {
	if depth > 40 {
		return
	}
	s := f.file.Resolve(schema)
	if s == nil || s.IsAny() || v == nil {
		return
	}
	if x := s.NullOr(); x != nil {
		f.walk(x, v, path, depth+1)
		return
	}
	t, _ := s.Type()
	switch t {
	case "string":
		if s.Get("enum") != nil {
			f.add(site{kind: "enum", path: path, value: "not-a-value-of-the-enum"})
		}
		if s.Get("format") != nil {
			f.add(site{kind: "format", path: path, value: "not a date"})
		}
		f.add(site{kind: "type", path: path, value: 12345})
		return
	case "integer", "number", "boolean":
		f.add(site{kind: "type", path: path, value: "x"})
		return
	case "array":
		a, ok := v.([]any)
		if !ok {
			return
		}
		f.add(site{kind: "type", path: path, value: "x"})
		for i, x := range a[:min(3, len(a))] {
			f.walk(s.Get("items"), x, extend(path, i), depth+1)
		}
		return
	}
	m, ok := v.(map[string]any)
	if t != "object" || !ok {
		return
	}
	f.add(site{kind: "type", path: path, value: "x"})
	if ap := s.Get("additionalProperties"); ap != nil {
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys[:min(3, len(keys))] {
			f.walk(ap, m[k], extend(path, k), depth+1)
		}
		return
	}
	if member := s.Discriminator(); member != "" {
		tag, _ := m[member].(string)
		if b := s.Branch(member, tag); b != nil {
			f.walk(b, v, path, depth+1)
		}
		return
	}
	if cases := s.Keyed(); cases != nil {
		if c, ok := jsontypes.CaseOf(cases, func(k string) bool { _, ok := m[k]; return ok }); ok {
			f.walk(c.Payload, v, path, depth+1)
		}
		return
	}
	for _, k := range s.Strings("required") {
		if _, ok := m[k]; ok {
			f.add(site{kind: "missing", path: path, key: k})
		}
	}
	if props := s.Get("properties"); props != nil {
		for _, k := range props.Keys {
			if x, ok := m[k]; ok {
				f.walk(props.Members[k], x, extend(path, k), depth+1)
			}
		}
	}
}

// apply makes a mutated copy of the document.
func apply(text []byte, s site) ([]byte, error) {
	doc, err := decodeJSON(text)
	if err != nil {
		return nil, err
	}
	parentPath := s.path
	if s.kind != "missing" {
		parentPath = s.path[:len(s.path)-1]
	}
	var at any = doc
	for _, k := range parentPath {
		switch k := k.(type) {
		case string:
			at = at.(map[string]any)[k]
		case int:
			at = at.([]any)[k]
		}
	}
	if s.kind == "missing" {
		delete(at.(map[string]any), s.key)
	} else {
		switch k := s.path[len(s.path)-1].(type) {
		case string:
			at.(map[string]any)[k] = s.value
		case int:
			at.([]any)[k] = s.value
		}
	}
	return json.Marshal(doc)
}

// Mutations returns up to perKind mutated documents of each kind, from the
// first documents that have such a place, one mutation per document.
func Mutations(c *Corpus, file *jsontypes.File, perKind int) ([]Mutation, error) {
	var out []Mutation
	made := map[string]int{}
	for i, d := range c.Documents {
		full := true
		for _, k := range MutationKinds {
			full = full && made[k] >= perKind
		}
		if full {
			break
		}
		v, err := decodeJSON(d.JSON)
		if err != nil {
			return nil, err
		}
		f := &siteFinder{file: file, limit: 4}
		f.walk(jsontypes.RefTo(d.Root), v, nil, 0)
		for _, s := range f.sites {
			if made[s.kind] >= perKind {
				continue
			}
			text, err := apply(d.JSON, s)
			if err != nil {
				return nil, err
			}
			out = append(out, Mutation{Kind: s.kind, Doc: i, JSON: text})
			made[s.kind]++
			break
		}
	}
	return out, nil
}
