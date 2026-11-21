//! Reading and writing take linear time on any input (spec §7, §9.8): four
//! times the input takes about four times as long, never sixteen. Each case
//! is timed at n and 4n (the best of five runs, each repeating the call
//! until it lasts at least 20 ms, so that a coarse clock can't measure a
//! fast call as nothing), and must take less than eight times as long at 4n:
//! twice what linear time gives, half of what quadratic time does. A busy
//! machine can slow one run down, so a case is measured up to three times;
//! quadratic time fails every time. The inputs are the ones the parser and
//! writers have fast paths and thresholds for: many keys, also keys made to
//! collide in a cheap hash, long strings, many short values, deep nesting.
//!
//! Both sizes are run once before they are timed (the first call pays for
//! page faults and cold caches), and what a call returns is kept until its
//! run ends and dropped outside the timed region: freeing a large value
//! costs time of its own, which would otherwise land on whichever call
//! happened to drop it.

use haus::{Record, Value};
use std::time::{Duration, Instant};

/// Runs of each size; the fastest counts.
const RUNS: usize = 5;
/// The shortest time one timed run lasts.
const MIN_RUN: Duration = Duration::from_millis(20);

/// The best time per call of `run` on `input`, over [`RUNS`] runs.
fn best<T, R>(input: &T, run: &impl Fn(&T) -> R) -> Duration {
    (0..RUNS)
        .map(|_| {
            let mut kept = Vec::with_capacity(64);
            let start = Instant::now();
            while kept.is_empty() || start.elapsed() < MIN_RUN {
                kept.push(run(input));
            }
            let per_call = start.elapsed() / u32::try_from(kept.len()).unwrap_or(u32::MAX);
            drop(kept);
            per_call
        })
        .min()
        .unwrap_or_default()
}

/// `run` on `make(4 * n)` takes less than eight times as long as on `make(n)`.
fn linear<T, R>(what: &str, n: usize, make: impl Fn(usize) -> T, run: impl Fn(&T) -> R) {
    let (small, large) = (make(n), make(4 * n));
    // Warm up both sizes.
    drop((run(&small), run(&large)));
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

/// The values of `text`, which parses.
fn parses(text: &impl AsRef<str>) -> Vec<Value> {
    haus::parse(text.as_ref()).expect("it parses")
}

/// The error of `text`, which doesn't parse.
fn fails(text: &impl AsRef<str>) -> haus::SyntaxError {
    haus::parse(text.as_ref()).expect_err("it doesn't parse")
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

/// `v` written minimised and compact, and its canonical form.
fn written(v: &Value) -> [String; 3] {
    let ok = "within the limits";
    [haus::to_string_minimised(v).expect(ok), haus::to_string(v).expect(ok), haus::canonical(v)]
}

fn record_value(n: usize, key: impl Fn(usize) -> String) -> Value {
    Value::record((0..n).map(|i| (key(i), Value::from(i)))).unwrap()
}

#[test]
fn writing() {
    linear("ordinary keys", 20_000, |n| record_value(n, |i| format!("k{i}")), written);
    linear("colliding keys", 20_000, |n| record_value(n, colliding), written);
    let string = |piece: &'static str| move |n: usize| Value::String(piece.repeat(n));
    linear("a long string", 200_000, string("abcdefgh"), written);
    linear("a string to escape", 50_000, string("a\"b\\c\nd\u{7}\u{202E}é中"), written);
    let numbers = |n: usize| Value::Array((0..n).map(|i| Value::number(&format!("-{i}.5")).unwrap()).collect());
    linear("numbers", 100_000, numbers, written);
    // Equality compares records of keys in another order sorted.
    let both = |n: usize| {
        (record_value(n, colliding), Value::record((0..n).rev().map(|i| (colliding(i), Value::from(i)))).unwrap())
    };
    linear("equality of reordered keys", 20_000, both, |(a, b): &(Value, Value)| assert!(haus::equals(a, b)));
}

/// Fields with keys made to collide, and one of them again at the end.
fn repeated(n: usize) -> Vec<(String, Value)> {
    let mut fields: Vec<(String, Value)> = (0..n).map(|i| (colliding(i), Value::from(i))).collect();
    fields.push((colliding(n / 2), Value::from(0)));
    fields
}

#[test]
fn building_values() {
    // A repeated key is found in linear time, whatever the keys: all at once ...
    let at_once = |fields: &Vec<(String, Value)>| Record::from_fields(fields.iter().cloned()).expect_err("a key twice");
    linear("a repeated colliding key", 20_000, repeated, at_once);
    // ... or one key at a time.
    let inserted = |fields: &Vec<(String, Value)>| {
        let mut r = Record::new();
        let added = fields.iter().cloned().map(|(k, v)| r.insert(k, v)).take_while(Result::is_ok).count();
        assert_eq!(added, fields.len() - 1);
        r
    };
    linear("a repeated colliding key, inserted", 20_000, repeated, inserted);
    let literals = |n: usize| (0..n).map(|i| format!("{i}E+05")).collect::<Vec<_>>();
    let normalized = |ns: &Vec<String>| ns.iter().map(|n| Value::number(n).expect("a number")).collect::<Vec<_>>();
    linear("numbers to normalize", 20_000, literals, normalized);
}

#[test]
fn checking_a_value_for_an_any() {
    // A raw value is checked against the writer's limits (spec §9.8).
    let check = |v: &Value| assert!(haus::Encoder::default().check(v).is_ok());
    linear("colliding keys", 20_000, |n| record_value(n, colliding), check);
}
