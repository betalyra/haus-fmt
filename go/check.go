package haus

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// MaxNodes is the most values (nodes) [CheckValue] accepts in one value built
// in code. A value whose arrays or records share one another many times (a
// DAG) expands when written out; this bounds the work of writing it
// (spec §9.8). 64 Mi, as many as the largest top-level value of a stream can
// hold.
const MaxNodes = 64 << 20

// CheckValue checks that a value built in code can be written within the
// limits (spec §7, §9.8): strings and keys are valid UTF-8 (cannot-encode),
// tags are [A-Z][A-Za-z0-9_]* (invalid-tag), numbers, strings, keys, tags
// and byte strings are within their limits, nesting is within the depth
// limit (a record payload, Tag { … }, counting one level, as when writing),
// it has at most [MaxNodes] nodes (too-many-nodes), and it doesn't contain
// itself (cyclic-value). Fields left at zero in limits take their defaults.
//
// The error's Path says where the problem is, such as $.items[2]. Values
// that [Parse] returns pass with the limits they were parsed with.
func CheckValue(v Value, limits Limits) error {
	lim, err := limits.resolve()
	if err != nil {
		return err
	}
	c := valueChecker{lim: lim}
	return c.value(v, 0)
}

// containerID identifies the items of a container: the address of its first
// item, and how many there are. Two containers with the same id hold the
// same values, so a container whose id appears twice on one path from the
// root contains itself.
type containerID struct {
	first any // *Value or *Field
	n     int
}

// idOf returns the id of a container with at least one item.
func idOf(v Value) (containerID, bool) {
	switch v := v.(type) {
	case Array:
		if len(v) > 0 {
			return containerID{&v[0], len(v)}, true
		}
	case Record:
		if len(v.fields) > 0 {
			return containerID{&v.fields[0], len(v.fields)}, true
		}
	case Variant:
		if len(v.Args) > 0 {
			return containerID{&v.Args[0], len(v.Args)}, true
		}
	}
	return containerID{}, false
}

// cycleGuard keeps the ids of the containers on the path from the root to
// the value being written. It costs a push and a pop per container; the
// path is searched for a repeated id only when the depth limit is reached,
// which is where every value that contains itself ends up (spec §9.8: a
// value that contains itself is cyclic-value, a deep one nesting-too-deep).
// A cycle longer than the depth limit is reported as nesting-too-deep.
type cycleGuard struct {
	ids []containerID
}

func (g *cycleGuard) push(v Value) {
	id, _ := idOf(v)
	g.ids = append(g.ids, id)
}

func (g *cycleGuard) pop() { g.ids = g.ids[:len(g.ids)-1] }

// cyclic reports whether the path, with v below it, holds a container twice.
func (g *cycleGuard) cyclic(v Value) bool {
	seen := make(map[containerID]bool, len(g.ids)+1)
	for _, id := range g.ids {
		if id.first == nil {
			continue
		}
		if seen[id] {
			return true
		}
		seen[id] = true
	}
	id, ok := idOf(v)
	return ok && seen[id]
}

// depthError is the error for a container at the depth limit: cyclic-value
// if it contains itself, nesting-too-deep otherwise.
func (g *cycleGuard) depthError(v Value, limit int) *Error {
	if g.cyclic(v) {
		return newError(CodeCyclicValue, "the value contains itself, so it has no finite text")
	}
	return newError(CodeNestingTooDeep, fmt.Sprintf("nesting deeper than the limit of %d", limit))
}

// step is one step of a path (spec §15): a key, or an index.
type step struct {
	key   string
	index int // -1 for a key
}

// pathString writes a path from $ (spec §15): .key for an identifier,
// ["key"] with the key in canonical form otherwise, [i] for an index.
func pathString(steps []step) string {
	var b strings.Builder
	b.WriteByte('$')
	for _, s := range steps {
		if s.index >= 0 {
			b.WriteByte('[')
			b.WriteString(strconv.Itoa(s.index))
			b.WriteByte(']')
			continue
		}
		b.WriteString(pathKey(s.key))
	}
	return b.String()
}

// valueChecker walks a value for [CheckValue].
type valueChecker struct {
	lim   Limits
	guard cycleGuard
	path  []step
	nodes int
}

func (c *valueChecker) fail(code ErrorCode, format string, args ...any) error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...), Path: pathString(c.path)}
}

