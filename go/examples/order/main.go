// The same order, decoded with the schema's own types and with the app's
// codecs. The same steps as rust/examples/order, on the same files.
// Run: go run ./examples/order (from go/).
package main

import (
	"fmt"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// root is the folder of the repository.
func root() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..", "..")
}

// Order is the app's type for the schema's Root, with the codecs' types.
type Order struct {
	ID        *big.Int
	Customer  string
	Placed    time.Time
	Total     Amount
	DeliverTo [2]float64 // [lng, lat]
	Status    Status
}

// Status is one of Pending, Shipped and Cancelled.
type Status interface{ isStatus() }

type (
	Pending   struct{}
	Shipped   struct{ Tracking string }
	Cancelled struct{}
)

func (Pending) isStatus()   {}
func (Shipped) isStatus()   {}
func (Cancelled) isStatus() {}

var codecs, _ = schema.NewCodecs(cents, geoJSON, date)

// decodeOrder decodes v with the schema and the codecs, which check their
// rules (errors have the place of the value), and then gives the codecs'
// host values.
func decodeOrder(t schema.Type, v haus.Value) (Order, error) {
	d, err := t.DecodeWith(v, schema.DecodeOptions{Codecs: codecs})
	if err != nil {
		return Order{}, err
	}
	r := d.(haus.Record)
	get := func(k string) haus.Value { x, _ := r.Get(k); return x }
	o := Order{Customer: string(get("customer").(haus.Variant).Args[0].(haus.String))}
	o.ID, _ = get("id").(haus.Number).BigInt()
	placed, _ := date.Decode(get("placed"))
	total, _ := cents.Decode(get("total"))
	at, _ := geoJSON.Decode(get("deliverTo"))
	o.Placed, o.Total, o.DeliverTo = placed.(time.Time), total.(Amount), at.([2]float64)
	switch s := get("status").(haus.Variant); s.Tag.String() {
	case "Pending":
		o.Status = Pending{}
	case "Cancelled":
		o.Status = Cancelled{}
	default:
		tracking, _ := s.Args[0].(haus.Record).Get("tracking")
		o.Status = Shipped{Tracking: string(tracking.(haus.String))}
	}
	return o, nil
}

// encodeOrder encodes an Order with the same codecs.
func encodeOrder(t schema.Type, o Order) (haus.Value, error) {
	placed, err := date.Encode(o.Placed)
	if err != nil {
		return nil, err
	}
	total, err := cents.Encode(o.Total)
	if err != nil {
		return nil, err
	}
	at, err := geoJSON.Encode(o.DeliverTo)
	if err != nil {
		return nil, err
	}
	var status haus.Value
	switch s := o.Status.(type) {
	case Pending:
		status = haus.Variant{Tag: haus.MustTag("Pending")}
	case Cancelled:
		status = haus.Variant{Tag: haus.MustTag("Cancelled")}
	case Shipped:
		r, _ := haus.NewRecord(haus.Field{Key: "tracking", Value: haus.String(s.Tracking)})
		status = haus.Variant{Tag: haus.MustTag("Shipped"), Args: []haus.Value{r}}
	}
	v, err := haus.NewRecord(
		haus.Field{Key: "id", Value: haus.NumberFromBigInt(o.ID)},
		haus.Field{Key: "customer", Value: haus.Variant{Tag: haus.MustTag("UserId"), Args: []haus.Value{haus.String(o.Customer)}}},
		haus.Field{Key: "placed", Value: placed},
		haus.Field{Key: "total", Value: total},
		haus.Field{Key: "deliverTo", Value: at},
		haus.Field{Key: "status", Value: status},
	)
	if err != nil {
		return nil, err
	}
	return t.EncodeWith(v, schema.DecodeOptions{Codecs: codecs})
}

func parse(text string) haus.Value {
	v, err := haus.Parse([]byte(text))
	if err != nil {
		log.Fatal(err)
	}
	return v
}

func floats(xs [2]float64) string {
	return "[" + strconv.FormatFloat(xs[0], 'g', -1, 64) + ", " + strconv.FormatFloat(xs[1], 'g', -1, 64) + "]"
}

func main() {
	// The packages the schema imports, @haus-fmt/money and @haus-fmt/geo,
	// given by the folder of their directories (a Go module that embeds a
	// package gives it with PackageFS instead).
	packages, err := schema.NewExplicit().Folder(filepath.Join(root(), "extensions"))
	if err != nil {
		log.Fatal(err)
	}
	s, err := schema.Load(filepath.Join(root(), "examples", "order.schema.haus"), schema.Options{Packages: packages})
	if err != nil {
		log.Fatal(err)
	}
	rootType, _ := s.Type("Root")
	text, err := os.ReadFile(filepath.Join(root(), "examples", "order.haus"))
	if err != nil {
		log.Fatal(err)
	}
	order := string(text)

	// Without codecs: Money is Money(Decimal, Currency), the Decimal as its exact text.
	plain, err := rootType.Decode(parse(order))
	if err != nil {
		log.Fatal(err)
	}
	get := func(k string) haus.Variant { x, _ := plain.(haus.Record).Get(k); return x.(haus.Variant) }
	total := get("total")
	fmt.Printf("plain:  %s pays %s %s\n", get("customer").Args[0].(haus.String), total.Args[0], total.Args[1].(haus.Variant).Tag.String())

	// With codecs: the fields have the codecs' types.
	typed, err := decodeOrder(rootType, parse(order))
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("typed:  %s pays %s cents, deliver to [lng, lat] %s\n", typed.Customer, typed.Total.Cents, floats(typed.DeliverTo))
	fmt.Printf("placed: %s, a %s\n", typed.Placed.Format(time.DateOnly), typed.Placed.Weekday())

	// Variants are a sealed interface: switch on the type.
	switch s := typed.Status.(type) {
	case Shipped:
		fmt.Printf("status: shipped, tracking %s\n", s.Tracking)
	case Pending, Cancelled:
		fmt.Println("status: not on its way")
	}

	// Encoding with the same codecs gives back the same haus text.
	encoded, err := encodeOrder(rootType, typed)
	if err != nil {
		log.Fatal(err)
	}
	out, err := haus.FormatValue(encoded, haus.FormatOptions{Layout: haus.Compact})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(strings.TrimSuffix(string(out), "\n"))

	// Codecs add rules on top of the schema's: Eur is a valid tag, but not ISO-shaped.
	eur := strings.Replace(order, "EUR", "Eur", 1)
	if _, err := rootType.Decode(parse(eur)); err == nil {
		fmt.Println("Eur without codecs: accepted")
	}
	if _, err := decodeOrder(rootType, parse(eur)); err != nil {
		fmt.Printf("Eur with codecs: %v\n", err)
	}
	if _, err := decodeOrder(rootType, parse(strings.Replace(order, "44.40", "44.405", 1))); err != nil {
		fmt.Printf("44.405 with codecs: %v\n", err)
	}
}
