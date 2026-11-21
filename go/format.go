package haus

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Layout is one of the three standard layouts of spec §11.
type Layout int

const (
	// Pretty is for people who edit: one entry per line, comments and blank
	// lines kept. The default.
	Pretty Layout = iota
	// Compact writes each top-level item on one line, with spaces, and drops
	// comments: for logs and streams people look at.
	Compact
	// Minimised is compact without whitespace between tokens: for the wire
	// and storage.
	Minimised
)

// String returns the layout's name: "pretty", "compact" or "minimised".
func (l Layout) String() string {
	switch l {
	case Pretty:
		return "pretty"
	case Compact:
		return "compact"
	case Minimised:
		return "minimised"
	}
	return fmt.Sprintf("Layout(%d)", int(l))
}

// FormatOptions configure [Format], [FormatValue] and [FormatValues].
//
// Indent and Width are taken literally (spec §11), 0 included, so the zero
// value is not the default layout: it is the pretty layout with no
// indentation and a width of 0, where nothing fits on one line. Start from
// [DefaultFormatOptions] for the default. A negative Indent or Width is
// rejected with [ErrInvalidOptions].
type FormatOptions struct {
	Layout Layout
	// Indent is the number of spaces per level in the pretty layout: with 0
	// no line is indented. The compact and minimised layouts ignore it.
	Indent int
	// Width is the line width in code points, which only decides whether a
	// positional payload fits on one line in the pretty layout: with 0
	// nothing fits, and every positional payload is written one argument per
	// line. The compact and minimised layouts ignore it.
	Width int
	// Limits are the limits of the text read (Format), or of the reader the
	// text is written for (FormatValue, FormatValues). Zero fields take their
	// defaults.
	Limits Limits
}

// DefaultFormatOptions returns the default options: the pretty layout with
// an indent of 2, a width of 80 and the default limits.
func DefaultFormatOptions() FormatOptions {
	return FormatOptions{Layout: Pretty, Indent: 2, Width: 80}
}

// ErrInvalidOptions is the error, wrapped with the detail, of a call given
// options no layout takes: a negative indent or width. It is a mistake in the
// calling program, not in the text or the values, so it isn't an [*Error]
// and has no code (spec §17).
var ErrInvalidOptions = errors.New("haus: invalid format options")

// Check returns an error wrapping [ErrInvalidOptions] if the indent or width
// is negative, in any layout, and nil otherwise. [Format], [FormatValue] and
// [FormatValues] check their options so before doing anything else.
func (o FormatOptions) Check() error {
	switch {
	case o.Indent < 0:
		return fmt.Errorf("%w: indent %d is negative", ErrInvalidOptions, o.Indent)
	case o.Width < 0:
		return fmt.Errorf("%w: width %d is negative", ErrInvalidOptions, o.Width)
	}
	return nil
}

// Format reformats haus text in a standard layout (spec §11). Numbers, byte
// strings and "…" strings keep their spelling. The pretty layout keeps
// comments and blank lines; compact and minimised drop them (see
// [HasComments] for tools that rewrite files in place). A negative indent or
// width fails with [ErrInvalidOptions] before the text is read.
func Format(src []byte, opts FormatOptions) ([]byte, error) {
	if err := opts.Check(); err != nil {
		return nil, err
	}
	lim, err := opts.Limits.resolve()
	if err != nil {
		return nil, err
	}
	p := newParser(string(src), lim, true)
	defer p.release()
	_, f, err := p.file()
	if err != nil {
		return nil, err
	}
	return printFile(f, opts), nil
}

// HasComments reports whether haus text has comments, which the compact and
// minimised layouts drop (spec §11: a tool that rewrites a file in place in
// those layouts refuses when it has comments, unless asked to drop them).
func HasComments(src []byte) (bool, error) {
	return HasCommentsWith(src, Limits{})
}

