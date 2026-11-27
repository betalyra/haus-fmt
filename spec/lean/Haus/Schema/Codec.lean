import Haus.Schema.RoundTrip

/-!
# The codec contract (spec §13.4) — X1

A codec gives a named type a host type of the application's choosing. It
runs after the type's schema: it reads the value the schema decoded
(`Typed`) into its host type, or rejects it, and writes a host value back as
a decoded value, which the schema's encoder writes out. So a codec is a pair
of functions on decoded values (`Codec`); it never sees the text, and it
can't change how the schema decodes.

Packages' rules (packages.md §6) are the common case: a check that keeps the
decoded value and only accepts or rejects it (`Codec.check`). For every codec
that keeps the value (`Codec.Keeps`, which every check does), the laws of
§13.4 hold, proven here once, so a package's rule or an application's codec
gets them without a proof of
its own:

- **It accepts only what the schema accepts** (`decode_ok`, `decode_schema`):
  by construction, it reads only what the schema decoded.
- **It rejects more, never fewer** (`decode_error`): what the schema rejects,
  it rejects with the schema's error.
- **Decode, encode, decode is decode** (`decode_encode`): from the schema's
  round trip, `Schema.decode_encode`.
- **It doesn't change what a value means** (`decoded`, `encode_eq`,
  `encode_equiv`, `encode_agree`, `same_value`): what it decodes is the value
  the schema decoded, and encoding through it writes the value the schema's
  encoding writes, equal (§2) and in fact the same; so it is the input
  except where §15 says (`Agree`), and two codecs that both accept a value
  agree on what it is.

A codec whose host type keeps less than the value (a JavaScript `Date` for
an `Instant`, which drops the offset) doesn't keep the value, and §13.4
doesn't ask it to. It has one obligation left for decode, encode, decode:
what it writes is a value of the type that it reads back as the same host
value (`decode_encode_of`).
-/

namespace Haus.Schema
open Haus

/--
A codec (§13.4) with host type `H`: `read` takes the value the type's schema
decoded into the host type, or rejects it (`none`); `write` gives a host
value back as a decoded value, for the schema's encoder.
-/
structure Codec (H : Type) where
  read : Typed → Option H
  write : H → Typed

namespace Codec

variable {H : Type}

/-- The error of a value the schema accepts and the codec doesn't (`codec-rejected`). Its message is the binding's. -/
def rejected : Error := { path := [], reason := "rejected by the codec", code := some .codecRejected }

/-- Decoding with a codec: the schema first, then the codec on what it decoded. -/
def decode (c : Codec H) (env : Env) (t : Ty) (v : Value) : Except Error H :=
  match Schema.decode env t v with
  | .error e => .error e
  | .ok x =>
    match c.read x with
    | some h => .ok h
    | none => .error rejected

/-- Encoding with a codec: the host value as a decoded value, encoded by the schema (§15). -/
def encode (c : Codec H) (h : H) : Value := Schema.encode (c.write h)

/--
The codec keeps the value: a host value it read writes back as the decoded
value it was read from. What §13.4 asks of a binding's default host types.
-/
def Keeps (c : Codec H) : Prop := ∀ x h, c.read x = some h → c.write h = x

/--
A **check**: the host type is the decoded value itself, kept as it is, and
`p` says which values are accepted. A package's rule is one (packages.md §6).
-/
def check (p : Typed → Bool) : Codec Typed where
  read x := if p x then some x else none
  write := id

/-! ## It accepts only what the schema accepts, and rejects more -/

/-- What the codec accepts: exactly what it reads from a value the schema decoded. -/
theorem decode_ok {c : Codec H} {env : Env} {t : Ty} {v : Value} {h : H} :
    c.decode env t v = .ok h ↔ ∃ x, Schema.decode env t v = .ok x ∧ c.read x = some h := by
  unfold decode
  cases hd : Schema.decode env t v with
  | error e => simp
  | ok x =>
    cases hr : c.read x with
    | none => simp [hr]
    | some h' => simp [hr]

/-- **It accepts only what the schema accepts** (§13.4). -/
theorem decode_schema {c : Codec H} {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) : ∃ x, Schema.decode env t v = .ok x :=
  let ⟨x, hx, _⟩ := decode_ok.mp hc
  ⟨x, hx⟩

/-- **It rejects more, never fewer** (§13.4): what the schema rejects, the codec rejects, with the same error. -/
theorem decode_error {c : Codec H} {env : Env} {t : Ty} {v : Value} {e : Error}
    (he : Schema.decode env t v = .error e) : c.decode env t v = .error e := by
  simp [decode, he]

/-! ## Decode, encode, decode is decode -/

/--
**Decode, encode, decode is decode** (§13.4), for a codec that keeps the
value: what it encodes decodes back to the same host value.
-/
theorem decode_encode {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) : c.decode env t (c.encode h) = .ok h := by
  obtain ⟨x, hx, hr⟩ := decode_ok.mp hc
  have hw : c.write h = x := hk x h hr
  exact decode_ok.mpr ⟨x, by rw [encode, hw]; exact Schema.decode_encode hx, hr⟩

