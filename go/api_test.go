package haus

import (
	"errors"
	"math/big"
	"strings"
	"testing"
)

func codeOf(err error) ErrorCode {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

func TestPositions(t *testing.T) {
	cases := []struct {
		src       string
		line, col int
	}{
		{"[1 2]", 1, 4},
		{"\uFEFF[1 2]", 1, 5},                  // a byte order mark is a character (spec §8)
		{"[\"😀\" 2]", 1, 6},                    // an emoji is one column
		{"[\r\n  1 2]", 2, 5},                  // CR LF is one line break
		{"[\"\u2028\" 2]", 1, 6},               // U+2028 doesn't start a line
		{"{\n  a: 1,\n  b: x }", 3, 6},         // bare-identifier
		{"// c\n\"a\x01b\"", 2, 3},             // control-character
		{"\"\"\"\n  ok\n bad\n  \"\"\"", 3, 1}, // block-string-indent
	}
	for _, c := range cases {
		_, err := ParseAll([]byte(c.src))
		var e *Error
		if !errors.As(err, &e) {
			t.Errorf("%q: no error", c.src)
			continue
		}
		if e.Line != c.line || e.Column != c.col {
			t.Errorf("%q: %d:%d, want %d:%d (%v)", c.src, e.Line, e.Column, c.line, c.col, e)
		}
	}
	if _, err := ParseAll([]byte("[1, \xff]")); codeOf(err) != CodeInvalidUTF8 {
		t.Errorf("invalid UTF-8: %v", err)
	} else if e := err.(*Error); e.Column != 5 {
		t.Errorf("invalid UTF-8 at column %d", e.Column)
	}
}

func TestVersionDirective(t *testing.T) {
	for src, want := range map[string]ErrorCode{
		"#haus 2\n{ a: 1 }":       CodeVersionDirective,
		"\uFEFF#haus 2\n{ a: 1 }": CodeVersionDirective,
		"#hello":                  CodeExpectedValue,
		" #haus 2":                CodeExpectedValue,
	} {
		if _, err := ParseAll([]byte(src)); codeOf(err) != want {
			t.Errorf("%q: %v, want %s", src, err, want)
		}
	}
}

func TestLimits(t *testing.T) {
	deep := func(n int, open, closer string) string {
		return strings.Repeat(open, n) + "1" + strings.Repeat(closer, n)
	}
	cases := []struct {
		src  string
		lim  Limits
		code ErrorCode
	}{
		{deep(256, "[", "]"), Limits{}, ""},
		{deep(257, "[", "]"), Limits{}, CodeNestingTooDeep},
		{deep(3, "A(", ")"), Limits{MaxDepth: 3}, ""},
		{deep(4, "A(", ")"), Limits{MaxDepth: 3}, CodeNestingTooDeep},
		{"Some { a: 1 }", Limits{MaxDepth: 1}, ""},
		{"Some({ a: 1 })", Limits{MaxDepth: 1}, CodeNestingTooDeep},
		{`"ééé"`, Limits{MaxStringLength: 3}, ""},
		{`"éééé"`, Limits{MaxStringLength: 3}, CodeStringTooLong},
		{`"a\u{41}\n"`, Limits{MaxStringLength: 3}, ""},
		{"\"\"\"\n    abc\n    \"\"\"", Limits{MaxStringLength: 3}, ""},
		{"\"\"\"\n    abcd\n    \"\"\"", Limits{MaxStringLength: 3}, CodeStringTooLong},
		{`{ abcd: 1 }`, Limits{MaxStringLength: 3}, CodeKeyTooLong},
		{`{ "abcd": 1 }`, Limits{MaxStringLength: 3}, CodeKeyTooLong},
		{`Abcd`, Limits{MaxStringLength: 3}, CodeTagTooLong},
		{`x"00 11"`, Limits{MaxStringLength: 5}, ""},
		{`x"00  11"`, Limits{MaxStringLength: 5}, CodeStringTooLong},
		{"12345", Limits{MaxNumberLength: 5}, ""},
		{"-12345", Limits{MaxNumberLength: 5}, CodeNumberTooLong},
		{"1_000", Limits{MaxNumberLength: 5}, ""},
		{"0xFFFF", Limits{MaxNumberLength: 6}, ""},                 // 4 hex digits: 65535 fits 5 characters
		{"0xFFFFF", Limits{MaxNumberLength: 7}, CodeNumberTooLong}, // 5 hex digits may not fit 6
		{"1e10", Limits{MaxExponent: 10}, ""},
		{"1e-11", Limits{MaxExponent: 10}, CodeExponentTooLarge},
		{"1e0000000000000000000010", Limits{MaxExponent: 10}, ""},
	}
	for _, c := range cases {
		_, err := ParseAllWith([]byte(c.src), c.lim)
		if codeOf(err) != c.code {
			t.Errorf("%.40q %+v: %v, want %q", c.src, c.lim, err, c.code)
		}
	}
	if _, err := ParseAllWith([]byte("1"), Limits{MaxDepth: MaxSupportedDepth + 1}); codeOf(err) != CodeUnsupportedDepth {
		t.Errorf("unsupported depth: %v", err)
	}
	if _, err := ParseAllWith([]byte(deep(MaxSupportedDepth, "[", "]")), Limits{MaxDepth: MaxSupportedDepth}); err != nil {
		t.Errorf("the supported depth: %v", err)
	}
	if got := DefaultLimits().MaxHexDigits(); got != 829 {
		t.Errorf("MaxHexDigits: %d", got)
	}
	for n, h := range map[int]int{1: 0, 2: 0, 3: 1, 5: 3, 6: 4, 7: 4, 1000: 829} {
		if got := (Limits{MaxNumberLength: n}).MaxHexDigits(); got != h {
			t.Errorf("MaxHexDigits(%d) = %d, want %d", n, got, h)
		}
	}
}

func TestParseOne(t *testing.T) {
	for _, src := range []string{"", "// nothing", "1, 2", "1, 2,"} {
		if _, err := Parse([]byte(src)); codeOf(err) != CodeNotOneValue {
			t.Errorf("%q: %v", src, err)
		}
	}
	if v, err := Parse([]byte("1,")); err != nil || v.(Number).String() != "1" {
		t.Errorf("1,: %v %v", v, err)
	}
}

func TestNumbers(t *testing.T) {
	for lit, want := range map[string]string{
		"1_000": "1000", "0xFF": "255", "-0x0": "-0", "0b1010": "10", "1E+05": "1e5",
		"1e-07": "1e-7", "1e-0": "1e0", "19.90": "19.90", "-0": "-0", "1.5e00_1": "1.5e1",
	} {
		n, err := ParseNumber(lit)
		if err != nil || n.String() != want {
			t.Errorf("%s: %v %v, want %s", lit, n, err, want)
		}
	}
	for _, bad := range []string{"", "1 ", "+1", "007", "1.", "0X1", "1e", "1__0", "-"} {
		if _, err := ParseNumber(bad); err == nil {
			t.Errorf("%q: accepted", bad)
		}
	}
	if n := NumberFromInt(-42); n.String() != "-42" || !n.IsInteger() {
		t.Error(n)
	}
	big1, _ := new(big.Int).SetString("123456789012345678901234567890", 10)
	if n := NumberFromBigInt(big1); n.String() != big1.String() {
		t.Error(n)
	}
	if (Number{}).String() != "0" {
		t.Error("zero Number")
	}
	if b, ok := mustNumber(t, "1e2").BigInt(); ok || b != nil {
		t.Error("1e2 is an integer")
	}
	if b, ok := mustNumber(t, "0xFF").BigInt(); !ok || b.Int64() != 255 {
		t.Error("0xFF")
	}
}

func mustNumber(t *testing.T, s string) Number {
	n, err := ParseNumber(s)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestRecords(t *testing.T) {
	if _, err := NewRecord(Field{"a", String("x")}, Field{"a", String("y")}); codeOf(err) != CodeDuplicateKey {
		t.Errorf("duplicate: %v", err)
	}
	var fields []Field
	for i := range 40 {
		fields = append(fields, Field{string(rune('a'+i%26)) + strings.Repeat("x", i/26), NumberFromInt(int64(i))})
	}
	r, err := NewRecord(fields...)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := r.Get("nx"); !ok || v.(Number).String() != "39" {
		t.Errorf("Get: %v %v", v, ok)
	}
	if _, ok := r.Get("zz"); ok {
		t.Error("Get of a missing key")
	}
	// A large record with a duplicate is found by the parser too.
	src := "{" + strings.Repeat("", 0)
	for _, f := range fields {
		src += f.Key + ": 1, "
	}
	if _, err := ParseAll([]byte(src + "}")); err != nil {
		t.Fatal(err)
	}
	if _, err := ParseAll([]byte(src + "kx: 2 }")); codeOf(err) != CodeDuplicateKey {
		t.Errorf("large duplicate: %v", err)
	}
	var empty Record
	if empty.Len() != 0 {
		t.Error("zero Record")
	}
}

func TestCanonical(t *testing.T) {
	cases := map[string]string{
		`Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }`: `Order{id:255,p:Point(1,2),total:19.90,"x-y":1e5}`,
		`Tag({ b: 1, a: 2 })`:                        `Tag{a:2,b:1}`,
		`["\u{41}", x"0B 34", "a\tb\u{1b}\u{202E}"]`: `["A",x"0b34","a\tb\u{1B}\u{202E}"]`,
		// Keys sort by code point, not UTF-16 unit: U+FF61 before U+1F600.
		`{ "😀": 1, "｡": 2, "Z": 3, a: 4 }`: `{"Z":3,a:4,"｡":2,"😀":1}`,
	}
	for src, want := range cases {
		v, err := Parse([]byte(src))
		if err != nil {
			t.Fatal(err)
		}
		if got, err := Canonical(v); err != nil || got != want {
			t.Errorf("%s: %s %v, want %s", src, got, err, want)
		}
	}
	vs, _ := ParseAll([]byte(`1, "a", Order { id: 0xFF },`))
	got, _ := HashAll(vs)
	one, _ := ParseAll([]byte(`1,"a",Order{id:255}`))
	want, _ := HashAll(one)
	if got != want {
		t.Error("hashAll")
	}
	if h, _ := HashAll(nil); h != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Errorf("empty hash %s", h)
	}
	v, _ := Parse([]byte("{ a: 1 }"))
	h1, _ := Hash(v)
	h2, _ := HashAll([]Value{v})
	if h1 != h2 {
		t.Error("hash(v) != hashAll([v])")
	}
	// Values without text.
	if _, err := Canonical(Variant{Tag: "lower"}); codeOf(err) != CodeInvalidTag {
		t.Errorf("invalid tag: %v", err)
	}
	if _, err := Canonical(String("\xff")); codeOf(err) != CodeCannotEncode {
		t.Errorf("invalid UTF-8: %v", err)
	}
	cyclic := Array{nil}
	cyclic[0] = cyclic
	if _, err := Canonical(cyclic); codeOf(err) != CodeCyclicValue {
		t.Errorf("cycle: %v", err)
	}
	_ = Compare(cyclic, cyclic) // ends
	if !Equals(cyclic, cyclic) {
		t.Error("a value is equal to itself")
	}
}

// cyclicValues are values built in code that contain themselves: through an
// array, a record, a positional payload and a record payload.
func cyclicValues() map[string]Value {
	arr := Array{String("a"), nil}
	arr[1] = arr
	inner := Array{nil}
	rec, _ := NewRecord(Field{Key: "children", Value: inner})
	inner[0] = rec
	v := Variant{Tag: "Cons", Args: []Value{NumberFromInt(1), nil}}
	v.Args[1] = v
	payload := Array{nil}
	prec, _ := NewRecord(Field{Key: "next", Value: payload})
	payload[0] = Variant{Tag: "Node", Args: []Value{prec}}
	// A sub-slice of itself: [a[:1]] contains a[:1] forever.
	sub := Array{nil, nil}
	sub[0] = sub[:1]
	return map[string]Value{"array": arr, "record": rec, "payload": v, "record payload": payload, "sub-slice": sub}
}

// deepValue is an acyclic value nested n levels deep.
func deepValue(n int) Value {
	var v Value = NumberFromInt(0)
	for range n {
		v = Array{v}
	}
	return v
}

func TestCyclicValues(t *testing.T) {
	for name, v := range cyclicValues() {
		if _, err := Canonical(v); codeOf(err) != CodeCyclicValue {
			t.Errorf("%s: Canonical: %v", name, err)
		}
		if _, err := Hash(v); codeOf(err) != CodeCyclicValue {
			t.Errorf("%s: Hash: %v", name, err)
		}
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			if _, err := FormatValue(v, FormatOptions{Layout: l}); codeOf(err) != CodeCyclicValue {
				t.Errorf("%s: FormatValue %s: %v", name, l, err)
			}
		}
		if err := CheckValue(v, Limits{}); codeOf(err) != CodeCyclicValue {
			t.Errorf("%s: CheckValue: %v", name, err)
		}
	}
	// Deep but acyclic values keep the depth error.
	deep := deepValue(DefaultMaxDepth + 1)
	if _, err := FormatValue(deep, FormatOptions{}); codeOf(err) != CodeNestingTooDeep {
		t.Errorf("deep FormatValue: %v", err)
	}
	if err := CheckValue(deep, Limits{}); codeOf(err) != CodeNestingTooDeep {
		t.Errorf("deep CheckValue: %v", err)
	}
	if _, err := Canonical(deep); err != nil {
		t.Errorf("deep Canonical (below the supported maximum): %v", err)
	}
	if _, err := Canonical(deepValue(MaxSupportedDepth + 1)); codeOf(err) != CodeNestingTooDeep {
		t.Errorf("too deep Canonical: %v", err)
	}
	// A value shared many times (a DAG) is not a cycle.
	shared := Array{String("x")}
	dag := Array{shared, shared, Array{shared, shared}}
	if _, err := Canonical(dag); err != nil {
		t.Errorf("dag: %v", err)
	}
	if err := CheckValue(dag, Limits{}); err != nil {
		t.Errorf("dag: %v", err)
	}
}