// HasCommentsWith is [HasComments] with the given limits.
func HasCommentsWith(src []byte, limits Limits) (bool, error) {
	lim, err := limits.resolve()
	if err != nil {
		return false, err
	}
	p := newParser(string(src), lim, true)
	defer p.release()
	_, f, err := p.file()
	if err != nil {
		return false, err
	}
	if len(f.dangling) > 0 {
		return true, nil
	}
	for _, it := range f.items {
		if it.hasComments() {
			return true, nil
		}
	}
	return false, nil
}

func (it *item) hasComments() bool {
	return len(it.leading) > 0 || len(it.trailing) > 0 || it.val.hasComments()
}

func (n *node) hasComments() bool {
	if len(n.dangling) > 0 {
		return true
	}
	for _, it := range n.items {
		if it.hasComments() {
			return true
		}
	}
	return false
}

// FormatValue writes one value in a layout, as a file holding it alone. With
// no source text, numbers are written normalized and in decimal, byte strings
// in lowercase hex without spaces, and strings with the fewest escapes.
//
// It checks every limit of opts.Limits that a value can break (spec §11),
// so that a parser with the same limits reads the text back: a number
// longer than the number limit (number-too-long, a decimal or exponent too,
// not only an integer), an exponent larger than the exponent limit
// (exponent-too-large), nesting deeper than the depth limit
// (nesting-too-deep, a record payload counting one level), a string, key,
// tag or byte string longer than the string limit (string-too-long,
// key-too-long, tag-too-long), and more values written than the node limit
// (too-many-nodes, at the top-level value: a value whose parts share one
// another is written once per place). It also fails for what Go lets code
// build past the constructors: a nil value, the zero [Tag] or a string that
// isn't UTF-8 (cannot-encode), and a value that contains itself
// (cyclic-value). A negative indent or width fails with
// [ErrInvalidOptions] before any value is looked at.
func FormatValue(v Value, opts FormatOptions) ([]byte, error) {
	return FormatValues([]Value{v}, opts)
}

// FormatValues writes values as a file (spec §6): one value alone, two or
// more as a stream with a comma after each. See [FormatValue]. A value that
// contains itself fails with the code cyclic-value.
func FormatValues(vs []Value, opts FormatOptions) ([]byte, error) {
	if err := opts.Check(); err != nil {
		return nil, err
	}
	lim, err := opts.Limits.resolve()
	if err != nil {
		return nil, err
	}
	if opts.Layout != Pretty {
		// No layout decisions to make: written as the values are checked.
		return writeLines(vs, lim, opts.Layout == Minimised)
	}
	b := builder{writeCheck: writeCheck{lim: lim}}
	f := &fileNode{items: make([]*item, len(vs))}
	for i, v := range vs {
		b.start(i, len(vs) > 1)
		n, err := b.node(v, 0)
		if err != nil {
			return nil, err
		}
		f.items[i] = &item{val: n}
	}
	return printFile(f, opts), nil
}

// writeCheck is what the writers of values built in code share: the checks
// that a value can be written, in one order, so that both writers fail with
// the same error. The path to the value being written is kept as steps and
// written out only for an error.
type writeCheck struct {
	lim   Limits
	path  []step
	guard cycleGuard
	// nodes counts the values written for the current top-level value, and
	// top is the length of its path ($, or $[i] in a stream).
	nodes, top int
}

func (c *writeCheck) fail(code ErrorCode, format string, args ...any) error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Path: pathString(c.path)}
}

// start starts the top-level value i, of a stream or alone.
func (c *writeCheck) start(i int, stream bool) {
	c.path = c.path[:0]
	if stream {
		c.path = append(c.path, step{index: i})
	}
	c.top = len(c.path)
	c.nodes = 0
}

// count counts one more value written, against the node limit (spec §7,
// "Values written"): too-many-nodes, at the top-level value. This check and
// the ones below are small enough to be inlined where values are written;
// their errors are built out of line.
func (c *writeCheck) count() error {
	c.nodes++
	if c.nodes > c.lim.MaxNodes {
		return c.tooManyNodes()
	}
	return nil
}

func (c *writeCheck) tooManyNodes() error {
	return tooManyNodes(c.lim.MaxNodes, pathString(c.path[:c.top]))
}

