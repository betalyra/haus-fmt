package schema

import haus "github.com/betalyra/haus-fmt/go"

// formatFloat writes a finite float in the one spelling of spec §15 (bits 32
// or 64); see [haus.FormatFloat].
func formatFloat(f float64, bits int) string { return haus.FormatFloat(f, bits) }
