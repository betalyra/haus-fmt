package schema

import (
	"fmt"
	"math/big"
	"strconv"
	"strings"
)

// The std/time profile (spec/std/time.md): which strings each type of
// std/time accepts. These are built-in rules, like the range of UInt8, and
// a schema binding checks exactly these. Each type reads its whole shape
// first, then checks the values, so that a string of the wrong shape says
// how to write the type, whatever its values.

// TimeTypes are the types of std/time, the only standard module.
var TimeTypes = []string{"Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"}

var timeExamples = map[string]string{
	"Date": "2026-11-09", "Time": "14:30:00", "DateTime": "2026-11-09T14:30:00",
	"Instant": "2026-11-09T14:30:00Z", "ZonedDateTime": "2026-11-09T14:30:00+01:00[Europe/Lisbon]",
	"Duration": "PT1H30M", "YearMonth": "2026-11", "TimeZone": "Europe/Lisbon",
}

// errShape is a string that doesn't have its type's shape at all.
var errShape = fmt.Errorf("shape")

// CheckTime reports whether text is a valid value of the std/time type
// typeName ("Date", "Instant", …), and if not, why: nil if it is.
func CheckTime(typeName, text string) error {
	example, ok := timeExamples[typeName]
	if !ok {
		return fmt.Errorf("%s is not a std/time type", typeName)
	}
	c := &cursor{s: text}
	var err error
	switch typeName {
	case "Date":
		err = c.dateOnly()
	case "Time":
		err = c.timeOnly()
	case "DateTime":
		err = c.dateTime(false, false)
	case "Instant":
		err = c.dateTime(true, false)
	case "ZonedDateTime":
		err = c.dateTime(true, true)
	case "Duration":
		err = c.duration()
	case "YearMonth":
		err = c.yearMonth()
	case "TimeZone":
		err = zone(text)
	}
	switch err {
	case nil:
		return nil
	case errShape:
		return fmt.Errorf("%s is not a %s; write it like %s", `"`+quote(text)+`"`, typeName, example)
	}
	return fmt.Errorf("%s is not a valid %s: %v", `"`+quote(text)+`"`, typeName, err)
}

type cursor struct {
	s string
	i int
}

func (c *cursor) atEnd() bool { return c.i == len(c.s) }

func (c *cursor) finish() error {
	if c.atEnd() {
		return nil
	}
	return errShape
}

func (c *cursor) opt(b byte) bool {
	if c.i < len(c.s) && c.s[c.i] == b {
		c.i++
		return true
	}
	return false
}

func (c *cursor) lit(b byte) error {
	if c.opt(b) {
		return nil
	}
	return errShape
}

// digits reads exactly n digits.
func (c *cursor) digits(n int) (string, error) {
	if c.i+n > len(c.s) {
		return "", errShape
	}
	for j := c.i; j < c.i+n; j++ {
		if !isDigit(c.s[j]) {
			return "", errShape
		}
	}
	c.i += n
	return c.s[c.i-n : c.i], nil
}

// run reads one or more digits, or "".
func (c *cursor) run() string {
	j := c.i
	for j < len(c.s) && isDigit(c.s[j]) {
		j++
	}
	out := c.s[c.i:j]
	c.i = j
	return out
}

// fraction reads a fraction of 1–9 digits after a '.', if there is a '.'.
func (c *cursor) fraction() error {
	if c.opt('.') {
		if f := c.run(); len(f) < 1 || len(f) > 9 {
			return errShape
		}
	}
	return nil
}

type ymd struct{ y, m, d string }
type hms struct{ h, m, s string }

func num(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 1 << 30
	}
	return n
}

func (c *cursor) date() (ymd, error) {
	var d ymd
	var err error
	if d.y, err = c.digits(4); err != nil {
		return d, err
	}
	if err := c.lit('-'); err != nil {
		return d, err
	}
	if d.m, err = c.digits(2); err != nil {
		return d, err
	}
	if err := c.lit('-'); err != nil {
		return d, err
	}
	d.d, err = c.digits(2)
	return d, err
}

func (d ymd) check() error {
	year, month, day := num(d.y), num(d.m), num(d.d)
	if month < 1 || month > 12 {
		return fmt.Errorf("month %s doesn't exist", d.m)
	}
	leap := year%4 == 0 && (year%100 != 0 || year%400 == 0)
	last := 31
	switch {
	case month == 2 && leap:
		last = 29
	case month == 2:
		last = 28
	case month == 4 || month == 6 || month == 9 || month == 11:
		last = 30
	}
	switch {
	case day >= 1 && day <= last:
		return nil
	case month == 2 && day == 29:
		return fmt.Errorf("%s-%s has no day %s (%s is not a leap year)", d.y, d.m, d.d, d.y)
	}
	return fmt.Errorf("%s-%s has no day %s", d.y, d.m, d.d)
}