func tooManyNodes(limit int, path string) *Error {
	return &Error{Code: CodeTooManyNodes, Path: path,
		Message: fmt.Sprintf("the value writes more than %d values, the node limit: its parts share one another", limit)}
}

// length checks a string or key against the string limit, in code points.
func (c *writeCheck) length(s string, code ErrorCode, what string) error {
	if len(s) > c.lim.MaxStringLength {
		return c.tooLong(s, code, what)
	}
	return nil
}

func (c *writeCheck) tooLong(s string, code ErrorCode, what string) error {
	if n := utf8.RuneCountInString(s); n > c.lim.MaxStringLength {
		return c.fail(code, "a %s of %d characters, more than the limit of %d", what, n, c.lim.MaxStringLength)
	}
	return nil
}

// bytes checks a byte string against the string limit: two characters
// between the quotes per byte.
func (c *writeCheck) bytes(b Bytes) error {
	if 2*len(b) > c.lim.MaxStringLength {
		return c.fail(CodeStringTooLong, "a byte string of %d bytes, more than the limit of %d characters", len(b), c.lim.MaxStringLength)
	}
	return nil
}

// tag checks a variant's tag: the zero Tag holds none (cannot-encode), and
// a tag is within the string limit (tag-too-long). Its characters are ASCII.
func (c *writeCheck) tag(t Tag) error {
	if t.IsZero() || len(t.name) > c.lim.MaxStringLength {
		return c.badTag(t)
	}
	return nil
}

func (c *writeCheck) badTag(t Tag) error {
	if t.IsZero() {
		return c.fail(CodeCannotEncode, "a variant with the zero Tag, which holds no tag")
	}
	return c.fail(CodeTagTooLong, "a tag of %d characters, more than the limit of %d", len(t.name), c.lim.MaxStringLength)
}

// enter starts the container v at depth, one level deeper.
func (c *writeCheck) enter(v Value, depth int) error {
	if depth+1 > c.lim.MaxDepth {
		e := c.guard.depthError(v, c.lim.MaxDepth)
		e.Path = pathString(c.path)
		return e
	}
	c.guard.push(v)
	return nil
}

// The errors of values that can't be written.
func (c *writeCheck) invalidString() error {
	return c.fail(CodeCannotEncode, "a string that isn't valid UTF-8")
}

func (c *writeCheck) invalidKey() error {
	return c.fail(CodeCannotEncode, "a key that isn't valid UTF-8")
}

// number checks a number against the number limits (§7): number-too-long
// or exponent-too-large, for a value built in code (a parsed one is within).
func (c *writeCheck) number(text string) error {
	if code, msg := numberLimits(text, c.lim); code != "" {
		return c.fail(code, "%s", msg)
	}
	return nil
}

func (c *writeCheck) unknownValue(v Value) error {
	if v == nil {
		return c.fail(CodeCannotEncode, "a nil value")
	}
	return c.fail(CodeCannotEncode, "an unknown kind of value")
}

// builder turns values built in code into syntax nodes for the pretty
// layout, checking that they can be written.
type builder struct {
	writeCheck
}

