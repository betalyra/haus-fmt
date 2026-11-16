//! Base64 with padding (RFC 4648 §4), for `Bytes` in schema-based JSON.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(crate) fn encode(bytes: &[u8]) -> String {
    let sextet = |n: u32, i: u32| ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char;
    bytes
        .chunks(3)
        .flat_map(|chunk| {
            let n = chunk.iter().enumerate().fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
            (0..4u32).map(move |i| if i as usize <= chunk.len() { sextet(n, i) } else { '=' })
        })
        .collect()
}

/// The bytes of a base64 text, or None. Strict: padded to a multiple of
/// four, `=` only at the end, and the bits the padding leaves unused are
/// zero, so every byte string has exactly one text.
pub(crate) fn decode(text: &str) -> Option<Vec<u8>> {
    let value = |c: u8| ALPHABET.iter().position(|&a| a == c).map(|v| v as u32);
    if !text.len().is_multiple_of(4) {
        return None;
    }
    let groups = text.as_bytes().chunks(4).collect::<Vec<_>>();
    let mut out = Vec::with_capacity(groups.len() * 3);
    for (i, group) in groups.iter().enumerate() {
        let padding = group.iter().rev().take_while(|&&c| c == b'=').count();
        if padding > 2 || (padding > 0 && i + 1 < groups.len()) {
            return None;
        }
        let n = group[..4 - padding].iter().try_fold(0u32, |n, &c| Some(n << 6 | value(c)?))? << (6 * padding);
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        // The unused low bits of the last group must be zero.
        if n & ((1 << (8 * padding)) - 1) != 0 {
            return None;
        }
        out.extend_from_slice(&bytes[..3 - padding]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::{decode, encode};

    #[test]
    fn round_trips() {
        for (bytes, text) in [(&b""[..], ""), (b"f", "Zg=="), (b"fo", "Zm8="), (b"foo", "Zm9v"), (b"\x0b\x34", "CzQ=")]
        {
            assert_eq!(encode(bytes), text);
            assert_eq!(decode(text).as_deref(), Some(bytes));
        }
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(decode(&encode(&all)), Some(all));
    }

    #[test]
    fn strict() {
        for text in ["CzQ", "CzQ", "Cz==Q===", "Cz=Q", "CzR=", "Zh==", "Zg=\0", "Zg==Zg==", "Z===", "Zm9v\n", "-_8="] {
            assert_eq!(decode(text), None, "{text:?}");
        }
    }
}