func TestCheckValue(t *testing.T) {
	huge, _ := ParseNumber("1e100")
	rec, _ := NewRecord(Field{Key: "a-b", Value: Array{String("ok")}})
	cases := []struct {
		v    Value
		lim  Limits
		code ErrorCode
		path string
	}{
		{String("ok"), Limits{}, "", ""},
		{Array{String("ok"), String("\xff")}, Limits{}, CodeCannotEncode, "$[1]"},
		{Variant{Tag: "x"}, Limits{}, CodeInvalidTag, "$"},
		{Variant{Tag: "A", Args: []Value{nil}}, Limits{}, CodeCannotEncode, "$[0]"},
		{huge, Limits{MaxExponent: 99}, CodeExponentTooLarge, "$"},
		{String("abc"), Limits{MaxStringLength: 2}, CodeStringTooLong, "$"},
		{Bytes{1, 2}, Limits{MaxStringLength: 3}, CodeStringTooLong, "$"},
		{rec, Limits{}, "", ""},
		{Variant{Tag: "T", Args: []Value{Array{Array{}}}}, Limits{MaxDepth: 1}, CodeNestingTooDeep, "$[0]"},
	}
	for i, c := range cases {
		err := CheckValue(c.v, c.lim)
		if codeOf(err) != c.code {
			t.Errorf("%d: got %v, want %s", i, err, c.code)
			continue
		}
		var e *Error
		if errors.As(err, &e) && e.Path != c.path {
			t.Errorf("%d: path %s, want %s", i, e.Path, c.path)
		}
	}
	// Tag { … } is one level, as when writing.
	payload, _ := NewRecord(Field{Key: "a", Value: NumberFromInt(1)})
	if err := CheckValue(Variant{Tag: "T", Args: []Value{payload}}, Limits{MaxDepth: 1}); err != nil {
		t.Errorf("record payload: %v", err)
	}
}