/--
**Decode, encode, decode is decode** for any codec, also one whose host type
keeps less than the value: when what it writes is a value of the type
(`hw`) that it reads back as the same host value (`hr`).
-/
theorem decode_encode_of {c : Codec H} {env : Env} {t : Ty} {h : H}
    (hw : ∃ v, Schema.decode env t v = .ok (c.write h)) (hr : c.read (c.write h) = some h) :
    c.decode env t (c.encode h) = .ok h :=
  let ⟨_, hv⟩ := hw
  decode_ok.mpr ⟨c.write h, Schema.decode_encode hv, hr⟩

/-- A codec that keeps the value meets the obligations of `decode_encode_of` for what it decoded. -/
theorem Keeps.obligations {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) :
    (∃ v, Schema.decode env t v = .ok (c.write h)) ∧ c.read (c.write h) = some h := by
  obtain ⟨x, hx, hr⟩ := decode_ok.mp hc
  rw [hk x h hr]
  exact ⟨⟨v, hx⟩, hr⟩

/-! ## The value's meaning doesn't change -/

/-- **The decoded value is the schema's** (§13.4): a codec that keeps the value holds what the schema decoded. -/
theorem decoded {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) : Schema.decode env t v = .ok (c.write h) := by
  obtain ⟨x, hx, hr⟩ := decode_ok.mp hc
  rw [hk x h hr]; exact hx

/-- The same, as the rules of §15: the type accepts the value, decoded as what the codec holds. -/
theorem dec {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) : Dec env t v (c.write h) :=
  decode_iff.mp (decoded hk hc)

/-- Encoding through the codec writes what the schema's encoding of the decoded value writes. -/
theorem encode_eq {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H} {x : Typed}
    (hc : c.decode env t v = .ok h) (hx : Schema.decode env t v = .ok x) :
    c.encode h = Schema.encode x := by
  have := (decoded hk hc).symm.trans hx
  simp only [Except.ok.injEq] at this
  rw [encode, this]

/--
**Encoding through the codec gives a value equal to the decoded one** (§2,
§13.4): equal to what the schema's encoding of the value the schema decoded
gives, so the same canonical form and hash (§12).
-/
theorem encode_equiv {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H} {x : Typed}
    (hc : c.decode env t v = .ok h) (hx : Schema.decode env t v = .ok x) :
    Value.Equiv (c.encode h) (Schema.encode x) := by
  rw [encode_eq hk hc hx]; rfl

/-- Encoding through the codec gives the input back, except where §15 says (`Agree`). -/
theorem encode_agree {c : Codec H} (hk : c.Keeps) {env : Env} {t : Ty} {v : Value} {h : H}
    (hc : c.decode env t v = .ok h) : Agree env t v (c.encode h) :=
  Schema.encode_agree (decoded hk hc)

/--
**Codecs agree on what a value is** (§13.4, "Codecs are part of the
application"): two codecs that keep the value and both accept a value
decode it to the same value, and encode it the same. They may disagree only
on what they accept.
-/
theorem same_value {H' : Type} {c : Codec H} {c' : Codec H'} (hk : c.Keeps) (hk' : c'.Keeps)
    {env : Env} {t : Ty} {v : Value} {h : H} {h' : H'}
    (hc : c.decode env t v = .ok h) (hc' : c'.decode env t v = .ok h') :
    c.write h = c'.write h' ∧ c.encode h = c'.encode h' := by
  have := (decoded hk hc).symm.trans (decoded hk' hc')
  simp only [Except.ok.injEq] at this
  exact ⟨this, by rw [encode, encode, this]⟩

/-! ## Checks -/

/-- A check keeps the value. -/
theorem check_keeps (p : Typed → Bool) : (check p).Keeps := by
  intro x h hr
  simp only [check] at hr
  split at hr
  · simp only [Option.some.injEq] at hr; subst hr; rfl
  · simp at hr

/-- A check accepts exactly the values the schema decoded that pass it, and holds them as decoded. -/
theorem check_decode {p : Typed → Bool} {env : Env} {t : Ty} {v : Value} {x : Typed} :
    (check p).decode env t v = .ok x ↔ Schema.decode env t v = .ok x ∧ p x = true := by
  rw [decode_ok]
  constructor
  · rintro ⟨y, hy, hr⟩
    simp only [check] at hr
    split at hr
    · simp only [Option.some.injEq] at hr; subst hr; exact ⟨hy, by assumption⟩
    · simp at hr
  · rintro ⟨hx, hp⟩
    exact ⟨x, hx, by simp [check, hp]⟩

/-- A check encodes as the schema does. -/
theorem check_encode (p : Typed → Bool) (x : Typed) : (check p).encode x = Schema.encode x := rfl

/-- Decode, encode, decode is decode, for a check. -/
theorem check_decode_encode {p : Typed → Bool} {env : Env} {t : Ty} {v : Value} {x : Typed}
    (hc : (check p).decode env t v = .ok x) : (check p).decode env t (Schema.encode x) = .ok x :=
  decode_encode (check_keeps p) hc

end Codec
end Haus.Schema
