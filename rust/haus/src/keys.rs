//! Repeated record keys (spec §1), found in linear time whatever the keys
//! (spec §9.8), for the parser and for records built in code
//! ([`crate::Record`], and JSON objects, [`crate::json::JsonObject`]).
//!
//! A few keys are compared with each other, and only when a key may repeat
//! one: when another key before it has the same length, first and last byte
//! modulo 64 (a bit of a 64-bit word). More are chained by a cheap hash (the
//! length and first and last eight bytes), and a new key is compared only
//! with the keys of its chain; when a chain grows long, which ordinary keys
//! don't do but keys made to collide do, the chains are rebuilt by std's
//! seeded SipHash. Every key is compared with at most [`FEW`] or
//! [`MAX_CHAIN`] keys before that, so the work stays linear in the size of
//! the keys.

use std::collections::hash_map::RandomState;
use std::hash::BuildHasher;

/// Records with at most this many keys compare a key with the ones before it.
pub(crate) const FEW: usize = 32;
/// The longest chain walked by the cheap hash before switching to the seeded one.
const MAX_CHAIN: usize = 8;
const END: u32 = u32::MAX;

/// The keys of a record so far, by their place in its fields.
#[derive(Default)]
pub(crate) struct Keys {
    /// While there are few: a bit for each [`sketch`] of a key so far.
    sketches: u64,
    /// The last key of each chain, `END` for none; a power of two of them.
    heads: Vec<u32>,
    /// For each key, the key before it in its chain.
    next: Vec<u32>,
    /// The seeded hash, once a chain of the cheap one grew long.
    seeded: Option<RandomState>,
}

impl Keys {
    /// The keys of `fields`, which are unique, chained: for a record built
    /// in code that grows one key at a time ([`crate::Record::insert`]).
    pub(crate) fn of<T>(fields: &[(String, T)]) -> Keys {
        let mut keys = Keys::default();
        keys.rebuild(fields, 4 * fields.len());
        keys
    }

    /// Adds `key`, the key of the field after `before` (whose keys were
    /// added before it), if none of them is the same: whether it is new.
    pub(crate) fn insert<T>(&mut self, before: &[(String, T)], key: &str) -> bool {
        // The number of keys with this one.
        let count = before.len() + 1;
        if self.heads.is_empty() && count <= FEW {
            let bit = 1 << sketch(key);
            let maybe = self.sketches & bit != 0;
            self.sketches |= bit;
            return !(maybe && before.iter().any(|(k, _)| k == key));
        }
        if 2 * count > self.heads.len() {
            self.rebuild(before, 4 * count);
        }
        let mut at = self.heads[self.bucket(key)];
        let mut walked = 0;
        while at != END {
            if before[at as usize].0 == key {
                return false;
            }
            at = self.next[at as usize];
            walked += 1;
        }
        if walked > MAX_CHAIN && self.seeded.is_none() {
            self.seeded = Some(RandomState::new());
            self.rebuild(before, self.heads.len());
        }
        self.add(key, before.len());
        true
    }

    /// Chains `keys` again, in `size` (rounded up to a power of two) chains.
    fn rebuild<T>(&mut self, keys: &[(String, T)], size: usize) {
        self.heads.clear();
        self.heads.resize(size.next_power_of_two().max(64), END);
        self.next.clear();
        for (i, (k, _)) in keys.iter().enumerate() {
            self.add(k, i);
        }
    }

    /// Chains the key at `i`.
    fn add(&mut self, key: &str, i: usize) {
        let bucket = self.bucket(key);
        self.next.push(self.heads[bucket]);
        self.heads[bucket] = i as u32;
    }

    fn bucket(&self, key: &str) -> usize {
        let hash = match &self.seeded {
            Some(state) => state.hash_one(key),
            None => cheap(key.as_bytes()),
        };
        // The top bits, as many as there are chains.
        (hash >> (64 - self.heads.len().trailing_zeros())) as usize
    }
}

/// The first of `fields` whose key an earlier one has, if any.
pub(crate) fn first_repeated<T>(fields: &[(String, T)]) -> Option<usize> {
    let mut keys = match fields.len() <= FEW {
        true => Keys::default(),
        false => Keys { heads: vec![END; (2 * fields.len()).next_power_of_two()], ..Keys::default() },
    };
    (0..fields.len()).find(|&i| !keys.insert(&fields[..i], &fields[i].0))
}

/// Six bits of a key: its length and first and last byte.
fn sketch(key: &str) -> u32 {
    let b = key.as_bytes();
    let (first, last) = (b.first().copied().unwrap_or(0), b.last().copied().unwrap_or(0));
    (b.len() as u32).wrapping_mul(7).wrapping_add(u32::from(first) * 3).wrapping_add(u32::from(last)) % 64
}

/// A hash of a key's length and its first and last eight bytes: cheap,
/// spread well for the keys records have, and easy to make collide.
fn cheap(key: &[u8]) -> u64 {
    let n = key.len();
    let word = |bytes: &[u8]| bytes.iter().rev().fold(0u64, |w, &c| w << 8 | u64::from(c));
    // Whole words where the key has them (the compiler loads each at once).
    let (first, last) = match n {
        8.. => (word(&key[..8]), word(&key[n - 8..])),
        4..8 => (word(&key[..4]), word(&key[n - 4..])),
        _ => (word(key), 0),
    };
    let mixed = (first ^ last.rotate_left(32) ^ (n as u64)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    mixed ^ mixed >> 29
}

#[cfg(test)]
mod tests {
    use super::{FEW, Keys, first_repeated};
    use crate::Value;

    fn fields(keys: &[String]) -> Vec<(String, Value)> {
        keys.iter().map(|k| (k.clone(), Value::Array(vec![]))).collect()
    }

    /// The first key that repeats an earlier one, added one at a time, as
    /// the parser adds them; the same as all at once, as `Record::from_fields` checks.
    fn first_repeat(keys: &[String]) -> Option<usize> {
        let fields = fields(keys);
        let mut seen = Keys::default();
        let first = (0..fields.len()).find(|&i| !seen.insert(&fields[..i], &fields[i].0));
        assert_eq!(first_repeated(&fields), first);
        first
    }

    #[test]
    fn finds_the_first_repeated_key() {
        for n in [2, FEW - 1, FEW, FEW + 1, 200, 5000] {
            let mut keys: Vec<String> = (0..n).map(|i| format!("key_{i}")).collect();
            assert_eq!(first_repeat(&keys), None, "{n}");
            keys.push(format!("key_{}", n / 2));
            keys.push("key_0".into());
            assert_eq!(first_repeat(&keys), Some(n), "{n}");
        }
        let short = ["", "a", "ab", "abc", "abcd", "b", "ba", "é", "\u{0}"].map(String::from);
        assert_eq!(first_repeat(&short), None);
        assert_eq!(first_repeat(&[short.as_slice(), &["ab".into()]].concat()), Some(short.len()));
    }

    #[test]
    fn colliding_keys_switch_to_the_seeded_hash() {
        // Same length, same first and last eight bytes: one cheap chain.
        let keys: Vec<String> = (0..3000).map(|i| format!("aaaaaaaa{i:06}zzzzzzzz")).collect();
        assert_eq!(first_repeat(&keys), None);
        let mut repeated = keys.clone();
        repeated.push(keys[1234].clone());
        assert_eq!(first_repeat(&repeated), Some(3000));
        let fields = fields(&keys);
        let mut all = Keys::default();
        assert!((0..fields.len()).all(|i| all.insert(&fields[..i], &fields[i].0)));
        assert!(all.seeded.is_some());
    }
}
