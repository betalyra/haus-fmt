module github.com/betalyra/haus-fmt/fuzz/go

go 1.26

require github.com/betalyra/haus-fmt/go v0.0.0

// Not part of the published module: a program of its own, built by
// fuzz/build.sh against the checkout.
replace github.com/betalyra/haus-fmt/go => ../../go
