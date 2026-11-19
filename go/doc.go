// Package haus reads and writes haus, a data format for people, friendly to
// write and pleasant to read (https://haus-fmt.org).
//
// [ParseAll] reads a file, zero or more top-level values separated by commas,
// into [Value]s; [Parse] reads a single document. Values are the six kinds of
// spec §1: [Number] (an exact decimal), [String], [Bytes], [Array], [Record]
// and [Variant] (a tag with arguments). The parser knows no types: it reads
// the syntax, enforces the limits of spec §7 while it reads, and reports every
// mistake as an [*Error] with a code from the catalogue (spec §17), a line and
// a column.
//
//	v, err := haus.Parse([]byte(`Person { name: "Ada", born: 1815 }`))
//	var e *haus.Error
//	if errors.As(err, &e) {
//		fmt.Println(e.Code, e.Line, e.Column)
//	}
//
// [Format] rewrites text in one of the standard layouts of spec §11 (pretty,
// compact, minimised), keeping comments in pretty; [FormatValue] and
// [FormatValues] write values built in code. [Canonical], [Equals], [Compare],
// [Hash] and [HashAll] implement spec §12. [StreamReader] reads a stream value
// by value from an [io.Reader] (spec §6).
//
// This package uses only the standard library.
package haus
