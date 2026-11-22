package schema

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"path"
	"path/filepath"
	"slices"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
)

// Locator finds the packages imports name (spec §13.3): the directory of the
// package an import names. Everything else is checked when a schema is
// loaded: the manifest, its name and version, the @major of the import,
// containment, one package per name, cycles and ids.
//
// The locators are [*Explicit] (packages given by the application) and
// [Or], which combines two. This binding doesn't look in node_modules: only
// implementations of the npm ecosystem (JavaScript runtimes) do, and a Go
// build declares its dependencies in go.mod (spec §13.3, "Installed
// packages"). A Go module publishes a schema package by embedding it
// (//go:embed) and giving it with [Explicit.PackageFS]. A nil Locator finds
// no packages: a schema that imports one fails with the code
// import-unavailable.
type Locator interface {
	// locate finds the package name (@org/name, without @major) for the
	// file at from (its real path; "" for a schema given as text). A
	// package that isn't there is import-not-found, saying where it was
	// looked for; [Or] then tries the next locator.
	locate(name, from string, files *fileCache) (Location, error)
}

// Location is a package directory a [Locator] found.
type Location struct {
	// Dir has package.haus and schema.haus: a real path, or the key of a
	// directory in a file tree (fs1:money).
	Dir string
	// Version is the version a package.json beside the manifest gives, if
	// it gives one: the manifest's must be the same (package-version).
	Version    string
	hasVersion bool
	// scanned is set for a package found by scanning a folder: it doesn't
	// replace a package the next locator of [Or] finds.
	scanned bool
	// sameAs is a package with the same name found by scanning a folder:
	// its files must be the same as this one's (duplicate-package).
	sameAs *Location
	tree   *tree
	inner  string
}

func (l Location) place() place { return place{dir: l.Dir, tree: l.tree, inner: l.inner} }

// noImports is the locator of a schema without one.
type noImports struct{}

func (noImports) locate(string, string, *fileCache) (Location, error) {
	return Location{}, newError(haus.CodeImportUnavailable, "no package locator (only std modules and files can be imported here)")
}

// Or is a [Locator] that tries First, then Second for the packages First
// doesn't find. A package First found by scanning a folder doesn't replace
// one Second finds: their files must be the same.
type Or struct {
	First, Second Locator
}

func (o Or) locate(name, from string, files *fileCache) (Location, error) {
	first, err := locatorOf(o.First).locate(name, from, files)
	switch {
	case err != nil && codeOf(err) == haus.CodeImportNotFound:
		second, err2 := locatorOf(o.Second).locate(name, from, files)
		if err2 != nil && codeOf(err2) == haus.CodeImportNotFound {
			return Location{}, notFound("%s; %s", messageOf(err), messageOf(err2))
		}
		return second, err2
	case err == nil && first.scanned:
		// A package found in a folder: the other locator's comes first, if it has the same files.
		found, err2 := locatorOf(o.Second).locate(name, from, files)
		switch {
		case err2 == nil:
			found.sameAs = &first
			return found, nil
		case codeOf(err2) == haus.CodeImportNotFound || codeOf(err2) == haus.CodeUndeclaredPackage:
			return first, nil
		}
		return Location{}, err2
	}
	return first, err
}

func locatorOf(l Locator) Locator {
	if l == nil {
		return noImports{}
	}
	return l
}

// Explicit is packages given explicitly (spec §13.3): each by its directory
// ([Explicit.Package]) or a directory of a file tree ([Explicit.PackageFS]),
// or the packages in a folder ([Explicit.Folder], [Explicit.FolderFS]).
// Their manifests name them, whatever the directories are called. They count
// as declared wherever they are imported. A package given by its directory
// comes before other locators for its name ([Or]); one found in a folder
// doesn't: if the next locator finds a package with its name and other
// files, the schema has two packages with one name. A package.json beside
// a manifest is read leniently: only for a version that differs
// (package-version), and ignored if it can't be read.
//
//	packages, err := schema.NewExplicit().Package("../extensions/money")
//	s, err := schema.Load("app.schema.haus", schema.Options{Packages: packages})
type Explicit struct {
	packages []given
	// unreadable is the subdirectories of folders whose manifest couldn't be
	// read: named when an import isn't found.
	unreadable []unreadable
}

type given struct {
	manifest Manifest
	at       place
	scanned  bool
}

type unreadable struct {
	dir string
	err error
}

// NewExplicit returns an empty set of packages.
func NewExplicit() *Explicit { return &Explicit{} }