func (b *builder) node(v Value, depth int) (*node, error) {
	if err := b.count(); err != nil {
		return nil, err
	}
	switch v := v.(type) {
	case String:
		if !utf8.ValidString(string(v)) {
			return nil, b.invalidString()
		}
		if err := b.length(string(v), CodeStringTooLong, "string"); err != nil {
			return nil, err
		}
		return &node{val: v}, nil
	case Number:
		text := v.String()
		if err := b.number(text); err != nil {
			return nil, err
		}
		return &node{val: v, text: text}, nil
	case Bytes:
		if err := b.bytes(v); err != nil {
			return nil, err
		}
		return &node{val: v, text: `x"` + hex.EncodeToString(v) + `"`}, nil
	case Array:
		if err := b.enter(v, depth); err != nil {
			return nil, err
		}
		n := &node{val: v, items: make([]*item, len(v))}
		for i, e := range v {
			c, err := b.child(step{index: i}, e, depth+1)
			if err != nil {
				return nil, err
			}
			n.items[i] = &item{val: c}
		}
		b.guard.pop()
		return n, nil
	case Record:
		if err := b.enter(v, depth); err != nil {
			return nil, err
		}
		n, err := b.fields(v, &node{val: v}, depth)
		if err != nil {
			return nil, err
		}
		b.guard.pop()
		return n, nil
	case Variant:
		if err := b.tag(v.Tag); err != nil {
			return nil, err
		}
		if len(v.Args) == 0 {
			return &node{val: v}, nil
		}
		if r, ok := v.Args[0].(Record); ok && len(v.Args) == 1 {
			// Tag { … }: the record is the payload's one level, and one
			// value written.
			if err := b.enter(r, depth); err != nil {
				return nil, err
			}
			if err := b.count(); err != nil {
				return nil, err
			}
			n, err := b.fields(r, &node{val: v, form: formBraces}, depth)
			if err != nil {
				return nil, err
			}
			b.guard.pop()
			return n, nil
		}
		if err := b.enter(v, depth); err != nil {
			return nil, err
		}
		n := &node{val: v, form: formParens, items: make([]*item, len(v.Args))}
		for i, a := range v.Args {
			c, err := b.child(step{index: i}, a, depth+1)
			if err != nil {
				return nil, err
			}
			n.items[i] = &item{val: c}
		}
		b.guard.pop()
		return n, nil
	}
	return nil, b.unknownValue(v)
}

// child builds the node of v, at the step s from the current value.
func (b *builder) child(s step, v Value, depth int) (*node, error) {
	b.path = append(b.path, s)
	n, err := b.node(v, depth)
	if err == nil {
		b.path = b.path[:len(b.path)-1]
	}
	return n, err
}

func (b *builder) fields(r Record, n *node, depth int) (*node, error) {
	n.items = make([]*item, len(r.fields))
	for i, f := range r.fields {
		if !utf8.ValidString(f.Key) {
			return nil, b.invalidKey()
		}
		if err := b.length(f.Key, CodeKeyTooLong, "key"); err != nil {
			return nil, err
		}
		c, err := b.child(step{key: f.Key, index: -1}, f.Value, depth+1)
		if err != nil {
			return nil, err
		}
		n.items[i] = &item{keyed: true, key: f.Key, val: c}
	}
	return n, nil
}

// pathKey writes a key as a step of a path (spec §15): .name or ["pt-BR"].
func pathKey(key string) string {
	if isIdent(key) {
		return "." + key
	}
	return "[" + string(appendQuoted(nil, key)) + "]"
}

// isIdent reports whether s can be a bare key: [a-z_][A-Za-z0-9_]*.
func isIdent(s string) bool {
	return s != "" && (s[0] >= 'a' && s[0] <= 'z' || s[0] == '_') && isWordTail(s[1:])
}

// isTag reports whether s is a tag: [A-Z][A-Za-z0-9_]*.
func isTag(s string) bool {
	return s != "" && s[0] >= 'A' && s[0] <= 'Z' && isWordTail(s[1:])
}

func isWordTail(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isWordChar(s[i]) {
			return false
		}
	}
	return true
}

// printer writes a syntax tree in a layout.
type printer struct {
	b      []byte
	indent int
	width  int
	layout Layout
}

func printFile(f *fileNode, opts FormatOptions) []byte {
	pr := &printer{indent: opts.Indent, width: opts.Width, layout: opts.Layout}
	stream := len(f.items) > 1
	if opts.Layout != Pretty {
		for _, it := range f.items {
			pr.compact(it.val)
			if stream {
				pr.b = append(pr.b, ',')
			}
			pr.b = append(pr.b, '\n')
		}
		return pr.b
	}
	first := true
	multiline := false
	for i, it := range f.items {
		pr.leading(it, 0, &first, i > 0 && multiline)
		multiline = pr.entry(it, 0, stream)
	}
	pr.comments(f.dangling, 0, &first)
	return pr.b
}

