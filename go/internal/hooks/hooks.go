// Package hooks lets the schema package build values it knows are valid
// without the copies and checks of the public constructors. Package haus
// sets the hooks when it is initialised; this package doesn't import it, so
// the hooks are typed as any and asserted once by their users.
package hooks

var (
	// RecordOwned is a func([]haus.Field) haus.Record that takes ownership of
	// fields whose keys are known to be distinct, without copying them.
	RecordOwned any
	// NumberLit is a func(string) haus.Number for a normalized literal
	// (spec §2), which it doesn't check.
	NumberLit any
)
