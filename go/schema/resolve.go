package schema

import (
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
)

// A schema file with its imports: names looked up, generic types applied,
// and every rule of spec §14 checked. Generic types are applied by
// instantiating them (List Int is a type of its own), which ends because no
// type parameter passes, inside a bigger type, along a cycle of references
// back to itself (§9.10, the expansive-cycle rule); a limit on the number of
// instances is a second guard.

// maxInstances bounds the instances of generic types one schema makes.
const maxInstances = 10_000

// generic is the prelude's types with parameters, and how many.
var generic = map[string]int{"Array": 1, "Map": 1, "Maybe": 1, "Result": 2, "Secret": 1, "Stream": 1}

// Options say how to load a schema.
type Options struct {
	// Packages finds the packages imports name (spec §13.3): [NodeModules],
	// an [*Explicit] set, or both with [Or]. Nil finds none: a schema that
	// imports a package fails with the code import-unavailable.
	Packages Locator
	// ID is the root file's id, for the ids of its types (shop/order gives
	// shop/order#Order). Default: from its manifest for a package's
	// schema.haus, else as for any file outside packages.
	ID string
	// Project and ProjectDir set the ids of files outside packages:
	// Project "shop" and ProjectDir dir give dir/src/common.schema.haus the
	// id shop/src/common. Default: the path from the root file's directory.
	Project, ProjectDir string
	// WithoutAttributes leaves out the attributes of every file, as if they
	// weren't written: decoding is the same (spec §15). For tests of that.
	WithoutAttributes bool
}

// Definition is a type definition of the schema file, its own or imported.
type Definition struct {
	// Name is its name in the file (imported types keep their names).
	Name string
	// ID is its id (spec §13.3): @haus-fmt/money@1#Money, file-id#Name.
	ID string
	// Params are its type parameters.
	Params []string
	// Doc is the // comment lines just above it.
	Doc string
	// Deprecated is set for @deprecated, with its message in Why.
	Deprecated bool
	Why        string
	template   *instance
}

// Package is a schema package a schema reaches, directly or through other
// packages.
type Package struct {
	Name    string // @haus-fmt/money
	Version string // the version of its manifest: 1.2.0
	Dir     string // its directory, a real path
}

// Schema is a schema file, its imports resolved and every rule of spec §14
// and §13.3 checked. Its types decode and encode values (spec §15). A Schema
// is immutable and safe for concurrent use.
type Schema struct {
	definitions []Definition // the file's own, in source order, then the imported ones by name
	own         int
	byName      map[string]int
	warnings    []*haus.Error
	packages    []Package
}

// Parse reads a schema from text. Its relative imports fail with the code
// import-unavailable, as it has no place among files; packages are found by
// opts.Packages.
func Parse(src []byte, opts Options) (*Schema, error) {
	l := newLoader(&opts, newFileCache())
	return l.run(string(src), "")
}

// Load reads the schema file at path, its relative imports next to it and
// the packages it imports found by opts.Packages. Errors in an imported
// file are reported at the import, with their place in that file.
func Load(path string, opts Options) (*Schema, error) {
	files := newFileCache()
	resolved, text, err := rootSource(path, files)
	if err != nil {
		return nil, err
	}
	l := newLoader(&opts, files)
	s, err := l.run(text, resolved)
	if err != nil {
		return nil, inFile(err, path)
	}
	return s, nil
}

// Definitions returns the file's own definitions, in source order.
func (s *Schema) Definitions() []Definition { return slices.Clone(s.definitions[:s.own]) }

// Imported returns the types the file imports from packages and files (not
// std/time), by the name they have in it.
func (s *Schema) Imported() []Definition { return slices.Clone(s.definitions[s.own:]) }

// Packages returns every schema package the schema reaches, by name.
func (s *Schema) Packages() []Package { return slices.Clone(s.packages) }

// Warnings returns what to point out in the file (not in the files it
// imports), in source order: attributes this version doesn't define
// (unknown-attribute), uses of deprecated types (deprecated), and record
// cases with no schema-based JSON form (no-json-form, spec §16.3).
func (s *Schema) Warnings() []*haus.Error { return slices.Clone(s.warnings) }

// ── loading ──────────────────────────────────────────────────

type defRef struct{ u, d int }

// origin is where a file was first imported: the importing file, the
// import's offset there, the module as written.
type origin struct {
	unit  int
	pos   int
	label string
}

// unit is one schema file: the root, or one it imports.
type unit struct {
	text   string
	file   *file
	path   string // its real path; "" for a schema given as text
	pkg    string // the package's name, for a package's schema.haus
	id     string
	origin *origin
	own    map[string]int    // its own definitions: what other files can import
	scope  map[string]defRef // every named type in scope, its own and imported ones
	std    map[string]string // the types imported from std/time
}

// fail is a mistake at an offset of a file.
type fail struct {
	unit int
	pos  int
	code haus.ErrorCode
	msg  string
}

func (f *fail) Error() string { return f.msg }

func failIn(u, pos int, code haus.ErrorCode, format string, args ...any) *fail {
	return &fail{unit: u, pos: pos, code: code, msg: fmt.Sprintf(format, args...)}
}

// reached is a package a schema reaches: one per name.
type reached struct {
	path string // its schema.haus
	pkg  *foundPackage
	text string
}

type state uint8

const (
	stateNew state = iota
	stateBusy
	stateDone
)

type refAt struct {
	inst *instance
	unit int
	pos  int
}

type loader struct {
	opts      *Options
	packages  Locator
	units     []*unit
	byPath    map[string]int
	reached   map[string]*reached
	base      string // ids of files outside packages: a prefix
	baseDir   string // and the directory their paths start from
	hasBase   bool
	loading   []int
	files     *fileCache
	copies    map[string]bool
	instances []*instance
	defOf     []defRef
	states    []state
	byKey     map[string]int
	// The key of each record's and variant's shape, and of each record and
	// variant: see key.
	shapes  map[string]string
	recKeys map[*recordType]string
	vrtKeys map[*variantType]string
	queue   []int
	refs    []refAt
}