// clock reads hh:mm:ss, then an optional fraction.
func (c *cursor) clock() (hms, error) {
	var t hms
	var err error
	if t.h, err = c.digits(2); err != nil {
		return t, err
	}
	if err := c.lit(':'); err != nil {
		return t, err
	}
	if t.m, err = c.digits(2); err != nil {
		return t, err
	}
	if err := c.lit(':'); err != nil {
		return t, err
	}
	if t.s, err = c.digits(2); err != nil {
		return t, err
	}
	return t, c.fraction()
}

func (t hms) check() error {
	h, m, s := num(t.h), num(t.m), num(t.s)
	switch {
	case h == 24:
		return fmt.Errorf("24:00 is not allowed; write 00:00 of the next day")
	case h > 24:
		return fmt.Errorf("hour %s doesn't exist", t.h)
	case m >= 60:
		return fmt.Errorf("minute %s doesn't exist", t.m)
	case s == 60:
		return fmt.Errorf("leap seconds (:60) are not allowed")
	case s > 60:
		return fmt.Errorf("second %s doesn't exist", t.s)
	}
	return nil
}

// offset reads Z or ±hh:mm.
func (c *cursor) offset() (string, error) {
	start := c.i
	switch {
	case c.opt('Z'):
	case c.opt('+') || c.opt('-'):
		if _, err := c.digits(2); err != nil {
			return "", err
		}
		if err := c.lit(':'); err != nil {
			return "", err
		}
		if _, err := c.digits(2); err != nil {
			return "", err
		}
	default:
		return "", errShape
	}
	return c.s[start:c.i], nil
}

// checkOffset checks Z or ±hh:mm: up to ±23:59, never -00:00.
func checkOffset(o string) error {
	switch {
	case o == "Z":
		return nil
	case o == "-00:00":
		return fmt.Errorf("-00:00 is not allowed; write Z")
	case num(o[1:3]) > 23 || num(o[4:6]) > 59:
		return fmt.Errorf("offset %s is out of range (±23:59 at most)", o)
	}
	return nil
}

func (c *cursor) dateOnly() error {
	d, err := c.date()
	if err != nil {
		return err
	}
	if err := c.finish(); err != nil {
		return err
	}
	return d.check()
}

func (c *cursor) timeOnly() error {
	t, err := c.clock()
	if err != nil {
		return err
	}
	if err := c.finish(); err != nil {
		return err
	}
	return t.check()
}

// dateTime reads a DateTime, with an offset for an Instant, and a zone in
// brackets for a ZonedDateTime.
func (c *cursor) dateTime(withOffset, withZone bool) error {
	d, err := c.date()
	if err != nil {
		return err
	}
	if err := c.lit('T'); err != nil {
		return err
	}
	t, err := c.clock()
	if err != nil {
		return err
	}
	o, z := "", ""
	if withOffset {
		if o, err = c.offset(); err != nil {
			return err
		}
	}
	if withZone {
		if err := c.lit('['); err != nil {
			return err
		}
		end := strings.IndexByte(c.s[c.i:], ']')
		if end < 0 {
			return errShape
		}
		z = c.s[c.i : c.i+end]
		c.i += end + 1
	}
	if err := c.finish(); err != nil {
		return err
	}
	if err := d.check(); err != nil {
		return err
	}
	if err := t.check(); err != nil {
		return err
	}
	if withOffset {
		if err := checkOffset(o); err != nil {
			return err
		}
	}
	if withZone {
		return zone(z)
	}
	return nil
}

func (c *cursor) yearMonth() error {
	if _, err := c.digits(4); err != nil {
		return err
	}
	if err := c.lit('-'); err != nil {
		return err
	}
	m, err := c.digits(2)
	if err != nil {
		return err
	}
	if err := c.finish(); err != nil {
		return err
	}
	if month := num(m); month < 1 || month > 12 {
		return fmt.Errorf("month %s doesn't exist", m)
	}
	return nil
}

