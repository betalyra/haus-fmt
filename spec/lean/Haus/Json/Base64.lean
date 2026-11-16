import Haus.Json.Data

/-!
# Base64 and hex for byte strings (spec §16)

Schema-based JSON writes `Bytes` as base64 with padding (RFC 4648 §4),
self-describing JSON as two lowercase hex digits per byte (§16.2). Both readers are strict:
they accept exactly what the writers write.

- Base64: the standard alphabet, `=` padding, length a multiple of 4, and
  the unused bits of the last group zero (RFC 4648 §3.5), so every byte
  string has one encoding and every accepted text is that encoding
  (`base64_decode_encode`, `base64_encode_decode`).
- Hex: lowercase only (`hex_decode_encode`, `hex_encode_decode`).
-/

namespace Haus.Bytes

/-! ## Base64 -/

/-- The base64 alphabet (RFC 4648, Table 1). -/
def b64Alphabet : List Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList

/-- The character for a 6-bit value. -/
def b64Char (n : Nat) : Char := b64Alphabet.getD n '='

/-- The 6-bit value of a base64 character; `none` for any other character, `=` included. -/
def b64Value (c : Char) : Option Nat := b64Alphabet.idxOf? c

def byte (n : Nat) : UInt8 := UInt8.ofNat n

/-- **Base64 with padding** (RFC 4648 §4). -/
def base64 : List UInt8 → Text
  | a :: b :: c :: rest =>
    let (a, b, c) := (a.toNat, b.toNat, c.toNat)
    b64Char (a / 4) :: b64Char (a % 4 * 16 + b / 16) :: b64Char (b % 16 * 4 + c / 64) ::
      b64Char (c % 64) :: base64 rest
  | [a, b] =>
    let (a, b) := (a.toNat, b.toNat)
    [b64Char (a / 4), b64Char (a % 4 * 16 + b / 16), b64Char (b % 16 * 4), '=']
  | [a] => [b64Char (a.toNat / 4), b64Char (a.toNat % 4 * 16), '=', '=']
  | [] => []

/--
**Reading base64**, strictly: groups of four characters, `=` only at the end
of the last group, and the bits that padding leaves over zero.
-/
def unbase64 : Text → Option (List UInt8)
  | [] => some []
  | c1 :: c2 :: c3 :: c4 :: rest => do
    let i1 ← b64Value c1
    let i2 ← b64Value c2
    if c3 = '=' then
      if c4 = '=' ∧ rest = [] ∧ i2 % 16 = 0 then some [byte (i1 * 4 + i2 / 16)] else none
    else
      let i3 ← b64Value c3
      if c4 = '=' then
        if rest = [] ∧ i3 % 4 = 0 then some [byte (i1 * 4 + i2 / 16), byte (i2 % 16 * 16 + i3 / 4)]
        else none
      else
        let i4 ← b64Value c4
        let r ← unbase64 rest
        some (byte (i1 * 4 + i2 / 16) :: byte (i2 % 16 * 16 + i3 / 4) :: byte (i3 % 4 * 64 + i4) :: r)
  | _ => none

theorem b64Value_char : ∀ n, n < 64 → b64Value (b64Char n) = some n := by decide +kernel

theorem b64Char_ne : ∀ n, n < 64 → b64Char n ≠ '=' := by decide +kernel

theorem byte_toNat (a : UInt8) : byte a.toNat = a := UInt8.ofNat_toNat

theorem b64_lt {n : Nat} (h : n < 256) : n / 4 < 64 := by omega

/-- **Base64 reads back**: decoding the encoding gives the bytes. -/
theorem base64_decode_encode : ∀ bs : List UInt8, unbase64 (base64 bs) = some bs
  | [] => rfl
  | [a] => by
    have ha := a.toNat_lt
    have h0 : a.toNat % 4 * 16 % 16 = 0 := by omega
    simp only [base64, unbase64, b64Value_char _ (b64_lt ha), b64Value_char (a.toNat % 4 * 16) (by omega),
      Option.bind_eq_bind, Option.bind_some, ↓reduceIte, true_and, h0]
    rw [show a.toNat / 4 * 4 + (a.toNat % 4 * 16) / 16 = a.toNat by omega, byte_toNat]
  | [a, b] => by
    have ha := a.toNat_lt
    have hb := b.toNat_lt
    simp only [base64, unbase64, b64Value_char _ (b64_lt ha), b64Value_char (a.toNat % 4 * 16 + b.toNat / 16) (by omega),
      b64Value_char (b.toNat % 16 * 4) (by omega), b64Char_ne (b.toNat % 16 * 4) (by omega),
      Option.bind_eq_bind, Option.bind_some, ↓reduceIte, true_and, show b.toNat % 16 * 4 % 4 = 0 by omega]
    rw [show a.toNat / 4 * 4 + (a.toNat % 4 * 16 + b.toNat / 16) / 16 = a.toNat by omega, byte_toNat,
      show (a.toNat % 4 * 16 + b.toNat / 16) % 16 * 16 + b.toNat % 16 * 4 / 4 = b.toNat by omega, byte_toNat]
  | a :: b :: c :: rest => by
    have ha := a.toNat_lt
    have hb := b.toNat_lt
    have hc := c.toNat_lt
    simp only [base64, unbase64, b64Value_char _ (b64_lt ha), b64Value_char (a.toNat % 4 * 16 + b.toNat / 16) (by omega),
      b64Value_char (b.toNat % 16 * 4 + c.toNat / 64) (by omega), b64Value_char (c.toNat % 64) (by omega),
      b64Char_ne (b.toNat % 16 * 4 + c.toNat / 64) (by omega), b64Char_ne (c.toNat % 64) (by omega),
      base64_decode_encode rest, Option.bind_eq_bind, Option.bind_some, ↓reduceIte, Option.some.injEq,
      List.cons.injEq, and_true]
    refine ⟨?_, ?_, ?_⟩
    · rw [show a.toNat / 4 * 4 + (a.toNat % 4 * 16 + b.toNat / 16) / 16 = a.toNat by omega, byte_toNat]
    · rw [show (a.toNat % 4 * 16 + b.toNat / 16) % 16 * 16 + (b.toNat % 16 * 4 + c.toNat / 64) / 4 = b.toNat by omega,
        byte_toNat]
    · rw [show (b.toNat % 16 * 4 + c.toNat / 64) % 4 * 64 + c.toNat % 64 = c.toNat by omega, byte_toNat]