// Package adds the package in dir. Its manifest is read and checked now: a
// directory without one is import-not-found. Two packages with one name
// are duplicate-package, unless they are copies (the same package.haus and
// schema.haus). Messages show its files relative to dir's parent
// (money/package.haus).
func (e *Explicit) Package(dir string) (*Explicit, error) {
	resolved, err := realPath(dir)
	if err != nil {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: errorText(err), File: shown(filepath.Base(dir))}
	}
	files := newFileCache(filepath.Dir(resolved))
	m, _, err := files.manifest(onDisk(resolved))
	if err != nil {
		return nil, err
	}
	return e.add(m, onDisk(resolved), false)
}

// PackageFS adds the package in the directory dir of the file tree fsys
// (an [fs.FS] path, "." for its root), such as the schema package a Go
// module embeds:
//
//	//go:embed money
//	var money embed.FS
//
//	packages, err := schema.NewExplicit().PackageFS(money, "money")
//
// The tree is read under the rules of a directory on disk (spec §13.3),
// and follows no links. Messages and [Package.Dir] name its files by a key
// of the tree (fs1:money/schema.haus).
func (e *Explicit) PackageFS(fsys fs.FS, dir string) (*Explicit, error) {
	t := newTree(fsys)
	if !t.isDir(dir) {
		return nil, notFound("%s is not a directory of the file tree (reached without links)", quote(dir))
	}
	at := t.at(dir)
	m, _, err := newFileCache("").manifest(at)
	if err != nil {
		return nil, err
	}
	return e.add(m, at, false)
}

// Folder adds the packages in folder: its subdirectories (or links to
// directories) that have a package.haus, not deeper. A folder that can't be
// read is import-not-found, one with more than [MaxFolderEntries] entries
// too-many-files. A subdirectory whose manifest is invalid, or whose
// package.json gives another version, is left out; an import that isn't
// found names it by the last name of the folder's real path and its own
// (schemas/broken), however the folder was given.
func (e *Explicit) Folder(folder string) (*Explicit, error) {
	resolvedFolder, err := realPath(folder)
	if err != nil {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: errorText(err), File: shown(filepath.Base(folder))}
	}
	base := filepath.Base(resolvedFolder)
	f, err := openDir(resolvedFolder)
	if err != nil {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: errorText(err), File: shown(base)}
	}
	names, err := f.Readdirnames(MaxFolderEntries + 1)
	_ = f.Close()
	if err != nil && len(names) == 0 && !isEOF(err) {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: errorText(err), File: shown(base)}
	}
	if len(names) > MaxFolderEntries {
		return nil, &haus.Error{Code: haus.CodeTooManyFiles, File: shown(base),
			Message: fmt.Sprintf("the folder of packages has more than %d entries", MaxFolderEntries)}
	}
	slices.Sort(names)
	files := newFileCache(filepath.Dir(resolvedFolder))
	for _, n := range names {
		dir := filepath.Join(resolvedFolder, n)
		if !files.hasManifest(dir) {
			continue
		}
		resolved, err := realPath(dir)
		var m Manifest
		if err == nil {
			m, _, err = files.manifest(onDisk(resolved))
		} else {
			err = &haus.Error{Code: haus.CodeImportNotFound, Message: errorText(err), File: shown(filepath.Join(base, n))}
		}
		if err == nil {
			err = folderVersion(m, onDisk(resolved), files)
		}
		if err != nil {
			e.unreadable = append(e.unreadable, unreadable{filepath.Join(base, n), err})
			continue
		}
		if e, err = e.add(m, onDisk(resolved), true); err != nil {
			return nil, err
		}
	}
	return e, nil
}