func newLoader(opts *Options, files *fileCache) *loader {
	return &loader{
		opts:     opts,
		packages: locatorOf(opts.Packages),
		byPath:   map[string]int{},
		reached:  map[string]*reached{},
		files:    files,
		copies:   map[string]bool{},
		byKey:    map[string]int{},
		shapes:   map[string]string{},
		recKeys:  map[*recordType]string{},
		vrtKeys:  map[*variantType]string{},
	}
}

// lineCol returns the 1-based line and column (in code points) of a byte
// offset of text (spec §8).
func lineCol(text string, pos int) (line, col int) {
	pos = min(pos, len(text))
	before := text[:pos]
	start := strings.LastIndexByte(before, '\n') + 1
	return 1 + strings.Count(before, "\n"), 1 + utf8.RuneCountInString(before[start:])
}

// lift turns a mistake in a file into an error of the root file: errors
// inside an imported file are reported at the import, with their place in
// that file.
func (l *loader) lift(f *fail) *haus.Error {
	for {
		u := l.units[f.unit]
		line, col := lineCol(u.text, f.pos)
		if u.origin == nil {
			return &haus.Error{Code: f.code, Message: f.msg, Line: line, Column: col}
		}
		f = &fail{unit: u.origin.unit, pos: u.origin.pos, code: f.code,
			msg: fmt.Sprintf("%s (%d:%d): %s", u.origin.label, line, col, f.msg)}
	}
}

func (l *loader) run(text, path string) (*Schema, error) {
	var pkg *foundPackage
	if path != "" {
		var err error
		if pkg, err = packageOfFile(path, l.files); err != nil {
			return nil, err
		}
	}
	switch {
	case l.opts.Project != "":
		dir := l.opts.ProjectDir
		if resolved, err := realPath(dir); err == nil {
			dir = resolved
		}
		l.base, l.baseDir, l.hasBase = l.opts.Project+"/", dir, true
	case path != "":
		l.base, l.baseDir, l.hasBase = "", filepath.Dir(path), true
	}
	id := l.opts.ID
	switch {
	case id != "":
	case pkg != nil:
		id = pkg.manifest.ID()
	case path != "":
		id = l.appID(path)
	}
	name := ""
	if pkg != nil {
		name = pkg.manifest.Name
		l.reached[name] = &reached{path: path, pkg: pkg, text: text}
	}
	root, err := l.load(text, path, name, id, nil)
	if err != nil {
		return nil, err
	}
	if f := l.evaluateAll(); f != nil {
		return nil, l.lift(f)
	}
	return l.schema(root), nil
}

// schema builds the result for the root file.
func (l *loader) schema(root int) *Schema {
	u := l.units[root]
	s := &Schema{byName: map[string]int{}}
	for d, def := range u.file.types {
		s.definitions = append(s.definitions, l.definition(def.name, defRef{root, d}))
	}
	s.own = len(s.definitions)
	var imported []string
	for name, at := range u.scope {
		if at.u != root {
			imported = append(imported, name)
		}
	}
	slices.Sort(imported)
	for _, name := range imported {
		s.definitions = append(s.definitions, l.definition(name, u.scope[name]))
	}
	for i, d := range s.definitions {
		s.byName[d.Name] = i
	}
	for _, w := range u.file.warnings {
		line, col := lineCol(u.text, w.pos)
		s.warnings = append(s.warnings, &haus.Error{Code: w.code, Message: w.msg, Line: line, Column: col})
	}
	s.warnings = append(s.warnings, l.noJSONForms(root)...)
	slices.SortStableFunc(s.warnings, func(a, b *haus.Error) int {
		if a.Line != b.Line {
			return a.Line - b.Line
		}
		return a.Column - b.Column
	})
	names := make([]string, 0, len(l.reached))
	for name := range l.reached {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		r := l.reached[name]
		s.packages = append(s.packages, Package{Name: name, Version: r.pkg.manifest.Version, Dir: r.pkg.dir})
	}
	return s
}

func (l *loader) definition(name string, at defRef) Definition {
	def := l.units[at.u].file.types[at.d]
	why, _ := deprecation(def.attrs)
	return Definition{
		Name:       name,
		ID:         l.defID(at.u, at.d),
		Params:     slices.Clone(def.params),
		Doc:        def.doc,
		Deprecated: isDeprecated(def.attrs),
		Why:        why,
		template:   l.instances[l.byKey[templateKey(at.u, at.d, def.params)]],
	}
}

// appID is the id of a file outside packages (spec §13.3): different for
// different files.
func (l *loader) appID(path string) string {
	if l.hasBase {
		return l.base + relativeID(l.baseDir, path)
	}
	return filepath.ToSlash(path)
}

func (l *loader) defID(u, d int) string {
	name := l.units[u].file.types[d].name
	if id := l.units[u].id; id != "" {
		return id + "#" + name
	}
	return name
}

// load parses a file, loads its imports and builds its scope.
func (l *loader) load(text, path, pkg, id string, from *origin) (int, error) {
	f, serr := parseFile(text)
	if serr != nil {
		line, col := lineCol(text, serr.pos)
		if from == nil {
			return 0, &haus.Error{Code: serr.code, Message: serr.msg, Line: line, Column: col}
		}
		return 0, l.lift(&fail{unit: from.unit, pos: from.pos, code: serr.code,
			msg: fmt.Sprintf("%s (%d:%d): %s", from.label, line, col, serr.msg)})
	}
	if l.opts.WithoutAttributes {
		withoutAttributes(f)
	}
	u := len(l.units)
	if path != "" {
		l.byPath[path] = u
	}
	l.units = append(l.units, &unit{text: text, file: f, path: path, pkg: pkg, id: id, origin: from,
		own: map[string]int{}, scope: map[string]defRef{}, std: map[string]string{}})
	l.loading = append(l.loading, u)
	err := l.imports(u)
	l.loading = l.loading[:len(l.loading)-1]
	if err != nil {
		return 0, err
	}
	if f := l.ownTypes(u); f != nil {
		return 0, l.lift(f)
	}
	return u, nil
}

