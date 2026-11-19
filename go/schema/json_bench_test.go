package schema_test

import (
	"strconv"
	"strings"
	"testing"

	"github.com/betalyra/haus-fmt/go/schema"
)

func BenchmarkSchemaJSON(b *testing.B) {
	s, err := schema.Parse([]byte(`type Item = { id: Int32, name: String, price: Float64, tags: Array String, active: Bool, note: Maybe String }
type Items = Array Item`), schema.Options{})
	if err != nil {
		b.Fatal(err)
	}
	items, _ := s.Type("Items")
	var sb strings.Builder
	sb.WriteString("[")
	for i := range 10000 {
		if i > 0 {
			sb.WriteString(",\n")
		}
		sb.WriteString(`{"id": ` + strconv.Itoa(i) + `, "name": "item number ` + strconv.Itoa(i) +
			`", "price": 19.9, "tags": ["a", "bé"], "active": true, "note": null}`)
	}
	sb.WriteString("]")
	data := []byte(sb.String())
	v, err := items.FromJSON(data)
	if err != nil {
		b.Fatal(err)
	}
	b.Run("read", func(b *testing.B) {
		b.SetBytes(int64(len(data)))
		for b.Loop() {
			if _, err := items.FromJSON(data); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("write", func(b *testing.B) {
		b.SetBytes(int64(len(data)))
		for b.Loop() {
			if _, err := items.ToJSON(v); err != nil {
				b.Fatal(err)
			}
		}
	})
}
