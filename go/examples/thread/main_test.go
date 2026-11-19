package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestOutput runs the website's sample in the examples folder, where its files are.
func TestOutput(t *testing.T) {
	t.Chdir(filepath.Join("..", "..", "..", "examples"))
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
	if got, want := string(out), "ada 0 1\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// TestWebsiteSample checks that the website shows this program: codeGo in
// website/src/content/samples.ts, after its imports, is main's body.
func TestWebsiteSample(t *testing.T) {
	samples, err := os.ReadFile(filepath.Join("..", "..", "..", "website", "src", "content", "samples.ts"))
	if err != nil {
		t.Fatal(err)
	}
	_, sample, _ := strings.Cut(string(samples), "export const codeGo = `")
	sample, _, _ = strings.Cut(sample, "`;")
	_, sample, _ = strings.Cut(sample, "\n)\n")
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	_, body, _ := strings.Cut(string(source), "func main() {\n")
	body, _, _ = strings.Cut(body, "\n}\n")
	lines := strings.Split(body, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimPrefix(l, "\t")
	}
	if got, want := strings.TrimSpace(sample), strings.TrimSpace(strings.Join(lines, "\n")); got != want {
		t.Errorf("the website's sample isn't main's body:\n%s\n\nmain:\n%s", got, want)
	}
}
