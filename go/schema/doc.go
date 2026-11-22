// Package schema reads haus schema files (.schema.haus, spec §14) with their
// imports (spec §13.3), and decodes and encodes values with their types
// (spec §15).
//
// [Load] reads a schema file, its relative imports next to it and the
// packages it imports found by a [Locator]: packages given explicitly
// ([Explicit]), as directories or as file trees ([fs.FS]), or two locators
// ([Or]). [Parse] reads a schema from text. Every rule of spec §14 and
// §13.3 is checked when a schema is loaded, so a [Schema] that loads
// decodes in time linear in the input.
//
//	packages, err := schema.NewExplicit().Folder("schemas")
//	s, err := schema.Load("order.schema.haus", schema.Options{Packages: packages})
//	order, err := s.Type("Order")
//	v, _ := haus.Parse(src)
//	decoded, err := order.Decode(v)
//
// [Type.Decode] gives the value an encoder writes back: integers in decimal
// (-0 as 0), floats in their one spelling, the fields an open record
// doesn't list left out, and everything else as it was. Errors are
// *haus.Error values with a code (spec §17) and the path of the failing value
// ($.items[2].price). std/time's types are checked by their profile
// ([CheckTime]). [Codec] chooses host types (spec §13.4), and [Secret]
// holds a value that is never printed.
//
// [Type.ToJSON] and [Type.FromJSON] write and read a type's schema-based
// JSON (spec §16.3), the JSON a JSON consumer expects. [Schema.CheckText]
// reports every problem of a data file with its position, and hints for
// fields and tags an open type doesn't list and for deprecated ones.
package schema