func (l *loader) imports(u int) error {
	for _, imp := range l.units[u].file.imports {
		at := func(code haus.ErrorCode, format string, args ...any) error {
			return l.lift(failIn(u, imp.pos, code, format, args...))
		}
		if module, ok := strings.CutPrefix(imp.module, "std/"); ok {
			names := make([]string, len(imp.names))
			for i, n := range imp.names {
				names[i] = n.name
			}
			switch module {
			case "money":
				return at(haus.CodeUnknownModule, "std/money is no longer a standard module; it is the package "+
					"@haus-fmt/money: import @haus-fmt/money (%s)", strings.Join(names, ", "))
			case "time":
			default:
				return at(haus.CodeUnknownModule, "unknown standard module %s (there is std/time)", quote(imp.module))
			}
			for _, n := range imp.names {
				if !stdTime[n.name] {
					return l.lift(failIn(u, n.pos, haus.CodeUnknownImport,
						"std/time has no type %s (it has Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone)", n.name))
				}
				if err := l.bring(u, n, nil, n.name); err != nil {
					return err
				}
			}
			continue
		}
		isModule := strings.HasPrefix(imp.module, "@") && strings.Contains(imp.module, "/") ||
			strings.HasPrefix(imp.module, "./") || strings.HasPrefix(imp.module, "../")
		if !isModule {
			return at(haus.CodeUnknownModule, "unknown module %s: import std/…, a package @org/name or a file ./name", quote(imp.module))
		}
		dep, err := l.importFrom(u, imp.pos, imp.module, imp.module, l.units[u].path)
		if err != nil {
			return err
		}
		for _, n := range imp.names {
			d, ok := l.units[dep].own[n.name]
			if !ok {
				var has []string
				for _, t := range l.units[dep].file.types {
					has = append(has, t.name)
				}
				list := ""
				if len(has) > 0 {
					list = " (it has " + strings.Join(has, ", ") + ")"
				}
				return l.lift(failIn(u, n.pos, haus.CodeUnknownImport, "%s has no type %s%s", quote(imp.module), n.name, list))
			}
			if err := l.bring(u, n, &defRef{dep, d}, ""); err != nil {
				return err
			}
		}
	}
	return nil
}

// bring puts an imported name in scope, once.
func (l *loader) bring(u int, n nameAt, def *defRef, std string) error {
	unit := l.units[u]
	_, inScope := unit.scope[n.name]
	_, inStd := unit.std[n.name]
	if inScope || inStd {
		return l.lift(failIn(u, n.pos, haus.CodeDuplicateImport, "%s is imported twice", n.name))
	}
	if def != nil {
		unit.scope[n.name] = *def
	}
	if std != "" {
		unit.std[n.name] = std
	}
	return nil
}

// importFrom loads the file module names for the file at from; errors are
// reported at the offset pos of unit u, for the import label.
func (l *loader) importFrom(u, pos int, module, label, from string) (int, error) {
	at := func(code haus.ErrorCode, format string, args ...any) error {
		return l.lift(failIn(u, pos, code, format, args...))
	}
	// @org/name@2: the package, and the major version wanted.
	name, wanted := module, ""
	if strings.HasPrefix(module, "@") {
		if i := strings.LastIndexByte(module, '@'); i > 1 && i < len(module)-1 && allDigits(module[i+1:]) {
			name, wanted = module[:i], module[i+1:]
		}
	}
	var (
		found *source
		err   error
	)
	if strings.HasPrefix(name, "@") {
		found, err = openPackageFor(l.packages, name, from, l.files)
	} else {
		found, err = openRelative(name, from, l.files)
	}
	if err != nil {
		return 0, at(codeOf(err), "can't import %s: %s", label, messageOf(err))
	}
	if wanted != "" && found.pkg != nil && found.pkg.manifest.Major() != wanted {
		return 0, at(haus.CodeImportVersion, "%s wants major version %s, but version %s was found",
			label, wanted, quote(found.pkg.manifest.Version))
	}
	// One package per name (spec §13.3): copies with the same files, whose
	// imports reach the same packages, are one.
	path, copyPath := found.path, ""
	if found.pkg != nil {
		if old, ok := l.reached[found.pkg.manifest.Name]; ok {
			switch {
			case old.path == found.path:
				path = old.path
			case old.pkg.manifestText == found.pkg.manifestText && old.text == found.text:
				copyPath, path = found.path, old.path
			default:
				e := duplicate(old.pkg.manifest, old.pkg.dir, found.pkg.manifest, found.pkg.dir)
				return 0, at(e.Code, "can't import %s: %s", label, e.Message)
			}
		}
	}
	for _, v := range l.loading {
		if l.units[v].path == path {
			return 0, at(haus.CodeImportCycle, "import cycle: %s imports this file again", label)
		}
	}
	if cached, ok := l.byPath[path]; ok {
		if copyPath != "" {
			if err := l.copyImports(u, pos, label, cached, copyPath); err != nil {
				return 0, err
			}
		}
		return cached, nil
	}
	if len(l.units)+len(l.copies) >= MaxFiles {
		return 0, at(haus.CodeTooManyFiles, "more than %d schema files are imported", MaxFiles)
	}
	o := &origin{unit: u, pos: pos, label: label}
	if found.pkg != nil {
		name := found.pkg.manifest.Name
		l.reached[name] = &reached{path: path, pkg: found.pkg, text: found.text}
		return l.load(found.text, path, name, found.pkg.manifest.ID(), o)
	}
	return l.load(found.text, path, "", l.appID(path), o)
}

func allDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isDigit(s[i]) {
			return false
		}
	}
	return s != ""
}

// copyImports resolves the imports of a copy of a package (its schema.haus
// at copyPath), identical to the package loaded as original, from the
// copy's place: they must reach the same packages (spec §13.3).
func (l *loader) copyImports(u, pos int, label string, original int, copyPath string) error {
	if l.copies[copyPath] {
		return nil
	}
	l.copies[copyPath] = true
	if len(l.units)+len(l.copies) > MaxFiles {
		return l.lift(failIn(u, pos, haus.CodeTooManyFiles, "more than %d schema files are imported", MaxFiles))
	}
	dir := shown(filepath.Dir(copyPath))
	for _, imp := range l.units[original].file.imports {
		if !strings.HasPrefix(imp.module, "@") {
			continue
		}
		label := fmt.Sprintf("%s (its copy in %s imports %s)", label, dir, imp.module)
		if _, err := l.importFrom(u, pos, imp.module, label, copyPath); err != nil {
			return err
		}
	}
	return nil
}

// ownTypes puts the file's own definitions in scope, unless a name is also
// imported, and checks that generic ones can't grow without bound (§9.10).
func (l *loader) ownTypes(u int) *fail {
	unit := l.units[u]
	for d, def := range unit.file.types {
		_, inScope := unit.scope[def.name]
		_, inStd := unit.std[def.name]
		if inScope || inStd {
			return failIn(u, def.pos, haus.CodeDuplicateType, "type %s is already imported", def.name)
		}
		unit.own[def.name] = d
	}
	for d, def := range unit.file.types {
		unit.scope[def.name] = defRef{u, d}
	}
	return l.growth(u)
}

// growth checks §9.10, the expansive-cycle rule: no type parameter passes,
// inside a bigger type, along a cycle of references back to itself (see
// [growthGraph]). The first expanding edge on a cycle is reported, at its
// reference: definitions in order, references in body order (outermost
// first), then by argument. Checked on the definitions as written, before
// anything is instantiated. Cycles are within one file: imports have no
// cycles.
func (l *loader) growth(u int) *fail {
	g := newGrowthGraph(l.units[u])
	component := components(g.edges)
	for _, p := range g.passes {
		to := g.first[p.to] + p.index
		if p.from < 0 || component[p.from] != component[to] {
			continue
		}
		// The first parameter in the argument that the cycle comes back to.
		back := -1
		walkTy(p.arg, func(t *ty) {
			if t.kind != tyParam || back >= 0 {
				return
			}
			if a := g.param(p.def, t.name); a >= 0 && component[a] == component[to] {
				back = a
			}
		})
		if back >= 0 {
			return failIn(u, p.pos, haus.CodeGrowingRecursion, "%s", g.growing(back, to, component))
		}
	}
	return nil
}

// growthGraph is the parameter graph of §9.10 for one file. It has a node
// per type parameter of every definition, and for each reference B t₁ … tₙ
// in the body of a definition A to a definition B of the file (not one of
// the prelude's), an edge from each parameter a of A occurring in tᵢ to the
// i-th parameter of B: expanding unless tᵢ is a itself. A schema in which an
// expanding edge lies on a cycle could have instances that grow without
// bound (type T a = < X (T (Pair a a)) >).
//
// It is built in linear time: rather than an edge per occurrence of a
// parameter (a nested in n references would count n times), an argument with
// several parameters gets a node of its own that they flow into, so that the
// node of tᵢ reaches exactly the parameters occurring in it, and the edge
// from it stands for the edges of all of them. Paths between parameters, and
// so cycles, are those of the parameter graph.
type growthGraph struct {
	unit  *unit
	types []*typeDef
	first []int // node first[d] + p is parameter p of definition d
	owner []int // per parameter node: its definition
	// The parameter nodes, then the nodes of arguments with several parameters.
	edges [][]int
	// The arguments other than a bare parameter, each passed to a definition
	// of the file, in the order they are checked.
	passes []growthPass
}

// growthPass is an argument other than a bare parameter passed to a
// definition of the file: the P a a of B (P a a).
type growthPass struct {
	def, pos  int // the definition the reference is in, and where
	to, index int // the definition referred to, and which of its parameters the argument is for
	arg       *ty
	from      int // the node of the argument's parameters; -1 if it has none
}

func newGrowthGraph(unit *unit) *growthGraph {
	g := &growthGraph{unit: unit, types: unit.file.types}
	for d, def := range g.types {
		g.first = append(g.first, len(g.owner))
		for range def.params {
			g.owner = append(g.owner, d)
		}
	}
	g.edges = make([][]int, len(g.owner))
	for d, def := range g.types {
		g.flow(d, def.ty)
	}
	return g
}

// callee is the definition of the file name refers to; -1 if it isn't one
// (the prelude's generic types come first).
func (g *growthGraph) callee(name string) int {
	if _, ok := generic[name]; ok {
		return -1
	}
	if d, ok := g.unit.own[name]; ok {
		return d
	}
	return -1
}

// param is the node of parameter name of definition d; -1 if it has none.
func (g *growthGraph) param(d int, name string) int {
	if p := slices.Index(g.types[d].params, name); p >= 0 {
		return g.first[d] + p
	}
	return -1
}