func TestEqualsCompare(t *testing.T) {
	parse := func(s string) Value {
		v, err := Parse([]byte(s))
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	equal := [][2]string{
		{"1_000", "1000"}, {"0xFF", "255"}, {"1E+05", "1e5"}, {"-0x0", "-0"},
		{`"\u{41}"`, `"A"`}, {`x"0B 34"`, `x"0b34"`}, {"{ a: 1, b: 2 }", "{ b: 2, a: 1 }"},
		{"Tag({ a: 1 })", "Tag { a: 1 }"},
	}
	for _, c := range equal {
		if a, b := parse(c[0]), parse(c[1]); !Equals(a, b) || Compare(a, b) != 0 {
			t.Errorf("%s = %s", c[0], c[1])
		}
	}
	differ := [][2]string{
		{"1.0", "1"}, {"1e2", "100"}, {`x"41"`, `"A"`}, {`x"01"`, "[1]"}, {"{}", "{ x: None }"},
		{"A", "A(1)"}, {"[1]", "[1, 2]"}, {"{ a: 1 }", "{ b: 1 }"},
	}
	for _, c := range differ {
		if a, b := parse(c[0]), parse(c[1]); Equals(a, b) || Compare(a, b) == 0 {
			t.Errorf("%s ≠ %s", c[0], c[1])
		}
	}
	if Compare(parse("10"), parse("9")) >= 0 || Compare(parse("1"), parse("10")) >= 0 {
		t.Error("order")
	}
}

func TestFormatValue(t *testing.T) {
	r, _ := NewRecord(
		Field{"n", mustNumber(t, "0xFF")},
		Field{"text", String("a\nb ")},
		Field{"bytes", Bytes{0x0b, 0x34}},
		Field{"content-type", String("x")},
		Field{"shape", Variant{Tag: "Circle", Args: []Value{mustRecord(t, Field{"r", NumberFromInt(1)})}}},
		Field{"pair", Variant{Tag: "Pair", Args: []Value{NumberFromInt(1), String("two")}}},
		Field{"none", Variant{Tag: "None"}},
		Field{"list", Array{}},
	)
	want := `{
  n: 255,
  text: """
    a
    b\u{20}
    """,
  bytes: x"0b34",
  "content-type": "x",
  shape: Circle {
    r: 1,
  },
  pair: Pair(1, "two"),
  none: None,
  list: [],
}
`
	got, err := FormatValue(r, FormatOptions{})
	if err != nil || string(got) != want {
		t.Errorf("pretty:\n%s%v", got, err)
	}
	got, _ = FormatValues([]Value{r, String("s")}, FormatOptions{Layout: Minimised})
	wantMin := `{n:255,text:"a\nb ",bytes:x"0b34","content-type":"x",shape:Circle{r:1},pair:Pair(1,"two"),none:None,list:[]},` + "\n" + `"s",` + "\n"
	if string(got) != wantMin {
		t.Errorf("minimised:\n%s", got)
	}
	// Formatting the output again changes nothing, and it parses back.
	for _, l := range []Layout{Pretty, Compact, Minimised} {
		out, _ := FormatValue(r, FormatOptions{Layout: l})
		again, err := Format(out, FormatOptions{Layout: l})
		if err != nil || string(again) != string(out) {
			t.Errorf("%s: %s %v", l, again, err)
		}
		back, _ := Parse(out)
		if !Equals(back, r) {
			t.Errorf("%s: parses to another value", l)
		}
	}
	bad := []struct {
		v    Value
		lim  Limits
		code ErrorCode
	}{
		{Variant{Tag: "bad"}, Limits{}, CodeInvalidTag},
		{String("\xff"), Limits{}, CodeCannotEncode},
		{NumberFromBigInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(1000), nil)), Limits{}, CodeNumberTooLong},
		{Array{Array{}}, Limits{MaxDepth: 1}, CodeNestingTooDeep},
		{Variant{Tag: "Some", Args: []Value{mustRecord(t)}}, Limits{MaxDepth: 1}, ""},
		{Array{nil}, Limits{}, CodeCannotEncode},
	}
	for _, c := range bad {
		_, err := FormatValue(c.v, FormatOptions{Limits: c.lim})
		if codeOf(err) != c.code {
			t.Errorf("%#v: %v, want %q", c.v, err, c.code)
		}
	}
}

func mustRecord(t *testing.T, fields ...Field) Record {
	r, err := NewRecord(fields...)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestHasComments(t *testing.T) {
	for src, want := range map[string]bool{
		"{ a: 1 }": false, "// c\n1": true, "[1 /* c */]": true, "1 // c": true, `"// no"`: false,
	} {
		if got, err := HasComments([]byte(src)); err != nil || got != want {
			t.Errorf("%q: %v %v", src, got, err)
		}
	}
}