/-- Two byte strings with the same base64 are the same. -/
theorem base64_injective {bs cs : List UInt8} (h : base64 bs = base64 cs) : bs = cs := by
  have := base64_decode_encode bs
  rw [h, base64_decode_encode cs] at this
  exact (Option.some.inj this).symm

theorem b64Value_lt {c : Char} {n : Nat} (h : b64Value c = some n) : n < 64 ∧ b64Char n = c := by
  unfold b64Value at h
  obtain ⟨hlt, heq, -⟩ := List.idxOf?_eq_some_iff.mp h
  refine ⟨hlt, ?_⟩
  unfold b64Char
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hlt, Option.getD_some, heq]

theorem toNat_byte {n : Nat} (h : n < 256) : (byte n).toNat = n := by
  simp only [byte, UInt8.toNat_ofNat']; omega

/-- **Only the encoding is read**: a text that base64 reading accepts is the encoding of what it reads. -/
theorem base64_encode_decode : ∀ (t : Text) (bs : List UInt8), unbase64 t = some bs → base64 bs = t
  | [], bs, h => by simp only [unbase64, Option.some.injEq] at h; subst h; rfl
  | [_], _, h | [_, _], _, h | [_, _, _], _, h => by simp [unbase64] at h
  | c1 :: c2 :: c3 :: c4 :: rest, bs, h => by
    simp only [unbase64, Option.bind_eq_bind] at h
    cases h1 : b64Value c1 with
    | none => simp [h1] at h
    | some i1 =>
    cases h2 : b64Value c2 with
    | none => simp [h1, h2] at h
    | some i2 =>
    obtain ⟨l1, e1⟩ := b64Value_lt h1
    obtain ⟨l2, e2⟩ := b64Value_lt h2
    simp only [h1, h2, Option.bind_some] at h
    by_cases p3 : c3 = '='
    · simp only [p3, ↓reduceIte] at h
      by_cases q : c4 = '=' ∧ rest = [] ∧ i2 % 16 = 0
      · simp only [q, and_self, ↓reduceIte, Option.some.injEq] at h
        obtain ⟨q4, rfl, q2⟩ := q
        subst h p3 q4
        simp only [base64, toNat_byte (show i1 * 4 + i2 / 16 < 256 by omega), List.cons.injEq, and_true]
        rw [← e1, ← e2]
        exact ⟨by congr 1; omega, by congr 1; omega⟩
      · simp only [q, ↓reduceIte, reduceCtorEq] at h
    · simp only [p3, ↓reduceIte] at h
      cases h3 : b64Value c3 with
      | none => simp [h3] at h
      | some i3 =>
      obtain ⟨l3, e3⟩ := b64Value_lt h3
      simp only [h3, Option.bind_some] at h
      by_cases p4 : c4 = '='
      · simp only [p4, ↓reduceIte] at h
        by_cases q : rest = [] ∧ i3 % 4 = 0
        · simp only [q, and_self, ↓reduceIte, Option.some.injEq] at h
          obtain ⟨rfl, q3⟩ := q
          subst h p4
          simp only [base64, toNat_byte (show i1 * 4 + i2 / 16 < 256 by omega),
            toNat_byte (show i2 % 16 * 16 + i3 / 4 < 256 by omega), List.cons.injEq, and_true]
          rw [← e1, ← e2, ← e3]
          exact ⟨by congr 1; omega, by congr 1; omega, by congr 1; omega⟩
        · simp only [q, ↓reduceIte, reduceCtorEq] at h
      · simp only [p4, ↓reduceIte] at h
        cases h4 : b64Value c4 with
        | none => simp [h4] at h
        | some i4 =>
        obtain ⟨l4, e4⟩ := b64Value_lt h4
        simp only [h4, Option.bind_some] at h
        cases hr : unbase64 rest with
        | none => simp [hr] at h
        | some r =>
        simp only [hr, Option.bind_some, Option.some.injEq] at h
        subst h
        have ih := base64_encode_decode rest r hr
        simp only [base64, toNat_byte (show i1 * 4 + i2 / 16 < 256 by omega),
          toNat_byte (show i2 % 16 * 16 + i3 / 4 < 256 by omega),
          toNat_byte (show i3 % 4 * 64 + i4 < 256 by omega), ih, List.cons.injEq, and_true]
        rw [← e1, ← e2, ← e3, ← e4]
        exact ⟨by congr 1; omega, by congr 1; omega, by congr 1; omega, by congr 1; omega⟩

-- RFC 4648 §10.
#guard ["", "f", "fo", "foo", "foob", "fooba", "foobar"].map (fun s => String.ofList (base64 s.toUTF8.toList)) ==
  ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]