// FolderFS adds the packages in the directory folder of the file tree fsys
// ("." for its root), as [Explicit.Folder] does on disk: its subdirectories
// (not links) that have a package.haus.
func (e *Explicit) FolderFS(fsys fs.FS, folder string) (*Explicit, error) {
	t := newTree(fsys)
	if !t.isDir(folder) {
		return nil, notFound("%s is not a directory of the file tree (reached without links)", quote(folder))
	}
	base := path.Base(folder)
	f, err := fsys.Open(folder)
	if err != nil {
		return nil, notFound("%s: %s", quote(folder), errorText(err))
	}
	var entries []fs.DirEntry
	if rd, ok := f.(fs.ReadDirFile); ok {
		entries, err = rd.ReadDir(MaxFolderEntries + 1)
	} else {
		entries, err = fs.ReadDir(fsys, folder)
	}
	_ = f.Close()
	if err != nil && len(entries) == 0 && !isEOF(err) {
		return nil, notFound("%s: %s", quote(folder), errorText(err))
	}
	if len(entries) > MaxFolderEntries {
		return nil, newError(haus.CodeTooManyFiles, "the folder of packages %s has more than %d entries", quote(folder), MaxFolderEntries)
	}
	slices.SortFunc(entries, func(a, b fs.DirEntry) int { return strings.Compare(a.Name(), b.Name()) })
	files := newFileCache("")
	for _, x := range entries {
		inner := path.Join(folder, x.Name())
		if !x.Type().IsDir() {
			continue
		}
		if _, ok, err := t.entry(path.Join(inner, ManifestFile)); err != nil || !ok {
			continue
		}
		at := t.at(inner)
		m, _, err := files.manifest(at)
		if err == nil {
			err = folderVersion(m, at, files)
		}
		if err != nil {
			e.unreadable = append(e.unreadable, unreadable{path.Join(base, x.Name()), err})
			continue
		}
		if e, err = e.add(m, at, true); err != nil {
			return nil, err
		}
	}
	return e, nil
}

func isEOF(err error) bool { return errors.Is(err, io.EOF) }

// lastNames is a package's directory for a message given before any
// build: its last two names (vendor/money), or a tree's key.
func lastNames(dir string) string {
	if isTreeKey(dir) {
		return shown(dir)
	}
	return shown(filepath.Join(filepath.Base(filepath.Dir(dir)), filepath.Base(dir)))
}

func (e *Explicit) add(m Manifest, at place, scanned bool) (*Explicit, error) {
	for i, g := range e.packages {
		if g.manifest.Name != m.Name {
			continue
		}
		if g.at.dir == at.dir || sameFiles(g.at, at) {
			e.packages[i].scanned = g.scanned && scanned
			return e, nil
		}
		return nil, duplicate(g.manifest, lastNames(g.at.dir), m, lastNames(at.dir))
	}
	e.packages = append(e.packages, given{manifest: m, at: at, scanned: scanned})
	return e, nil
}

func (e *Explicit) locate(name, _ string, files *fileCache) (Location, error) {
	for _, g := range e.packages {
		if g.manifest.Name == name {
			version, has := files.lenientVersion(g.at)
			return Location{Dir: g.at.dir, Version: version, hasVersion: has, scanned: g.scanned,
				tree: g.at.tree, inner: g.at.inner}, nil
		}
	}
	why := fmt.Sprintf("package %s is not among the packages given", name)
	if len(e.unreadable) > 0 {
		dirs := make([]string, len(e.unreadable))
		for i, u := range e.unreadable {
			dirs[i] = fmt.Sprintf("%s (%s)", shown(u.dir), messageOf(u.err))
		}
		why += fmt.Sprintf(" (packages in the folders given that could not be read: %s)", strings.Join(dirs, ", "))
	}
	return Location{}, notFound("%s", why)
}

// lenientVersion returns the version of the package.json beside the manifest
// of a package given explicitly, if it gives one. Such a package.json only
// gives a version: one that can't be read (a link, not a regular file, too
// large, not JSON) is ignored, and is no error (spec §13.3, "Package
// versions").
func (c *fileCache) lenientVersion(at place) (version string, ok bool) {
	v, _ := c.packageJSON(at)
	version, ok = member(v, "version").(string)
	return version, ok
}

// folderVersion checks a package found in a folder against the version of
// the package.json beside its manifest, read leniently: a subdirectory with
// another version is skipped like one with a broken manifest (spec §13.3).
func folderVersion(m Manifest, at place, files *fileCache) error {
	if version, ok := files.lenientVersion(at); ok && version != m.Version {
		return newError(haus.CodePackageVersion, "the package.haus of %s says version %s, the package.json next to it %s",
			m.Name, quote(m.Version), quote(version))
	}
	return nil
}

// member returns the member key of a JSON object (the last one, as
// encoding/json and JSON.parse keep), or nil.
func member(doc any, key string) any {
	if obj, ok := doc.(map[string]any); ok {
		return obj[key]
	}
	return nil
}

func codeOf(err error) haus.ErrorCode {
	if e, ok := err.(*haus.Error); ok {
		return e.Code
	}
	return ""
}

func messageOf(err error) string {
	if e, ok := err.(*haus.Error); ok {
		return e.Message
	}
	return err.Error()
}
