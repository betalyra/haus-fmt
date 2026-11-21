package schema

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"

	haus "github.com/betalyra/haus-fmt/go"
)

// Locator finds the packages imports name, for one package manager (spec
// §13.3): the directory of the package an import names, and whether the
// importing file declares it. Everything else is the same for every package
// manager and is checked when a schema is loaded: the manifest, its name and
// version, the @major of the import, containment, one package per name,
// cycles and ids.
//
// The locators are [NodeModules], [*Explicit] (packages given by the user)
// and [Or], which combines two. A nil Locator finds no packages: a schema
// that imports one fails with the code import-unavailable.
type Locator interface {
	// locate finds the package name (@org/name, without @major) for the
	// file at from (its real path; "" for a schema given as text). A
	// package that isn't there is import-not-found, saying where it was
	// looked for; [Or] then tries the next locator.
	locate(name, from string, files *fileCache) (Location, error)
}

// Location is a package directory a [Locator] found.
type Location struct {
	// Dir has package.haus and schema.haus.
	Dir string
	// Version is the version the package manager gives the package (the
	// version of npm's package.json), if it gives one: the manifest's must
	// be the same (package-version).
	Version    string
	hasVersion bool
	// scanned is set for a package found by scanning a folder: it doesn't
	// replace a package the next locator of [Or] finds.
	scanned bool
	// sameAs is a package with the same name found by scanning a folder:
	// its files must be the same as this one's (duplicate-package).
	sameAs string
}

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
			found.sameAs = first.Dir
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
// ([Explicit.Package]), or the packages in a folder ([Explicit.Folder]).
// Their manifests name them, whatever the directories are called. They count
// as declared wherever they are imported. A package given by its directory
// comes before other locators for its name ([Or]); one found in a folder
// doesn't: if the next locator finds a package with its name and other
// files, the schema has two packages with one name.
//
//	packages, err := schema.NewExplicit().Package("../extensions/money")
//	s, err := schema.Load("app.schema.haus", schema.Options{Packages: schema.Or{First: packages, Second: schema.NodeModules{}}})
type Explicit struct {
	packages []given
	// unreadable is the subdirectories of folders whose manifest couldn't be
	// read: named when an import isn't found.
	unreadable []unreadable
}

type given struct {
	manifest Manifest
	dir      string // its real path
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
// schema.haus).
func (e *Explicit) Package(dir string) (*Explicit, error) {
	resolved, err := realPath(dir)
	if err != nil {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: err.Error(), File: shown(dir)}
	}
	m, err := readManifest(resolved)
	if err != nil {
		return nil, err
	}
	return e.add(m, resolved, false)
}

// Folder adds the packages in folder: its subdirectories (or links to
// directories) that have a package.haus, not deeper. A folder that can't be
// read is import-not-found, one with more than [MaxFolderEntries] entries
// too-many-files. A subdirectory whose manifest is invalid is left out; an
// import that isn't found names it.
func (e *Explicit) Folder(folder string) (*Explicit, error) {
	f, err := os.Open(folder)
	if err != nil {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: err.Error(), File: shown(folder)}
	}
	names, err := f.Readdirnames(MaxFolderEntries + 1)
	_ = f.Close()
	if err != nil && len(names) == 0 && !isEOF(err) {
		return nil, &haus.Error{Code: haus.CodeImportNotFound, Message: err.Error(), File: shown(folder)}
	}
	if len(names) > MaxFolderEntries {
		return nil, &haus.Error{Code: haus.CodeTooManyFiles, File: shown(folder),
			Message: fmt.Sprintf("the folder of packages has more than %d entries", MaxFolderEntries)}
	}
	var dirs []string
	for _, n := range names {
		dir := filepath.Join(folder, n)
		if exists(filepath.Join(dir, ManifestFile)) {
			dirs = append(dirs, dir)
		}
	}
	slices.Sort(dirs)
	for _, dir := range dirs {
		resolved, err := realPath(dir)
		var m Manifest
		if err == nil {
			m, err = readManifest(resolved)
		} else {
			err = &haus.Error{Code: haus.CodeImportNotFound, Message: err.Error(), File: shown(dir)}
		}
		if err != nil {
			e.unreadable = append(e.unreadable, unreadable{dir, err})
			continue
		}
		if e, err = e.add(m, resolved, true); err != nil {
			return nil, err
		}
	}
	return e, nil
}

func isEOF(err error) bool { return errors.Is(err, io.EOF) }

func (e *Explicit) add(m Manifest, dir string, scanned bool) (*Explicit, error) {
	for i, g := range e.packages {
		if g.manifest.Name != m.Name {
			continue
		}
		if g.dir == dir || sameFiles(g.dir, dir) {
			e.packages[i].scanned = g.scanned && scanned
			return e, nil
		}
		return nil, duplicate(g.manifest, g.dir, m, dir)
	}
	e.packages = append(e.packages, given{manifest: m, dir: dir, scanned: scanned})
	return e, nil
}

