package schema_test

import (
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"testing/fstest"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// Import resolution beyond the package suite (spec §13.3): directories
// that can't be listed, file ids, and packages given as file trees.

// wantCode fails unless err has the code want.
func wantCode(t *testing.T, err error, want haus.ErrorCode) {
	t.Helper()
	if code, _ := codeAndPath(err); code != want {
		t.Fatalf("got %v, want %s", err, want)
	}
}

// TestUnlistableDirectory: a directory that can't be listed can't show how
// a name is spelled, so the name is not found there, although the file
// could be opened (spec §13.3, "Spelling").
func TestUnlistableDirectory(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("permissions: Unix, not as root")
	}
	root := t.TempDir()
	write(t, filepath.Join(root, "app", "a.schema.haus"), "import ./sub/x (X)\ntype Root = { x: X }")
	write(t, filepath.Join(root, "app", "sub", "x.schema.haus"), "type X = Int")
	sub := filepath.Join(root, "app", "sub")
	if err := os.Chmod(sub, 0o311); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
	_, err := schema.Load(filepath.Join(root, "app", "a.schema.haus"), schema.Options{})
	wantCode(t, err, haus.CodeImportNotFound)
}

// TestFileIDsAreNotPackageIDs: a file's id never has the form of a
// package's, @org/name@N, whatever its project and name (spec §13.3,
// "Identity").
func TestFileIDsAreNotPackageIDs(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "x@1.schema.haus"), "type T = Int")
	s, err := schema.Load(filepath.Join(root, "x@1.schema.haus"), schema.Options{Project: "@acme", ProjectDir: root})
	if err != nil {
		t.Fatal(err)
	}
	if id := s.Definitions()[0].ID; id != "./@acme/x@1#T" {
		t.Errorf("id %s", id)
	}
}

// TestRootOption: the root option widens the root; one that doesn't
// contain the entry file is import-outside-root, without a path.
func TestRootOption(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "proj", "app", "a.schema.haus"), "import ../shared/s (S)\ntype Root = { s: S }")
	write(t, filepath.Join(root, "proj", "shared", "s.schema.haus"), "type S = Int")
	entry := filepath.Join(root, "proj", "app", "a.schema.haus")
	_, err := schema.Load(entry, schema.Options{})
	wantCode(t, err, haus.CodeImportOutsideRoot)
	if strings.Contains(err.Error(), root) {
		t.Errorf("the message shows an absolute path: %v", err)
	}
	if _, err := schema.Load(entry, schema.Options{Root: filepath.Join(root, "proj")}); err != nil {
		t.Fatal(err)
	}
	_, err = schema.Load(entry, schema.Options{Root: filepath.Join(root, "proj", "shared")})
	wantCode(t, err, haus.CodeImportOutsideRoot)
	// A relative root is relative to the entry file's real directory, not
	// the working directory.
	if _, err := schema.Load(entry, schema.Options{Root: ".."}); err != nil {
		t.Fatal(err)
	}
}

// TestEntryBelowAPackageDirectory: only a file read as a package's schema
// imports no files; a target's package directory is looked for up to the
// root only (spec §13.3, packages.imports.into-package-checked), not above
// it. An entry file below a package's directory, with a wider root, imports
// a file next to it.
func TestEntryBelowAPackageDirectory(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, "package.haus"), `{ name: "@acme/evil", version: "1.2.0" }`)
	write(t, filepath.Join(root, "schema.haus"), "type Money = Decimal")
	write(t, filepath.Join(root, "app", "main", "common.schema.haus"), "type Money = Decimal")
	write(t, filepath.Join(root, "app", "main", "main.schema.haus"), "import ./common (Money)\ntype Root = Money")
	s, err := schema.Load(filepath.Join(root, "app", "main", "main.schema.haus"), schema.Options{Root: ".."})
	if err != nil {
		t.Fatal(err)
	}
	if id := s.Imported()[0].ID; id != "common#Money" {
		t.Errorf("id %s", id)
	}
	// The package's own schema, read as the entry file, still imports no files.
	write(t, filepath.Join(root, "schema.haus"), "import ./app/main/common (Money)\ntype Root = Money")
	_, err = schema.Load(filepath.Join(root, "schema.haus"), schema.Options{})
	wantCode(t, err, haus.CodePackagePath)
	if !strings.Contains(err.Error(), "can't import files") {
		t.Errorf("message: %v", err)
	}
}

