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
		{"\"\"\"", 1, 4},                       // block-string-opening at the end of the input
		{"[1,\r\n\"\"\"  ", 2, 6},
		{"[ -1e6145 ]", 1, 3}, // every number error at the literal's first character
		{"[ 1_ ]", 1, 3},
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
		if _, err := ParseNumber(bad); codeOf(err) != CodeInvalidNumber {
			t.Errorf("%q: %v", bad, err)
		}
	}
	// The constructor applies no limits (spec §11): a writer does.
	long := "1" + strings.Repeat("0", 2000)
	for lit, want := range map[string]string{
		long: long, "1e99999999999": "1e99999999999", "0x" + strings.Repeat("F", 900): "",
		"1E-0000000000000000000007": "1e-7",
	} {
		n, err := ParseNumber(lit)
		if err != nil || want != "" && n.String() != want {
			t.Errorf("%.20s…: %.20s %v", lit, n, err)
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
	if _, err := NewRecord(Field{"\xff", String("x")}); codeOf(err) != CodeCannotEncode {
		t.Errorf("a key that isn't UTF-8: %v", err)
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
	// What Go lets code build past the constructors has no text.
	if _, err := Canonical(Variant{}); codeOf(err) != CodeCannotEncode {
		t.Errorf("the zero Tag: %v", err)
	}
	if _, err := Canonical(String("\xff")); codeOf(err) != CodeCannotEncode {
		t.Errorf("invalid UTF-8: %v", err)
	}
	cyclic := Array{nil}
	cyclic[0] = cyclic
	if _, err := Canonical(cyclic); codeOf(err) != CodeCyclicValue {
		t.Errorf("cycle: %v", err)
	}
	if _, err := Compare(cyclic, cyclic); codeOf(err) != CodeCyclicValue {
		t.Errorf("compare a cycle: %v", err)
	}
	if !Equals(cyclic, cyclic) {
		t.Error("a value is equal to itself")
	}
}

func TestTags(t *testing.T) {
	for _, name := range []string{"A", "None", "EUR", "T_1", "X" + strings.Repeat("y", 100)} {
		if tag, err := NewTag(name); err != nil || tag.String() != name || tag.IsZero() {
			t.Errorf("%s: %v %v", name, tag, err)
		}
	}
	for _, name := range []string{"", "lower", "_A", "1A", "A-B", "Ä", "A b"} {
		if _, err := NewTag(name); codeOf(err) != CodeInvalidTag {
			t.Errorf("%q: %v", name, err)
		}
	}
	if some, _ := NewTag("Some"); some != MustTag("Some") || some == MustTag("None") || !(Tag{}).IsZero() {
		t.Error("tags compare by name")
	}
	defer func() {
		if recover() == nil {
			t.Error("MustTag of an invalid name doesn't panic")
		}
	}()
	MustTag("bad")
}

// shared returns a value built in code whose arrays share one another: n
// levels of [x, x], which writes 2^(n+1)−1 values.
func shared(n int) Value {
	var v Value = NumberFromInt(1)
	for range n {
		v = Array{v, v}
	}
	return v
}

// TestNodeLimit: writers, CheckValue, the canonical form and hashing count
// the values they write, each as often as it is written, for each
// top-level value on its own (spec §7, "Values written").
func TestNodeLimit(t *testing.T) {
	dag := shared(10) // 2047 values
	lim := Limits{MaxNodes: 2046}
	for _, l := range []Layout{Pretty, Compact, Minimised} {
		if _, err := FormatValue(dag, withLimits(inLayout(l), lim)); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$" {
			t.Errorf("%s: %v", l, err)
		}
		if _, err := FormatValue(dag, withLimits(inLayout(l), Limits{MaxNodes: 2047})); err != nil {
			t.Errorf("%s at the limit: %v", l, err)
		}
		// Each value of a stream has the limit to itself.
		if _, err := FormatValues([]Value{dag, dag}, withLimits(inLayout(l), Limits{MaxNodes: 2047})); err != nil {
			t.Errorf("%s stream: %v", l, err)
		}
		if _, err := FormatValues([]Value{String("a"), dag}, withLimits(inLayout(l), lim)); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$[1]" {
			t.Errorf("%s stream: %v", l, err)
		}
		// A writer of several values gives $[0] for a stream of one (spec §11).
		if _, err := FormatValues([]Value{dag}, withLimits(inLayout(l), lim)); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$[0]" {
			t.Errorf("%s stream of one: %v", l, err)
		}
	}
	if err := CheckValue(dag, lim); codeOf(err) != CodeTooManyNodes {
		t.Errorf("CheckValue: %v", err)
	}
	if _, err := AppendHausJSON(nil, dag, lim); codeOf(err) != CodeTooManyNodes {
		t.Errorf("self-describing JSON: %v", err)
	}
	if _, err := CanonicalWith(dag, lim); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$" {
		t.Errorf("CanonicalWith: %v", err)
	}
	if _, err := HashWith(dag, lim); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$" {
		t.Errorf("HashWith: %v", err)
	}
	// HashAll: at the place of the value among the values hashed.
	if _, err := HashAllWith([]Value{String("a"), dag}, lim); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$[1]" {
		t.Errorf("HashAllWith: %v", err)
	}
	if _, err := HashAllWith([]Value{dag, dag}, Limits{MaxNodes: 2047}); err != nil {
		t.Errorf("HashAllWith: %v", err)
	}
	if _, err := HashAllWith([]Value{dag}, lim); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$[0]" {
		t.Errorf("HashAllWith one value: %v", err)
	}
	// Tag { … } writes the variant and its record: Tag{a:1} is three values.
	payload := Variant{Tag: MustTag("T"), Args: []Value{mustRecord(t, Field{"a", NumberFromInt(1)})}}
	for maxNodes, code := range map[int]ErrorCode{2: CodeTooManyNodes, 3: ""} {
		lim := Limits{MaxNodes: maxNodes}
		if _, err := FormatValue(payload, withLimits(DefaultFormatOptions(), lim)); codeOf(err) != code {
			t.Errorf("%d: format %v", maxNodes, err)
		}
		if _, err := FormatValue(payload, withLimits(inLayout(Minimised), lim)); codeOf(err) != code {
			t.Errorf("%d: minimised %v", maxNodes, err)
		}
		if err := CheckValue(payload, lim); codeOf(err) != code {
			t.Errorf("%d: check %v", maxNodes, err)
		}
		if _, err := CanonicalWith(payload, lim); codeOf(err) != code {
			t.Errorf("%d: canonical %v", maxNodes, err)
		}
	}
	// With the default limit, 2^27 values written is too many, though the
	// value is small in memory.
	if _, err := Hash(shared(26)); codeOf(err) != CodeTooManyNodes {
		t.Errorf("default limit: %v", err)
	}
	if _, err := Compare(shared(26), dag); codeOf(err) != CodeTooManyNodes || err.(*Error).Path != "$" ||
		!strings.Contains(err.(*Error).Message, "first") {
		t.Errorf("Compare: %v", err)
	}
	if _, err := Compare(dag, shared(26)); codeOf(err) != CodeTooManyNodes || !strings.Contains(err.(*Error).Message, "second") {
		t.Errorf("Compare, the second: %v", err)
	}
}

