//! The haus data model, exactly as written in the source. No schema has been
//! applied: numbers are kept as exact literal text, and variants are generic.

/// A haus value.
///
/// A value built in code may nest any depth. Dropping, cloning and comparing
/// with `==` take a heap stack rather than recursion, so they need no call
/// stack per level (a parsed value nests at most [`crate::MAX_SUPPORTED_DEPTH`]
/// levels). `==` compares the values as built: `Number("1E5")` is not
/// `Number("1e5")`; [`crate::equals`] is haus equality (spec §2). `{:?}`
/// recurses, one call per level.
#[derive(Debug)]
pub enum Value {
    /// The exact literal, digit separators removed and the exponent marker
    /// lower-cased. Hex and binary literals are converted to decimal integers:
    /// `"19.90"`, `"-1e10"`, `"255"`. A value built in code may hold any
    /// text here: the writer checks it (and normalizes it) before writing.
    Number(String),
    String(String),
    /// A byte string, written `x"0b34ff"`.
    Bytes(Vec<u8>),
    Array(Vec<Value>),
    /// Fields in source order. Keys are unique.
    Record(Vec<(String, Value)>),
    /// `args` is empty for a bare tag; `Tag { … }` has one record argument.
    Variant {
        tag: String,
        args: Vec<Value>,
    },
}

impl Value {
    /// A field of a record.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Record(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// Whether this is an array, record or variant with at least one part.
    fn has_parts(&self) -> bool {
        match self {
            Value::Array(items) | Value::Variant { args: items, .. } => !items.is_empty(),
            Value::Record(fields) => !fields.is_empty(),
            _ => false,
        }
    }

    /// Moves this value's parts onto `stack`, leaving it without parts.
    fn move_parts(&mut self, stack: &mut Vec<Value>) {
        match self {
            Value::Array(items) | Value::Variant { args: items, .. } => stack.append(items),
            Value::Record(fields) => stack.extend(fields.drain(..).map(|(_, v)| v)),
            _ => {}
        }
    }
}

/// Without recursion: a value nested deeper than one level hands its parts to
/// a stack, which takes theirs in turn, so each part is dropped without parts.
impl Drop for Value {
    fn drop(&mut self) {
        let nested = match self {
            Value::Array(items) | Value::Variant { args: items, .. } => items.iter().any(Value::has_parts),
            Value::Record(fields) => fields.iter().any(|(_, v)| v.has_parts()),
            _ => false,
        };
        if !nested {
            return;
        }
        let mut stack = Vec::new();
        self.move_parts(&mut stack);
        while let Some(mut v) = stack.pop() {
            v.move_parts(&mut stack);
        }
    }
}

/// Structural equality without recursion: the same kind, text, tag, keys in
/// the same order and equal parts.
impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        // Values without parts are compared without a stack.
        match (self, other) {
            (Value::Number(x), Value::Number(y)) | (Value::String(x), Value::String(y)) => return x == y,
            (Value::Bytes(x), Value::Bytes(y)) => return x == y,
            _ => {}
        }
        let mut todo = vec![(self, other)];
        while let Some((a, b)) = todo.pop() {
            let same = match (a, b) {
                (Value::Number(x), Value::Number(y)) | (Value::String(x), Value::String(y)) => x == y,
                (Value::Bytes(x), Value::Bytes(y)) => x == y,
                (Value::Array(x), Value::Array(y)) => {
                    x.len() == y.len() && {
                        todo.extend(x.iter().zip(y));
                        true
                    }
                }
                (Value::Record(x), Value::Record(y)) => {
                    x.len() == y.len()
                        && x.iter().zip(y).all(|((k, v), (l, w))| {
                            todo.push((v, w));
                            k == l
                        })
                }
                (Value::Variant { tag: s, args: x }, Value::Variant { tag: t, args: y }) => {
                    s == t && x.len() == y.len() && {
                        todo.extend(x.iter().zip(y));
                        true
                    }
                }
                _ => false,
            };
            if !same {
                return false;
            }
        }
        true
    }
}

impl Eq for Value {}

/// A copy, without recursion: containers are rebuilt from a stack of the ones
/// being copied, each finished when its last part is.
impl Clone for Value {
    fn clone(&self) -> Value {
        /// A container being copied: its parts so far, and the ones left.
        enum Frame<'a> {
            Array(Vec<Value>, std::slice::Iter<'a, Value>),
            Variant(&'a str, Vec<Value>, std::slice::Iter<'a, Value>),
            Record(Vec<(String, Value)>, std::slice::Iter<'a, (String, Value)>),
        }
        /// A copy of a value without parts, or the frame that copies its parts.
        fn start(v: &Value) -> Result<Value, Frame<'_>> {
            match v {
                Value::Number(n) => Ok(Value::Number(n.clone())),
                Value::String(s) => Ok(Value::String(s.clone())),
                Value::Bytes(b) => Ok(Value::Bytes(b.clone())),
                Value::Array(items) => Err(Frame::Array(Vec::with_capacity(items.len()), items.iter())),
                Value::Variant { tag, args } => Err(Frame::Variant(tag, Vec::with_capacity(args.len()), args.iter())),
                Value::Record(fields) => Err(Frame::Record(Vec::with_capacity(fields.len()), fields.iter())),
            }
        }
        let mut stack = match start(self) {
            Ok(v) => return v,
            Err(frame) => vec![frame],
        };
        loop {
            let top = stack.last_mut().expect("a frame is open");
            let next = match top {
                Frame::Array(_, rest) | Frame::Variant(_, _, rest) => rest.next(),
                Frame::Record(done, rest) => rest.next().map(|(k, v)| {
                    done.push((k.clone(), Value::Number(String::new())));
                    v
                }),
            };
            let copy = match next {
                Some(part) => match start(part) {
                    Ok(v) => v,
                    Err(frame) => {
                        stack.push(frame);
                        continue;
                    }
                },
                None => match stack.pop().expect("a frame is open") {
                    Frame::Array(done, _) => Value::Array(done),
                    Frame::Variant(tag, done, _) => Value::Variant { tag: tag.to_owned(), args: done },
                    Frame::Record(done, _) => Value::Record(done),
                },
            };
            // A finished part: the next part of the container below, or the copy.
            match stack.last_mut() {
                None => return copy,
                Some(Frame::Array(done, _) | Frame::Variant(_, done, _)) => done.push(copy),
                Some(Frame::Record(done, _)) => done.last_mut().expect("its key was pushed").1 = copy,
            }
        }
    }
}
