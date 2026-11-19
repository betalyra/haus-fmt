package haus

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

// benchJSON is a JSON document of n records with a few typical fields.
func benchJSON(n int) []byte {
	var b strings.Builder
	b.WriteString("[")
	for i := range n {
		if i > 0 {
			b.WriteString(",\n")
		}
		b.WriteString(`{"id": ` + strconv.Itoa(i) + `, "name": "item number ` + strconv.Itoa(i) +
			`", "price": 19.90, "tags": ["a", "bé"], "active": true, "note": null}`)
	}
	b.WriteString("]")
	return []byte(b.String())
}

func BenchmarkImportJSON(b *testing.B) {
	data := benchJSON(10000)
	b.SetBytes(int64(len(data)))
	for b.Loop() {
		if _, err := ImportJSON(data); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkEncodingJSON is the standard library's reader into any, for
// comparison.
func BenchmarkEncodingJSON(b *testing.B) {
	data := benchJSON(10000)
	b.SetBytes(int64(len(data)))
	for b.Loop() {
		var x any
		if err := json.Unmarshal(data, &x); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkHausJSON(b *testing.B) {
	v, err := ImportJSON(benchJSON(10000))
	if err != nil {
		b.Fatal(err)
	}
	data, err := ToHausJSON(v)
	if err != nil {
		b.Fatal(err)
	}
	b.Run("write", func(b *testing.B) {
		b.SetBytes(int64(len(data)))
		for b.Loop() {
			if _, err := ToHausJSON(v); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.Run("read", func(b *testing.B) {
		b.SetBytes(int64(len(data)))
		for b.Loop() {
			if _, err := FromHausJSON(data); err != nil {
				b.Fatal(err)
			}
		}
	})
}
