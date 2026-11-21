//! Equality and order (test-suite/equality/cases.haus, test-suite/README.md
//! "Equality and order", spec §2, §12): `equals` and `compare` of two values,
//! in both directions.

use haus::{Value, canonical, compare, equals};
use std::cmp::Ordering;
use std::path::Path;

#[test]
fn equality_and_order() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/equality/cases.haus");
    let cases = haus::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let (Some(a), Some(b), Some(Value::Variant { tag: equal, .. }), Some(Value::Number(order))) =
                (c.get("a"), c.get("b"), c.get("equal"), c.get("order"))
            else {
                panic!("not a case: {}", canonical(c).unwrap())
            };
            let equal = equal == "True";
            let order = match order.as_str() {
                "-1" => Ordering::Less,
                "0" => Ordering::Equal,
                "1" => Ordering::Greater,
                _ => panic!("not a case: {}", canonical(c).unwrap()),
            };
            let got = (equals(a, b), equals(b, a), compare(a, b).unwrap(), compare(b, a).unwrap());
            let want = (equal, equal, order, order.reverse());
            (got != want).then(|| {
                format!(
                    "a {} b {}: (equals(a, b), equals(b, a), compare(a, b), compare(b, a)) = {got:?}, expected {want:?}",
                    canonical(a).unwrap(),
                    canonical(b).unwrap()
                )
            })
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
