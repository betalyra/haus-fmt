package schema

import (
	"fmt"
	"strings"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
)

// Checking data against a schema, for tools such as haus check and editors:
// every problem of a data file, not only the first, with its place in the
// text, and hints that aren't errors: fields and tags an open type doesn't
// list (with a "did you mean"), and deprecated fields and tags the data
// uses (spec §14). A problem inside a Secret is one error at the secret,
// with its type only, and nothing inside a secret is shown (spec §15).
//
// The rules are those of decoding (§15), with the same codes and messages
// for the same mistakes; the work is bounded as decoding's is.

// MaxIssues is the most issues a check reports for one file.
const MaxIssues = 200

// Severity says how bad an [Issue] is.
type Severity uint8

const (
	// SeverityError is data that doesn't fit the schema.
	SeverityError Severity = iota
	// SeverityHint is allowed but maybe not meant: a field or tag an open
	// type doesn't list (a typo?), or a deprecated one.
	SeverityHint
)

// String returns "error" or "hint".
func (s Severity) String() string {
	if s == SeverityHint {
		return "hint"
	}
	return "error"
}

// Issue is a problem with data, or a hint about it.
type Issue struct {
	Severity Severity
	// Code is the mistake (spec §17): missing-field, or for a hint
	// unlisted-field, unlisted-tag or deprecated.
	Code haus.ErrorCode
	// Message is for people, without the place.
	Message string
	// Path is the place in the value (spec §15): $.items[2].price, or
	// $[3].price for the fourth value of a stream.
	Path string
	// Line and Column are where the issue starts in the data text (spec
	// §8), when checked from text; 0 otherwise.
	Line, Column int
	// Offset and End are the byte offsets of what the issue is about in
	// the text, End exclusive, when checked from text.
	Offset, End int
	// Fix is a concrete fix for this case, better than the catalogue's for
	// the code, or "".
	Fix string
}

// Err returns the issue as an *haus.Error, whose JSON form is that of spec
// §17.
func (i Issue) Err() *haus.Error {
	return &haus.Error{Code: i.Code, Message: i.Message, Path: i.Path, Line: i.Line, Column: i.Column, Hint: i.Fix}
}

// String returns "line:column: path: message [code]", leaving out the parts
// it doesn't have.
func (i Issue) String() string { return i.Err().Error() }

// MarshalJSON writes the JSON form of spec §17.
func (i Issue) MarshalJSON() ([]byte, error) { return i.Err().MarshalJSON() }

// Check returns every problem of values, a file's top-level values, as the
// type name: a Stream definition checks each value, any other type expects
// exactly one. Errors and hints, without positions, at most [MaxIssues].
func (s *Schema) Check(name string, values []haus.Value) []Issue {
	return s.CheckValues(name, values, CheckOptions{}).Issues
}

// CheckText returns every problem of the data file text as the type name,
// with positions: its syntax error, or what [Schema.Check] finds.
func (s *Schema) CheckText(name string, text []byte) []Issue {
	return s.CheckTextWith(name, text, haus.Limits{})
}

// CheckTextWith is [Schema.CheckText], parsing and checking with limits.
func (s *Schema) CheckTextWith(name string, text []byte, limits haus.Limits) []Issue {
	return s.CheckTextResult(name, text, CheckOptions{Limits: limits}).Issues
}

// CheckOptions configure [Schema.CheckValues] and [Schema.CheckTextResult].
type CheckOptions struct {
	// First stops at the first error (haus check --first), with the hints
	// found before it. By default every error is reported (spec §14,
	// "Every error"), up to [MaxIssues] issues.
	First bool
	// Limits are the parser's limits, also the depth limit and the limits
	// raw values are checked against. Zero fields take their defaults.
	Limits haus.Limits
}

// CheckResult is what a check found: the issues, a set (which issues is
// specified, their order is not, spec §14), and whether it stopped at
// [MaxIssues] with more to report.
type CheckResult struct {
	Issues []Issue
	// Stopped is set when the check stopped at [MaxIssues] issues: there
	// are more.
	Stopped bool
}

// OK reports whether the result has no errors (hints don't count): the
// data decodes with the type.
func (r CheckResult) OK() bool {
	for _, i := range r.Issues {
		if i.Severity == SeverityError {
			return false
		}
	}
	return true
}