// flow adds the edges of the references in t, in definition d, and returns
// the node that the parameters occurring in t flow into; -1 if none do.
func (g *growthGraph) flow(d int, t *ty) int {
	var nodes []int
	add := func(n int) {
		if n >= 0 {
			nodes = append(nodes, n)
		}
	}
	switch t.kind {
	case tyParam:
		return g.param(d, t.name)
	case tyName:
		to, n := g.callee(t.name), 0
		if to >= 0 {
			n = min(len(t.args), len(g.types[to].params))
		}
		// This reference's arguments are checked before those of the
		// references inside them.
		start := len(g.passes)
		var nested []int
		for i, a := range t.args[:n] {
			if a.kind != tyParam {
				nested = append(nested, i)
				g.passes = append(g.passes, growthPass{def: d, pos: t.pos, to: to, index: i, arg: a, from: -1})
			}
		}
		argNodes := make([]int, len(t.args))
		for i, a := range t.args {
			argNodes[i] = g.flow(d, a)
			add(argNodes[i])
		}
		for i, node := range argNodes[:n] {
			if node >= 0 {
				g.edges[node] = append(g.edges[node], g.first[to]+i)
			}
		}
		for k, i := range nested {
			g.passes[start+k].from = argNodes[i]
		}
	case tyRecord:
		for _, f := range t.fields {
			add(g.flow(d, f.ty))
		}
	case tyVariant:
		for _, c := range t.cases {
			for _, p := range c.payload {
				add(g.flow(d, p))
			}
		}
	}
	return g.join(nodes)
}

// join returns one node for nodes: -1 for none, the node for one (or the
// same one again), otherwise a new node they all flow into.
func (g *growthGraph) join(nodes []int) int {
	if len(nodes) == 0 {
		return -1
	}
	one := nodes[0]
	if !slices.ContainsFunc(nodes, func(n int) bool { return n != one }) {
		return one
	}
	joined := len(g.edges)
	g.edges = append(g.edges, nil)
	for _, n := range nodes {
		g.edges[n] = append(g.edges[n], joined)
	}
	return joined
}

// growing is the message for parameter node a passed, inside a bigger type,
// to parameter node to, from where it comes back to a.
func (g *growthGraph) growing(a, to int, component []int) string {
	def, b := g.owner[a], g.owner[to]
	name, param := g.types[def].name, g.types[def].params[a-g.first[def]]
	if a == to {
		return fmt.Sprintf("%s passes its parameter %s to itself inside a bigger type: instances could grow without bound", name, param)
	}
	target := g.types[b].name
	if b == def {
		target = "itself"
	}
	names := []string{name, g.types[b].name}
	for _, n := range g.way(to, a, component) {
		names = append(names, g.types[g.owner[n]].name)
	}
	return fmt.Sprintf("%s passes its parameter %s to %s inside a bigger type, and it comes back (%s): instances could grow without bound",
		name, param, target, strings.Join(names, " → "))
}

// way is a shortest way along the parameter graph's edges from parameter
// node from to to in the same component: the nodes after from (a
// breadth-first search, each node's edges in the order of its references).
// It is only for a message, so it builds the edges between parameters
// itself.
func (g *growthGraph) way(from, to int, component []int) []int {
	edges := make([][]int, len(g.owner))
	for d, def := range g.types {
		walkTy(def.ty, func(t *ty) {
			if t.kind != tyName {
				return
			}
			b := g.callee(t.name)
			if b < 0 {
				return
			}
			for i, arg := range t.args[:min(len(t.args), len(g.types[b].params))] {
				walkTy(arg, func(x *ty) {
					if x.kind != tyParam {
						return
					}
					if p := g.param(d, x.name); p >= 0 {
						edges[p] = append(edges[p], g.first[b]+i)
					}
				})
			}
		})
	}
	before := make([]int, len(edges))
	for i := range before {
		before[i] = -1
	}
	queue := []int{from}
	for len(queue) > 0 {
		n := queue[0]
		queue = queue[1:]
		if n == to {
			break
		}
		for _, m := range edges[n] {
			if m != from && before[m] < 0 && component[m] == component[from] {
				before[m] = n
				queue = append(queue, m)
			}
		}
	}
	var way []int
	for n := to; before[n] >= 0; n = before[n] {
		way = append(way, n)
	}
	slices.Reverse(way)
	return way
}

// components returns the strongly connected component of each node of a
// graph, the edges of node n in edges[n] (Tarjan's algorithm, with a stack of
// its own rather than recursion).
func components(edges [][]int) []int {
	n := len(edges)
	index, low, component := make([]int, n), make([]int, n), make([]int, n)
	for i := range n {
		index[i], component[i] = -1, -1
	}
	type frame struct{ node, next int }
	var stack []int
	var work []frame
	visited, count := 0, 0
	visit := func(v int) {
		index[v], low[v] = visited, visited
		visited++
		stack = append(stack, v)
		work = append(work, frame{v, 0})
	}
	for start := range n {
		if index[start] >= 0 {
			continue
		}
		visit(start)
		for len(work) > 0 {
			top := &work[len(work)-1]
			v := top.node
			if top.next < len(edges[v]) {
				w := edges[v][top.next]
				top.next++
				if index[w] < 0 {
					visit(w)
				} else if component[w] < 0 {
					low[v] = min(low[v], index[w])
				}
				continue
			}
			work = work[:len(work)-1]
			if len(work) > 0 {
				parent := work[len(work)-1].node
				low[parent] = min(low[parent], low[v])
			}
			if low[v] == index[v] {
				for {
					w := stack[len(stack)-1]
					stack = stack[:len(stack)-1]
					component[w] = count
					if w == v {
						break
					}
				}
				count++
			}
		}
	}
	return component
}

// walkTy calls f on every type expression in t, outermost first.
func walkTy(t *ty, f func(*ty)) {
	f(t)
	for _, a := range t.args {
		walkTy(a, f)
	}
	for _, fd := range t.fields {
		walkTy(fd.ty, f)
	}
	for _, c := range t.cases {
		for _, a := range c.payload {
			walkTy(a, f)
		}
	}
}