// blankLine writes a blank line if one is wanted and this isn't the first
// thing in its container.
func (pr *printer) blankLine(blank bool, first *bool) {
	if blank && !*first {
		pr.b = append(pr.b, '\n')
	}
	*first = false
}

func (pr *printer) writeIndent(level int) {
	for range level * pr.indent {
		pr.b = append(pr.b, ' ')
	}
}

// comments writes comments on lines of their own.
func (pr *printer) comments(cs []comment, level int, first *bool) {
	for _, c := range cs {
		pr.blankLine(c.blank(), first)
		pr.writeIndent(level)
		pr.b = append(pr.b, c.text...)
		pr.b = append(pr.b, '\n')
	}
}

// leading writes the comments above an item and the blank line before it.
// force asks for a blank line before whatever comes first.
func (pr *printer) leading(it *item, level int, first *bool, force bool) {
	for i, c := range it.leading {
		pr.blankLine(c.blank() || force && i == 0, first)
		pr.writeIndent(level)
		pr.b = append(pr.b, c.text...)
		pr.b = append(pr.b, '\n')
	}
	pr.blankLine(it.blank || force && len(it.leading) == 0, first)
}

// entry writes an item on its line(s) in the pretty layout, and reports
// whether its value took more than one line.
func (pr *printer) entry(it *item, level int, comma bool) bool {
	pr.writeIndent(level)
	col := level * pr.indent
	if it.keyed {
		start := len(pr.b)
		pr.key(it)
		pr.b = append(pr.b, ": "...)
		col += utf8.RuneCount(pr.b[start:])
	}
	start := len(pr.b)
	suffix := 0
	if comma {
		suffix = 1
	}
	pr.value(it.val, level, col, suffix)
	multiline := strings.IndexByte(string(pr.b[start:]), '\n') >= 0
	if comma {
		pr.b = append(pr.b, ',')
	}
	for _, c := range it.trailing {
		pr.b = append(pr.b, ' ')
		pr.b = append(pr.b, c.text...)
	}
	pr.b = append(pr.b, '\n')
	return multiline
}

func (pr *printer) key(it *item) {
	switch {
	case isIdent(it.key):
		pr.b = append(pr.b, it.key...)
	default:
		pr.b = appendQuoted(pr.b, it.key)
	}
}

// value writes a value in the pretty layout, starting at column col (in code
// points), with suffix characters to follow it on its last line.
func (pr *printer) value(n *node, level, col, suffix int) {
	switch v := n.val.(type) {
	case String:
		if strings.IndexByte(string(v), '\n') >= 0 {
			pr.blockString(string(v), level)
			return
		}
		pr.scalar(n)
	case Record:
		pr.container('{', '}', n, level)
	case Array:
		pr.container('[', ']', n, level)
	case Variant:
		switch n.form {
		case formBare:
			pr.b = append(pr.b, v.Tag.name...)
		case formBraces:
			pr.b = append(pr.b, v.Tag.name...)
			pr.b = append(pr.b, ' ')
			pr.container('{', '}', n, level)
		case formParens:
			if w := pr.inlineWidth(n); w >= 0 && col+w+suffix <= pr.width {
				pr.compact(n)
				return
			}
			pr.b = append(pr.b, v.Tag.name...)
			pr.container('(', ')', n, level)
		}
	default:
		pr.scalar(n)
	}
}

// container writes a record, array or payload one entry per line.
func (pr *printer) container(open, closer byte, n *node, level int) {
	if len(n.items) == 0 && len(n.dangling) == 0 {
		pr.b = append(pr.b, open, closer)
		return
	}
	pr.b = append(pr.b, open, '\n')
	first := true
	for _, it := range n.items {
		pr.leading(it, level+1, &first, false)
		pr.entry(it, level+1, true)
	}
	pr.comments(n.dangling, level+1, &first)
	pr.writeIndent(level)
	pr.b = append(pr.b, closer)
}

