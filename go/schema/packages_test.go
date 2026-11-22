package schema_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// The package suite (test-suite/packages, spec §13.3): each case is a file
// tree, written into a temporary directory, a schema file loaded from it
// with packages found in node_modules (Npm) or given explicitly (Explicit),
// and the result. See test-suite/README.md, "Package suite".

func strs(v haus.Value) []string {
	a, _ := v.(haus.Array)
	out := make([]string, len(a))
	for i, x := range a {
		out[i] = str(x)
	}
	return out
}

// create writes one entry of a case's files under root.
func create(t *testing.T, root string, entry haus.Variant) {
	t.Helper()
	at := func(i int) string { return str(entry.Args[i]) }
	switch entry.Tag.String() {
	case "File":
		write(t, filepath.Join(root, at(0)), at(1))
	case "Package":
		dir := filepath.Join(root, at(0))
		name, _ := json.Marshal(at(1))
		version, _ := json.Marshal(at(2))
		write(t, filepath.Join(dir, "package.haus"), fmt.Sprintf("{ name: %s, version: %s }", name, version))
		write(t, filepath.Join(dir, "schema.haus"), at(3))
	case "Npm":
		fields := entry.Args[1].(haus.Record)
		doc := map[string]any{}
		for _, key := range []string{"name", "version"} {
			if v, ok := fields.Get(key); ok {
				doc[key] = str(v)
			}
		}
		for _, key := range []string{"dependencies", "peerDependencies", "devDependencies", "optionalDependencies"} {
			if v, ok := fields.Get(key); ok {
				deps := map[string]string{}
				for _, n := range strs(v) {
					deps[n] = "*"
				}
				doc[key] = deps
			}
		}
		b, _ := json.Marshal(doc)
		write(t, filepath.Join(root, at(0), "package.json"), string(b))
	case "Link":
		// On Windows, making links needs Developer Mode or an administrator
		// (as on CI); os.Symlink writes the target with \ and makes a link to
		// a directory as one if the directory exists: links are made last.
		path := filepath.Join(root, at(0))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(at(1), path); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("unknown file entry %s", entry.Tag.String())
	}
}

// given returns the packages a case gives explicitly ({ packages?, folders? }).
func given(root string, args []haus.Value) (*schema.Explicit, error) {
	e := schema.NewExplicit()
	if len(args) == 0 {
		return e, nil
	}
	r := args[0].(haus.Record)
	var err error
	for _, dir := range strs(get(r, "packages")) {
		if e, err = e.Package(filepath.Join(root, dir)); err != nil {
			return nil, err
		}
	}
	for _, dir := range strs(get(r, "folders")) {
		if e, err = e.Folder(filepath.Join(root, dir)); err != nil {
			return nil, err
		}
	}
	return e, nil
}

// load loads the case's root in its mode: the packages reached, or the error.
func load(root string, c haus.Record) ([]string, error) {
	mode := get(c, "mode").(haus.Variant)
	explicit, err := given(root, mode.Args)
	if err != nil {
		return nil, err
	}
	var packages schema.Locator = explicit
	switch mode.Tag.String() {
	case "Npm":
		packages = schema.Or{First: explicit, Second: schema.NodeModules{}}
	case "Explicit":
	default:
		return nil, fmt.Errorf("unknown mode %s", mode.Tag.String())
	}
	s, err := schema.Load(filepath.Join(root, str(get(c, "root"))), schema.Options{Packages: packages})
	if err != nil {
		return nil, err
	}
	var reached []string
	for _, p := range s.Packages() {
		reached = append(reached, p.Name+"@"+p.Version)
	}
	slices.Sort(reached)
	return reached, nil
}

// writeTree writes a case's files under root: links last, once their
// targets exist.
func writeTree(t *testing.T, root string, c haus.Record) {
	files := get(c, "files").(haus.Array)
	for _, links := range []bool{false, true} {
		for _, f := range files {
			entry := f.(haus.Variant)
			if (entry.Tag.String() == "Link") == links {
				create(t, root, entry)
			}
		}
	}
}

