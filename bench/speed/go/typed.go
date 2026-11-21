package speed

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"slices"
	"strconv"
	"time"

	"github.com/betalyra/haus-fmt/bench/speed/go/jsontypes"
)

// JSONTyped is the JSON baseline of the typed tasks for one library: Go
// types generated from the source's JSON Schema (cmd/jsontypes), each
// document's root type's codec, and the documents decoded with them.
type JSONTyped struct {
	Lib    string
	Codecs []jsontypes.Codec
	// Values are the documents decoded (pointers to the root types).
	Values []any
}

// prepareTyped looks up the generated types of each document's root type,
// for each library, and decodes the documents with them.
func prepareTyped(c *Corpus, file *jsontypes.File) ([]*JSONTyped, error) {
	var out []*JSONTyped
	for _, lib := range jsontypes.Libs {
		src, ok := jsontypes.Lookup(lib, c.Source)
		if !ok {
			return nil, fmt.Errorf("no Go types for %s (%s): run `go generate` in bench/speed/go after convert", c.Source, lib)
		}
		if src.SchemaSHA256 != file.SHA256 {
			return nil, fmt.Errorf("the Go types for %s (%s) are of another schema: run `go generate` in bench/speed/go again", c.Source, lib)
		}
		t := &JSONTyped{Lib: lib}
		for _, d := range c.Documents {
			codec, ok := src.Roots[d.Root]
			if !ok {
				return nil, fmt.Errorf("no Go type for %s: run `go generate` in bench/speed/go again", d.Root)
			}
			v, err := codec.Decode(d.JSON)
			if err != nil {
				return nil, fmt.Errorf("%s: %s rejects the document as %s: %w", d.ID, lib, d.Root, err)
			}
			t.Codecs = append(t.Codecs, codec)
			t.Values = append(t.Values, v)
		}
		out = append(out, t)
	}
	return out, nil
}

// RoundTrip counts the documents whose typed JSON round trip (the document
// decoded into the Go types, then encoded) isn't the document's members
// the schema lists, by reason; any other difference is an error.
type RoundTrip struct {
	// NumbersRounded: a number float64 can't hold exactly (in a Float64 or
	// an Any) comes back rounded.
	NumbersRounded int `json:"numbersRounded"`
	// TimesRespelled: a date-time comes back as the same instant in
	// time.Time's spelling (Z for +00:00, no trailing zeros in the
	// fraction).
	TimesRespelled int `json:"timesRespelled"`
	// NullsDropped: an optional member that is null is left out (a nil
	// pointer, slice, map or any is both "absent" and null).
	NullsDropped int `json:"nullsDropped"`
	// OtherText: the text written isn't the document's (the above, members
	// the schema doesn't list, member order, escaping).
	OtherText int `json:"otherText"`
}

// roundTrip compares a document's JSON with the JSON the typed baseline
// wrote for it, by the schema.
type roundTrip struct {
	file                     *jsontypes.File
	rounded, respelled, null bool
}

func decodeJSON(text []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(text))
	d.UseNumber()
	var v any
	return v, d.Decode(&v)
}