#guard unbase64 "CzQ=".toList == some [0x0b, 0x34]
#guard unbase64 "CzQ".toList == none && unbase64 "CzR=".toList == none && unbase64 "Cz==".toList == none
#guard unbase64 "Zg==Zg==".toList == none && unbase64 "Z===".toList == none

/-! ## Hex -/

/-- The lowercase hex digits. -/
def hexChars : List Char := "0123456789abcdef".toList

def hexChar (n : Nat) : Char := hexChars.getD n '0'

/-- Two lowercase hex digits per byte (§16.2). -/
def hex (bs : List UInt8) : Text := bs.flatMap fun b => [hexChar (b.toNat / 16), hexChar (b.toNat % 16)]

/-- Reading hex: lowercase digits, in pairs. -/
def unhex : Text → Option (List UInt8)
  | [] => some []
  | a :: b :: rest => do
    let i ← hexChars.idxOf? a
    let j ← hexChars.idxOf? b
    let r ← unhex rest
    some (byte (i * 16 + j) :: r)
  | [_] => none

theorem hexChar_idx : ∀ n, n < 16 → hexChars.idxOf? (hexChar n) = some n := by decide +kernel

theorem hex_decode_encode : ∀ bs : List UInt8, unhex (hex bs) = some bs
  | [] => rfl
  | b :: bs => by
    have hb := b.toNat_lt
    have := hex_decode_encode bs
    simp only [hex, List.flatMap_cons, List.cons_append, List.nil_append] at this ⊢
    simp only [unhex, hexChar_idx _ (show b.toNat / 16 < 16 by omega), hexChar_idx _ (show b.toNat % 16 < 16 by omega),
      this, Option.bind_eq_bind, Option.bind_some, Option.some.injEq, List.cons.injEq, and_true]
    rw [show b.toNat / 16 * 16 + b.toNat % 16 = b.toNat by omega, byte_toNat]

theorem hex_injective {bs cs : List UInt8} (h : hex bs = hex cs) : bs = cs := by
  have := hex_decode_encode bs
  rw [h, hex_decode_encode cs] at this
  exact (Option.some.inj this).symm

theorem hexChars_idx {c : Char} {n : Nat} (h : hexChars.idxOf? c = some n) : n < 16 ∧ hexChar n = c := by
  obtain ⟨hlt, heq, -⟩ := List.idxOf?_eq_some_iff.mp h
  refine ⟨hlt, ?_⟩
  unfold hexChar
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hlt, Option.getD_some, heq]

theorem hex_encode_decode : ∀ (t : Text) (bs : List UInt8), unhex t = some bs → hex bs = t
  | [], bs, h => by simp only [unhex, Option.some.injEq] at h; subst h; rfl
  | [_], _, h => by simp [unhex] at h
  | a :: b :: rest, bs, h => by
    simp only [unhex, Option.bind_eq_bind] at h
    cases ha : hexChars.idxOf? a with
    | none => simp [ha] at h
    | some i =>
    cases hb : hexChars.idxOf? b with
    | none => simp [ha, hb] at h
    | some j =>
    cases hr : unhex rest with
    | none => simp [ha, hb, hr] at h
    | some r =>
    simp only [ha, hb, hr, Option.bind_some, Option.some.injEq] at h
    subst h
    obtain ⟨li, ei⟩ := hexChars_idx ha
    obtain ⟨lj, ej⟩ := hexChars_idx hb
    have ih := hex_encode_decode rest r hr
    simp only [hex, List.flatMap_cons, List.cons_append, List.nil_append] at ih ⊢
    rw [ih, toNat_byte (show i * 16 + j < 256 by omega)]
    rw [← ei, ← ej]
    simp only [List.cons.injEq, and_true]
    exact ⟨by congr 1; omega, by congr 1; omega⟩

#guard String.ofList (hex [0x0b, 0x34, 0xff]) == "0b34ff"
#guard unhex "0B34".toList == none && unhex "0b3".toList == none

end Haus.Bytes