// zone checks an IANA zone name by its syntax (it is never looked up), or
// an offset. Z, in either case, is the offset letter of an instant, not a
// zone: TimeZone("Z"), TimeZone("z"), …Z[Z] and …Z[z] are rejected.
func zone(z string) error {
	if z == "Z" || z == "z" {
		return fmt.Errorf(`%q is the offset letter of an instant, not a zone; write an offset (+00:00) or a zone name (Etc/UTC)`, z)
	}
	c := &cursor{s: z}
	if o, err := c.offset(); err == nil && c.atEnd() {
		return checkOffset(o)
	}
	part := func(p string) bool {
		if p == "" || p == "." || p == ".." {
			return false
		}
		for i := 0; i < len(p); i++ {
			if b := p[i]; (!isWord(b) || b == '_') && strings.IndexByte("._+-", b) < 0 {
				return false
			}
		}
		return true
	}
	ok := len(z) <= 255 && z != "" && (isUpper(z[0]) || isLower(z[0]))
	for _, p := range strings.Split(z, "/") {
		ok = ok && part(p)
	}
	if ok {
		return nil
	}
	return fmt.Errorf("%s is not an IANA zone name (like Europe/Lisbon) or an offset (like +01:00)", `"`+quote(z)+`"`)
}

// component reads a duration component, digits (and a fraction, if
// allowed) and its unit letter, if the next one is that unit; otherwise it
// reads nothing.
func (c *cursor) component(unit byte, fraction bool) (text string, ok bool, err error) {
	start := c.i
	if c.run() == "" {
		c.i = start
		return "", false, nil
	}
	if fraction {
		if err := c.fraction(); err != nil {
			return "", false, err
		}
	}
	n := c.s[start:c.i]
	if c.opt(unit) {
		return n, true, nil
	}
	c.i = start
	return "", false, nil
}

// duration reads -?P[nY][nM][nW][nD][T[nH][nM][n[.f]S]].
func (c *cursor) duration() error {
	negative := c.opt('-')
	if err := c.lit('P'); err != nil {
		return err
	}
	var texts [7]string // years, months, weeks, days, hours, minutes, seconds (with their fraction)
	var has [7]bool
	for i, unit := range []byte("YMWD") {
		var err error
		if texts[i], has[i], err = c.component(unit, false); err != nil {
			return err
		}
	}
	hasTime := c.opt('T')
	endsWithT := hasTime && c.atEnd()
	if hasTime {
		for i, unit := range []byte("HMS") {
			var err error
			if texts[4+i], has[4+i], err = c.component(unit, unit == 'S'); err != nil {
				return err
			}
		}
	}
	if err := c.finish(); err != nil {
		return err
	}
	var values [7]string // without the fraction
	given := false
	for i := range texts {
		values[i], _, _ = strings.Cut(texts[i], ".")
		given = given || has[i]
	}
	if !given {
		return fmt.Errorf("a duration needs at least one component, like PT0S")
	}
	if endsWithT {
		return fmt.Errorf("a T must be followed by hours, minutes or seconds")
	}
	for i, v := range values {
		if has[i] && len(v) > 1 && v[0] == '0' {
			return fmt.Errorf("%s has a leading zero", v)
		}
	}
	zero := func(x string) bool { return strings.Trim(x, "0.") == "" }
	others := false
	for i := 0; i < 6; i++ {
		if has[i] {
			others = true
			if zero(texts[i]) {
				return fmt.Errorf("a duration leaves out components that are zero (zero is PT0S)")
			}
		}
	}
	if has[6] && zero(texts[6]) && others {
		return fmt.Errorf("a duration leaves out components that are zero (zero is PT0S)")
	}
	if negative && strings.Trim(c.s, "-PYMWDTHS0.") == "" {
		return fmt.Errorf("a zero duration has no sign")
	}
	// Exact bounds, whatever the number of digits.
	limit32 := new(big.Int).Lsh(big.NewInt(1), 32)
	for i := 0; i < 3; i++ {
		if has[i] && bigOf(values[i]).Cmp(limit32) >= 0 {
			return fmt.Errorf("%s is too large (years, months and weeks stay below 2^32)", values[i])
		}
	}
	// Days and time below 2^53 seconds: the whole seconds decide, as a
	// fraction is below one second.
	total := new(big.Int)
	for i, per := range map[int]int64{3: 86400, 4: 3600, 5: 60, 6: 1} {
		if has[i] {
			total.Add(total, new(big.Int).Mul(bigOf(values[i]), big.NewInt(per)))
		}
	}
	if total.Cmp(new(big.Int).Lsh(big.NewInt(1), 53)) >= 0 {
		return fmt.Errorf("days and time together must stay below 2^53 seconds")
	}
	return nil
}

func bigOf(digits string) *big.Int {
	n, _ := new(big.Int).SetString(digits, 10)
	if n == nil {
		return new(big.Int)
	}
	return n
}