// CheckValues is [Schema.Check] with options: every error (spec §14,
// "Every error") or only the first, and whether it stopped at [MaxIssues].
func (s *Schema) CheckValues(name string, values []haus.Value, opts CheckOptions) CheckResult {
	return s.check(name, values, nil, opts)
}

// CheckTextResult is [Schema.CheckText] with options: every error (spec
// §14, "Every error") or only the first, and whether it stopped at
// [MaxIssues]. A syntax or limit error of the text is its only issue.
func (s *Schema) CheckTextResult(name string, text []byte, opts CheckOptions) CheckResult {
	src := string(text)
	ls := newLines(src)
	values, err := haus.ParseAllWith(text, opts.Limits)
	if err != nil {
		e, ok := err.(*haus.Error)
		if !ok {
			return CheckResult{Issues: []Issue{{Code: haus.CodeInvalidUTF8, Message: err.Error()}}}
		}
		at := ls.offset(e.Line, e.Column)
		return CheckResult{Issues: []Issue{{Code: e.Code, Message: e.Message, Line: e.Line, Column: e.Column,
			Offset: at, End: at + charLen(src, at), Fix: e.Hint}}}
	}
	locs := locate(src)
	if len(locs) != len(values) {
		locs = nil
	}
	r := s.check(name, values, locs, opts)
	for i := range r.Issues {
		is := &r.Issues[i]
		if is.End == 0 { // no span: the start of the file
			is.Offset, is.End = 0, charLen(src, 0)
		}
		is.Line, is.Column = ls.position(is.Offset)
	}
	return r
}

// charLen is the length of the character at s[i], at least 1 within s.
func charLen(s string, i int) int {
	if i >= len(s) {
		return 0
	}
	_, n := utf8.DecodeRuneInString(s[i:])
	return n
}

// offset returns the byte offset of a line and column (spec §8).
func (l *lines) offset(line, col int) int {
	if line < 1 || line > len(l.starts) {
		return len(l.text)
	}
	i := l.starts[line-1]
	for c := 1; c < col && i < len(l.text); c++ {
		_, n := utf8.DecodeRuneInString(l.text[i:])
		i += n
	}
	return i
}

func (s *Schema) check(name string, values []haus.Value, locs []*loc, opts CheckOptions) CheckResult {
	at := func(i int) *loc {
		if i < len(locs) {
			return locs[i]
		}
		return nil
	}
	t, err := s.Type(name)
	if err != nil {
		e := err.(*haus.Error)
		return CheckResult{Issues: []Issue{{Code: e.Code, Message: e.Message}}}
	}
	lim, err := resolveLimits(opts.Limits)
	if err != nil {
		e := err.(*haus.Error)
		return CheckResult{Issues: []Issue{{Code: e.Code, Message: e.Message}}}
	}
	c := checker{located: locs != nil, first: opts.First}
	c.w = walker{lim: lim, budget: budgetStart, path: make([]step, 0, 16)}
	switch {
	case t.stream:
		for i, v := range values {
			c.w.root = v
			c.w.path = append(c.w.path[:0], step{index: i})
			c.w.prefix = 1
			c.value(v, t.t, at(i))
			if c.stopped() {
				break
			}
		}
	case len(values) != 1:
		c.w.path = c.w.path[:0]
		c.report(SeverityError, haus.CodeNotOneValue,
			fmt.Sprintf("expected one value (%s is not a Stream), found %d", name, len(values)), "", spanOf(at(1)))
	default:
		c.w.root = values[0]
		c.value(values[0], t.t, at(0))
	}
	return CheckResult{Issues: c.issues, Stopped: c.capped}
}

// span is a part of the text; zero when there is none.
type span struct{ start, end int }

func spanOf(l *loc) span {
	if l == nil {
		return span{}
	}
	return span{l.start, l.end}
}

type checker struct {
	w       walker // its path is the checker's; it checks scalars as decoding does
	issues  []Issue
	errors  int // the errors among issues
	fatal   bool
	located bool
	first   bool // stop at the first error
	capped  bool // an issue past MaxIssues was found: nothing more is checked
}

func (c *checker) stopped() bool { return c.fatal || c.capped || (c.first && c.errors > 0) }

