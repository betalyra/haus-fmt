package schema

import (
	"fmt"
	"slices"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
)

// Official profiles without their codecs (spec §13.4, "A profile without
// its codec"). A package's rule is checked only where a codec applies it: a
// schema that reaches Currency without a codec for it checks currencies for
// their shape only. That is allowed, never an error, but not silent. Codecs
// are given to each decoding call ([DecodeOptions]), so the warnings are
// asked for with the codecs: [Type.MissingCodecs] for one type,
// [Schema.MissingCodecs] for the file's own definitions. Codecs for an id
// that no type has are pointed out the same way, by [Schema.UnusedCodecs].

// ProfiledTypes are the types official profiles have a rule for, by id,
// with the profiles (spec §13.4). The iso profile's rule for Money is its
// currency's, so Currency stands for it. A build reads only a package's
// package.haus and schema.haus, so the binding keeps this table itself.
var ProfiledTypes = map[string][]string{
	"@haus-fmt/money@1#Currency": {"iso"},
	"@haus-fmt/geo@1#LatLng":     {"wgs84"},
	"@haus-fmt/geo@1#BBox":       {"wgs84"},
	"@haus-fmt/uuid@1#Uuid":      {"rfc9562"},
}

// MissingCodecs returns the missing-codec warnings for decoding with the
// type and codecs (nil: none): one for each type of [ProfiledTypes] that
// the type reaches and that has no codec, so that its values are checked
// for their shape only. A type reached only inside a type that has a codec
// doesn't count: that codec decides which values it holds (a codec for
// Money covers its Currency). Sorted by id, at no place, with the code
// [haus.CodeMissingCodec], like the warnings of [Schema.Warnings].
func (t Type) MissingCodecs(c *Codecs) []*haus.Error {
	if t.t == nil {
		return nil
	}
	return missingCodecs([]*typ{t.t}, c)
}

// MissingCodecs returns the missing-codec warnings of [Type.MissingCodecs]
// for every type the file's own definitions reach.
func (s *Schema) MissingCodecs(c *Codecs) []*haus.Error {
	roots := make([]*typ, 0, s.own)
	for _, d := range s.definitions[:s.own] {
		roots = append(roots, d.template.body)
	}
	return missingCodecs(roots, c)
}

func missingCodecs(roots []*typ, c *Codecs) []*haus.Error {
	coded := func(id string) bool {
		if c == nil {
			return false
		}
		_, ok := c.byID[id]
		return ok
	}
	missing := map[string]bool{}
	seenTypes := map[*typ]bool{}
	seenInstances := map[*instance]bool{}
	// An explicit stack: types nest as deep as schema files allow, and instances form cycles.
	stack := slices.Clone(roots)
	push := func(ts ...*typ) {
		for _, t := range ts {
			if t != nil && !seenTypes[t] {
				seenTypes[t] = true
				stack = append(stack, t)
			}
		}
	}
	for len(stack) > 0 {
		t := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		switch t.kind {
		case kRef:
			inst := t.inst
			if seenInstances[inst] {
				continue
			}
			seenInstances[inst] = true
			plain := len(inst.args) == 0
			if plain && coded(inst.id) {
				continue
			}
			if _, ok := ProfiledTypes[inst.id]; ok && plain {
				missing[inst.id] = true
			}
			push(inst.body)
		case kArray, kMap, kMaybe, kSecret:
			push(t.elem)
		case kRecord:
			for i := range t.rec.fields {
				push(t.rec.fields[i].typ)
			}
		case kVariant:
			for i := range t.vrt.cases {
				cs := &t.vrt.cases[i]
				if cs.rec != nil {
					for j := range cs.rec.fields {
						push(cs.rec.fields[j].typ)
					}
				}
				push(cs.named)
				push(cs.items...)
			}
		}
	}
	ids := make([]string, 0, len(missing))
	for id := range missing {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	out := make([]*haus.Error, len(ids))
	for i, id := range ids {
		out[i] = missingCodec(id)
	}
	return out
}

// UnusedCodecs returns the unused-codec warnings for decoding with the
// schema's types and codecs (spec §13.4, "A codec that matches no type"):
// one for each codec whose id is no type of the prelude, of std/time, nor of
// the schema's files and the packages they import, such as a typo or
// @haus-fmt/money@2#Money when the schema imports major 1. Such a codec
// never runs, and the values it was meant to check pass. Sorted by id, at
// no place, with the code [haus.CodeUnusedCodec], like the warnings of
// [Schema.Warnings].
func (s *Schema) UnusedCodecs(c *Codecs) []*haus.Error {
	if c == nil {
		return nil
	}
	var ids []string
	for id := range c.byID {
		if !s.ids[id] && !standardID(id) {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	out := make([]*haus.Error, len(ids))
	for i, id := range ids {
		out[i] = &haus.Error{Code: haus.CodeUnusedCodec, Message: fmt.Sprintf(
			"a codec is set for %s, but no type has that id: it never runs, and its values are checked for their shape only", id)}
	}
	return out
}

// standardID reports whether id is the id of a type of the prelude or of
// std/time.
func standardID(id string) bool {
	if name, ok := strings.CutPrefix(id, "prelude#"); ok {
		_, builtin := builtins[name]
		_, gen := generic[name]
		return builtin || gen
	}
	if name, ok := strings.CutPrefix(id, "std/time#"); ok {
		return slices.Contains(TimeTypes, name)
	}
	return false
}

// missingCodec is the warning for a type of [ProfiledTypes] without its codec.
func missingCodec(id string) *haus.Error {
	return &haus.Error{Code: haus.CodeMissingCodec, Message: fmt.Sprintf(
		"%s has profiles (%s), but no codec is set for it: its values are checked for their shape only",
		id, strings.Join(ProfiledTypes[id], ", "))}
}