// ── evaluation ───────────────────────────────────────────────

// evaluateAll evaluates every definition of every file (templates for
// generic ones), so that all errors surface, then checks references to
// streams and that every cycle of definitions consumes input (§9.9).
func (l *loader) evaluateAll() *fail {
	for u, unit := range l.units {
		for d, def := range unit.file.types {
			args := make([]*typ, len(def.params))
			for i, p := range def.params {
				args[i] = &typ{kind: kParam, name: p}
			}
			if _, f := l.instance(u, d, args, u, def.pos); f != nil {
				return f
			}
			for len(l.queue) > 0 {
				id := l.queue[0]
				l.queue = l.queue[1:]
				if f := l.evaluateInstance(id); f != nil {
					return f
				}
			}
		}
	}
	for _, r := range l.refs {
		if r.inst.stream {
			return failIn(r.unit, r.pos, haus.CodeMisplacedStream,
				"%s is a Stream; a stream can only be the whole file, not part of a type", r.inst.name)
		}
	}
	// §9.9: every cycle passes through a record, array or variant (Secret is no step).
	for start, inst := range l.instances {
		seen := map[*instance]bool{}
		t := inst.body
		for t.kind == kRef || t.kind == kSecret {
			if t.kind == kSecret {
				t = t.elem
				continue
			}
			if seen[t.inst] {
				at := l.defOf[start]
				return failIn(at.u, l.units[at.u].file.types[at.d].pos, haus.CodeUnguardedRecursion,
					"type %s refers to itself without a record, array or variant in between", inst.name)
			}
			seen[t.inst] = true
			t = t.inst.body
		}
	}
	for _, inst := range l.instances {
		t := inst.body
		for t.kind == kRef {
			t = t.inst.body
		}
		inst.resolved = t
	}
	l.markJSONNull()
	return nil
}

// templateKey is the key of a definition's template instance.
func templateKey(u, d int, params []string) string {
	if len(params) == 0 {
		return fmt.Sprintf("%d:%d", u, d)
	}
	keys := make([]string, len(params))
	for i, p := range params {
		keys[i] = "'" + p
	}
	return fmt.Sprintf("%d:%d(%s)", u, d, strings.Join(keys, ","))
}

// instance returns the instance of definition d of file u with args,
// created if new. at and pos are where it is used, for errors.
func (l *loader) instance(u, d int, args []*typ, at, pos int) (*instance, *fail) {
	key := fmt.Sprintf("%d:%d", u, d)
	if len(args) > 0 {
		keys := make([]string, len(args))
		for i, a := range args {
			keys[i] = l.key(a)
		}
		key += "(" + strings.Join(keys, ",") + ")"
	}
	if id, ok := l.byKey[key]; ok {
		return l.instances[id], nil
	}
	if len(l.instances) >= maxInstances {
		return nil, failIn(at, pos, haus.CodeGrowingRecursion,
			"more than %d type instances: a generic type grows without bound", maxInstances)
	}
	id := len(l.instances)
	inst := &instance{name: l.units[u].file.types[d].name, id: l.defID(u, d), args: args,
		body: &typ{kind: kAny}, idx: id}
	l.instances = append(l.instances, inst)
	l.defOf = append(l.defOf, defRef{u, d})
	l.states = append(l.states, stateNew)
	l.byKey[key] = id
	l.queue = append(l.queue, id)
	return inst, nil
}

// key is a text that tells types apart, for instances. It never holds the
// whole of an argument, which can grow exponentially with legitimate nesting
// (P a a inside P a a …): an instance is keyed by its number, a record or
// variant by the number of its shape, so a key is as long as one type
// expression. Each record and variant is keyed once.
func (l *loader) key(t *typ) string {
	switch t.kind {
	case kTime:
		return t.name
	case kParam:
		return "'" + t.name
	case kArray:
		return "Array(" + l.key(t.elem) + ")"
	case kMap:
		return "Map(" + l.key(t.elem) + ")"
	case kMaybe:
		return "Maybe(" + l.key(t.elem) + ")"
	case kSecret:
		return "Secret(" + l.key(t.elem) + ")"
	case kRef:
		// The instance, not its key: keys stay as long as the type
		// expression, however deep the arguments nest (P a a in P a a …).
		return "#" + strconv.Itoa(t.inst.idx)
	case kRecord:
		return l.recordKey(t.rec)
	case kVariant:
		if k, ok := l.vrtKeys[t.vrt]; ok {
			return k
		}
		cases := make([]string, len(t.vrt.cases))
		for i, c := range t.vrt.cases {
			switch c.payload {
			case payloadNone:
				cases[i] = c.tag
			case payloadRecord:
				cases[i] = c.tag + l.recordKey(c.rec)
			case payloadNamed:
				// Not the key of one positional argument: X R and X a with R for a differ.
				cases[i] = c.tag + "{" + l.key(c.named) + "}"
			default:
				items := make([]string, len(c.items))
				for j, x := range c.items {
					items[j] = l.key(x)
				}
				cases[i] = c.tag + "(" + strings.Join(items, ",") + ")"
			}
		}
		open := ""
		if t.vrt.open {
			open = "|_"
		}
		k := l.shapeKey("<" + strings.Join(cases, "|") + open + ">")
		l.vrtKeys[t.vrt] = k
		return k
	}
	return builtinNames[t.kind]
}

// shapeKey is the number of a shape, as a key.
func (l *loader) shapeKey(shape string) string {
	k, ok := l.shapes[shape]
	if !ok {
		k = "~" + strconv.Itoa(len(l.shapes))
		l.shapes[shape] = k
	}
	return k
}

