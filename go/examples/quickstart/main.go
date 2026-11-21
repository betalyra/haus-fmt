// The quickstart: data checked by its schema, decoding, encoding and
// errors. The same steps as rust/examples/quickstart, on the same files.
// Run: go run ./examples/quickstart (from go/).
package main

import (
	"fmt"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

const reply = `Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }`

// examples is the folder of the shared example files.
func examples() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "examples")
}

// comment is the record of a Comment { … }, which the schema checked.
func comment(v haus.Value) haus.Record {
	return v.(haus.Variant).Args[0].(haus.Record)
}

func field(v haus.Value, key string) haus.Value {
	x, _ := comment(v).Get(key)
	return x
}

func likes(v haus.Value) *big.Int {
	n, _ := field(v, "likes").(haus.Number).BigInt()
	for _, r := range field(v, "replies").(haus.Array) {
		n.Add(n, likes(r))
	}
	return n
}

func depth(v haus.Value) int {
	deepest := 0
	for _, r := range field(v, "replies").(haus.Array) {
		deepest = max(deepest, depth(r))
	}
	return 1 + deepest
}

// oneLine writes a value on one line, in the compact layout.
func oneLine(v haus.Value) string {
	out, err := haus.FormatValue(v, haus.FormatOptions{Layout: haus.Compact})
	if err != nil {
		log.Fatal(err)
	}
	return strings.TrimSuffix(string(out), "\n")
}

func main() {
	s, err := schema.Load(filepath.Join(examples(), "thread.schema.haus"), schema.Options{})
	if err != nil {
		log.Fatal(err)
	}
	root, _ := s.Type("Root")
	commentType, _ := s.Type("Comment")

	// 1. The thread, checked with its schema: Root is a Comment, whose replies are Comments.
	text, err := os.ReadFile(filepath.Join(examples(), "thread.haus"))
	if err != nil {
		log.Fatal(err)
	}
	v, err := haus.Parse(text)
	if err != nil {
		log.Fatal(err)
	}
	thread, err := root.Decode(v)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("thread by %s: %d levels, %s likes\n", field(thread, "author"), depth(thread), likes(thread))

	// 2. Decode haus text with the schema, change it, encode it back.
	v, _ = haus.Parse([]byte(reply))
	decoded, err := commentType.Decode(v)
	if err != nil {
		log.Fatal(err)
	}
	fields := comment(decoded).Fields()
	for i, f := range fields {
		if f.Key == "likes" {
			n, _ := f.Value.(haus.Number).BigInt()
			fields[i].Value = haus.NumberFromBigInt(n.Add(n, big.NewInt(1)))
		}
	}
	liked, _ := haus.NewRecord(fields...)
	encoded, err := commentType.Encode(haus.Variant{Tag: haus.MustTag("Comment"), Args: []haus.Value{liked}})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(oneLine(encoded))

	// 3. A value that doesn't match the schema is an error that says where.
	v, _ = haus.Parse([]byte(strings.Replace(reply, "likes: 0", `likes: "lots"`, 1)))
	if _, err := commentType.Decode(v); err != nil {
		fmt.Printf("error: %v\n", err)
	}
}
