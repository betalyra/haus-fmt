package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

// TestOutput runs the example and compares its output with the lines of
// rust/examples/quickstart. Messages of errors are each binding's own (spec §17
// fixes codes, not messages): those lines are compared as Go writes them.
func TestOutput(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	main()
	os.Stdout = stdout
	_ = w.Close()
	out, _ := io.ReadAll(r)
	if got := string(out); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

var want = strings.Join([]string{
	"thread by ada: 15 levels, 30 likes",
	`Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 1, replies: [] }`,
	// rust: error: (Comment).likes: expected a number (Int), found a string
	`error: $.likes: expected Int, found the string "lots" [type-mismatch]`,
	"",
}, "\n")