// moneyTree is a schema package in a tree given in code, as a Go module
// embeds one.
func moneyTree() fstest.MapFS {
	return fstest.MapFS{
		"money/package.haus": {Data: []byte(`{ name: "@acme/money", version: "1.2.0" }`)},
		"money/schema.haus":  {Data: []byte("type Money = { amount: Decimal, currency: String }")},
	}
}

func loadWith(t *testing.T, packages schema.Locator) (*schema.Schema, error) {
	t.Helper()
	root := t.TempDir()
	write(t, filepath.Join(root, "a.schema.haus"), "import @acme/money@1 (Money)\ntype Root = { total: Money }")
	return schema.Load(filepath.Join(root, "a.schema.haus"), schema.Options{Packages: packages})
}

// TestPackageFS: a package given as a file tree is read under the rules of
// a directory (spec §13.3, packages.explicit.file-tree).
func TestPackageFS(t *testing.T) {
	e, err := schema.NewExplicit().PackageFS(moneyTree(), "money")
	if err != nil {
		t.Fatal(err)
	}
	s, err := loadWith(t, e)
	if err != nil {
		t.Fatal(err)
	}
	if p := s.Packages(); len(p) != 1 || p[0].Name != "@acme/money" || p[0].Version != "1.2.0" {
		t.Errorf("packages %v", p)
	}
	if id := s.Imported()[0].ID; id != "@acme/money@1#Money" {
		t.Errorf("id %s", id)
	}

	t.Run("folder", func(t *testing.T) {
		e, err := schema.NewExplicit().FolderFS(moneyTree(), ".")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := loadWith(t, e); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("link", func(t *testing.T) {
		tree := moneyTree()
		tree["elsewhere.haus"] = &fstest.MapFile{Data: tree["money/schema.haus"].Data}
		tree["money/schema.haus"] = &fstest.MapFile{Data: []byte("../elsewhere.haus"), Mode: fs.ModeSymlink}
		e, err := schema.NewExplicit().PackageFS(tree, "money")
		if err != nil {
			t.Fatal(err)
		}
		_, err = loadWith(t, e)
		wantCode(t, err, haus.CodePackagePath)
	})
	t.Run("fifo", func(t *testing.T) {
		tree := moneyTree()
		tree["money/schema.haus"] = &fstest.MapFile{Mode: fs.ModeNamedPipe}
		e, err := schema.NewExplicit().PackageFS(tree, "money")
		if err != nil {
			t.Fatal(err)
		}
		_, err = loadWith(t, e)
		wantCode(t, err, haus.CodePackagePath)
	})
	t.Run("wrong-case", func(t *testing.T) {
		tree := moneyTree()
		tree["money/Schema.haus"] = tree["money/schema.haus"]
		delete(tree, "money/schema.haus")
		e, err := schema.NewExplicit().PackageFS(tree, "money")
		if err != nil {
			t.Fatal(err)
		}
		_, err = loadWith(t, e)
		wantCode(t, err, haus.CodeImportNotFound)
	})
	t.Run("version", func(t *testing.T) {
		tree := moneyTree()
		tree["money/package.json"] = &fstest.MapFile{Data: []byte(`{ "version": "1.3.0" }`)}
		e, err := schema.NewExplicit().PackageFS(tree, "money")
		if err != nil {
			t.Fatal(err)
		}
		_, err = loadWith(t, e)
		wantCode(t, err, haus.CodePackageVersion)
	})
	t.Run("imports-a-file", func(t *testing.T) {
		tree := moneyTree()
		tree["money/schema.haus"] = &fstest.MapFile{Data: []byte("import ./x (X)\ntype Money = X")}
		tree["money/x.schema.haus"] = &fstest.MapFile{Data: []byte("type X = Int")}
		e, err := schema.NewExplicit().PackageFS(tree, "money")
		if err != nil {
			t.Fatal(err)
		}
		_, err = loadWith(t, e)
		wantCode(t, err, haus.CodePackagePath)
	})
	t.Run("copy-on-disk", func(t *testing.T) {
		// A tree and a directory with the same files are one package.
		dir := t.TempDir()
		for name, f := range moneyTree() {
			write(t, filepath.Join(dir, filepath.FromSlash(name)), string(f.Data))
		}
		e, err := schema.NewExplicit().PackageFS(moneyTree(), "money")
		if err != nil {
			t.Fatal(err)
		}
		if e, err = e.Package(filepath.Join(dir, "money")); err != nil {
			t.Fatal(err)
		}
		if _, err := loadWith(t, e); err != nil {
			t.Fatal(err)
		}
	})
}