func (l *loader) recordKey(r *recordType) string {
	if k, ok := l.recKeys[r]; ok {
		return k
	}
	fields := make([]string, len(r.fields))
	for i, f := range r.fields {
		opt := ""
		if f.optional {
			opt = "?"
		}
		fields[i] = fmt.Sprintf("%q%s:%s", f.key, opt, l.key(f.typ))
	}
	closed := ""
	if r.closed {
		closed = "|"
	}
	k := l.shapeKey("{" + closed + strings.Join(fields, ",") + "}")
	l.recKeys[r] = k
	return k
}

// evaluateInstance evaluates the body of an instance, now if it isn't yet
// (a spread needs it).
func (l *loader) evaluateInstance(id int) *fail {
	at := l.defOf[id]
	def := l.units[at.u].file.types[at.d]
	switch l.states[id] {
	case stateDone:
		return nil
	case stateBusy:
		return failIn(at.u, def.pos, haus.CodeSpreadCycle, "type %s spreads itself (directly or through another type)", def.name)
	}
	l.states[id] = stateBusy
	inst := l.instances[id]
	env := map[string]*typ{}
	for i, p := range def.params {
		env[p] = inst.args[i]
	}
	var (
		body   *typ
		stream bool
		f      *fail
	)
	if def.ty.kind == tyName && def.ty.name == "Stream" {
		if len(def.ty.args) != 1 {
			return failIn(at.u, def.ty.pos, haus.CodeWrongArity, "Stream takes 1 argument(s), found %d", len(def.ty.args))
		}
		body, f = l.eval(at.u, def.ty.args[0], env)
		stream = true
	} else {
		body, f = l.eval(at.u, def.ty, env)
	}
	if f != nil {
		return f
	}
	inst.body, inst.stream = body, stream
	l.states[id] = stateDone
	return nil
}

// isRecord reports whether ty, written in file u, is a record (spec §15),
// decided where it is written: names are followed through their
// definitions, with their arguments as written, and a type parameter of the
// definition it is written in is not a record, whatever its argument is.
func (l *loader) isRecord(u int, t *ty) bool {
	type binding struct {
		param string
		u     int
		ty    *ty
		env   *[]binding
	}
	var env *[]binding
	for range maxInstances {
		switch t.kind {
		case tyRecord:
			return true
		case tyVariant:
			return false
		case tyParam:
			var found *binding
			if env != nil {
				for i := range *env {
					if (*env)[i].param == t.name {
						found = &(*env)[i]
						break
					}
				}
			}
			if found == nil {
				return false
			}
			u, t, env = found.u, found.ty, found.env
		case tyName:
			if _, ok := generic[t.name]; ok {
				return false
			}
			at, ok := l.units[u].scope[t.name]
			if !ok {
				return false
			}
			def := l.units[at.u].file.types[at.d]
			bound := make([]binding, 0, len(def.params))
			for i, p := range def.params {
				if i < len(t.args) {
					bound = append(bound, binding{p, u, t.args[i], env})
				}
			}
			u, t, env = at.u, def.ty, &bound
		}
	}
	return false
}

// spread returns the record or variant ...Name copies (want: "record" or
// "variant").
func (l *loader) spread(u int, s spreadDef, want string) (*typ, *fail) {
	at, ok := l.units[u].scope[s.name]
	if !ok {
		_, std := l.units[u].std[s.name]
		_, pre := prelude[s.name]
		if std || pre {
			return nil, failIn(u, s.pos, haus.CodeInvalidSpread, "%s is not a %s, so it can't be spread here", s.name, want)
		}
		return nil, failIn(u, s.pos, haus.CodeUnknownType, "%s", unknownType(s.name))
	}
	if params := l.units[at.u].file.types[at.d].params; len(params) > 0 {
		return nil, failIn(u, s.pos, haus.CodeInvalidSpread,
			"%s has parameters (%s %s); only a type without parameters can be spread", s.name, s.name, strings.Join(params, " "))
	}
	inst, f := l.instance(at.u, at.d, nil, u, s.pos)
	if f != nil {
		return nil, f
	}
	seen := map[*instance]bool{}
	for {
		if f := l.evaluateInstance(inst.idx); f != nil {
			return nil, f
		}
		if inst.stream {
			return nil, failIn(u, s.pos, haus.CodeInvalidSpread, "%s is a Stream and can't be spread", s.name)
		}
		b := inst.body
		switch {
		case b.kind == kRef && !seen[b.inst]:
			seen[b.inst] = true
			inst = b.inst
			continue
		case b.kind == kRecord && want == "record", b.kind == kVariant && want == "variant":
			return b, nil
		}
		return nil, failIn(u, s.pos, haus.CodeInvalidSpread, "%s is not a %s, so it can't be spread here", s.name, want)
	}
}

// eval evaluates a type expression of file u, with the parameters in env.
func (l *loader) eval(u int, t *ty, env map[string]*typ) (*typ, *fail) {
	switch t.kind {
	case tyParam:
		if a, ok := env[t.name]; ok {
			return a, nil
		}
		return nil, failIn(u, t.pos, haus.CodeUnknownParameter, "unknown type parameter %s", t.name)
	case tyRecord:
		r, f := l.record(u, t, env)
		if f != nil {
			return nil, f
		}
		return &typ{kind: kRecord, rec: r}, nil
	case tyVariant:
		return l.variant(u, t, env)
	}
	return l.named(u, t, env)
}

