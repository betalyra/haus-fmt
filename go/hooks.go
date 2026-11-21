package haus

import "github.com/betalyra/haus-fmt/go/internal/hooks"

func init() {
	hooks.RecordOwned = recordOwned
	hooks.RecordFields = func(r Record) []Field { return r.fields }
	hooks.AppendQuoted = appendQuotedValid
	hooks.AppendLine = func(b []byte, v Value, lim Limits, minimised bool, depth int) ([]byte, error) {
		w := lineWriter{writeCheck: writeCheck{lim: lim}, b: b, minimised: minimised}
		err := w.value(v, depth)
		return w.b, err
	}
	hooks.CheckWritten = func(v Value, lim Limits) error {
		c := valueChecker{lim: lim, written: true}
		return c.value(v, 0)
	}
	hooks.NumberLit = func(lit string) Number { return Number{lit: lit} }
	hooks.ParseSchemaJSON = func(src string, lim Limits, skipBOM bool) (Value, error) {
		return parseJSON(src, lim, jsonSchema, skipBOM)
	}
	hooks.ParseValues = func(src string) ([]Value, error) {
		lim, err := Limits{}.resolve()
		if err != nil {
			return nil, err
		}
		p := newParser(src, lim, false)
		defer p.release()
		p.fileStart = false
		vs, _, err := p.file()
		return vs, err
	}
	hooks.SelfDescribing = func(j Value, lim Limits, depth int, prefix string) (Value, error) {
		s := selfDescribing{lim: lim, prefix: prefix}
		return s.value(j, depth)
	}
	hooks.SelfDescribingArgs = func(tag string, args Value, lim Limits, depth int, prefix string) (Value, error) {
		s := selfDescribing{lim: lim, prefix: prefix}
		return s.variant(tag, args, depth)
	}
	hooks.AppendSelfDescribing = appendSelfDescribing
	hooks.AppendJSONString = appendJSONString
	hooks.JSONLines = jsonLines
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
