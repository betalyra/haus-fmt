package schema

import (
	"fmt"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
)

// The files of a schema package (spec §13.3).
const (
	// ManifestFile is a schema package's manifest: { name, version }.
	ManifestFile = "package.haus"
	// SchemaFile is a schema package's one schema file, next to its manifest.
	SchemaFile = "schema.haus"
	// Extension is the extension of schema files, always added to relative
	// imports: import ./common reads common.schema.haus.
	Extension = ".schema.haus"
)

// Manifest is a schema package's package.haus: { name: "@haus-fmt/money",
// version: "1.2.0" }. Other fields are ignored.
type Manifest struct {
	Name    string
	Version string
}

// Major returns the major version: "1" for 1.2.0.
func (m Manifest) Major() string {
	major, _, _ := strings.Cut(m.Version, ".")
	return major
}

// ID returns the package's id (spec §13.3): @haus-fmt/money@1.
func (m Manifest) ID() string { return m.Name + "@" + m.Major() }

// ParseManifest reads a manifest: one record with a string name that is a
// package name (@org/name in lowercase) and a string version that is a
// semantic version. It fails with the code package-manifest.
func ParseManifest(text []byte) (Manifest, error) {
	m, why := parseManifest(text)
	if why != "" {
		return Manifest{}, &haus.Error{Code: haus.CodePackageManifest, Message: why}
	}
	return m, nil
}

func parseManifest(text []byte) (m Manifest, why string) {
	if len(text) > MaxManifest {
		return Manifest{}, fmt.Sprintf("the manifest has %d bytes, more than 64 KiB", len(text))
	}
	values, err := haus.ParseAll(text)
	if err != nil {
		return Manifest{}, "the manifest is not valid haus: " + err.Error()
	}
	var rec haus.Record
	if len(values) == 1 {
		rec, _ = values[0].(haus.Record)
	}
	if len(values) != 1 || values[0].Kind() != haus.KindRecord {
		return Manifest{}, `a manifest is one record: { name: "@org/name", version: "1.0.0" }`
	}
	field := func(key string) (string, bool) {
		v, _ := rec.Get(key)
		s, ok := v.(haus.String)
		return string(s), ok
	}
	name, ok := field("name")
	if !ok {
		return Manifest{}, "the manifest needs a string field name"
	}
	version, ok := field("version")
	if !ok {
		return Manifest{}, "the manifest needs a string field version"
	}
	if !isPackageName(name) {
		return Manifest{}, `"` + quote(name) + fmt.Sprintf(`" is not a package name: @org/name in lowercase, each part starting with a letter or digit, `+
			"made of a-z, 0-9, -, . and _, and not node_modules, at most %d characters", maxName)
	}
	if !isSemver(version) {
		return Manifest{}, `"` + quote(version) + `" is not a semantic version, like 1.2.0`
	}
	return Manifest{Name: name, Version: version}, ""
}

// maxName is the longest package name (npm's limit).
const maxName = 214

// isPackageName reports whether name is @org/name (spec §13.3): npm's rules
// for scoped names in lowercase.
func isPackageName(name string) bool {
	segment := func(s string) bool {
		if s == "" || s == "node_modules" || !isLower(s[0]) && !isDigit(s[0]) {
			return false
		}
		for i := 0; i < len(s); i++ {
			if c := s[i]; !isLower(c) && !isDigit(c) && c != '-' && c != '.' && c != '_' {
				return false
			}
		}
		return true
	}
	rest, ok := strings.CutPrefix(name, "@")
	if !ok || len(name) > maxName {
		return false
	}
	org, pkg, ok := strings.Cut(rest, "/")
	return ok && segment(org) && segment(pkg)
}

// isSemver reports whether version is a semantic version (SemVer 2.0):
// 1.2.0, 1.0.0-rc.1+build.5.
func isSemver(version string) bool {
	number := func(s string) bool {
		if s == "" || len(s) > 1 && s[0] == '0' {
			return false
		}
		for i := 0; i < len(s); i++ {
			if !isDigit(s[i]) {
				return false
			}
		}
		return true
	}
	ident := func(s string) bool {
		if s == "" {
			return false
		}
		for i := 0; i < len(s); i++ {
			if c := s[i]; (!isWord(c) || c == '_') && c != '-' {
				return false
			}
		}
		return true
	}
	allDigits := func(s string) bool {
		for i := 0; i < len(s); i++ {
			if !isDigit(s[i]) {
				return false
			}
		}
		return true
	}
	rest, build, hasBuild := strings.Cut(version, "+")
	core, pre, hasPre := strings.Cut(rest, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if !number(p) {
			return false
		}
	}
	if hasPre {
		for _, id := range strings.Split(pre, ".") {
			if !ident(id) || allDigits(id) && !number(id) {
				return false
			}
		}
	}
	if hasBuild {
		for _, id := range strings.Split(build, ".") {
			if !ident(id) {
				return false
			}
		}
	}
	return true
}

// quote returns text from a file for a message (spec §9.2): control and
// bidirectional characters escaped as \u{…}, at most 40 characters, cut
// with an ellipsis.
func quote(text string) string {
	const maxChars = 40
	var pieces []string
	total := 0
	for i, r := range text {
		if r == utf8.RuneError {
			if _, size := utf8.DecodeRuneInString(text[i:]); size == 1 {
				r = 0xFFFD
			}
		}
		piece := string(r)
		if isControlOrBidi(r) {
			piece = fmt.Sprintf(`\u{%X}`, r)
		}
		pieces = append(pieces, piece)
		total += utf8.RuneCountInString(piece)
		if total > maxChars {
			break
		}
	}
	if total <= maxChars {
		return strings.Join(pieces, "")
	}
	var b strings.Builder
	used := 0
	for _, piece := range pieces {
		n := utf8.RuneCountInString(piece)
		if used+n > maxChars-1 {
			break
		}
		b.WriteString(piece)
		used += n
	}
	b.WriteString("…")
	return b.String()
}

func isControlOrBidi(r rune) bool {
	return r < 0x20 || r >= 0x7f && r <= 0x9f || r == 0x61c || r == 0x200e || r == 0x200f ||
		r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 || r == 0x2028 || r == 0x2029
}

// quoteKey writes a key as data writes it: bare if it can be, else quoted.
func quoteKey(k string) string {
	if isIdent(k) {
		return k
	}
	s, _ := haus.Canonical(haus.String(k))
	return quote(s)
}

// isIdent reports whether k is a bare key: [a-z_][A-Za-z0-9_]*.
func isIdent(k string) bool {
	if k == "" || !isLower(k[0]) && k[0] != '_' {
		return false
	}
	for i := 1; i < len(k); i++ {
		if !isWord(k[i]) {
			return false
		}
	}
	return true
}
