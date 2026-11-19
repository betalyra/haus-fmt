// The website's Go sample (codeGo in website/src/content/samples.ts): the
// comment thread of examples/, checked by its schema. Keep the two in step.
// It reads the files from the working directory: run it in the examples
// folder, as main_test.go does.
package main

import (
	"fmt"
	"log"
	"os"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

func main() {
	s, _ := schema.Load("thread.schema.haus", schema.Options{})
	root, _ := s.Type("Root")
	text, _ := os.ReadFile("thread.haus")
	v, _ := haus.Parse(text)

	thread, err := root.Decode(v) // checked against its schema
	if err != nil {
		log.Fatal(err) // $.replies[0].likes: expected Int, found the string "lots" [type-mismatch]
	}

	c := thread.(haus.Variant).Args[0].(haus.Record)
	author, _ := c.Get("author")   // String        → haus.String
	likes, _ := c.Get("likes")     // Int           → haus.Number, exact
	replies, _ := c.Get("replies") // Array Comment → haus.Array

	fmt.Println(author, likes, len(replies.(haus.Array))) // ada 0 1
}
