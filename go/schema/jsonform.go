package schema

import (
	"cmp"
	"slices"

	haus "github.com/betalyra/haus-fmt/go"
)

// What a schema decides about schema-based JSON (spec §16.3) when it loads:
// which Maybes write None as null, and which record cases have no JSON form.

// markJSONNull decides, for every Maybe of the schema, whether its JSON
// writes None as null: when its item's JSON can't be null, and it doesn't
// reach itself through Maybe, Secret and names only (type T = Maybe T).
// A Maybe is identified by where it is written: each kMaybe node of an
// instance is one.
func (l *loader) markJSONNull() {
	var maybes []*typ
	seen := map[*typ]bool{}
	var walk func(t *typ)
	walkRecord := func(r *recordType) {
		for i := range r.fields {
			walk(r.fields[i].typ)
		}
	}
	walk = func(t *typ) {
		if t == nil || seen[t] {
			return
		}
		seen[t] = true
		switch t.kind {
		case kArray, kMap, kSecret:
			walk(t.elem)
		case kMaybe:
			maybes = append(maybes, t)
			walk(t.elem)
		case kRecord:
			walkRecord(t.rec)
		case kVariant:
			for i := range t.vrt.cases {
				c := &t.vrt.cases[i]
				if c.rec != nil {
					walkRecord(c.rec)
				}
				walk(c.named)
				for _, x := range c.items {
					walk(x)
				}
			}
		}
	}
	for _, inst := range l.instances {
		walk(inst.body)
	}
	memo := map[*typ]bool{}
	for _, m := range maybes {
		m.jsonNull = usesNull(m, memo)
	}
}

func usesNull(m *typ, memo map[*typ]bool) bool {
	if v, ok := memo[m]; ok {
		return v
	}
	memo[m] = false // a cycle back here is a Maybe that reaches itself
	v := !reachesItself(m) && !jsonNullable(m.elem, memo)
	memo[m] = v
	return v
}

// reachesItself reports whether the Maybe m reaches itself through Maybe,
// Secret and names only.
func reachesItself(m *typ) bool {
	seen := map[*typ]bool{}
	for t := m.elem; ; {
		switch t.kind {
		case kRef:
			t = t.inst.body
		case kMaybe, kSecret:
			if t == m {
				return true
			}
			if seen[t] {
				return false
			}
			seen[t] = true
			t = t.elem
		default:
			return false
		}
	}
}

// jsonNullable reports whether a type's JSON can be null: a Maybe that uses
// null, directly or through names and Secret.
func jsonNullable(t *typ, memo map[*typ]bool) bool {
	for {
		switch t.kind {
		case kRef:
			t = t.inst.body
		case kSecret:
			t = t.elem
		case kMaybe:
			return usesNull(t, memo)
		default:
			return false
		}
	}
}

// noJSONForms returns the record cases written in file u with a field
// named _tag or _args, which have no schema-based JSON form (spec §16.3):
// the schema is valid, converters fail on values of such a case, and
// checkers warn about it (no-json-form), at the case. Cases that spreads
// copy are reported where they are written.
func (l *loader) noJSONForms(u int) []*haus.Error {
	unit := l.units[u]
	type found struct {
		pos int
		msg string
	}
	var all []found
	var cases func(t *ty, rt *typ)
	inFields := func(fields []*fieldDef, r *recordType) {
		for _, f := range fields {
			if x := r.field(f.key); x != nil {
				cases(f.ty, x.typ)
			}
		}
	}
	cases = func(t *ty, rt *typ) {
		switch {
		case t.kind == tyName && t.name == "Result" && rt.kind == kVariant:
			for i, tag := range []string{"Err", "Ok"} {
				if c := rt.vrt.caseOf(tag); c != nil && c.payload == payloadPositional && i < len(t.args) {
					cases(t.args[i], c.items[0])
				}
			}
		case t.kind == tyName && (rt.kind == kArray || rt.kind == kMap || rt.kind == kMaybe || rt.kind == kSecret):
			for _, a := range t.args {
				cases(a, rt.elem)
			}
		case t.kind == tyRecord && rt.kind == kRecord:
			inFields(t.fields, rt.rec)
		case t.kind == tyVariant && rt.kind == kVariant:
			for _, cd := range t.cases {
				c := rt.vrt.caseOf(cd.tag)
				if c == nil {
					continue
				}
				if f := reservedField(c); f != "" {
					all = append(all, found{cd.pos, cd.tag + " has a field named " + f + ", so it has no schema-based JSON form"})
				}
				switch {
				case c.payload == payloadRecord && len(cd.payload) == 1 && cd.payload[0].kind == tyRecord:
					inFields(cd.payload[0].fields, c.rec)
				case c.payload == payloadNamed && len(cd.payload) == 1:
					cases(cd.payload[0], c.named)
				case c.payload == payloadPositional && len(cd.payload) == len(c.items):
					for i, p := range cd.payload {
						cases(p, c.items[i])
					}
				}
			}
		}
		// Named types are checked where they are defined; parameters and
		// scalars have no cases.
	}
	for d, def := range unit.file.types {
		inst := l.instances[l.byKey[templateKey(u, d, def.params)]]
		t := def.ty
		if t.kind == tyName && t.name == "Stream" && inst.stream && len(t.args) == 1 {
			t = t.args[0]
		}
		cases(t, inst.body)
	}
	slices.SortFunc(all, func(a, b found) int { return cmp.Compare(a.pos, b.pos) })
	all = slices.CompactFunc(all, func(a, b found) bool { return a.pos == b.pos })
	out := make([]*haus.Error, len(all))
	for i, f := range all {
		line, col := lineCol(unit.text, f.pos)
		out[i] = &haus.Error{Code: haus.CodeNoJSONForm, Message: f.msg, Line: line, Column: col}
	}
	return out
}