// checkRoundTrip checks the typed write of each document and counts the
// differences that are the Go types' (RoundTrip).
func (t *JSONTyped) checkRoundTrip(c *Corpus, file *jsontypes.File) (RoundTrip, error) {
	var counts RoundTrip
	for i, d := range c.Documents {
		written, err := t.Codecs[i].Encode(t.Values[i])
		if err != nil {
			return counts, fmt.Errorf("%s: %s can't write the document back: %w", d.ID, t.Lib, err)
		}
		if !bytes.Equal(written, d.JSON) {
			counts.OtherText++
		}
		orig, err := decodeJSON(d.JSON)
		if err != nil {
			return counts, err
		}
		back, err := decodeJSON(written)
		if err != nil {
			return counts, fmt.Errorf("%s: %s wrote invalid JSON: %w", d.ID, t.Lib, err)
		}
		r := &roundTrip{file: file}
		if err := r.same(jsontypes.RefTo(d.Root), orig, back, "$"); err != nil {
			return counts, fmt.Errorf("%s: %s's typed round trip gives another value: %w", d.ID, t.Lib, err)
		}
		counts.NumbersRounded += b2i(r.rounded)
		counts.TimesRespelled += b2i(r.respelled)
		counts.NullsDropped += b2i(r.null)
	}
	return counts, nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func (r *roundTrip) same(s *jsontypes.Node, a, b any, path string) error {
	s = r.file.Resolve(s)
	if s == nil || s.IsAny() {
		return r.sameAny(a, b, path)
	}
	if x := s.NullOr(); x != nil {
		if a == nil || b == nil {
			return r.both(a == nil && b == nil, path)
		}
		return r.same(x, a, b, path)
	}
	if c, ok := s.Str("const"); ok {
		return r.both(a == c && b == c, path)
	}
	t, nullable := s.Type()
	if a == nil || b == nil {
		return r.both(a == nil && b == nil && nullable, path)
	}
	am, aObj := a.(map[string]any)
	bm, bObj := b.(map[string]any)
	if member := s.Discriminator(); member != "" {
		tag, _ := am[member].(string)
		branch := s.Branch(member, tag)
		if !aObj || !bObj || branch == nil {
			return fmt.Errorf("%s: no case", path)
		}
		return r.record(branch, am, bm, path)
	}
	if cases := s.Keyed(); cases != nil {
		if !aObj {
			return fmt.Errorf("%s: not an object", path)
		}
		c, ok := jsontypes.CaseOf(cases, func(k string) bool { _, ok := am[k]; return ok })
		if !ok {
			return fmt.Errorf("%s: not one case's keys", path)
		}
		return r.same(c.Payload, a, b, path)
	}
	switch t {
	case "string":
		as, _ := a.(string)
		bs, _ := b.(string)
		if f, _ := s.Str("format"); f == "date-time" && as != bs {
			ta, errA := time.Parse(time.RFC3339Nano, as)
			tb, errB := time.Parse(time.RFC3339Nano, bs)
			if errA == nil && errB == nil && ta.Equal(tb) {
				r.respelled = true
				return nil
			}
		}
		return r.both(as == bs, path)
	case "integer":
		return r.both(sameNumber(a, b), path)
	case "number":
		return r.number(a, b, path)
	case "boolean":
		return r.both(a == b, path)
	case "array":
		as, aOK := a.([]any)
		bs, bOK := b.([]any)
		if !aOK || !bOK || len(as) != len(bs) {
			return fmt.Errorf("%s: another array", path)
		}
		for i := range as {
			if err := r.same(s.Get("items"), as[i], bs[i], fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		return nil
	case "object":
		if !aObj || !bObj {
			return fmt.Errorf("%s: not an object", path)
		}
		if ap := s.Get("additionalProperties"); ap != nil {
			if len(am) != len(bm) {
				return fmt.Errorf("%s: other members", path)
			}
			for k, x := range am {
				y, ok := bm[k]
				if !ok {
					return fmt.Errorf("%s: %s left out", path, k)
				}
				if err := r.same(ap, x, y, path+"."+k); err != nil {
					return err
				}
			}
			return nil
		}
		return r.record(s, am, bm, path)
	}
	return fmt.Errorf("%s: a schema the check doesn't read", path)
}

// record compares the members a record lists (the others are dropped: the
// types ignore them, as haus's decoder does).
func (r *roundTrip) record(s *jsontypes.Node, a, b map[string]any, path string) error {
	props := s.Get("properties")
	if props == nil {
		props = &jsontypes.Node{IsObject: true}
	}
	required := s.Strings("required")
	listed := 0
	for _, k := range props.Keys {
		x, inA := a[k]
		y, inB := b[k]
		switch {
		case inA && inB:
			listed++
			if err := r.same(props.Members[k], x, y, path+"."+k); err != nil {
				return err
			}
		case inA && x == nil && !slices.Contains(required, k):
			r.null = true
		case inA || inB:
			return fmt.Errorf("%s.%s: there on one side only", path, k)
		}
	}
	if listed != len(b) {
		return fmt.Errorf("%s: members written that the schema doesn't list", path)
	}
	return nil
}

func (r *roundTrip) both(ok bool, path string) error {
	if !ok {
		return fmt.Errorf("%s: another value", path)
	}
	return nil
}

func (r *roundTrip) number(a, b any, path string) error {
	if sameNumber(a, b) {
		return nil
	}
	an, aOK := a.(json.Number)
	bn, bOK := b.(json.Number)
	if aOK && bOK {
		x, errX := strconv.ParseFloat(string(an), 64)
		y, errY := strconv.ParseFloat(string(bn), 64)
		if errX == nil && errY == nil && x == y {
			r.rounded = true
			return nil
		}
	}
	return fmt.Errorf("%s: another number (%v, %v)", path, a, b)
}

// sameNumber: the same number, however spelled (1.0 and 1, 1e-09 and 1e-9).
func sameNumber(a, b any) bool {
	an, aOK := a.(json.Number)
	bn, bOK := b.(json.Number)
	if !aOK || !bOK {
		return false
	}
	if an == bn {
		return true
	}
	x, okX := new(big.Rat).SetString(string(an))
	y, okY := new(big.Rat).SetString(string(bn))
	return okX && okY && x.Cmp(y) == 0
}

// sameAny compares an Any: every member, numbers as float64 can hold them.
func (r *roundTrip) sameAny(a, b any, path string) error {
	switch x := a.(type) {
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return fmt.Errorf("%s: another object", path)
		}
		for k, v := range x {
			w, ok := y[k]
			if !ok {
				return fmt.Errorf("%s: %s left out", path, k)
			}
			if err := r.sameAny(v, w, path+"."+k); err != nil {
				return err
			}
		}
		return nil
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return fmt.Errorf("%s: another array", path)
		}
		for i := range x {
			if err := r.sameAny(x[i], y[i], fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
		return nil
	case json.Number:
		return r.number(a, b, path)
	default:
		return r.both(a == b, path)
	}
}