// TestCanonicalOnlyNodeLimit: the canonical form and hashing apply no limit
// but the node limit (spec §12): a value deeper or longer than a writer's
// limits still has a canonical form.
func TestCanonicalOnlyNodeLimit(t *testing.T) {
	long := String(strings.Repeat("é", DefaultMaxStringLength+1))
	key := mustRecord(t, Field{strings.Repeat("k", DefaultMaxStringLength+1), NumberFromInt(1)})
	tag := Variant{Tag: MustTag("T" + strings.Repeat("a", DefaultMaxStringLength))}
	wide, _ := ParseNumber("1" + strings.Repeat("0", DefaultMaxNumberLength))
	exp, _ := ParseNumber("1e99999")
	for name, v := range map[string]Value{
		"deep": deepValue(DefaultMaxDepth + 1), "string": long, "key": key, "tag": tag,
		"number": wide, "exponent": exp, "bytes": make(Bytes, DefaultMaxStringLength/2+1),
	} {
		if _, err := Canonical(v); err != nil {
			t.Errorf("%s: Canonical %v", name, err)
		}
		if _, err := Hash(v); err != nil {
			t.Errorf("%s: Hash %v", name, err)
		}
		if err := CheckValue(v, Limits{}); err == nil {
			t.Errorf("%s: CheckValue accepts it", name)
		}
		if _, err := FormatValue(v, inLayout(Minimised)); err == nil {
			t.Errorf("%s: FormatValue accepts it", name)
		}
	}
}

