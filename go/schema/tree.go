package schema

import (
	"errors"
	"fmt"
	"io/fs"
	"path"
	"path/filepath"
	"strings"
	"sync/atomic"
)

// Packages given as a read-only tree of files that code provides, an
// [fs.FS] (spec §13.3, packages.explicit.file-tree): a Go module can embed
// a schema package (//go:embed) and give it with [Explicit.PackageFS]. A
// tree is a package under the rules of a directory: its package.haus and
// schema.haus, the version check, the limits, exact names, and no links. A
// tree that can hold links (os.DirFS) follows none: every name on the way
// to a file is listed by its directory with that spelling and is a
// directory, and the file itself is listed as a regular file, then checked
// again on the opened file. An fs.FS opens files without asking whether
// they block, so a file swapped for a FIFO between the listing and the open
// of an os.DirFS can block the build; an embed.FS has no such files.

// place is a directory a package's files are read in: on disk (dir, a real
// path), or in a file tree (tree, at inner; dir is then its key).
type place struct {
	dir   string
	tree  *tree
	inner string
}

// onDisk is the directory dir (a real path) on disk.
func onDisk(dir string) place { return place{dir: dir} }

// file is the real path, or key, of the file name in p.
func (p place) file(name string) string {
	if p.tree != nil {
		return p.dir + "/" + name
	}
	return filepath.Join(p.dir, name)
}

// read reads the file name in p, of at most limit bytes: listed by its
// directory with that spelling (a directory that can't be listed lists
// nothing), and a regular file. c keeps the listings of a load (or nil).
func (p place) read(c *fileCache, name string, limit int64) openResult {
	if p.tree != nil {
		return p.tree.read(path.Join(p.inner, name), limit)
	}
	if ok, err := c.lists(p.dir, name); err != nil || !ok {
		return openResult{state: missing}
	}
	return readFile(filepath.Join(p.dir, name), limit)
}

// tree is a file tree given in code. Its id names it in keys and messages
// (fs1:money/schema.haus): the files of two trees are never the same file.
type tree struct {
	fsys fs.FS
	id   string
}

var trees atomic.Uint64

func newTree(fsys fs.FS) *tree {
	return &tree{fsys: fsys, id: fmt.Sprintf("fs%d", trees.Add(1))}
}

func (t *tree) at(inner string) place {
	return place{dir: t.id + ":" + inner, tree: t, inner: inner}
}

// isTreeKey reports whether p is the key of a file tree's directory or file
// (fs1:money), not a path on disk.
func isTreeKey(p string) bool {
	i := strings.IndexByte(p, ':')
	return i > 2 && strings.HasPrefix(p, "fs") && allDigits(p[2:i])
}

// entry finds name in the tree: each name on its way is listed by its
// directory with that spelling and is a directory (not a link). found is
// false if it isn't there; an error says a directory couldn't be listed.
func (t *tree) entry(name string) (typ fs.FileMode, found bool, err error) {
	if !fs.ValidPath(name) {
		return 0, false, nil
	}
	if name == "." {
		return fs.ModeDir, true, nil
	}
	dir := "."
	parts := strings.Split(name, "/")
	for i, part := range parts {
		entries, err := fs.ReadDir(t.fsys, dir)
		if err != nil {
			return 0, false, err
		}
		var e fs.DirEntry
		for _, x := range entries {
			if x.Name() == part {
				e = x
				break
			}
		}
		switch {
		case e == nil:
			return 0, false, nil
		case i == len(parts)-1:
			return e.Type(), true, nil
		case !e.Type().IsDir():
			return 0, false, nil
		}
		dir = path.Join(dir, part)
	}
	return 0, false, nil
}

// isDir reports whether inner is a directory of the tree, reached without
// links.
func (t *tree) isDir(inner string) bool {
	typ, ok, err := t.entry(inner)
	return err == nil && ok && typ.IsDir()
}

// read reads the regular file name of the tree, of at most limit bytes.
func (t *tree) read(name string, limit int64) openResult {
	typ, ok, err := t.entry(name)
	switch {
	case err != nil || !ok:
		return openResult{state: missing}
	case !typ.IsRegular():
		return openResult{state: notRegular}
	}
	f, err := t.fsys.Open(name)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return openResult{state: missing}
		}
		return openResult{state: failed, err: errorText(err)}
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	switch {
	case err != nil:
		return openResult{state: failed, err: errorText(err)}
	case !fi.Mode().IsRegular():
		return openResult{state: notRegular}
	}
	return readOpened(f, fi.Size(), limit)
}