func (e *Explicit) locate(name, _ string, files *fileCache) (Location, error) {
	for _, g := range e.packages {
		if g.manifest.Name == name {
			version, has, err := npmVersion(g.dir, files)
			if err != nil {
				return Location{}, err
			}
			return Location{Dir: g.dir, Version: version, hasVersion: has, scanned: g.scanned}, nil
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

// NodeModules finds packages in node_modules, by the npm rules of spec §13.3.
//
// A file imports only the packages it declares, checked before anything is
// looked for (undeclared-package): for a package's schema.haus, those in
// dependencies, peerDependencies and optionalDependencies of the package's
// own package.json; for other files, those and devDependencies of the
// nearest package.json above the file, skipping one with neither a name nor
// a dependency field. Without one, a file declares nothing.
//
// @org/name is then D/node_modules/@org/name for the nearest directory D
// from the importing file's real path up, as Node finds packages (so pnpm's
// links and workspace links find each package's own dependencies),
// skipping a D named node_modules, a scope directory inside one
// (node_modules/@acme), a drive root (Windows) and a world-writable D such
// as /tmp (Unix). The first one that exists is the package: without a
// package.haus the import is not found. Nothing else is read: not
// NODE_PATH, npm's global folder or ~/.node_modules.
type NodeModules struct{}

func (NodeModules) locate(name, from string, files *fileCache) (Location, error) {
	start := ""
	if from != "" {
		start = filepath.Dir(from)
	} else {
		wd, err := os.Getwd()
		if err != nil {
			return Location{}, notFound("%v", err)
		}
		start = wd
	}
	if err := declared(name, from, start, files); err != nil {
		return Location{}, err
	}
	installed := ""
	for d := start; ; {
		if searched(d) {
			candidate := filepath.Join(append([]string{d, "node_modules"}, strings.Split(name, "/")...)...)
			if exists(candidate) {
				installed = candidate
				break
			}
		}
		parent := filepath.Dir(d)
		if parent == d {
			break
		}
		d = parent
	}
	if installed == "" {
		return Location{}, notFound("package %s is not installed (no node_modules/%s in %s or above)", name, name, shown(start))
	}
	if !exists(filepath.Join(installed, ManifestFile)) {
		return Location{}, notFound("%s is not a schema package: it has no %s (the nearest node_modules/%s is the package)",
			shown(installed), ManifestFile, name)
	}
	dir, err := realPath(installed)
	if err != nil {
		return Location{}, notFound("%s: %v", shown(installed), err)
	}
	version, has, err := npmVersion(dir, files)
	if err != nil {
		return Location{}, err
	}
	return Location{Dir: dir, Version: version, hasVersion: has}, nil
}

// searched reports whether node_modules is looked for in dir (spec §13.3).
func searched(dir string) bool {
	base := filepath.Base(dir)
	scope := strings.HasPrefix(base, "@") && filepath.Base(filepath.Dir(dir)) == "node_modules"
	return base != "node_modules" && !scope && !driveRoot(dir) && !worldWritable(dir)
}

// dependencyFields are the dependency fields of a package.json: all four
// count for a project's files, the first three for a package's schema.haus.
var dependencyFields = []string{"dependencies", "peerDependencies", "optionalDependencies", "devDependencies"}

// declared checks that the file at from (in dir) declares name
// (undeclared-package if not).
func declared(name, from, dir string, files *fileCache) error {
	file := "the schema"
	if from != "" {
		file = shown(from)
	}
	var (
		path   string
		doc    any
		fields []string
	)
	if from != "" && filepath.Base(from) == SchemaFile && exists(filepath.Join(dir, ManifestFile)) {
		path = filepath.Join(dir, "package.json")
		v, present, err := files.packageJSON(path, kindPackageJSON)
		if err != nil {
			return err
		}
		if !present {
			return newError(haus.CodeUndeclaredPackage,
				"the package in %s has no package.json, so it declares no packages: %s isn't declared", shown(dir), name)
		}
		doc, fields = v, dependencyFields[:3]
	} else {
		p, v, ok, err := project(dir, files)
		if err != nil {
			return err
		}
		if !ok {
			return newError(haus.CodeUndeclaredPackage, "no package.json above %s declares %s: list it in the dependencies "+
				"of a package.json, or give the package explicitly", file, name)
		}
		path, doc, fields = p, v, dependencyFields
	}
	for _, f := range fields {
		if deps, ok := member(doc, f).(map[string]any); ok {
			if _, ok := deps[name]; ok {
				return nil
			}
		}
	}
	return newError(haus.CodeUndeclaredPackage, "%s doesn't declare %s: %s doesn't list it in %s",
		file, name, shown(path), strings.Join(fields, ", "))
}

// project finds the nearest package.json above dir that has a name or a
// dependency field: the project's. One that is valid JSON but not an
// object is skipped. One that isn't valid JSON or isn't a regular file (a
// directory, a broken link) is the project's too, and declares nothing:
// the search stops there.
func project(dir string, files *fileCache) (path string, doc any, ok bool, err error) {
	for d := dir; ; {
		path = filepath.Join(d, "package.json")
		v, present, err := files.packageJSON(path, kindProjectJSON)
		if err != nil {
			return "", nil, false, err
		}
		if present {
			if v == notAPackageJSON || hasMember(v, "name") {
				return path, v, true, nil
			}
			for _, f := range dependencyFields {
				if hasMember(v, f) {
					return path, v, true, nil
				}
			}
		}
		parent := filepath.Dir(d)
		if parent == d {
			return "", nil, false, nil
		}
		d = parent
	}
}

// npmVersion returns the version of the package.json in the package
// directory dir, if there is one.
func npmVersion(dir string, files *fileCache) (version string, ok bool, err error) {
	v, _, err := files.packageJSON(filepath.Join(dir, "package.json"), kindPackageJSON)
	if err != nil {
		return "", false, err
	}
	s, ok := member(v, "version").(string)
	return s, ok, nil
}

// member returns the member key of a JSON object (the last one, as
// encoding/json and JSON.parse keep), or nil.
func member(doc any, key string) any {
	if obj, ok := doc.(map[string]any); ok {
		return obj[key]
	}
	return nil
}

// hasMember reports whether a JSON object has the member key.
func hasMember(doc any, key string) bool {
	obj, ok := doc.(map[string]any)
	if ok {
		_, ok = obj[key]
	}
	return ok
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