// inlineWidth returns the width of a value written on one line in the
// compact layout, or -1 if the pretty layout never writes it on one line: it
// holds a non-empty record or array, a multi-line string or a comment.
func (pr *printer) inlineWidth(n *node) int {
	if n.iw != 0 {
		return max(n.iw-1, -1)
	}
	w := pr.measure(n)
	if w < 0 {
		n.iw = -1
	} else {
		n.iw = w + 1
	}
	return w
}

func (pr *printer) measure(n *node) int {
	switch v := n.val.(type) {
	case String:
		if strings.IndexByte(string(v), '\n') >= 0 {
			return -1
		}
		if n.text != "" {
			return utf8.RuneCount(appendSpelling(nil, n.text))
		}
		return utf8.RuneCount(appendQuoted(nil, string(v)))
	case Record, Array:
		if len(n.items) == 0 && len(n.dangling) == 0 {
			return 2
		}
		return -1
	case Variant:
		switch n.form {
		case formBare:
			return len(v.Tag.name)
		case formBraces:
			if len(n.items) == 0 && len(n.dangling) == 0 {
				return len(v.Tag.name) + 3
			}
			return -1
		}
		if len(n.dangling) > 0 {
			return -1
		}
		w := len(v.Tag.name) + 2 + 2*(len(n.items)-1)
		for _, it := range n.items {
			if len(it.leading) > 0 || len(it.trailing) > 0 {
				return -1
			}
			a := pr.inlineWidth(it.val)
			if a < 0 {
				return -1
			}
			w += a
		}
		return w
	}
	return utf8.RuneCountInString(n.text)
}

// scalar writes a number, byte string or single-line string.
func (pr *printer) scalar(n *node) {
	if s, ok := n.val.(String); ok && n.text == "" {
		pr.b = appendQuoted(pr.b, string(s))
		return
	}
	pr.b = appendSpelling(pr.b, n.text)
}

// compact writes a value on one line, in the compact or minimised layout.
func (pr *printer) compact(n *node) {
	minimised := pr.layout == Minimised
	switch v := n.val.(type) {
	case Record:
		pr.compactFields('{', '}', n, minimised)
	case Array:
		pr.compactItems('[', ']', n, minimised)
	case Variant:
		pr.b = append(pr.b, v.Tag.name...)
		switch n.form {
		case formBraces:
			if !minimised {
				pr.b = append(pr.b, ' ')
			}
			pr.compactFields('{', '}', n, minimised)
		case formParens:
			pr.compactItems('(', ')', n, minimised)
		}
	default:
		pr.scalar(n)
	}
}

func (pr *printer) compactItems(open, closer byte, n *node, minimised bool) {
	pr.b = append(pr.b, open)
	for i, it := range n.items {
		if i > 0 {
			pr.b = append(pr.b, ',')
			if !minimised {
				pr.b = append(pr.b, ' ')
			}
		}
		pr.compact(it.val)
	}
	pr.b = append(pr.b, closer)
}

func (pr *printer) compactFields(open, closer byte, n *node, minimised bool) {
	if len(n.items) == 0 {
		pr.b = append(pr.b, open, closer)
		return
	}
	pr.b = append(pr.b, open)
	if !minimised {
		pr.b = append(pr.b, ' ')
	}
	for i, it := range n.items {
		if i > 0 {
			pr.b = append(pr.b, ',')
			if !minimised {
				pr.b = append(pr.b, ' ')
			}
		}
		pr.key(it)
		pr.b = append(pr.b, ':')
		if !minimised {
			pr.b = append(pr.b, ' ')
		}
		pr.compact(it.val)
	}
	if !minimised {
		pr.b = append(pr.b, ' ')
	}
	pr.b = append(pr.b, closer)
}

// blockString writes a string with line feeds as a """ block string, its
// content one level deeper than the entry (spec §11).
func (pr *printer) blockString(s string, level int) {
	pr.b = append(pr.b, `"""`...)
	pr.b = append(pr.b, '\n')
	for {
		line, rest, more := strings.Cut(s, "\n")
		if line != "" {
			pr.writeIndent(level + 1)
			pr.b = appendBlockLine(pr.b, line)
		}
		pr.b = append(pr.b, '\n')
		if !more {
			break
		}
		s = rest
	}
	pr.writeIndent(level + 1)
	pr.b = append(pr.b, `"""`...)
}