func (c *valueChecker) value(v Value, depth int) error {
	c.nodes++
	if c.nodes > MaxNodes {
		return c.fail(CodeTooManyNodes, "the value has more than %d nodes", MaxNodes)
	}
	switch v := v.(type) {
	case Number:
		return c.number(v)
	case String:
		return c.text(string(v), CodeStringTooLong, "string")
	case Bytes:
		if 2*len(v) > c.lim.MaxStringLength {
			return c.fail(CodeStringTooLong, "a byte string of %d bytes, more than the limit of %d characters", len(v), c.lim.MaxStringLength)
		}
		return nil
	case Array:
		if len(v) == 0 {
			return nil
		}
		if err := c.enter(v, depth); err != nil {
			return err
		}
		for i, e := range v {
			c.path = append(c.path, step{index: i})
			if err := c.value(e, depth+1); err != nil {
				return err
			}
			c.path = c.path[:len(c.path)-1]
		}
		c.guard.pop()
		return nil
	case Record:
		if v.Len() == 0 {
			return nil
		}
		if err := c.enter(v, depth); err != nil {
			return err
		}
		if err := c.fields(v, depth); err != nil {
			return err
		}
		c.guard.pop()
		return nil
	case Variant:
		if !isTag(v.Tag) {
			return c.fail(CodeInvalidTag, "the tag %s isn't [A-Z][A-Za-z0-9_]*", quoteForMessage(v.Tag))
		}
		if len(v.Tag) > c.lim.MaxStringLength {
			return c.fail(CodeTagTooLong, "a tag longer than the limit of %d characters", c.lim.MaxStringLength)
		}
		if len(v.Args) == 0 {
			return nil
		}
		if r, ok := v.Args[0].(Record); ok && len(v.Args) == 1 {
			// Tag { … }: the record is the payload's one level.
			if err := c.enter(r, depth); err != nil {
				return err
			}
			c.nodes++
			if err := c.fields(r, depth); err != nil {
				return err
			}
			c.guard.pop()
			return nil
		}
		if err := c.enter(v, depth); err != nil {
			return err
		}
		for i, a := range v.Args {
			c.path = append(c.path, step{index: i})
			if err := c.value(a, depth+1); err != nil {
				return err
			}
			c.path = c.path[:len(c.path)-1]
		}
		c.guard.pop()
		return nil
	case nil:
		return c.fail(CodeCannotEncode, "a nil value")
	}
	return c.fail(CodeCannotEncode, "an unknown kind of value")
}

// enter starts the container v at depth, one level deeper.
func (c *valueChecker) enter(v Value, depth int) error {
	if depth+1 > c.lim.MaxDepth {
		e := c.guard.depthError(v, c.lim.MaxDepth)
		e.Path = pathString(c.path)
		return e
	}
	c.guard.push(v)
	return nil
}

func (c *valueChecker) fields(r Record, depth int) error {
	for _, f := range r.fields {
		c.path = append(c.path, step{key: f.Key, index: -1})
		if !utf8.ValidString(f.Key) {
			return c.fail(CodeCannotEncode, "a key that isn't valid UTF-8")
		}
		if len(f.Key) > c.lim.MaxStringLength && utf8.RuneCountInString(f.Key) > c.lim.MaxStringLength {
			return c.fail(CodeKeyTooLong, "a key longer than the limit of %d characters", c.lim.MaxStringLength)
		}
		if err := c.value(f.Value, depth+1); err != nil {
			return err
		}
		c.path = c.path[:len(c.path)-1]
	}
	return nil
}

func (c *valueChecker) text(s string, tooLong ErrorCode, what string) error {
	if !utf8.ValidString(s) {
		return c.fail(CodeCannotEncode, "a %s that isn't valid UTF-8", what)
	}
	if len(s) > c.lim.MaxStringLength {
		if n := utf8.RuneCountInString(s); n > c.lim.MaxStringLength {
			return c.fail(tooLong, "a %s of %d characters, more than the limit of %d", what, n, c.lim.MaxStringLength)
		}
	}
	return nil
}

func (c *valueChecker) number(n Number) error {
	text := n.String()
	if len(text) > c.lim.MaxNumberLength {
		return c.fail(CodeNumberTooLong, "a number of %d characters, more than the limit of %d", len(text), c.lim.MaxNumberLength)
	}
	if i := strings.IndexByte(text, 'e'); i >= 0 {
		exp := strings.TrimPrefix(text[i+1:], "-")
		if len(exp) > 9 || atoi(exp) > c.lim.MaxExponent {
			return c.fail(CodeExponentTooLarge, "an exponent larger than the limit of %d", c.lim.MaxExponent)
		}
	}
	return nil
}
