package schema_test

import (
	"errors"
	"fmt"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

func ExampleType_Decode() {
	s, err := schema.Parse([]byte(`
import std/time (Date)
type Order = { id: Int, total: Decimal, items: Array { sku: String, price: Float64 }, due?: Date }`), schema.Options{})
	if err != nil {
		panic(err)
	}
	order, _ := s.Type("Order")

	v, _ := haus.Parse([]byte(`{ id: 0x10, total: 19.90, items: [{ sku: "A1", price: 0.10 }], note: "ignored" }`))
	decoded, _ := order.Decode(v)
	text, _ := haus.Canonical(decoded)
	fmt.Println(text)

	v, _ = haus.Parse([]byte(`{ id: 1, total: 1, items: [{ sku: "A1", price: "0.10" }], due: Date("2026-02-30") }`))
	_, err = order.Decode(v)
	var e *haus.Error
	if errors.As(err, &e) {
		fmt.Println(e.Code, e.Path)
	}
	// Output:
	// {id:16,items:[{price:0.1,sku:"A1"}],total:19.90}
	// type-mismatch $.items[0].price
}

func ExampleType_Format() {
	s, err := schema.Parse([]byte(`type Order = { id: Int, total: Decimal, items: Array { sku: String, price: Float64 } }`), schema.Options{})
	if err != nil {
		panic(err)
	}
	order, _ := s.Type("Order")

	decoded, _ := order.Parse([]byte(`{ id: 0x10, total: 19.90, items: [{ sku: "A1", price: 0.10 }], note: "ignored" }`))
	text, _ := order.Format(decoded, haus.FormatOptions{Layout: haus.Minimised})
	fmt.Print(string(text))

	_, err = order.Format(haus.Array{}, haus.FormatOptions{Layout: haus.Minimised})
	fmt.Println(err)
	// Output:
	// {id:16,total:19.90,items:[{sku:"A1",price:0.1}]}
	// $: expected Order, found an array [type-mismatch]
}