// failure runs a case: "" if it passes, what went wrong otherwise.
func failure(t *testing.T, c haus.Record) string {
	root := t.TempDir()
	writeTree(t, root, c)
	reached, err := load(root, c)
	expect := get(c, "expect").(haus.Variant)
	want := expect.Args[0].(haus.Record)
	switch {
	case expect.Tag.String() == "Ok" && err != nil:
		return fmt.Sprintf("failed: %v", err)
	case expect.Tag.String() == "Ok":
		if w := strs(get(want, "packages")); !slices.Equal(reached, w) && (len(reached) != 0 || len(w) != 0) {
			return fmt.Sprintf("reached %v, expected %v", reached, w)
		}
		return ""
	case err == nil:
		return fmt.Sprintf("loaded (reaching %v), expected %s", reached, str(get(want, "code")))
	}
	code, _ := codeAndPath(err)
	message := err.Error()
	t.Log(message)
	if string(code) != str(get(want, "code")) {
		return fmt.Sprintf("failed with %s, expected %s: %s", code, str(get(want, "code")), message)
	}
	for _, m := range strs(get(want, "mentions")) {
		if !strings.Contains(strings.ReplaceAll(message, `\`, "/"), m) {
			return fmt.Sprintf("the message doesn't mention %q: %s", m, message)
		}
	}
	for _, h := range strs(get(want, "hides")) {
		if strings.Contains(message, h) {
			return fmt.Sprintf("the message shows %q: %s", h, message)
		}
	}
	return ""
}

func packageCases(t *testing.T) []haus.Record {
	src, err := os.ReadFile("../../test-suite/packages/cases.haus")
	if err != nil {
		t.Fatal(err)
	}
	values, err := haus.ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	cases := make([]haus.Record, len(values))
	for i, v := range values {
		x, ok := v.(haus.Variant)
		if !ok || x.Tag.String() != "Case" {
			t.Fatalf("every entry is Case { … }: %v", v)
		}
		cases[i] = x.Args[0].(haus.Record)
	}
	return cases
}

// TestPackageSuite runs every case: this binding reads node_modules, takes
// packages explicitly and makes the SHOULD version check (should: True).
func TestPackageSuite(t *testing.T) {
	cases := packageCases(t)
	should := 0
	for _, c := range cases {
		if s, ok := get(c, "should").(haus.Variant); ok && s.Tag.String() == "True" {
			should++
		}
		name := str(get(c, "name"))
		t.Run(name, func(t *testing.T) {
			if why := failure(t, c); why != "" {
				t.Error(why)
			}
		})
	}
	if len(cases) != 99 {
		t.Errorf("%d cases, expected 99", len(cases))
	}
	t.Logf("package suite: %d cases run (%d of them the SHOULD version check), 0 skipped", len(cases), should)
}

// TestCopiesInEitherOrder: copies are one package only if their imports
// reach the same packages, whichever copy is loaded first (spec §13.3).
func TestCopiesInEitherOrder(t *testing.T) {
	var c haus.Record
	for _, x := range packageCases(t) {
		if str(get(x, "name")) == "identical-copies-different-dependencies" {
			c = x
		}
	}
	for _, text := range []string{
		"import @acme/orders@1 (Order)\nimport @acme/billing@1 (Bill)\ntype Root = { order: Order, bill: Bill }",
		"import @acme/billing@1 (Bill)\nimport @acme/orders@1 (Order)\ntype Root = { order: Order, bill: Bill }",
	} {
		root := t.TempDir()
		writeTree(t, root, c)
		write(t, filepath.Join(root, "app", "app.schema.haus"), text)
		_, err := load(root, c)
		code, _ := codeAndPath(err)
		if code != haus.CodeDuplicatePackage || !strings.Contains(err.Error(), "1.2.0") || !strings.Contains(err.Error(), "1.4.0") {
			t.Errorf("%q: %v", text, err)
		}
	}
}