// TestWriterLimits: a writer checks every limit a value built in code can
// break (spec §11), in every layout, and CheckValue the same.
func TestWriterLimits(t *testing.T) {
	cases := []struct {
		v    Value
		lim  Limits
		code ErrorCode
	}{
		{String("abc"), Limits{MaxStringLength: 2}, CodeStringTooLong},
		{String("éé"), Limits{MaxStringLength: 2}, ""},
		{String("😀😀😀"), Limits{MaxStringLength: 2}, CodeStringTooLong},
		{Bytes{1, 2}, Limits{MaxStringLength: 3}, CodeStringTooLong},
		{Bytes{1, 2}, Limits{MaxStringLength: 4}, ""},
		{mustRecord(t, Field{"abc", NumberFromInt(1)}), Limits{MaxStringLength: 2}, CodeKeyTooLong},
		{mustRecord(t, Field{"a-c", NumberFromInt(1)}), Limits{MaxStringLength: 2}, CodeKeyTooLong},
		{Variant{Tag: MustTag("Abc")}, Limits{MaxStringLength: 2}, CodeTagTooLong},
		{mustNumber(t, "123"), Limits{MaxNumberLength: 2}, CodeNumberTooLong},
		{mustNumber(t, "1e100"), Limits{MaxExponent: 99}, CodeExponentTooLarge},
		{Array{Array{}}, Limits{MaxDepth: 1}, CodeNestingTooDeep},
		{shared(3), Limits{MaxNodes: 14}, CodeTooManyNodes},
		{Variant{}, Limits{}, CodeCannotEncode},
	}
	for i, c := range cases {
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			if _, err := FormatValue(c.v, withLimits(inLayout(l), c.lim)); codeOf(err) != c.code {
				t.Errorf("%d %s: %v, want %q", i, l, err, c.code)
			}
		}
		if err := CheckValue(c.v, c.lim); codeOf(err) != c.code {
			t.Errorf("%d check: %v, want %q", i, err, c.code)
		}
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
	v := Variant{Tag: MustTag("Cons"), Args: []Value{NumberFromInt(1), nil}}
	v.Args[1] = v
	payload := Array{nil}
	prec, _ := NewRecord(Field{Key: "next", Value: payload})
	payload[0] = Variant{Tag: MustTag("Node"), Args: []Value{prec}}
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
			if _, err := FormatValue(v, inLayout(l)); codeOf(err) != CodeCyclicValue {
				t.Errorf("%s: FormatValue %s: %v", name, l, err)
			}
		}
		if err := CheckValue(v, Limits{}); codeOf(err) != CodeCyclicValue {
			t.Errorf("%s: CheckValue: %v", name, err)
		}
	}
	// Deep but acyclic values keep the depth error.
	deep := deepValue(DefaultMaxDepth + 1)
	if _, err := FormatValue(deep, DefaultFormatOptions()); codeOf(err) != CodeNestingTooDeep {
		t.Errorf("deep FormatValue: %v", err)
	}
	if err := CheckValue(deep, Limits{}); codeOf(err) != CodeNestingTooDeep {
		t.Errorf("deep CheckValue: %v", err)
	}
	if _, err := Canonical(deep); err != nil {
		t.Errorf("deep Canonical: %v", err)
	}
	// A cycle below a deep start is found too.
	tail := Array{nil}
	tail[0] = Array{Array{tail}}
	var deepCyclic Value = tail
	for range 5000 {
		deepCyclic = Array{deepCyclic}
	}
	if _, err := Canonical(deepCyclic); codeOf(err) != CodeCyclicValue {
		t.Errorf("deep cyclic Canonical: %v", err)
	}
	if Equals(deepCyclic, Array{deepCyclic}) {
		t.Error("deep cyclic Equals: true")
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

// veryDeep is a value built in code n levels deep, by turns an array, a
// variant with arguments and a variant with a record payload, around inner.
func veryDeep(t *testing.T, n int, inner Value) Value {
	t.Helper()
	v := inner
	for i := range n {
		switch i % 3 {
		case 0:
			v = Array{v}
		case 1:
			v = Variant{Tag: MustTag("Some"), Args: []Value{v, NumberFromInt(int64(i))}}
		default:
			r, err := NewRecord(Field{Key: "next", Value: v}, Field{Key: "a b", Value: String("x")})
			if err != nil {
				t.Fatal(err)
			}
			v = Variant{Tag: MustTag("Node"), Args: []Value{r}}
		}
	}
	return v
}

// TestAnyDepth: canonical, hash, hashAll, equals and compare work for a
// value of any depth, bounded only by memory (spec §12), on a goroutine of
// its own.
func TestAnyDepth(t *testing.T) {
	const depth = 100_000
	done := make(chan struct{})
	go func() {
		defer close(done)
		a := veryDeep(t, depth, NumberFromInt(1))
		b := veryDeep(t, depth, NumberFromInt(1))
		c := veryDeep(t, depth, NumberFromInt(2))
		ca, err := Canonical(a)
		if err != nil {
			t.Errorf("Canonical: %v", err)
			return
		}
		if cb, err := Canonical(b); err != nil || cb != ca {
			t.Errorf("Canonical of a copy: %v", err)
		}
		if !strings.HasPrefix(ca, `[Node{"a b":"x",next:Some([Node{"a b":"x",next:`) {
			t.Errorf("Canonical: %.40s", ca)
		}
		ha, err := Hash(a)
		if hb, errB := Hash(b); err != nil || errB != nil || ha != hb {
			t.Errorf("Hash: %v %v", err, errB)
		}
		if hc, err := Hash(c); err != nil || hc == ha {
			t.Errorf("Hash of another value: %v", err)
		}
		if _, err := HashAll([]Value{a, c}); err != nil {
			t.Errorf("HashAll: %v", err)
		}
		if !Equals(a, b) {
			t.Error("Equals of two copies: false")
		}
		if Equals(a, c) {
			t.Error("Equals with another innermost value: true")
		}
		if n, err := Compare(a, b); err != nil || n != 0 {
			t.Errorf("Compare of two copies: %d %v", n, err)
		}
		if n, err := Compare(a, c); err != nil || n != -1 {
			t.Errorf("Compare: %d %v", n, err)
		}
	}()
	<-done
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
		{Variant{}, Limits{}, CodeCannotEncode, "$"},
		{Variant{Tag: MustTag("A"), Args: []Value{nil}}, Limits{}, CodeCannotEncode, "$[0]"},
		{huge, Limits{MaxExponent: 99}, CodeExponentTooLarge, "$"},
		{String("abc"), Limits{MaxStringLength: 2}, CodeStringTooLong, "$"},
		{Bytes{1, 2}, Limits{MaxStringLength: 3}, CodeStringTooLong, "$"},
		{rec, Limits{}, "", ""},
		{Variant{Tag: MustTag("T"), Args: []Value{Array{Array{}}}}, Limits{MaxDepth: 1}, CodeNestingTooDeep, "$[0]"},
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
	// An empty record, array or record payload is a level, as when parsing
	// (spec §7): a value built in code and the same value parsed have the
	// same depth. Writers check it so too.
	empty, _ := NewRecord()
	inRecord, _ := NewRecord(Field{Key: "a", Value: empty})
	for _, c := range []struct {
		v    Value
		path string
	}{
		{Array{Array{}}, "$[0]"},
		{inRecord, "$.a"},
		{Array{Variant{Tag: MustTag("T"), Args: []Value{empty}}}, "$[0]"},
		{Variant{Tag: MustTag("T"), Args: []Value{Array{}}}, "$[0]"},
	} {
		one := Limits{MaxDepth: 1}
		text, err := Canonical(c.v)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ParseWith([]byte(text), one); codeOf(err) != CodeNestingTooDeep {
			t.Errorf("parse %s: %v", text, err)
		}
		if err := CheckValue(c.v, one); codeOf(err) != CodeNestingTooDeep || err.(*Error).Path != c.path {
			t.Errorf("check %s: %v", text, err)
		}
		if _, err := FormatValue(c.v, withLimits(DefaultFormatOptions(), one)); codeOf(err) != CodeNestingTooDeep {
			t.Errorf("format %s: %v", text, err)
		}
		if _, err := AppendHausJSON(nil, c.v, one); codeOf(err) != CodeNestingTooDeep {
			t.Errorf("self-describing JSON %s: %v", text, err)
		}
		if err := CheckValue(c.v, Limits{MaxDepth: 2}); err != nil {
			t.Errorf("check %s at depth 2: %v", text, err)
		}
	}
	for _, v := range []Value{Array{}, empty, Variant{Tag: MustTag("T"), Args: []Value{empty}}} {
		if err := CheckValue(v, Limits{MaxDepth: 1}); err != nil {
			t.Errorf("%v at depth 1: %v", v, err)
		}
	}
	// Tag { … } is one level, as when writing.
	payload, _ := NewRecord(Field{Key: "a", Value: NumberFromInt(1)})
	if err := CheckValue(Variant{Tag: MustTag("T"), Args: []Value{payload}}, Limits{MaxDepth: 1}); err != nil {
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
		if a, b := parse(c[0]), parse(c[1]); !Equals(a, b) || compare(t, a, b) != 0 {
			t.Errorf("%s = %s", c[0], c[1])
		}
	}
	differ := [][2]string{
		{"1.0", "1"}, {"1e2", "100"}, {`x"41"`, `"A"`}, {`x"01"`, "[1]"}, {"{}", "{ x: None }"},
		{"A", "A(1)"}, {"[1]", "[1, 2]"}, {"{ a: 1 }", "{ b: 1 }"},
	}
	for _, c := range differ {
		if a, b := parse(c[0]), parse(c[1]); Equals(a, b) || compare(t, a, b) == 0 {
			t.Errorf("%s ≠ %s", c[0], c[1])
		}
	}
	if compare(t, parse("10"), parse("9")) >= 0 || compare(t, parse("1"), parse("10")) >= 0 {
		t.Error("order")
	}
}

// TestFormatStream: FormatOptions.Stream writes a comma after a single value
// too, in every layout (spec §11); FormatValue writes one value and ignores it.
func TestFormatStream(t *testing.T) {
	v := Variant{Tag: MustTag("Paged"), Args: []Value{mustRecord(t, Field{"n", NumberFromInt(1)})}}
	want := map[Layout]string{Pretty: "Paged {\n  n: 1,\n},\n", Compact: "Paged { n: 1 },\n", Minimised: "Paged{n:1},\n"}
	for l, w := range want {
		o := inLayout(l)
		o.Stream = true
		if got, err := FormatValues([]Value{v}, o); err != nil || string(got) != w {
			t.Errorf("%s FormatValues: %q %v", l, got, err)
		}
		if got, err := Format([]byte("Paged { n: 1 }"), o); err != nil || string(got) != w {
			t.Errorf("%s Format: %q %v", l, got, err)
		}
		if got, _ := FormatValue(v, o); strings.HasSuffix(strings.TrimSuffix(string(got), "\n"), ",") {
			t.Errorf("%s FormatValue: %q", l, got)
		}
		// Two values, or none: as without it.
		two, _ := FormatValues([]Value{v, v}, o)
		if plain, _ := FormatValues([]Value{v, v}, inLayout(l)); string(two) != string(plain) {
			t.Errorf("%s: two values %q, %q", l, two, plain)
		}
		if none, err := FormatValues(nil, o); err != nil || len(none) != 0 {
			t.Errorf("%s: no values %q %v", l, none, err)
		}
	}
}

func compare(t *testing.T, a, b Value) int {
	t.Helper()
	c, err := Compare(a, b)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// TestFormatComments: where comments and blank lines land, as the other
// formatters put them (found by the differential fuzzer, main.ts --format).
func TestFormatComments(t *testing.T) {
	cases := []struct{ in, want string }{
		// A blank line before a record payload's '}' stays, before the comments moved inside.
		{"{b:T(/**/{/**/\n\n}//\n),/**/a:F}//", "{\n  b: T {\n    /**/\n    /**/\n\n    //\n  }, /**/\n  a: F,\n} //\n"},
		{"F,//\nF({a:0/**/\n\n}\n/**/)", "F, //\nF {\n  a: 0, /**/\n\n  /**/\n},\n"},
		// In an empty record payload, a blank line between the comments before and after the braces stays.
		{"T(/**/\n\n{}/*x*/)", "T {\n  /**/\n\n  /*x*/\n}\n"},
		{"E(//\n\n{}//a\n)", "E {\n  //\n\n  //a\n}\n"},
		// A comment after the braces doesn't trail an entry whose line a multi-line comment ends.
		{"N({a:0/*\n*/}//\n)", "N {\n  a: 0, /*\n*/\n  //\n}\n"},
		// A comment after a multi-line comment starts on a later line: it doesn't trail.
		{"N(\"\"\"\n\"\"\")/*\n*///", "N(\"\") /*\n*/\n//\n"},
		{"[A(5)/*\n*/,//c\n\"\"]", "[\n  A(5), /*\n*/\n  //c\n  \"\",\n]\n"},
		// A comma on a line of its own makes no blank line.
		{"\"\"//\n,\n\"\"//", "\"\", //\n\"\", //\n"},
		// A comment between a key and its value moves above the entry, after its blank line.
		{"{b:{b:\"\"},\n\na://\n\"x\"}", "{\n  b: {\n    b: \"\",\n  },\n\n  //\n  a: \"x\",\n}\n"},
	}
	for _, c := range cases {
		got, err := Format([]byte(c.in), DefaultFormatOptions())
		if err != nil || string(got) != c.want {
			t.Errorf("Format(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
}

func TestFormatValue(t *testing.T) {
	r, _ := NewRecord(
		Field{"n", mustNumber(t, "0xFF")},
		Field{"text", String("a\nb ")},
		Field{"bytes", Bytes{0x0b, 0x34}},
		Field{"content-type", String("x")},
		Field{"shape", Variant{Tag: MustTag("Circle"), Args: []Value{mustRecord(t, Field{"r", NumberFromInt(1)})}}},
		Field{"pair", Variant{Tag: MustTag("Pair"), Args: []Value{NumberFromInt(1), String("two")}}},
		Field{"none", Variant{Tag: MustTag("None")}},
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
	got, err := FormatValue(r, DefaultFormatOptions())
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
		out, _ := FormatValue(r, inLayout(l))
		again, err := Format(out, inLayout(l))
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
		{Variant{}, Limits{}, CodeCannotEncode},
		{String("\xff"), Limits{}, CodeCannotEncode},
		{NumberFromBigInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(1000), nil)), Limits{}, CodeNumberTooLong},
		// Every number, a decimal or an exponent too: what a parser with the same limits reads back.
		{mustNumber(t, "1.0000000000"), Limits{MaxNumberLength: 10}, CodeNumberTooLong},
		{mustNumber(t, "1e100"), Limits{MaxExponent: 99}, CodeExponentTooLarge},
		{mustNumber(t, "-1.5e-100"), Limits{MaxExponent: 99}, CodeExponentTooLarge},
		{Array{Array{}}, Limits{MaxDepth: 1}, CodeNestingTooDeep},
		{Variant{Tag: MustTag("Some"), Args: []Value{mustRecord(t)}}, Limits{MaxDepth: 1}, ""},
		{Array{nil}, Limits{}, CodeCannotEncode},
	}
	for _, c := range bad {
		_, err := FormatValue(c.v, withLimits(DefaultFormatOptions(), c.lim))
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
