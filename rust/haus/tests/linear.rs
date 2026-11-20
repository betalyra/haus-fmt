//! Reading and writing take linear time on any input (spec §9.8): four times
//! the input takes about four times as long, never sixteen. Each case is
//! timed at n and 4n (the best of five runs), and must take less than eight
//! times as long at 4n: twice what linear time gives, half of what quadratic
//! time does. A busy machine can slow one run down, so a case is measured
//! up to three times; quadratic time fails every time. The inputs are the
//! ones the parser and writers have fast paths and thresholds for: many
//! keys, also keys made to collide in a cheap hash, long strings, many short
//! values, deep nesting.

use haus::Value;
use std::time::{Duration, Instant};

/// The best of five runs of `run` on `input`.
fn best<T>(input: &T, run: &impl Fn(&T)) -> Duration {
    (0..5)
        .map(|_| {
            let start = Instant::now();
            run(input);
            start.elapsed()
        })
        .min()
        .unwrap_or_default()
}

/// `run` on `make(4 * n)` takes less than eight times as long as on `make(n)`.
fn linear<T>(what: &str, n: usize, make: impl Fn(usize) -> T, run: impl Fn(&T)) {
    let (small, large) = (make(n), make(4 * n));
    let measure = || {
        let (t1, t4) = (best(&small, &run), best(&large, &run));
        (t1, t4, t4.as_secs_f64() / t1.as_secs_f64().max(1e-9))
    };
    let tries: Vec<_> = std::iter::repeat_with(measure).take(3).take_while(|&(_, _, ratio)| ratio >= 8.0).collect();
    if tries.len() == 3 {
        let shown: Vec<String> = tries.iter().map(|(t1, t4, r)| format!("{t1:?} and {t4:?} ({r:.1}×)")).collect();
        panic!("{what}: n = {n} and 4n took {}", shown.join(", "));
    }
}

/// Keys of the same length and the same first and last eight bytes.
fn colliding(i: usize) -> String {
    format!("aaaaaaaa{i:08}zzzzzzzz")
}

fn record(n: usize, key: impl Fn(usize) -> String) -> String {
    let fields: Vec<String> = (0..n).map(|i| format!("{}:{i}", key(i))).collect();
    format!("{{{}}}", fields.join(","))
}

fn parses(text: &impl AsRef<str>) {
    assert!(haus::parse(text.as_ref()).is_ok());
}

fn fails(text: &impl AsRef<str>) {
    assert!(haus::parse(text.as_ref()).is_err());
}

#[test]
fn records_with_many_keys() {
    linear("ordinary keys", 20_000, |n| record(n, |i| format!("k{i}")), parses);
    linear("colliding keys", 20_000, |n| record(n, colliding), parses);
    linear("quoted colliding keys", 20_000, |n| record(n, |i| format!("\"{}\"", colliding(i))), parses);
    let repeated = |n| record(n, colliding).replacen('}', &format!(",{}:0}}", colliding(n / 2)), 1);
    linear("a repeated colliding key at the end", 20_000, repeated, fails);
    // Many small records, each just above the size compared one by one.
    let small = |n: usize| format!("[{}]", vec![record(40, colliding); n / 40].join(","));
    linear("many records of 40 keys", 20_000, small, parses);
}

#[test]
fn long_strings() {
    let string = |piece: &'static str| move |n: usize| format!("\"{}\"", piece.repeat(n));
    linear("ASCII", 200_000, string("abcdefgh"), parses);
    linear("escapes", 100_000, string("ab\\\"cd\\\\e\\n"), parses);
    linear("unicode escapes", 100_000, string("a\\u{1F600}b"), parses);
    linear("non-ASCII", 200_000, string("é中😀 "), parses);
    linear("a raw control character at the end", 200_000, |n| format!("\"{}\u{7}\"", "ab".repeat(n)), fails);
    linear("unterminated", 200_000, |n| format!("\"{}", "ab".repeat(n)), fails);
    let block = |n: usize| format!("\"\"\"\n{}\"\"\"", "  line \\t of text\n".repeat(n));
    linear("a block string", 50_000, block, parses);
}

#[test]
fn many_short_values() {
    let array = |item: &'static str| move |n: usize| format!("[{}]", vec![item; n].join(","));
    linear("integers", 100_000, array("-12345"), parses);
    linear("decimals", 25_000, array("1_000.5e-3"), parses);
    linear("hex", 25_000, array("0xFF"), parses);
    linear("strings", 100_000, array("\"ab\""), parses);
    linear("tags", 100_000, array("True"), parses);
    linear("payloads", 50_000, array("Some(1)"), parses);
    linear("a stream", 100_000, |n| "1,\n".repeat(n), parses);
}

#[test]
fn deep_nesting() {
    // Arrays and records nested to the limit, many times over.
    let deep = "[{a:".repeat(127) + "1" + &"}]".repeat(127);
    linear("nested to the limit", 200, |n| format!("[{}]", vec![deep.as_str(); n].join(",")), parses);
    let too_deep = |n: usize| format!("[{},{}]", vec![deep.as_str(); n].join(","), "[".repeat(300));
    linear("too deep at the end", 200, too_deep, fails);
}

fn written(v: &Value) {
    assert!(haus::to_string_minimised(v).is_ok() && haus::to_string(v).is_ok());
}

fn record_value(n: usize, key: impl Fn(usize) -> String) -> Value {
    Value::Record((0..n).map(|i| (key(i), Value::Number(i.to_string()))).collect())
}

#[test]
fn writing() {
    linear("ordinary keys", 20_000, |n| record_value(n, |i| format!("k{i}")), written);
    linear("colliding keys", 20_000, |n| record_value(n, colliding), written);
    let repeated = |n| {
        let Value::Record(mut fields) = record_value(n, colliding) else { unreachable!() };
        fields.push((colliding(n / 2), Value::Number("0".into())));
        Value::Record(fields)
    };
    linear("a repeated colliding key", 20_000, repeated, |v| assert!(haus::to_string(v).is_err()));
    let string = |piece: &'static str| move |n: usize| Value::String(piece.repeat(n));
    linear("a long string", 200_000, string("abcdefgh"), written);
    linear("a string to escape", 50_000, string("a\"b\\c\nd\u{7}\u{202E}é中"), written);
    let numbers = |n: usize| Value::Array((0..n).map(|i| Value::Number(format!("-{i}.5"))).collect());
    linear("numbers", 100_000, numbers, written);
    let unnormalized = |n: usize| Value::Array((0..n).map(|i| Value::Number(format!("{i}E+05"))).collect());
    linear("numbers to normalize", 20_000, unnormalized, written);
}

#[test]
fn checking_a_value_for_an_any() {
    // A raw value is checked as the writer checks it (spec §9.8).
    let check = |v: &Value| assert!(haus::Encoder::default().check(v).is_ok());
    linear("colliding keys", 20_000, |n| record_value(n, colliding), check);
}
