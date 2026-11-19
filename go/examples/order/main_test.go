package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

// TestOutput runs the example and compares its output with the lines of
// rust/examples/order. Messages of errors are each binding's own (spec §17
// fixes codes, not messages): those lines are compared as Go writes them.
func TestOutput(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	main()
	os.Stdout = stdout
	_ = w.Close()
	out, _ := io.ReadAll(r)
	if got := string(out); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

var want = strings.Join([]string{
	"plain:  usr_ada pays 44.40 EUR",
	"typed:  usr_ada pays 4440 cents, deliver to [lng, lat] [-9.1393, 38.7223]",
	"placed: 2026-11-09, a Monday",
	"status: shipped, tracking DE-4711",
	`{ id: 7, customer: UserId("usr_ada"), placed: Date("2026-11-09"), total: Money(44.40, EUR), deliverTo: LatLng(38.7223, -9.1393), status: Shipped { tracking: "DE-4711" } }`,
	"Eur without codecs: accepted",
	// rust: Eur with codecs: .total: Eur is not a currency: three letters A–Z (ISO 4217)
	"Eur with codecs: $.total: @haus-fmt/money@1#Money rejects the value: Eur is not a currency: three letters A–Z (ISO 4217) [type-mismatch]",
	// rust: 44.405 with codecs: .total: 44.405 has more than 2 decimal places
	"44.405 with codecs: $.total: @haus-fmt/money@1#Money rejects the value: 44.405 has more than 2 decimal places [type-mismatch]",
	"",
}, "\n")
