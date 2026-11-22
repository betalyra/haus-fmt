package schema

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
)

// Reading the files imports name (spec §13.3): a [Locator] says where a
// package is, and the rules here say whether it may be read. Resolution
// happens when a schema is loaded, never while data is parsed, and never
// over the network (§9.2).
//
// Every file is a regular file, read the same way (spec §13.3, "Files
// read"): lstat the path, open it without following a link at its last name
// and without blocking (O_NOFOLLOW | O_NONBLOCK | O_NOCTTY on Unix;
// FILE_FLAG_OPEN_REPARSE_POINT on Windows), check on the opened file that it
// is a regular file, the same one the path named, and read from it, so the
// file checked is the file read. A schema file outside packages is opened
// by its real path. Each name a build looks up itself (package.haus,
// schema.haus, package.json) and each name of a relative import is spelled
// as its directory lists it; a directory that can't be listed lists nothing.
//
// Only the entry file and the root option are resolved to real paths
// (filepath.EvalSymlinks), once, at the start, and package directories, which
// may be links. A relative import follows no link: it is walked down name by
// name from the importing file's real directory, none a symbolic link
// (os.Lstat), so the path reached is a real path and its root check is on
// the text.

// The limits of spec §13.3.
const (
	// MaxManifest is the largest package.haus, in bytes (64 KiB).
	MaxManifest = 64 << 10
	// MaxFile is the largest schema file and package.json, in bytes (1 MiB).
	MaxFile = 1 << 20
	// MaxFolderEntries is the most entries a folder of packages may have.
	MaxFolderEntries = 4096
	// MaxFiles is the most schema files one schema reads, the root included.
	MaxFiles = 256
)

// fileKind is which file is read, and so its limit.
type fileKind uint8

const (
	kindManifest      fileKind = iota // a package's package.haus: at most 64 KiB
	kindPackageSchema                 // a package's schema.haus
	kindPackageJSON                   // the package.json beside a package's manifest
	kindSchema                        // a schema file outside packages, read at its real path
)

func (k fileKind) limit() int64 {
	if k == kindManifest {
		return MaxManifest
	}
	return MaxFile
}

// openState is what opening a file gave.
type openState uint8

const (
	opened openState = iota
	missing
	notRegular // a symbolic link, a directory, a FIFO, …: not read
	tooLarge
	failed
)

type openResult struct {
	state openState
	bytes []byte
	size  int64
	err   string
}

// errNotRegular is an open that found something other than a regular file.
var errNotRegular = errors.New("not a regular file")

// readFile reads the regular file at path, of at most limit bytes: never
// through a link at its last name, never blocking on a FIFO or a device,
// and checked on the opened file (the same file as the path's, a regular
// one).
func readFile(path string, limit int64) openResult {
	before, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return openResult{state: missing}
	case err != nil:
		return openResult{state: failed, err: errorText(err)}
	case !before.Mode().IsRegular():
		return openResult{state: notRegular}
	}
	f, err := openFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return openResult{state: missing}
		}
		if fi, lerr := os.Lstat(path); errors.Is(err, errNotRegular) || lerr == nil && !fi.Mode().IsRegular() {
			return openResult{state: notRegular}
		}
		return openResult{state: failed, err: errorText(err)}
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return openResult{state: failed, err: errorText(err)}
	}
	if !fi.Mode().IsRegular() || !os.SameFile(before, fi) {
		return openResult{state: notRegular}
	}
	return readOpened(f, fi.Size(), limit)
}

// readOpened reads an opened regular file of the given size: at most limit
// bytes, and one more to see that there is no more.
func readOpened(f io.Reader, size, limit int64) openResult {
	if size > limit {
		return openResult{state: tooLarge, size: size}
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	switch {
	case err != nil:
		return openResult{state: failed, err: errorText(err)}
	case int64(len(b)) > limit:
		return openResult{state: tooLarge, size: int64(len(b))}
	}
	return openResult{state: opened, bytes: b}
}

// errorText is an error without the path it names (an absolute path, which
// messages don't show).
func errorText(err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		return le.Err.Error()
	}
	return err.Error()
}

// within is a file read for one use, as another use with its own limit sees it.
func within(r openResult, kind fileKind) openResult {
	if r.state == opened && int64(len(r.bytes)) > kind.limit() {
		return openResult{state: tooLarge, size: int64(len(r.bytes))}
	}
	return r
}

