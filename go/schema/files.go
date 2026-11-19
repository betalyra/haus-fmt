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

// Reading the files imports name (spec §13.3), the same for every package
// manager: a [Locator] says where a package is, and the rules here say
// whether it may be read. Resolution happens when a schema is loaded, never
// while data is parsed, and never over the network (§9.2).
//
// A package's package.haus, schema.haus and package.json are opened without
// following links (O_NOFOLLOW, and O_NONBLOCK so that a FIFO can't block the
// open, on Unix); their type and size are checked on the opened file, and
// they are read from it, so the file checked is the file read.

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

// fileKind is which file is read, and so how.
type fileKind uint8

const (
	kindManifest      fileKind = iota // a package's package.haus: never through a link, at most 64 KiB
	kindPackageSchema                 // a package's schema.haus: never through a link
	kindPackageJSON                   // a package's package.json: never through a link
	kindSchema                        // a schema file outside packages, read at its real path
	kindProjectJSON                   // the package.json of a project (not a package's)
)

func (k fileKind) followsLinks() bool { return k == kindSchema || k == kindProjectJSON }

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

// readFile opens the file at path, following a link or not, and reads it:
// a regular file of at most limit bytes, checked on the opened file.
func readFile(path string, follow bool, limit int64) openResult {
	f, err := openFile(path, follow)
	if err != nil {
		fi, lerr := os.Lstat(path)
		switch {
		case lerr == nil && !fi.Mode().IsRegular():
			return openResult{state: notRegular}
		case errors.Is(err, fs.ErrNotExist):
			return openResult{state: missing}
		}
		return openResult{state: failed, err: err.Error()}
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return openResult{state: failed, err: err.Error()}
	}
	if !fi.Mode().IsRegular() {
		return openResult{state: notRegular}
	}
	if fi.Size() > limit {
		return openResult{state: tooLarge, size: fi.Size()}
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	switch {
	case err != nil:
		return openResult{state: failed, err: err.Error()}
	case int64(len(b)) > limit:
		return openResult{state: tooLarge, size: int64(len(b))}
	}
	return openResult{state: opened, bytes: b}
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

// exists reports whether something is at path, without following a link.
func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// shown is a path for a message, as the platform writes it (C:\app\x on
// Windows, as the other bindings show it), with its control and
// bidirectional characters escaped (spec §9.2).
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

// fileCache is the files one schema reads, each once (spec §13.3), by real
// path: a file needed in two roles (a package.json that is a link to a
// schema file) is read once, and every use sees the same bytes. Each use
// keeps its own checks: a package's files are never read through a link,
// and each kind of file has its own size limit.
type fileCache struct {
	opened map[string]openResult
	json   map[string]any // parsed package.json files; nil for one that isn't JSON
}

func newFileCache() *fileCache {
	return &fileCache{opened: map[string]openResult{}, json: map[string]any{}}
}

// open reads the file at path as kind says, and returns the path it is
// cached by.
func (c *fileCache) open(path string, kind fileKind) (string, openResult) {
	if !kind.followsLinks() {
		fi, err := os.Lstat(path)
		switch {
		case err == nil && fi.Mode()&fs.ModeSymlink != 0:
			return path, openResult{state: notRegular}
		case errors.Is(err, fs.ErrNotExist):
			return path, openResult{state: missing}
		}
	}
	key, err := realPath(path)
	if err != nil {
		key = path
	}
	r, ok := c.opened[key]
	if !ok {
		r = readFile(path, kind.followsLinks(), max(MaxFile, MaxManifest))
		c.opened[key] = r
	}
	return key, within(r, kind)
}

// packageJSON reads a package.json (kind says whose). present is false if
// there is none (or, for a project's, it isn't a regular file); the value is
// nil if it isn't valid JSON: it declares nothing and gives no version.
func (c *fileCache) packageJSON(path string, kind fileKind) (value any, present bool, err error) {
	key, r := c.open(path, kind)
	switch r.state {
	case missing:
		return nil, false, nil
	case notRegular:
		if kind == kindProjectJSON {
			return nil, false, nil
		}
		return nil, false, newError(haus.CodePackagePath, "%s is a symbolic link or not a regular file; it is not read", shown(path))
	case tooLarge:
		return nil, false, tooLargeError(path, r.size)
	case failed:
		return nil, false, notFound("%s: %s", shown(path), r.err)
	}
	if v, ok := c.json[key]; ok {
		return v, true, nil
	}
	var v any
	if !utf8.Valid(r.bytes) || json.Unmarshal(r.bytes, &v) != nil {
		v = nil
	}
	c.json[key] = v
	return v, true, nil
}

// manifest reads and checks the manifest of the package in dir (a real path).
func (c *fileCache) manifest(dir string) (Manifest, string, error) {
	path := filepath.Join(dir, ManifestFile)
	_, r := c.open(path, kindManifest)
	return manifestOf(dir, r)
}

// manifestOf checks the manifest at dir/package.haus, opened.
func manifestOf(dir string, r openResult) (Manifest, string, error) {
	path := filepath.Join(dir, ManifestFile)
	invalid := func(why string) error {
		return &haus.Error{Code: haus.CodePackageManifest, Message: why, File: shown(path)}
	}
	switch r.state {
	case missing:
		return Manifest{}, "", notFound("%s is not a schema package: it has no %s", shown(dir), ManifestFile)
	case notRegular:
		return Manifest{}, "", newError(haus.CodePackagePath,
			"the manifest %s is a symbolic link or not a regular file; it is not read", shown(path))
	case tooLarge:
		return Manifest{}, "", invalid(fmt.Sprintf("the manifest has %d bytes, more than 64 KiB", r.size))
	case failed:
		return Manifest{}, "", &haus.Error{Code: haus.CodeImportNotFound, Message: r.err, File: shown(path)}
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

// readManifest reads the manifest of the package in dir, on its own.
func readManifest(dir string) (Manifest, error) {
	m, _, err := manifestOf(dir, readFile(filepath.Join(dir, ManifestFile), false, MaxManifest))
	return m, err
}

// schemaText reads a schema file: a package's schema.haus, or a file outside
// packages at its real path. missingWhy says why a missing one is missing.
func (c *fileCache) schemaText(path string, kind fileKind, missingWhy func() string) (string, error) {
	_, r := c.open(path, kind)
	switch r.state {
	case opened:
		return string(r.bytes), nil
	case missing:
		return "", notFound("%s", missingWhy())
	case notRegular:
		if kind == kindPackageSchema {
			return "", newError(haus.CodePackagePath, "%s is a symbolic link or not a regular file; it is not read", shown(path))
		}
		return "", notFound("%s is not a regular file", shown(path))
	case tooLarge:
		return "", tooLargeError(path, r.size)
	}
	return "", notFound("%s: %s", shown(path), r.err)
}

// source is a schema file an import names, read.
type source struct {
	path string // its real path: two imports reach the same file when it is the same
	text string
	pkg  *foundPackage // for a package's schema.haus
}

// foundPackage is a package, with its manifest checked.
type foundPackage struct {
	manifest     Manifest
	dir          string // its real path
	manifestText string // copies of a package have the same
}

// openPackageFor finds the package name for the file at from (a real path)
// with the locator and checks it: the manifest (package-manifest) and its
// name (import-not-found), its version (package-version), its files
// (package-path, file-too-large), and that a package found in a folder that
// the package manager has too is the same (duplicate-package).
func openPackageFor(packages Locator, name, from string, files *fileCache) (*source, error) {
	loc, err := packages.locate(name, from, files)
	if err != nil {
		return nil, err
	}
	src, err := openPackage(loc.Dir, name, loc.Version, loc.hasVersion, files)
	if err != nil {
		return nil, err
	}
	if loc.sameAs != "" {
		other, err := openPackage(loc.sameAs, name, "", false, files)
		if err != nil {
			return nil, err
		}
		a, b := src.pkg, other.pkg
		if a.dir != b.dir && (a.manifestText != b.manifestText || src.text != other.text) {
			return nil, duplicate(a.manifest, a.dir, b.manifest, b.dir)
		}
	}
	return src, nil
}

// openPackage reads the package in dir, which must be called name, with the
// version its package manager gives it, if any.
func openPackage(dir, name, version string, hasVersion bool, files *fileCache) (*source, error) {
	resolved, err := realPath(dir)
	if err != nil {
		return nil, notFound("%s: %v", shown(dir), err)
	}
	m, text, err := files.manifest(resolved)
	if err != nil {
		return nil, err
	}
	if m.Name != name {
		return nil, notFound("%s names the package %s, not %s", shown(filepath.Join(resolved, ManifestFile)), quote(m.Name), name)
	}
	if hasVersion && version != m.Version {
		if isSemver(version) {
			return nil, newError(haus.CodePackageVersion, "the package.haus of %s says version %s, its package manager %s (%s)",
				name, quote(m.Version), quote(version), shown(resolved))
		}
		return nil, newError(haus.CodePackageVersion, "the package.haus of %s says version %s, and the version its package "+
			"manager gives isn't a semantic version (%s)", name, quote(m.Version), shown(resolved))
	}
	path := filepath.Join(resolved, SchemaFile)
	schema, err := files.schemaText(path, kindPackageSchema, func() string {
		return fmt.Sprintf("%s has no %s next to its manifest (%s)", name, SchemaFile, shown(resolved))
	})
	if err != nil {
		return nil, err
	}
	return &source{path: path, text: schema, pkg: &foundPackage{manifest: m, dir: resolved, manifestText: text}}, nil
}

// openFile reads the file module (./common, ../shared/money) imports, next to
// the file at from (a real path; "" for a schema given as text, which
// imports no files). A package imports no files, and a file outside a
// package no file inside one (package-path). Each name in the path is
// spelled as its directory lists it, and the file's real path ends in
// .schema.haus (import-not-found, the file not read).
func openRelative(module, from string, files *fileCache) (*source, error) {
	if from == "" {
		return nil, newError(haus.CodeImportUnavailable, "a schema read from text imports no files (load it from its file)")
	}
	if pkg := packageDirOf(from); pkg != "" {
		name := shown(pkg)
		if m, _, err := files.manifest(pkg); err == nil {
			name = m.Name
		}
		return nil, newError(haus.CodePackagePath, "the schema of %s can't import files, only packages by name", name)
	}
	dir := filepath.Dir(from)
	relative := module + Extension
	path := filepath.Join(dir, filepath.FromSlash(relative))
	if name, ok := misspelled(dir, relative); ok {
		return nil, notFound("file not found: %s (no %s in its directory: names are spelled as the directory lists them)",
			shown(path), quote(name))
	}
	resolved, rerr := realPath(path)
	into := ""
	if rerr == nil {
		into = packageDirOf(resolved)
	}
	if into == "" {
		into = packageDirOf(path)
	}
	if into != "" {
		return nil, newError(haus.CodePackagePath, "the file is in the package directory %s: import the package by its name", shown(into))
	}
	if rerr != nil {
		return nil, notFound("file not found: %s", shown(path))
	}
	if !strings.HasSuffix(filepath.Base(resolved), Extension) {
		return nil, notFound("%s is not a schema file: its real path %s doesn't end in %s; it is not read",
			shown(path), shown(resolved), Extension)
	}
	text, err := files.schemaText(resolved, kindSchema, func() string { return "file not found: " + shown(path) })
	if err != nil {
		return nil, err
	}
	return &source{path: resolved, text: text}, nil
}

// misspelled returns the first name in relative (from dir) that its
// directory doesn't list byte for byte: on file systems that ignore case or
// Unicode normalization, ./Billing/common finds billing/common.schema.haus.
func misspelled(dir, relative string) (string, bool) {
	at := dir
	for _, part := range strings.Split(relative, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			at = filepath.Join(at, "..")
			continue
		}
		entries, err := os.ReadDir(at)
		if err != nil {
			// A directory that can't be listed: the file isn't found later.
			return "", false
		}
		listed := false
		for _, e := range entries {
			if e.Name() == part {
				listed = true
				break
			}
		}
		if !listed {
			return part, true
		}
		at = filepath.Join(at, part)
	}
	return "", false
}

// rootSource reads the root schema file at path: its real path and text. A
// package's schema.haus is read as one (never through a link).
func rootSource(path string, files *fileCache) (resolved, text string, err error) {
	resolved, err = realPath(path)
	if err != nil {
		return "", "", &haus.Error{Code: haus.CodeImportNotFound, Message: err.Error(), File: shown(path)}
	}
	kind := kindSchema
	if isPackageSchema(resolved) {
		kind = kindPackageSchema
	}
	text, err = files.schemaText(resolved, kind, func() string { return "file not found: " + shown(path) })
	if err != nil {
		return "", "", inFile(err, path)
	}
	return resolved, text, nil
}

// isPackageSchema reports whether the file at path is a package's
// schema.haus: next to a package.haus.
func isPackageSchema(path string) bool {
	return filepath.Base(path) == SchemaFile && exists(filepath.Join(filepath.Dir(path), ManifestFile))
}

// packageOfFile returns the package whose schema.haus is the file at path
// (a real path), if it is one, with its manifest checked.
func packageOfFile(path string, files *fileCache) (*foundPackage, error) {
	if !isPackageSchema(path) {
		return nil, nil
	}
	dir := filepath.Dir(path)
	m, text, err := files.manifest(dir)
	if err != nil {
		return nil, err
	}
	return &foundPackage{manifest: m, dir: dir, manifestText: text}, nil
}

// packageDirOf returns the package directory a file is in: the nearest
// directory above it with a manifest, or "".
func packageDirOf(path string) string {
	for d := filepath.Dir(path); ; {
		if exists(filepath.Join(d, ManifestFile)) {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return ""
		}
		d = parent
	}
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

// sameFiles reports whether the packages in a and b are copies of one
// package: their manifests and schema files are the same, byte for byte,
// and regular files (spec §13.3).
func sameFiles(a, b string) bool {
	read := func(dir string) ([]byte, []byte, bool) {
		m := readFile(filepath.Join(dir, ManifestFile), false, MaxManifest)
		s := readFile(filepath.Join(dir, SchemaFile), false, MaxFile)
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

func tooLargeError(path string, size int64) *haus.Error {
	return newError(haus.CodeFileTooLarge, "%s has %d bytes, more than 1 MiB; it is not read", shown(path), size)
}

// inFile sets the file of an error that has none.
func inFile(err error, path string) error {
	var e *haus.Error
	if errors.As(err, &e) && e.File == "" {
		c := *e
		c.File = shown(path)
		return &c
	}
	return err
}

// duplicate is duplicate-package: two packages with one name.
func duplicate(a Manifest, aDir string, b Manifest, bDir string) *haus.Error {
	copies := ""
	if a.Version == b.Version {
		copies = fmt.Sprintf(" (two copies of %s whose files or imports differ)", quote(a.Version))
	}
	return newError(haus.CodeDuplicatePackage, "two packages are called %s: %s in %s and %s in %s%s",
		quote(a.Name), quote(a.Version), shown(aDir), quote(b.Version), shown(bDir), copies)
}
