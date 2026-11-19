package haus

// The syntax tree the formatter works on: values with their source
// spellings, and the comments and blank lines around them. The parser builds
// it only for formatting; [Parse] builds values alone.

// comment is a comment as written (a CR LF inside it read as LF).
type comment struct {
	text string
	nl   int // line breaks between the previous token or comment and this one
}

// blank reports whether a blank line comes before the comment.
func (c comment) blank() bool { return c.nl >= 2 }

// gap collects the comments and line breaks between two tokens.
type gap struct {
	comments []comment
	nl       int // line breaks after the last comment (or since the token)
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

// trailingCount returns how many of the comments in g directly follow the
// previous token on its line.
func trailingCount(g *gap) int {
	n := 0
	for n < len(g.comments) && g.comments[n].nl == 0 {
		n++
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
// the end, and whether the closer is on the line where the last item ends.
func closeItems(prev *item, g *gap) (dangling []comment, sameLine bool) {
	cs := g.comments
	if prev != nil {
		n := trailingCount(g)
		prev.trailing = append(prev.trailing, cs[:n]...)
		cs = cs[n:]
	}
	sameLine = prev != nil && len(cs) == 0 && g.nl == 0
	*g = gap{}
	return cs, sameLine
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
	// Comments before the record lead its first entry.
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
			}
			rec.dangling = append(append([]comment(nil), arg.leading...), rec.dangling...)
		}
	}
	// Comments after the record: on the line of its last entry they trail
	// that entry, otherwise they dangle at its end.
	if len(arg.trailing) > 0 {
		if len(rec.items) > 0 && len(rec.dangling) == 0 && rec.sameLine {
			last := rec.items[len(rec.items)-1]
			last.trailing = append(last.trailing, arg.trailing...)
		} else {
			rec.dangling = append(rec.dangling, arg.trailing...)
		}
	}
	rec.dangling = append(rec.dangling, parens.dangling...)
	return rec
}

func blankNL(blank bool) int {
	if blank {
		return 2
	}
	return 0
}
