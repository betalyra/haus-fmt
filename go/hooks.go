package haus

import "github.com/betalyra/haus-fmt/go/internal/hooks"

func init() {
	hooks.RecordOwned = recordOwned
	hooks.NumberLit = func(lit string) Number { return Number{lit: lit} }
}

// recordOwned builds a record from fields with distinct keys, which it keeps.
func recordOwned(fields []Field) Record {
	r := Record{fields: fields}
	if len(fields) >= indexFrom {
		r.index = make(map[string]int, len(fields))
		for i, f := range fields {
			r.index[f.Key] = i
		}
	}
	return r
}
