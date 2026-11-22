//! Generated code at the supported depth (spec §7): recursive types nested
//! [`haus::MAX_SUPPORTED_DEPTH`] levels deep are read and written in a thread
//! with a 2 MiB stack (the default of spawned and test threads), and JSON
//! nested deeper fails at the depth limit instead of overflowing the stack.

#[allow(dead_code)]
mod features {
    haus::include_schema!("features");
}

use features::{Thread, Tree};
use haus::{Encode, Limits, MAX_SUPPORTED_DEPTH as MAX, json};

/// Runs `f` in a thread with a 2 MiB stack.
fn in_small_thread(f: impl FnOnce() + Send + 'static) {
    in_thread(2 * 1024, f);
}

/// Runs `f` in a thread with a stack of `kib` KiB.
fn in_thread(kib: usize, f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new().stack_size(kib * 1024).spawn(f).unwrap().join().unwrap();
}

/// `Node(Node(…, Leaf), Leaf)`: each `Node` is a level.
fn tree(levels: usize) -> (String, Tree) {
    let text = format!("{}Leaf{}", "Node(".repeat(levels), ", Leaf)".repeat(levels));
    (text, (0..levels).fold(Tree::Leaf, |t, _| Tree::Node(Box::new(t), Box::new(Tree::Leaf))))
}

/// `{ text: "", reply: Some({ … }) }`: written so, each reply is two levels,
/// the payload of `Some` and the record; written `Some { … }`, one (spec §7).
fn thread(replies: usize) -> (String, Thread) {
    let text = format!(
        "{}{{ text: \"\", reply: None }}{}",
        "{ text: \"\", reply: Some(".repeat(replies),
        ") }".repeat(replies)
    );
    let value = (0..replies).fold(Thread { text: String::new(), reply: None }, |t, _| Thread {
        text: String::new(),
        reply: Some(Box::new(t)),
    });
    (text, value)
}

#[test]
fn recursive_types_at_the_supported_depth() {
    in_small_thread(recursive_types_at_max);
}

/// The same in a 512 KiB thread (spec §7), in an optimized build: a debug
/// build's parser needs more at 256 levels (see haus/tests/limits.rs).
#[test]
#[cfg_attr(debug_assertions, ignore = "a debug build needs more than 512 KiB at 256 levels: run with --release")]
fn recursive_types_at_the_supported_depth_in_a_512_kib_thread() {
    in_thread(512, recursive_types_at_max);
}

fn recursive_types_at_max() {
    {
        let limits = Limits { max_depth: MAX, ..Limits::default() };
        let (text, value) = tree(MAX);
        assert_eq!(haus::from_str::<Tree>(&text).unwrap(), value);
        assert_eq!(haus::to_string_with(&value, &limits).unwrap(), text);
        let as_json = json::to_string_with(&value, &limits).unwrap();
        assert_eq!(json::from_str_with::<Tree>(&as_json, &limits).unwrap(), value);
        assert_eq!(haus::parse_with(&text, &limits).unwrap()[0], value.encode().unwrap());

        // 1 + 2·replies levels.
        let (text, value) = thread((MAX - 1) / 2);
        assert_eq!(haus::from_str::<Thread>(&text).unwrap(), value);
        // Written `Some { … }`, the same value as `Some({ … })` (spec §2).
        let written = haus::to_string_with(&value, &limits).unwrap();
        assert_eq!(haus::from_str::<Thread>(&written).unwrap(), value);
        let as_json = json::to_string_with(&value, &limits).unwrap();
        assert_eq!(json::from_str_with::<Thread>(&as_json, &limits).unwrap(), value);
        // One level more as written with parentheses; the writer's
        // `Some { … }` takes one level per reply, so it still fits (spec §7).
        let (text, value) = thread(MAX.div_ceil(2));
        let deeper = format!("nesting deeper than {MAX} levels");
        assert!(haus::from_str::<Thread>(&text).unwrap_err().to_string().contains(&deeper));
        let written = haus::to_string_with(&value, &limits).unwrap();
        assert_eq!(haus::from_str::<Thread>(&written).unwrap(), value);
        // 1 + replies levels as written: MAX replies are one too many.
        let (_, value) = thread(MAX);
        assert!(haus::to_string_with(&value, &limits).unwrap_err().to_string().ends_with(&deeper));
        assert!(json::to_string_with(&value, &limits).unwrap_err().to_string().ends_with(&deeper));
        let (_, value) = thread(MAX - 1);
        assert!(haus::to_string_with(&value, &limits).is_ok());
    }
}

#[test]
fn json_too_deep_for_a_recursive_type_fails_at_the_depth_limit() {
    // JSON may nest 4·d + 1 levels; a `Thread` takes one JSON level for two
    // haus levels, so reading it stops after d / 2 of them.
    in_small_thread(|| {
        let n = 4 * MAX + 1;
        let deep = format!(
            "{}{{\"text\":\"\",\"reply\":null}}{}",
            "{\"text\":\"\",\"reply\":".repeat(n - 1),
            "}".repeat(n - 1)
        );
        let e = json::from_str::<Thread>(&deep).unwrap_err().to_string();
        assert!(e.ends_with(&format!("nesting deeper than {MAX} levels")), "{e:.100}");
        assert!(e.starts_with(".reply.reply"), "{e:.100}");
        let deep = format!(
            "{}{{\"_tag\":\"Leaf\"}}{}",
            "{\"_tag\":\"Node\",\"values\":[".repeat(2 * MAX),
            ",{\"_tag\":\"Leaf\"}]}".repeat(2 * MAX)
        );
        let e = json::from_str::<Tree>(&deep).unwrap_err().to_string();
        assert!(e.ends_with(&format!("nesting deeper than {MAX} levels")), "{e:.100}");
    });
}

#[test]
fn values_built_a_million_levels_deep_fail_at_the_depth_limit() {
    // A `Value` built in code isn't limited by a parser: decoding it with a
    // recursive type stops at the depth limit instead of recursing on.
    in_small_thread(|| {
        use haus::{Decode, Value};
        let leaf = || Value::variant("Leaf", vec![]).unwrap();
        // `Node(Leaf, Node(Leaf, …))`, the deep side last, so the value is dropped from it.
        let tree = (0..1_000_000).fold(leaf(), |t, _| Value::variant("Node", vec![leaf(), t]).unwrap());
        let e = Tree::decode(&tree).map(|_| ());
        // Taken apart before checking, so that a failing check doesn't drop it recursively.
        let e = e.unwrap_err();
        assert_eq!(e.code, haus::ErrorCode::NestingTooDeep);
        assert_eq!(e.to_string(), format!("{}: nesting deeper than {MAX} levels", "(Node)[1]".repeat(MAX)));
        // `{ text: "", reply: Some { text: "", reply: … } }`: a level per reply (spec §7).
        let reply = |v: Value| Value::record([("text", Value::String(String::new())), ("reply", v)]).unwrap();
        let thread = (0..1_000_000).fold(reply(Value::variant("None", vec![]).unwrap()), |t, _| {
            reply(Value::variant("Some", vec![t]).unwrap())
        });
        let e = Thread::decode(&thread).map(|_| ());
        assert_eq!(
            e.unwrap_err().to_string(),
            format!("{}.reply: nesting deeper than {MAX} levels", ".reply(Some)[0]".repeat(MAX - 1))
        );
    });
}