func (l *loader) variant(u int, t *ty, env map[string]*typ) (*typ, *fail) {
	type entry struct {
		c   caseType
		pos int
	}
	var own []entry
	for _, c := range t.cases {
		ct := caseType{tag: c.tag, deprecated: deprecatedOf(c.attrs)}
		switch {
		case len(c.payload) == 0:
			ct.payload = payloadNone
		case len(c.payload) == 1 && c.payload[0].kind == tyRecord:
			r, f := l.record(u, c.payload[0], env)
			if f != nil {
				return nil, f
			}
			ct.payload, ct.rec = payloadRecord, r
		default:
			items := make([]*typ, len(c.payload))
			for i, p := range c.payload {
				x, f := l.eval(u, p, env)
				if f != nil {
					return nil, f
				}
				items[i] = x
			}
			// A record case by name, if it is a record where it is written.
			if len(c.payload) == 1 && c.payload[0].kind == tyName && l.isRecord(u, c.payload[0]) {
				ct.payload, ct.named = payloadNamed, items[0]
			} else {
				ct.payload, ct.items = payloadPositional, items
			}
		}
		own = append(own, entry{ct, c.pos})
	}
	var out []entry
	n := len(own)
	for i := 0; i <= n; i++ {
		for _, sp := range t.spreads {
			if sp.at != i {
				continue
			}
			v, f := l.spread(u, sp, "variant")
			if f != nil {
				return nil, f
			}
			for _, c := range v.vrt.cases {
				out = append(out, entry{c, sp.pos})
			}
		}
		if i < n {
			out = append(out, own[i])
		}
	}
	seen := map[string]bool{}
	cases := make([]caseType, len(out))
	for i, e := range out {
		if seen[e.c.tag] {
			return nil, failIn(u, e.pos, haus.CodeDuplicateTag, "duplicate tag %s", e.c.tag)
		}
		seen[e.c.tag] = true
		cases[i] = e.c
	}
	return &typ{kind: kVariant, vrt: newVariant(!t.closed, cases)}, nil
}

func (l *loader) record(u int, t *ty, env map[string]*typ) (*recordType, *fail) {
	type entry struct {
		f   fieldType
		pos int
	}
	var own []entry
	for _, fd := range t.fields {
		x, f := l.eval(u, fd.ty, env)
		if f != nil {
			return nil, f
		}
		own = append(own, entry{fieldType{key: fd.key, optional: fd.optional, typ: x, deprecated: deprecatedOf(fd.attrs)}, fd.pos})
	}
	var out []entry
	n := len(own)
	for i := 0; i <= n; i++ {
		for _, sp := range t.spreads {
			if sp.at != i {
				continue
			}
			r, f := l.spread(u, sp, "record")
			if f != nil {
				return nil, f
			}
			for _, fd := range r.rec.fields {
				out = append(out, entry{fd, sp.pos})
			}
		}
		if i < n {
			out = append(out, own[i])
		}
	}
	seen := map[string]bool{}
	fields := make([]fieldType, len(out))
	for i, e := range out {
		if seen[e.f.key] {
			return nil, failIn(u, e.pos, haus.CodeDuplicateField, "duplicate field %s", quoteKey(e.f.key))
		}
		seen[e.f.key] = true
		fields[i] = e.f
	}
	return newRecord(t.closed, fields), nil
}

func deprecatedOf(attrs []attribute) *deprecated {
	if !isDeprecated(attrs) {
		return nil
	}
	why, _ := deprecation(attrs)
	return &deprecated{why: why}
}

func (l *loader) named(u int, t *ty, env map[string]*typ) (*typ, *fail) {
	arity := func(n int) *fail {
		if len(t.args) == n {
			return nil
		}
		return failIn(u, t.pos, haus.CodeWrongArity, "%s takes %d argument(s), found %d", t.name, n, len(t.args))
	}
	evalArgs := func() ([]*typ, *fail) {
		out := make([]*typ, len(t.args))
		for i, a := range t.args {
			x, f := l.eval(u, a, env)
			if f != nil {
				return nil, f
			}
			out[i] = x
		}
		return out, nil
	}
	if n, ok := generic[t.name]; ok {
		// Arity first, then where it is: `{ e: Stream }` is wrong-arity.
		if f := arity(n); f != nil {
			return nil, f
		}
		if t.name == "Stream" {
			return nil, failIn(u, t.pos, haus.CodeMisplacedStream, "Stream is only allowed as the whole type of a definition")
		}
		args, f := evalArgs()
		if f != nil {
			return nil, f
		}
		switch t.name {
		case "Array":
			return &typ{kind: kArray, elem: args[0]}, nil
		case "Map":
			return &typ{kind: kMap, elem: args[0]}, nil
		case "Maybe":
			return &typ{kind: kMaybe, elem: args[0]}, nil
		case "Secret":
			return &typ{kind: kSecret, elem: args[0]}, nil
		}
		return &typ{kind: kVariant, vrt: newVariant(false, []caseType{
			{tag: "Err", payload: payloadPositional, items: []*typ{args[0]}},
			{tag: "Ok", payload: payloadPositional, items: []*typ{args[1]}},
		})}, nil
	}
	if at, ok := l.units[u].scope[t.name]; ok {
		if f := arity(len(l.units[at.u].file.types[at.d].params)); f != nil {
			return nil, f
		}
		args, f := evalArgs()
		if f != nil {
			return nil, f
		}
		inst, f := l.instance(at.u, at.d, args, u, t.pos)
		if f != nil {
			return nil, f
		}
		l.refs = append(l.refs, refAt{inst, u, t.pos})
		return &typ{kind: kRef, inst: inst}, nil
	}
	if name, ok := l.units[u].std[t.name]; ok {
		if f := arity(0); f != nil {
			return nil, f
		}
		return &typ{kind: kTime, name: name}, nil
	}
	if k, ok := builtins[t.name]; ok {
		if f := arity(0); f != nil {
			return nil, f
		}
		return &typ{kind: k}, nil
	}
	return nil, failIn(u, t.pos, haus.CodeUnknownType, "%s", unknownType(t.name))
}
