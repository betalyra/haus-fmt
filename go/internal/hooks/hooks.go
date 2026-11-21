// Package hooks lets the schema package build values it knows are valid
// without the copies and checks of the public constructors, and use the
// JSON reader and writer of package haus. Package haus sets the hooks when
// it is initialised; this package doesn't import it, so the hooks are typed
// as any and asserted once by their users.
package hooks

var (
	// RecordOwned is a func([]haus.Field) haus.Record that takes ownership of
	// fields whose keys are known to be distinct, without copying them.
	RecordOwned any
	// RecordFields is a func(haus.Record) []haus.Field that returns a
	// record's fields, in order, without copying them; they must not be
	// changed.
	RecordFields any
	// AppendQuoted is a func([]byte, string) ([]byte, bool) that appends a
	// "…" string as the writers write it, and reports whether the string is
	// valid UTF-8.
	AppendQuoted any
	// AppendLine is a func(b []byte, v haus.Value, lim haus.Limits,
	// minimised bool, depth int) ([]byte, error) that appends a value built
	// in code in the compact or minimised layout, as FormatValue writes it
	// at nesting depth (a container there is at depth+1), with its checks;
	// lim is resolved. An error's path starts at the value.
	AppendLine any
	// CheckWritten is a func(v haus.Value, lim haus.Limits) error that is
	// CheckValue for a value AppendLine has written (with no error), without
	// checking again that its strings and keys are UTF-8; lim is resolved.
	CheckWritten any
	// NumberLit is a func(string) haus.Number for a normalized literal
	// (spec §2), which it doesn't check.
	NumberLit any
	// ParseSchemaJSON is a func(src string, lim haus.Limits, skipBOM bool)
	// (haus.Value, error) that reads a JSON text for schema-based JSON
	// (spec §16.3) as the value the import gives (§16.1), with the nesting
	// limit 4·d+1 and no string limits; lim is resolved.
	ParseSchemaJSON any
	// ParseValues is a func(src string) ([]haus.Value, error) that parses
	// values within a file, as the arguments of an attribute (spec §14):
	// src doesn't start the file, so a byte order mark is no more skipped
	// there than after a comma, and #haus is no version directive.
	ParseValues any
	// SelfDescribing is a func(j haus.Value, lim haus.Limits, depth int,
	// prefix string) (haus.Value, error) that reads the self-describing
	// form (§16.2, no envelope) j at nesting depth; error paths start with
	// prefix.
	SelfDescribing any
	// SelfDescribingArgs is a func(tag string, args haus.Value, lim
	// haus.Limits, depth int, prefix string) (haus.Value, error) that reads
	// the "_args" of an unknown tag (§16.3) as self-describing values.
	SelfDescribingArgs any
	// AppendSelfDescribing is a func([]byte, haus.Value) []byte that appends
	// the self-describing form of a checked value, without the envelope.
	AppendSelfDescribing any
	// AppendJSONString is a func([]byte, string) []byte that appends a JSON
	// string with the escapes of §16.
	AppendJSONString any
	// JSONLines is a func(r io.Reader, maxLine int, convert func(line
	// string, i int) (haus.Value, error)) iter.Seq2[haus.Value, error] that
	// reads JSON Lines (§16, "Streams").
	JSONLines any
)