// add adds an issue, unless there are MaxIssues already: then the check
// stops, and says so (spec §14, "Every error").
func (c *checker) add(is Issue) {
	if len(c.issues) >= MaxIssues {
		c.capped = true
		return
	}
	if is.Severity == SeverityError {
		c.errors++
	}
	c.issues = append(c.issues, is)
}

func (c *checker) report(sev Severity, code haus.ErrorCode, msg, fix string, sp span) {
	if !c.located {
		sp = span{}
	}
	if sp.end <= sp.start && sp != (span{}) {
		sp.end = sp.start + 1
	}
	c.add(Issue{Severity: sev, Code: code, Message: msg, Path: pathString(c.w.path),
		Offset: sp.start, End: sp.end, Fix: fix})
}

func (c *checker) errorAt(code haus.ErrorCode, msg string, l *loc) {
	c.report(SeverityError, code, msg, "", spanOf(l))
}

func (c *checker) fatalError(code haus.ErrorCode, msg string) {
	c.report(SeverityError, code, msg, "", span{})
	c.fatal = true
}

// child checks v with t one level deeper, at the step s.
func (c *checker) child(s step, v haus.Value, t *typ, l *loc) {
	c.w.path = append(c.w.path, s)
	if c.w.depth >= c.w.lim.MaxDepth {
		c.fatalError(haus.CodeNestingTooDeep, fmt.Sprintf("nesting deeper than %d levels", c.w.lim.MaxDepth))
	} else {
		c.w.budget += stepsPerValue
		c.w.depth++
		c.value(v, t, l)
		c.w.depth--
	}
	c.w.path = c.w.path[:len(c.w.path)-1]
}

func (c *checker) value(v haus.Value, t *typ, l *loc) {
	if c.stopped() {
		return
	}
	c.w.steps++
	if c.w.steps > c.w.budget {
		c.fatalError(haus.CodeStepBudget, fmt.Sprintf(
			"decode budget of %d steps exceeded (a schema doing more work than the input justifies)", c.w.budget))
		return
	}
	rt := resolve(t)
	switch rt.kind {
	case kArray:
		a, ok := v.(haus.Array)
		if !ok {
			c.mismatch(v, t, l)
			return
		}
		for i, x := range a {
			c.child(step{index: i}, x, rt.elem, l.item(i))
		}
	case kMap:
		r, ok := v.(haus.Record)
		if !ok {
			c.mismatch(v, t, l)
			return
		}
		i := 0
		for k, x := range r.All() {
			var at *loc
			if f := l.field(i); f != nil {
				at = f.val
			}
			c.child(step{key: k, index: -1}, x, rt.elem, at)
			i++
		}
	case kMaybe:
		x, ok := v.(haus.Variant)
		switch {
		case ok && x.Tag.String() == "None" && len(x.Args) == 0:
		case ok && x.Tag.String() == "Some" && len(x.Args) == 1:
			c.child(step{index: 0}, x.Args[0], rt.elem, l.item(0))
		default:
			fix := ""
			if ok && x.Tag.String() == "None" {
				fix = payloadFix("None", &caseType{tag: "None"})
			} else if ok && x.Tag.String() == "Some" {
				fix = payloadFix("Some", &caseType{tag: "Some", payload: payloadPositional, items: []*typ{rt.elem}})
			}
			c.report(SeverityError, notCase(v, "None", "Some"),
				fmt.Sprintf("expected None or Some(…) (%s), found %s", describe(t), found(v)), fix, spanOf(l))
		}
	case kSecret:
		c.secret(v, rt.elem, l)
	case kRecord:
		r, ok := v.(haus.Record)
		if !ok {
			c.mismatch(v, t, l)
			return
		}
		c.record(r, rt.rec, l)
	case kVariant:
		c.variant(v, rt.vrt, t, l)
	default:
		c.scalar(v, rt, t, l)
	}
}

// scalar checks a value of a type without parts, as decoding does.
func (c *checker) scalar(v haus.Value, rt, t *typ, l *loc) {
	n := len(c.w.path)
	_, _, err := c.w.resolved(v, rt, t)
	c.w.path = c.w.path[:n]
	if err == nil {
		return
	}
	e, ok := err.(*haus.Error)
	if !ok {
		c.errorAt(haus.CodeTypeMismatch, err.Error(), l)
		return
	}
	at := l
	if e.Code == haus.CodeInvalidTime && l.item(0) != nil {
		at = l.item(0) // the string of Date("…")
	}
	sp := spanOf(at)
	if !c.located {
		sp = span{}
	}
	c.add(Issue{Code: e.Code, Message: e.Message, Path: e.Path, Offset: sp.start, End: sp.end})
}

