package schema_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// The package suite (test-suite/packages, spec §13.3): each case is a file
// tree, written into a temporary directory, a schema file loaded from it
// with packages given explicitly, and the result. See test-suite/README.md,
// "Package suite". This binding implements the core rules: it runs the
// cases of the ecosystem "core" and skips the npm ones, as it doesn't look
// in node_modules.

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
	case "Large":
		size, _ := entry.Args[1].(haus.Number)
		n, err := strconv.Atoi(size.String())
		if err != nil {
			t.Fatal(err)
		}
		write(t, filepath.Join(root, at(0)), strings.Repeat(" ", n))
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
	case "Fifo":
		fifo := filepath.Join(root, at(0))
		if err := os.MkdirAll(filepath.Dir(fifo), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := mkfifo(fifo); err != nil {
			t.Fatal(err)
		}
	case "Link":
		// On Windows, making links needs Developer Mode or an administrator
		// (as on CI); os.Symlink writes the target with \ and makes a link to
		// a directory as one if the directory exists: links are made last.
		link := filepath.Join(root, at(0))
		if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(at(1), link); err != nil {
			t.Fatal(err)
		}
	case "Mode":
		// Set after the whole tree is written (writeTree).
	default:
		t.Fatalf("unknown file entry %s", entry.Tag.String())
	}
}

// how says where a case's packages come from: from disk, or from file trees
// over the same directories (os.DirFS), given in code.
type how int

const (
	fromDisk how = iota
	fromTree
)

// given returns the packages a case gives explicitly ({ packages?, folders? }).
func given(root string, args []haus.Value, h how) (*schema.Explicit, error) {
	e := schema.NewExplicit()
	if len(args) == 0 {
		return e, nil
	}
	r := args[0].(haus.Record)
	fsys := os.DirFS(root)
	var err error
	for _, dir := range strs(get(r, "packages")) {
		if h == fromTree {
			e, err = e.PackageFS(fsys, path.Clean(dir))
		} else {
			e, err = e.Package(filepath.Join(root, dir))
		}
		if err != nil {
			return nil, err
		}
	}
	for _, dir := range strs(get(r, "folders")) {
		if h == fromTree {
			e, err = e.FolderFS(fsys, path.Clean(dir))
		} else {
			e, err = e.Folder(filepath.Join(root, dir))
		}
		if err != nil {
			return nil, err
		}
	}
	return e, nil
}

// load loads the case's root: the packages reached, or the error.
func load(root string, c haus.Record, h how) ([]string, error) {
	mode := get(c, "mode").(haus.Variant)
	if mode.Tag.String() != "Explicit" {
		return nil, fmt.Errorf("mode %s: this binding reads no node_modules", mode.Tag.String())
	}
	explicit, err := given(root, mode.Args, h)
	if err != nil {
		return nil, err
	}
	opts := schema.Options{Packages: explicit}
	if dir, ok := get(c, "rootDir").(haus.String); ok {
		opts.Root = filepath.Join(root, string(dir))
	}
	s, err := schema.Load(filepath.Join(root, str(get(c, "root"))), opts)
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

// entries returns the case's file entries tagged tag.
func entries(c haus.Record, tag string) []haus.Variant {
	var out []haus.Variant
	for _, f := range get(c, "files").(haus.Array) {
		if e := f.(haus.Variant); e.Tag.String() == tag {
			out = append(out, e)
		}
	}
	return out
}

// writeTree writes a case's files under root: links last, once their
// targets exist, then the modes. Directories whose mode is set get their
// owner's permissions back before the temporary directory is removed.
func writeTree(t *testing.T, root string, c haus.Record) {
	for _, links := range []bool{false, true} {
		for _, f := range get(c, "files").(haus.Array) {
			entry := f.(haus.Variant)
			if (entry.Tag.String() == "Link") == links {
				create(t, root, entry)
			}
		}
	}
	for _, m := range entries(c, "Mode") {
		dir := filepath.Join(root, str(m.Args[0]))
		mode, err := strconv.ParseUint(str(m.Args[1]), 8, 32)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, os.FileMode(mode)); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	}
}

// caseTimeout bounds a case: a resolver that opens a FIFO blocking would
// hang.
const caseTimeout = 10 * time.Second

// failure runs a case: "" if it passes, what went wrong otherwise.
func failure(t *testing.T, c haus.Record, h how) string {
	root := t.TempDir()
	writeTree(t, root, c)
	type result struct {
		reached []string
		err     error
	}
	done := make(chan result, 1)
	go func() {
		reached, err := load(root, c, h)
		done <- result{reached, err}
	}()
	var r result
	select {
	case r = <-done:
	case <-time.After(caseTimeout):
		return fmt.Sprintf("no result after %v (a blocking open?)", caseTimeout)
	}
	reached, err := r.reached, r.err
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
	// Messages show paths relative to the root, never absolute ones (spec
	// §13.3, "The root").
	resolved, _ := filepath.EvalSymlinks(root)
	for _, abs := range []string{root, resolved} {
		if abs != "" && strings.Contains(message, abs) {
			return fmt.Sprintf("the message shows the absolute path %s: %s", abs, message)
		}
	}
	return ""
}

// skipped says why a case doesn't run here, or "".
func skipped(c haus.Record) string {
	if eco := str(get(c, "ecosystem")); eco != "core" {
		return eco
	}
	if s, ok := get(c, "os").(haus.String); ok && string(s) == "unix" && runtime.GOOS == "windows" {
		return "unix"
	}
	if len(entries(c, "Mode")) > 0 && os.Geteuid() == 0 {
		return "root"
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

// TestPackageSuite runs every case of the ecosystem "core" (spec §13.3):
// this binding takes packages explicitly, reads no node_modules and makes
// the SHOULD version check (should: True).
func TestPackageSuite(t *testing.T) {
	cases := packageCases(t)
	ran, should := 0, 0
	skips := map[string]int{}
	for _, c := range cases {
		name := str(get(c, "name"))
		if why := skipped(c); why != "" {
			skips[why]++
			continue
		}
		ran++
		if s, ok := get(c, "should").(haus.Variant); ok && s.Tag.String() == "True" {
			should++
		}
		t.Run(name, func(t *testing.T) {
			if why := failure(t, c, fromDisk); why != "" {
				t.Error(why)
			}
		})
	}
	if len(cases) != 136 || skips["npm"] != 46 {
		t.Errorf("%d cases, %d npm, expected 136 and 46", len(cases), skips["npm"])
	}
	t.Logf("package suite: %d cases run (%d of them the SHOULD version check), skipped: %v", ran, should, skips)
}

// TestPackageSuiteFromTrees runs the core cases that give packages again,
// with each package and folder given as a file tree over the same directory
// (os.DirFS, spec §13.3 packages.explicit.file-tree): the same results,
// except where a case has links, which a tree follows none of.
func TestPackageSuiteFromTrees(t *testing.T) {
	ran, withLinks := 0, 0
	for _, c := range packageCases(t) {
		mode := get(c, "mode").(haus.Variant)
		name := str(get(c, "name"))
		if skipped(c) != "" || len(mode.Args) == 0 {
			continue
		}
		r := mode.Args[0].(haus.Record)
		if len(strs(get(r, "packages")))+len(strs(get(r, "folders"))) == 0 {
			continue
		}
		if len(entries(c, "Link")) > 0 {
			withLinks++
			continue
		}
		ran++
		t.Run(name, func(t *testing.T) {
			if why := failure(t, c, fromTree); why != "" {
				t.Error(why)
			}
		})
	}
	t.Logf("package suite from file trees: %d cases run, %d with links left out", ran, withLinks)
}
