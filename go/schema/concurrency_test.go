package schema_test

import (
	"bytes"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// One schema, its types and codecs, and the inputs are shared by many
// goroutines doing everything at once; each must get what one goroutine
// alone gets. Run with -race, this also checks that the pools of parsers,
// walkers and buffers hand out nothing two calls share.

const concurrentSchema = `
import std/time (Instant, Date)
type Order = { id: Int, total: Decimal, placed: Instant, due?: Date, items: Array Item, status: Status, note: Maybe String, tags: Map Int, key: Secret String }
type Item = { sku: String, price: Float64, qty: Int }
type Status = < Open | Shipped Date | Cancelled { reason: String } >
type Orders = Stream Order
`

const concurrentText = `// two orders
{ id: 0x10, total: 19.90, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: 0.10, qty: 2 }], status: Shipped(Date("2026-01-03")), note: Some("leave at door"), tags: { a: 1, b: 2 }, key: "k1", extra: "ignored" },
{ id: 17, total: 1, placed: Instant("2026-01-02T03:04:05+01:00"), due: Date("2026-02-01"), items: [], status: Cancelled { reason: "late" }, note: None, tags: {}, key: "k2" },
`

// concurrentBad are texts and values every path fails on, so that the
// errors, and the pooled state an error leaves behind, are compared too.
var concurrentBad = []string{
	`{ id: 1, total: 1, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: "0.10", qty: 1 }], status: Open, note: None, tags: {}, key: "k" }`,
	`{ id: 1, total: 1, placed: Instant("2026-02-30T00:00:00Z"), items: [], status: Open, note: None, tags: {}, key: "k" }`,
	`[1, 2, { a: }]`,
	`{ a: 1, a: 2 }`,
	"\"\u202e\"",
}

var concurrentLayouts = []haus.Layout{haus.Pretty, haus.Compact, haus.Minimised}

// concurrentRun does every operation once with the shared schema s,
// codecs and inputs, and returns what each gave, in order.
func concurrentRun(s *schema.Schema, codecs *schema.Codecs) []string {
	var out []string
	add := func(label string, b any, err error) {
		out = append(out, fmt.Sprintf("%s: %v | %v", label, b, err))
	}
	addText := func(label string) func([]byte, error) {
		return func(b []byte, err error) { add(label, string(b), err) }
	}

	order, err := s.Type("Order")
	add("type", order.Name(), err)
	orders, err := s.Type("Orders")
	add("stream type", orders.IsStream(), err)
	add("type id", order.ID(), nil)

	src := []byte(concurrentText)
	vs, err := haus.ParseAll(src)
	add("parse", len(vs), err)
	for _, layout := range concurrentLayouts {
		opts := haus.FormatOptions{Layout: layout, Width: 40}
		addText(fmt.Sprintf("format %d", layout))(haus.Format(src, opts))
		addText(fmt.Sprintf("format values %d", layout))(haus.FormatValues(vs, opts))
	}
	hasComments, err := haus.HasComments(src)
	add("has comments", hasComments, err)

	// The stream reader, over a reader of its own and the shared bytes.
	reader := haus.NewStreamReader(bytes.NewReader(src), haus.StreamOptions{})
	for v, err := range reader.All() {
		c, cerr := haus.Canonical(v)
		add("stream", c, err)
		add("stream canonical", c, cerr)
	}

	for i, v := range vs {
		c, err := haus.Canonical(v)
		add("canonical", c, err)
		h, err := haus.Hash(v)
		add("hash", h, err)
		add("equals", haus.Equals(v, vs[0]), nil)
		add("compare", haus.Compare(v, vs[len(vs)-1-i]), nil)
		add("check", nil, haus.CheckValue(v, haus.Limits{MaxDepth: 3}))
		j, err := haus.ToHausJSON(v)
		addText("to haus json")(j, err)
		back, err := haus.FromHausJSON(j)
		add("from haus json", haus.Equals(back, v), err)

		decoded, err := order.Decode(v)
		add("decode", canonicalOf(decoded), err)
		encoded, err := order.Encode(decoded)
		add("encode", canonicalOf(encoded), err)
		withCodecs, err := order.DecodeWith(v, schema.DecodeOptions{Codecs: codecs})
		add("decode with codecs", canonicalOf(withCodecs), err)
		placed, _ := v.(haus.Record).Get("placed")
		at, err := schema.DecodeAs[time.Time](instantType, placed, schema.InstantTime)
		add("decode as", at.UTC().Format(time.RFC3339), err)
		back2, err := schema.EncodeFrom(instantType, at, schema.InstantTime)
		add("encode from", canonicalOf(back2), err)
		for _, layout := range concurrentLayouts {
			addText(fmt.Sprintf("type format %d", layout))(order.Format(decoded, haus.FormatOptions{Layout: layout}))
		}
		tj, err := order.ToJSON(decoded)
		addText("to json")(tj, err)
		fj, err := order.FromJSON(tj)
		add("from json", canonicalOf(fj), err)
	}
	all, err := orders.DecodeAll(vs)
	add("decode all", len(all), err)
	for v, err := range orders.DecodeStream(bytes.NewReader(src), haus.StreamOptions{}) {
		add("decode stream", canonicalOf(v), err)
	}
	lines, err := orders.ToJSONLines(all)
	addText("to json lines")(lines, err)
	fromLines, err := orders.FromJSONLines(lines)
	add("from json lines", len(fromLines), err)
	add("check text", s.CheckText("Orders", src), nil)

	for _, bad := range concurrentBad {
		text := []byte(bad)
		v, err := order.Parse(text)
		add("type parse bad", canonicalOf(v), err)
		_, err = haus.Parse(text)
		add("parse bad", nil, err)
		_, err = haus.Format(text, haus.FormatOptions{})
		add("format bad", nil, err)
		add("check bad", s.CheckText("Order", text), nil)
		if raw, err := haus.Parse(text); err == nil {
			for _, layout := range concurrentLayouts {
				addText(fmt.Sprintf("type format bad %d", layout))(order.Format(raw, haus.FormatOptions{Layout: layout}))
			}
			_, err = order.ToJSON(raw)
			add("to json bad", nil, err)
		}
	}
	// A typed parse, and one of a value deeper than a small limit allows.
	first, _, _ := strings.Cut(strings.TrimPrefix(concurrentText, "// two orders\n"), "\n")
	v, err := order.Parse([]byte(strings.TrimSuffix(first, ",")))
	add("type parse", canonicalOf(v), err)
	_, err = order.ParseWith([]byte(concurrentBad[0]), schema.DecodeOptions{Limits: haus.Limits{MaxDepth: 2}})
	add("type parse deep", nil, err)
	return out
}

// instantType is std/time's Instant, the type of an order's placed field,
// from a schema of its own.
var instantType = func() schema.Type {
	s, err := schema.Parse([]byte("import std/time (Instant)\ntype At = Instant"), schema.Options{})
	if err != nil {
		panic(err)
	}
	t, err := s.Type("At")
	if err != nil {
		panic(err)
	}
	return t
}()

func canonicalOf(v haus.Value) string {
	if v == nil {
		return "<nil>"
	}
	c, err := haus.Canonical(v)
	if err != nil {
		return err.Error()
	}
	return c
}

func TestConcurrentUse(t *testing.T) {
	s, err := schema.Parse([]byte(concurrentSchema), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	codecs, err := schema.NewCodecs(schema.InstantTime)
	if err != nil {
		t.Fatal(err)
	}
	want := concurrentRun(s, codecs)
	const goroutines, rounds = 16, 8
	var wg sync.WaitGroup
	got := make([][]string, goroutines)
	for g := range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range rounds {
				got[g] = concurrentRun(s, codecs)
				if !slices.Equal(got[g], want) {
					return
				}
			}
		}()
	}
	wg.Wait()
	for g, results := range got {
		if !slices.Equal(results, want) {
			for i := range min(len(results), len(want)) {
				if results[i] != want[i] {
					t.Fatalf("goroutine %d, result %d:\n got %s\nwant %s", g, i, results[i], want[i])
				}
			}
			t.Fatalf("goroutine %d: %d results, want %d", g, len(results), len(want))
		}
	}
}