func (c *checker) mismatch(v haus.Value, t *typ, l *loc) {
	c.errorAt(haus.CodeTypeMismatch, fmt.Sprintf("expected %s, found %s", describe(t), found(v)), l)
}

// secret checks what's inside, then replaces whatever was found there
// (messages quote values, keys and tags of the data, and paths may name
// keys) by one error at the secret, with its type only.
func (c *checker) secret(v haus.Value, item *typ, l *loc) {
	before := len(c.issues)
	c.value(v, item, l)
	inside := false
	for _, is := range c.issues[before:] {
		if is.Severity == SeverityError {
			inside = true
			c.errors--
		}
	}
	c.issues = c.issues[:before]
	if inside {
		c.errorAt(haus.CodeInvalidSecret, fmt.Sprintf("expected %s (a Secret: the value is not shown)", describe(item)), l)
	}
}

func (c *checker) record(r haus.Record, rt *recordType, l *loc) {
	var missing []string
	for i := range rt.fields {
		f := &rt.fields[i]
		if _, ok := r.Get(f.key); !ok && !f.optional {
			missing = append(missing, quoteKey(f.key))
		}
	}
	if len(missing) > 0 {
		s := ""
		if len(missing) > 1 {
			s = "s"
		}
		sp := spanOf(l)
		sp.end = sp.start + 1
		c.report(SeverityError, haus.CodeMissingField, fmt.Sprintf("missing field%s %s", s, strings.Join(missing, ", ")), "", sp)
	}
	i := -1
	for k, x := range r.All() {
		i++
		if c.stopped() {
			return
		}
		var at *loc
		keySpan := spanOf(l)
		if f := l.field(i); f != nil {
			at, keySpan = f.val, span{f.keyStart, f.keyEnd}
		}
		f := rt.field(k)
		if f != nil {
			if f.deprecated != nil {
				c.w.path = append(c.w.path, step{key: k, index: -1})
				c.report(SeverityHint, haus.CodeDeprecated, f.deprecated.note(quoteKey(k)), "", keySpan)
				c.w.path = c.w.path[:len(c.w.path)-1]
			}
			c.child(step{key: k, index: -1}, x, f.typ, at)
			continue
		}
		var unused []string
		for _, g := range rt.fields {
			if _, ok := r.Get(g.key); !ok {
				unused = append(unused, g.key)
			}
		}
		hint := suggest(k, unused)
		c.w.path = append(c.w.path, step{key: k, index: -1})
		if rt.closed {
			c.report(SeverityError, haus.CodeUnknownField, fmt.Sprintf("%s is not a field of this closed record.%s", quoteKey(k), hint), "", keySpan)
		} else {
			c.report(SeverityHint, haus.CodeUnlistedField, fmt.Sprintf("%s is not in the schema; a reader ignores it.%s", quoteKey(k), hint), "", keySpan)
		}
		c.w.path = c.w.path[:len(c.w.path)-1]
	}
}

