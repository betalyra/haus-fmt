module github.com/betalyra/haus-fmt/bench/speed/go

go 1.26

require (
	github.com/betalyra/haus-fmt/go v0.0.0
	github.com/goccy/go-json v0.12.0
)

// Not part of the published module: a benchmark of its own, outside go/'s
// module (CI for go/ never builds it), against the checkout.
replace github.com/betalyra/haus-fmt/go => ../../../go