// realPath returns the absolute path with every link resolved.
func realPath(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

// inside reports whether path is dir or inside it, by names (vendor/common-x
// is not inside vendor/common).
func inside(dir, path string) bool {
	rel, err := filepath.Rel(dir, path)
	return err == nil && !filepath.IsAbs(rel) && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// fileCache is the files one schema reads, each once (spec §13.3), by real
// path (or, in a file tree, by its key): every use sees the same bytes, and
// each kind of file keeps its own size limit. root is the directory paths
// in messages are relative to (spec §13.3, "The root").
type fileCache struct {
	root     string
	opened   map[string]openResult
	json     map[string]any // parsed package.json files; nil for one that isn't JSON
	listings map[string]listing
}

func newFileCache(root string) *fileCache {
	return &fileCache{root: root, opened: map[string]openResult{}, json: map[string]any{}, listings: map[string]listing{}}
}

// listing is the names a directory lists, or why it can't be listed.
type listing struct {
	names map[string]bool
	err   error
}

func listDir(dir string) listing {
	f, err := openDir(dir)
	if err != nil {
		return listing{err: err}
	}
	defer func() { _ = f.Close() }()
	names := map[string]bool{}
	for {
		batch, err := f.Readdirnames(256)
		for _, n := range batch {
			names[n] = true
		}
		switch {
		case errors.Is(err, io.EOF):
			return listing{names: names}
		case err != nil:
			return listing{err: err}
		}
	}
}

// lists reports whether dir lists name, spelled byte for byte. An error
// says that dir can't be listed: then it shows no name (spec §13.3,
// "Spelling"). A load lists each directory once (c may be nil: then
// nothing is kept).
func (c *fileCache) lists(dir, name string) (bool, error) {
	var l listing
	if c == nil {
		l = listDir(dir)
	} else if cached, ok := c.listings[dir]; ok {
		l = cached
	} else {
		l = listDir(dir)
		c.listings[dir] = l
	}
	return l.names[name], l.err
}

// hasManifest reports whether dir has a package.haus, spelled so. A
// directory that can't be listed has one if something is there by that
// name: it may be a package, whose files are then not imported.
func (c *fileCache) hasManifest(dir string) bool {
	ok, err := c.lists(dir, ManifestFile)
	if err != nil {
		_, lerr := os.Lstat(filepath.Join(dir, ManifestFile))
		return lerr == nil
	}
	return ok
}

// shown is a path for a message, as the platform writes it (app\x on
// Windows), with its control and bidirectional characters escaped (spec
// §9.2).
func shown(path string) string {
	var b strings.Builder
	for _, r := range path {
		if isControlOrBidi(r) {
			fmt.Fprintf(&b, `\u{%X}`, r)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// show is a path for a message: relative to the root (../vendor/x for one
// outside it), never absolute; a file tree's paths as their keys
// (fs1:money/schema.haus).
func (c *fileCache) show(path string) string {
	if c.root != "" && !isTreeKey(path) {
		if rel, err := filepath.Rel(c.root, path); err == nil {
			return shown(rel)
		}
	}
	return shown(path)
}

// open reads the file name in the package or directory at, as kind says,
// and returns the key it is cached by.
func (c *fileCache) open(at place, name string, kind fileKind) (string, openResult) {
	key := at.file(name)
	r, ok := c.opened[key]
	if !ok {
		r = at.read(c, name, max(MaxFile, MaxManifest))
		c.opened[key] = r
	}
	return key, within(r, kind)
}

// notAPackageJSON is the value of a package.json that isn't valid JSON: it
// gives no version.
var notAPackageJSON any = notJSON{}

type notJSON struct{}

// packageJSON reads the package.json in at. present is false if there is
// none, or it can't be read (a link, not a regular file, too large); the
// value is notAPackageJSON if it isn't valid JSON.
func (c *fileCache) packageJSON(at place) (value any, present bool) {
	key, r := c.open(at, "package.json", kindPackageJSON)
	if r.state != opened {
		return nil, false
	}
	if v, ok := c.json[key]; ok {
		return v, true
	}
	var v any
	if !utf8.Valid(r.bytes) || json.Unmarshal(r.bytes, &v) != nil {
		v = notAPackageJSON
	}
	c.json[key] = v
	return v, true
}

// manifest reads and checks the manifest of the package at at.
func (c *fileCache) manifest(at place) (Manifest, string, error) {
	path, r := c.open(at, ManifestFile, kindManifest)
	invalid := func(why string) error {
		return &haus.Error{Code: haus.CodePackageManifest, Message: why, File: c.show(path)}
	}
	switch r.state {
	case missing:
		return Manifest{}, "", notFound("%s is not a schema package: it has no %s", c.show(at.dir), ManifestFile)
	case notRegular:
		return Manifest{}, "", newError(haus.CodePackagePath,
			"the manifest %s is a symbolic link or not a regular file; it is not read", c.show(path))
	case tooLarge:
		return Manifest{}, "", invalid(fmt.Sprintf("the manifest has %d bytes, more than 64 KiB", r.size))
	case failed:
		return Manifest{}, "", &haus.Error{Code: haus.CodeImportNotFound, Message: r.err, File: c.show(path)}
	}
	if !utf8.Valid(r.bytes) {
		return Manifest{}, "", invalid("the manifest is not UTF-8")
	}
	m, why := parseManifest(r.bytes)
	if why != "" {
		return Manifest{}, "", invalid(why)
	}
	return m, string(r.bytes), nil
}

// schemaText reads a schema file: a package's schema.haus, or a file outside
// packages at its real path. missingWhy says why a missing one is missing.
func (c *fileCache) schemaText(at place, name string, kind fileKind, missingWhy func() string) (string, error) {
	path, r := c.open(at, name, kind)
	switch r.state {
	case opened:
		return string(r.bytes), nil
	case missing:
		return "", notFound("%s", missingWhy())
	case notRegular:
		if kind == kindPackageSchema {
			return "", newError(haus.CodePackagePath, "%s is a symbolic link or not a regular file; it is not read", c.show(path))
		}
		return "", notFound("%s is not a regular file; it is not read", c.show(path))
	case tooLarge:
		return "", newError(haus.CodeFileTooLarge, "%s has %d bytes, more than 1 MiB; it is not read", c.show(path), r.size)
	}
	return "", notFound("%s: %s", c.show(path), r.err)
}

// source is a schema file an import names, read.
type source struct {
	path string // its real path (or key): two imports reach the same file when it is the same
	text string
	pkg  *foundPackage // for a package's schema.haus
}

// foundPackage is a package, with its manifest checked.
type foundPackage struct {
	manifest     Manifest
	dir          string // its real path, or its key in a file tree
	manifestText string // copies of a package have the same
}

// openPackageFor finds the package name for the file at from (a real path)
// with the locator and checks it: the manifest (package-manifest) and its
// name (import-not-found), its version (package-version), its files
// (package-path, file-too-large), and that a package found in a folder that
// another locator has too is the same (duplicate-package).
func openPackageFor(packages Locator, name, from string, files *fileCache) (*source, error) {
	loc, err := packages.locate(name, from, files)
	if err != nil {
		return nil, err
	}
	src, err := openPackage(loc.place(), name, loc.Version, loc.hasVersion, files)
	if err != nil {
		return nil, err
	}
	if loc.sameAs != nil {
		other, err := openPackage(loc.sameAs.place(), name, "", false, files)
		if err != nil {
			return nil, err
		}
		a, b := src.pkg, other.pkg
		if a.dir != b.dir && (a.manifestText != b.manifestText || src.text != other.text) {
			return nil, duplicate(a.manifest, files.show(a.dir), b.manifest, files.show(b.dir))
		}
	}
	return src, nil
}

// openPackage reads the package at at, which must be called name, with the
// version its package manager gives it, if any.
func openPackage(at place, name, version string, hasVersion bool, files *fileCache) (*source, error) {
	m, text, err := files.manifest(at)
	if err != nil {
		return nil, err
	}
	if m.Name != name {
		return nil, notFound("%s names the package %s, not %s", files.show(at.file(ManifestFile)), quote(m.Name), name)
	}
	if hasVersion && version != m.Version {
		if isSemver(version) {
			return nil, newError(haus.CodePackageVersion, "the package.haus of %s says version %s, its package manager %s (%s)",
				name, quote(m.Version), quote(version), files.show(at.dir))
		}
		return nil, newError(haus.CodePackageVersion, "the package.haus of %s says version %s, and the version its package "+
			"manager gives isn't a semantic version (%s)", name, quote(m.Version), files.show(at.dir))
	}
	schema, err := files.schemaText(at, SchemaFile, kindPackageSchema, func() string {
		return fmt.Sprintf("%s has no %s next to its manifest (%s)", name, SchemaFile, files.show(at.dir))
	})
	if err != nil {
		return nil, err
	}
	return &source{path: at.file(SchemaFile), text: schema, pkg: &foundPackage{manifest: m, dir: at.dir, manifestText: text}}, nil
}

// openRelative reads the file module (./common, ../shared/money, of the
// grammar's path, checked when the importing file was parsed) imports, next
// to the file at from (a real path inside the root; "" for a schema given as
// text, which imports no files), in the order of spec §13.3 ("Resolution"):
//
//   - a package imports no files (package-path): pkg is the name of the
//     package whose schema.haus the importing file was read as, or "" (what
//     is above it on the disk doesn't matter: an application's file may sit
//     in a package's directory);
//   - a path whose ".." names go above the root is import-outside-root,
//     checked on the text, before anything is looked at;
//   - the walk down its names from the importing file's real directory: each
//     name listed by its directory with that spelling, and none a symbolic
//     link, checked without following it (import-not-found; nothing behind a
//     link is looked at), so the path reached is a real path inside the root;
//   - the directories from the file's up to the root, the root included,
//     aren't a package's (package-path: a file outside a package imports no
//     file inside one), and can be listed to check that (import-not-found);
//   - the file is opened: a regular file (import-not-found), within its limit.
func (c *fileCache) openRelative(module, from, pkg string) (*source, error) {
	if from == "" {
		return nil, newError(haus.CodeImportUnavailable, "a schema read from text imports no files (load it from its file)")
	}
	if pkg != "" {
		return nil, newError(haus.CodePackagePath, "the schema of %s can't import files, only packages by name", pkg)
	}
	if isTreeKey(from) {
		// Only packages are in file trees.
		return nil, newError(haus.CodePackagePath, "the schema of the package in %s can't import files, only packages by name",
			c.show(filepath.Dir(from)))
	}
	// The grammar's path: "./" or "../"…, then names (no ".", "..", empty).
	names := strings.Split(module+Extension, "/")
	if names[0] == "." {
		names = names[1:]
	}
	base := filepath.Dir(from)
	for len(names) > 0 && names[0] == ".." {
		if base == c.root || !inside(c.root, base) {
			return nil, newError(haus.CodeImportOutsideRoot, "%s goes above the root directory of the build: a relative import "+
				"stays inside it (give the build a root option that contains both files, or import a package)", quote(module))
		}
		base, names = filepath.Dir(base), names[1:]
	}
	path, err := c.walk(base, names)
	if err != nil {
		return nil, err
	}
	// An application's file doesn't reach into a package: it imports the package by name.
	if err := c.inPackage(path); err != nil {
		return nil, err
	}
	text, err := c.schemaText(onDisk(filepath.Dir(path)), filepath.Base(path), kindSchema,
		func() string { return "file not found: " + c.show(path) })
	if err != nil {
		return nil, err
	}
	return &source{path: path, text: text}, nil
}

// walk returns the path names lead to from the real directory dir, walked
// down one name at a time (spec §13.3, "Resolution"): each name listed by
// its directory byte for byte (on file systems that ignore case or Unicode
// normalization, ./Billing/common would find billing/common.schema.haus,
// and on Windows ./sub./x would find sub/x; a directory that can't be listed
// lists no name), and none a symbolic link, checked without following it
// (os.Lstat), so nothing behind a link is looked at; each name but the last
// a directory. The path reached has no links: it is a real path.
func (c *fileCache) walk(dir string, names []string) (string, error) {
	wanted := filepath.Join(append([]string{dir}, names...)...)
	at := dir
	for i, name := range names {
		ok, err := c.lists(at, name)
		switch {
		case err != nil:
			return "", notFound("file not found: %s (the directory of %s can't be listed: %s)",
				c.show(wanted), quote(name), errorText(err))
		case !ok:
			return "", notFound("file not found: %s (no %s in its directory: names are spelled as the directory lists them)",
				c.show(wanted), quote(name))
		}
		at = filepath.Join(at, name)
		fi, err := os.Lstat(at)
		switch {
		case err != nil:
			return "", notFound("file not found: %s: %s", c.show(wanted), errorText(err))
		case isLink(fi):
			return "", notFound("%s is a symbolic link: a relative import follows no link, and nothing behind it is read",
				quote(name))
		case i < len(names)-1 && !fi.IsDir():
			return "", notFound("file not found: %s (%s is not a directory)", c.show(wanted), quote(name))
		}
	}
	return at, nil
}

// inPackage fails if the file at path (a real path inside the root) is in a
// package's directory (spec §13.3, "Imports"): the directories from its own
// up to the root, the root included, each a package's when it lists
// package.haus. One that can't be listed can't show whether it is a
// package's: the import fails (import-not-found), never passes as one
// outside a package.
func (c *fileCache) inPackage(path string) error {
	for d := filepath.Dir(path); inside(c.root, d); d = filepath.Dir(d) {
		ok, err := c.lists(d, ManifestFile)
		switch {
		case err != nil:
			return notFound("whether %s is a package's directory can't be checked (it can't be listed); it is not read", c.show(d))
		case ok:
			return newError(haus.CodePackagePath, "the file is in the package directory %s: import the package by its name", c.show(d))
		case d == c.root || filepath.Dir(d) == d:
			return nil
		}
	}
	return nil
}

// entryText reads the entry file at its real path: a package's schema.haus
// is read as one.
func (c *fileCache) entryText(resolved string) (string, error) {
	kind := kindSchema
	if c.isPackageSchema(resolved) {
		kind = kindPackageSchema
	}
	return c.schemaText(onDisk(filepath.Dir(resolved)), filepath.Base(resolved), kind,
		func() string { return "file not found: " + c.show(resolved) })
}

// isPackageSchema reports whether the file at path is a package's
// schema.haus: next to a package.haus.
func (c *fileCache) isPackageSchema(path string) bool {
	return filepath.Base(path) == SchemaFile && c.hasManifest(filepath.Dir(path))
}

// packageOfFile returns the package whose schema.haus is the file at path
// (a real path), if it is one, with its manifest checked.
func packageOfFile(path string, files *fileCache) (*foundPackage, error) {
	if !files.isPackageSchema(path) {
		return nil, nil
	}
	dir := filepath.Dir(path)
	m, text, err := files.manifest(onDisk(dir))
	if err != nil {
		return nil, err
	}
	return &foundPackage{manifest: m, dir: dir, manifestText: text}, nil
}

// relativeID returns the id of a file outside packages: its path from
// base, /-separated, without the extension (billing/common,
// ../shared/money). Different files have different ids.
func relativeID(base, path string) string {
	rel, err := filepath.Rel(base, path)
	if err != nil {
		rel = path
	}
	return strings.TrimSuffix(filepath.ToSlash(rel), Extension)
}

// sameFiles reports whether the packages at a and b are copies of one
// package: their manifests and schema files are the same, byte for byte,
// and regular files (spec §13.3).
func sameFiles(a, b place) bool {
	read := func(at place) ([]byte, []byte, bool) {
		m := at.read(nil, ManifestFile, MaxManifest)
		s := at.read(nil, SchemaFile, MaxFile)
		return m.bytes, s.bytes, m.state == opened && s.state == opened
	}
	am, as, ok := read(a)
	if !ok {
		return false
	}
	bm, bs, ok := read(b)
	return ok && string(am) == string(bm) && string(as) == string(bs)
}

func newError(code haus.ErrorCode, format string, args ...any) *haus.Error {
	return &haus.Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

func notFound(format string, args ...any) *haus.Error {
	return newError(haus.CodeImportNotFound, format, args...)
}

// inFile sets the file of an error that has none.
func inFile(err error, shownPath string) error {
	var e *haus.Error
	if errors.As(err, &e) && e.File == "" {
		c := *e
		c.File = shownPath
		return &c
	}
	return err
}

// duplicate is duplicate-package: two packages with one name, in the
// directories shown as aDir and bDir.
func duplicate(a Manifest, aDir string, b Manifest, bDir string) *haus.Error {
	copies := ""
	if a.Version == b.Version {
		copies = fmt.Sprintf(" (two copies of %s whose files or imports differ)", quote(a.Version))
	}
	return newError(haus.CodeDuplicatePackage, "two packages are called %s: %s in %s and %s in %s%s",
		quote(a.Name), quote(a.Version), aDir, quote(b.Version), bDir, copies)
}
