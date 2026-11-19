package haus

import "strings"

// The syntax tree the formatter works on: values with their source
// spellings, and the comments and blank lines around them. The parser builds
// it only for formatting; [Parse] builds values alone.

// comment is a comment as written (a CR LF inside it read as LF).
type comment struct {
	text string
	// nl is the most line breaks in a row (with only blanks between them)
	// since the previous comment or item: 0 if the comment is on that line,
	// 2 or more if a blank line comes before it.
	nl int
}

// blank reports whether a blank line comes before the comment.
func (c comment) blank() bool { return c.nl >= 2 }

// gap collects the comments and line breaks between two items.
type gap struct {
	comments []comment
	nl       int // the most line breaks in a row after the last comment (or since the item)
	run      int // the line breaks in a row so far: a comment or a comma ends a row
}

// lineBreak counts a line break of whitespace; g may be nil.
func (g *gap) lineBreak() {
	if g != nil {
		g.run++
		g.nl = max(g.nl, g.run)
	}
}

// form is how a variant's payload is written.
type form uint8

const (
	formBare   form = iota // Tag
	formBraces             // Tag { … }, also for Tag({ … })
	formParens             // Tag(a, b)
)

// node is one value in the syntax tree.
type node struct {
	val      Value
	text     string    // the spelling of a number, byte string or "…" string; "" to write it from the value
	form     form      // for variants
	items    []*item   // the fields of a record (also a record payload), elements of an array, arguments of a payload
	dangling []comment // comments after the last item, before the closer
	sameLine bool      // the closer is on the line where the last item ends
	closeNL  int       // line breaks before the closer, after the last item or comment
	iw       int       // memo for the inline width: 0 unknown, -1 never inline, else width+1
}

// item is an entry of a container or file: a field, an element or an
// argument, with its comments.
type item struct {
	leading  []comment // comments on lines of their own above it
	blank    bool      // a blank line directly before it
	keyed    bool      // a record field
	key      string    // written bare when it can be, else quoted with the fewest escapes
	val      *node
	trailing []comment // comments after it on its last line
}

// fileNode is a whole file: its top-level items and the comments after them.
type fileNode struct {
	items    []*item
	dangling []comment
}

// trailingCount returns how many of the comments in g start on the line of
// the previous token: those with no line break before them, up to the first
// that spans lines (a comment after it starts on a later line).
func trailingCount(g *gap) int {
	n := 0
	for n < len(g.comments) && g.comments[n].nl == 0 {
		n++
		if strings.Contains(g.comments[n-1].text, "\n") {
			break
		}
	}
	return n
}

// newItem starts the item that follows the gap g: the comments of g on the
// line of the previous item prev (if any) trail prev, the others lead the
// new item. It resets g.
func newItem(prev *item, g *gap) *item {
	it := &item{blank: g.nl >= 2}
	cs := g.comments
	if prev != nil {
		n := trailingCount(g)
		prev.trailing = append(prev.trailing, cs[:n]...)
		cs = cs[n:]
	}
	if len(cs) > 0 {
		it.leading = cs
	}
	*g = gap{}
	return it
}

// closeItems ends a container whose last item is prev (nil if it has none),
// with the gap g before the closer. It returns the comments that dangle at
// the end, whether the closer is on the line where the last item ends, and
// the line breaks before the closer.
func closeItems(prev *item, g *gap) (dangling []comment, sameLine bool, closeNL int) {
	cs := g.comments
	if prev != nil {
		n := trailingCount(g)
		prev.trailing = append(prev.trailing, cs[:n]...)
		cs = cs[n:]
	}
	sameLine = prev != nil && len(cs) == 0 && g.nl == 0
	closeNL = g.nl
	*g = gap{}
	return cs, sameLine, closeNL
}

// mergeRecordArg turns the payload of Tag({ … }), a parenthesized payload
// whose one argument is a record, into a record payload, Tag { … }. The
// comments inside the parentheses but outside the braces move inside the
// braces (spec §11).
func mergeRecordArg(parens *node) *node {
	arg := parens.items[0]
	rec := arg.val
	rec.val = parens.val
	rec.form = formBraces
	rec.iw = 0
	// Comments before the record lead its first entry. In an empty record a
	// blank line between them and the record goes to the comment after them
	// (pending, if that comment comes from after the record).
	pending := 0
	if len(arg.leading) > 0 {
		if len(rec.items) > 0 {
			first := rec.items[0]
			if len(first.leading) > 0 {
				first.leading[0].nl = max(first.leading[0].nl, blankNL(arg.blank))
			} else {
				first.blank = first.blank || arg.blank
			}
			first.leading = append(append([]comment(nil), arg.leading...), first.leading...)
		} else {
			if len(rec.dangling) > 0 {
				rec.dangling[0].nl = max(rec.dangling[0].nl, blankNL(arg.blank))
			} else {
				pending = blankNL(arg.blank)
			}
			rec.dangling = append(append([]comment(nil), arg.leading...), rec.dangling...)
		}
	}
	// Comments after the record: on the line of its last entry they trail
	// that entry (unless a comment over several lines already ends that
	// line), otherwise they dangle at its end, after the line breaks before
	// its closing brace (a blank line there stays).
	var moved []comment
	if len(arg.trailing) > 0 && len(rec.items) > 0 && len(rec.dangling) == 0 && rec.sameLine && !endsMultiline(rec.items[len(rec.items)-1].trailing) {
		last := rec.items[len(rec.items)-1]
		last.trailing = append(last.trailing, arg.trailing...)
	} else {
		moved = append(moved, arg.trailing...)
	}
	moved = append(moved, parens.dangling...)
	if len(moved) > 0 {
		moved[0].nl = max(moved[0].nl, rec.closeNL, pending)
		rec.dangling = append(rec.dangling, moved...)
	}
	return rec
}

// endsMultiline reports whether the last of the comments spans several lines.
func endsMultiline(cs []comment) bool {
	return len(cs) > 0 && strings.Contains(cs[len(cs)-1].text, "\n")
}

func blankNL(blank bool) int {
	if blank {
		return 2
	}
	return 0
}