const hexDigits = "0123456789ABCDEF"

func writeUnicodeEscape(b *strings.Builder, r rune) {
	b.Write(appendUnicodeEscape(nil, r))
}

// appendUnicodeEscape appends \u{…} with uppercase hex digits and no leading
// zeros.
func appendUnicodeEscape(b []byte, r rune) []byte {
	b = append(b, `\u{`...)
	started := false
	for shift := 20; shift >= 0; shift -= 4 {
		d := (r >> shift) & 0xF
		if d != 0 || started || shift == 0 {
			b = append(b, hexDigits[d])
			started = true
		}
	}
	return append(b, '}')
}

// appendQuoted appends s as a "…" string with the fewest escapes (the same
// as the canonical form).
func appendQuoted(b []byte, s string) []byte {
	b, _ = appendQuotedValid(b, s)
	return b
}

// appendQuotedValid is appendQuoted, and reports whether s is valid UTF-8
// (bytes that aren't are written as they are).
func appendQuotedValid(b []byte, s string) ([]byte, bool) {
	valid := true
	b = append(b, '"')
	plain := 0
	for i := 0; ; {
		if i = plainRun(s, i, &quoteStop); i == len(s) {
			break
		}
		c := s[i]
		r, size := rune(c), 1
		if c >= utf8.RuneSelf {
			r, size = utf8.DecodeRuneInString(s[i:])
			if r == utf8.RuneError && size == 1 {
				valid = false
			}
			if !needsEscape(r) {
				i += size
				continue
			}
		}
		b = append(b, s[plain:i]...)
		switch r {
		case '"':
			b = append(b, `\"`...)
		case '\\':
			b = append(b, `\\`...)
		case '\n':
			b = append(b, `\n`...)
		case '\r':
			b = append(b, `\r`...)
		case '\t':
			b = append(b, `\t`...)
		default:
			b = appendUnicodeEscape(b, r)
		}
		i += size
		plain = i
	}
	b = append(b, s[plain:]...)
	return append(b, '"'), valid
}

// appendSpelling appends a scalar as written in the source, with raw U+2028
// and U+2029 escaped, which no layout writes raw (spec §11).
func appendSpelling(b []byte, text string) []byte {
	for {
		i := strings.Index(text, "\u2028")
		j := strings.Index(text, "\u2029")
		if i < 0 || j >= 0 && j < i {
			i = j
		}
		if i < 0 {
			return append(b, text...)
		}
		b = append(b, text[:i]...)
		r, n := utf8.DecodeRuneInString(text[i:])
		b = appendUnicodeEscape(b, r)
		text = text[i+n:]
	}
}

// appendBlockLine appends one content line of a block string: a quote
// followed by two more is escaped, a carriage return is \r, and the last
// character is escaped if it is a space or tab, so that no line ends in one.
func appendBlockLine(b []byte, line string) []byte {
	last := len(line) - 1
	for i := 0; i < len(line); {
		c := line[i]
		switch {
		case c == '\\':
			b = append(b, `\\`...)
		case c == '"' && strings.HasPrefix(line[i:], `"""`):
			b = append(b, `\"`...)
		case c == ' ' && i == last:
			b = append(b, `\u{20}`...)
		case c == '\t' && i == last:
			b = append(b, `\t`...)
		case c == '\t' || c >= 0x20 && c < 0x7f:
			b = append(b, c)
		case c == '\r':
			b = append(b, `\r`...)
		default:
			r, size := utf8.DecodeRuneInString(line[i:])
			if needsEscape(r) {
				b = appendUnicodeEscape(b, r)
			} else {
				b = append(b, line[i:i+size]...)
			}
			i += size
			continue
		}
		i++
	}
	return b
}