func (c *checker) variant(v haus.Value, vt *variantType, t *typ, l *loc) {
	x, ok := v.(haus.Variant)
	if !ok {
		c.mismatch(v, t, l)
		return
	}
	tagSpan := span{}
	if l != nil {
		tagSpan = span{l.start, l.tagEnd}
	}
	cs := vt.caseOf(x.Tag.String())
	if cs == nil {
		names := make([]string, len(vt.cases))
		for i, k := range vt.cases {
			names[i] = k.tag
		}
		hint := suggest(x.Tag.String(), names)
		if vt.open {
			// < > lists no tags: any tag is meant, so there is nothing to hint.
			if len(vt.cases) > 0 {
				c.report(SeverityHint, haus.CodeUnlistedTag,
					fmt.Sprintf("%s is not in the schema; a reader keeps it as an unknown value.%s", x.Tag.String(), hint), "", tagSpan)
			}
			c.scalar(v, &typ{kind: kAny}, t, l)
			return
		}
		c.report(SeverityError, haus.CodeUnknownTag, fmt.Sprintf("%s is not allowed here: expected %s.%s", quote(x.Tag.String()), tags(vt), hint), "", tagSpan)
		return
	}
	if cs.deprecated != nil {
		c.report(SeverityHint, haus.CodeDeprecated, cs.deprecated.note(x.Tag.String()), "", tagSpan)
	}
	switch cs.payload {
	case payloadNone:
		if len(x.Args) > 0 {
			c.report(SeverityError, haus.CodeWrongPayload, x.Tag.String()+" takes no payload", payloadFix(x.Tag.String(), cs), spanOf(l))
		}
	case payloadRecord, payloadNamed:
		r, ok := oneRecord(x.Args)
		if !ok {
			c.report(SeverityError, haus.CodeWrongPayload,
				fmt.Sprintf("%s takes one argument, a record; found %s", x.Tag.String(), foundArgs(x.Args)), payloadFix(x.Tag.String(), cs), spanOf(l))
			return
		}
		// Tag { … }: the record is at the variant's level and place.
		if cs.payload == payloadRecord {
			c.record(r, cs.rec, l.item(0))
		} else {
			c.value(r, cs.named, l.item(0))
		}
	default:
		if len(cs.items) != len(x.Args) {
			described := make([]string, len(cs.items))
			for i, it := range cs.items {
				described[i] = describe(it)
			}
			s := "s"
			if len(cs.items) == 1 {
				s = ""
			}
			c.report(SeverityError, haus.CodeWrongPayload, fmt.Sprintf("%s takes %d argument%s (%s), found %d",
				x.Tag.String(), len(cs.items), s, strings.Join(described, ", "), len(x.Args)), payloadFix(x.Tag.String(), cs), spanOf(l))
			return
		}
		for i, a := range x.Args {
			c.child(step{index: i}, a, cs.items[i], l.item(i))
		}
	}
}

// note is what tools say about a use of name: mail is deprecated: use email.
func (d *deprecated) note(name string) string {
	if d.why == "" {
		return name + " is deprecated"
	}
	return name + " is deprecated: " + d.why
}

// payloadFix says what a tag takes, as a fix: Point takes 2 arguments
// (Float64, Float64): write `Point(…, …)`.
func payloadFix(tag string, c *caseType) string {
	if r := caseRecord(c); r != nil {
		fields := make([]string, 0, min(len(r.fields), 7))
		for i, f := range r.fields {
			if i == 6 {
				fields = append(fields, "…")
				break
			}
			opt := ""
			if f.optional {
				opt = "?"
			}
			fields = append(fields, quoteKey(f.key)+opt+": "+describe(f.typ))
		}
		record := "{}"
		if len(fields) > 0 {
			record = "{ " + strings.Join(fields, ", ") + " }"
		}
		return fmt.Sprintf("%s takes one argument, a record %s: write `%s { … }`.", tag, record, tag)
	}
	items := c.items
	if c.payload == payloadNamed {
		items = []*typ{c.named}
	}
	if len(items) == 0 {
		return fmt.Sprintf("%s takes no payload: write %#q.", tag, tag)
	}
	described := make([]string, len(items))
	holes := make([]string, len(items))
	for i, it := range items {
		described[i], holes[i] = describe(it), "…"
	}
	s := "s"
	if len(items) == 1 {
		s = ""
	}
	return fmt.Sprintf("%s takes %d argument%s (%s): write `%s(%s)`.", tag, len(items), s,
		strings.Join(described, ", "), tag, strings.Join(holes, ", "))
}

// suggest is " Did you mean quantity?" for the closest candidate within two
// edits, or "".
func suggest(word string, candidates []string) string {
	w := strings.ToLower(word)
	best, bestD := "", 3
	for _, cand := range candidates {
		if d := distance(w, strings.ToLower(cand)); d < bestD {
			best, bestD = cand, d
		}
	}
	if best == "" {
		return ""
	}
	return " Did you mean " + best + "?"
}

// distance is the edit distance, or 3 for strings far apart in length.
func distance(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	if len(ra)-len(rb) > 2 || len(rb)-len(ra) > 2 || len(ra) > 64 || len(rb) > 64 {
		return 3
	}
	prev := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur := make([]int, len(rb)+1)
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			sub := 1
			if ra[i-1] == rb[j-1] {
				sub = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+sub)
		}
		prev = cur
	}
	return prev[len(rb)]
}
