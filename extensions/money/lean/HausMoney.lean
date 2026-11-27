import Haus.Schema.Codec

/-!
# The rule `iso` of `@haus-fmt/money`, version 1 — X2

The rule of [`profiles/iso.md`](../profiles/iso.md) (packages.md §6),
stated on the values the schema decoded: a `Currency` is a bare
tag of three capitals `A`–`Z`; a `Money` is any `Decimal` with such a
currency. `Valid` is the rule, `check` computes it (`check_iff`), and
`codec` is the rule as a check on the decoded value (§13.4), so the laws of
`Haus.Schema.Codec` hold for it (`codec_decode`, `codec_decode_encode`).
The package's manifest gives the rule to `Currency`; `Money` is covered
through it. Built as the library `HausMoney` of `spec/lean`, run by
`haus-rules`.
-/

namespace Haus.Rules.Money
open Haus Schema

/-- The schema of `@haus-fmt/money` (`extensions/money/schema.haus`), resolved. -/
def env : Env := ⟨[
  -- type Money = closed < Money Decimal Currency >
  ("Money", .variant true [.positional "Money" [.decimal, .ref "Currency"]]),
  -- type Currency = < >
  ("Currency", .variant false [])]⟩

/-- The types the rule decides on. -/
inductive Type_ where
  | money
  | currency
  deriving DecidableEq, Repr

def Type_.name : Type_ → String
  | .money => "Money"
  | .currency => "Currency"

def Type_.all : List Type_ := [.money, .currency]

/-! ## The rule -/

/-- A currency code: three characters, each a capital letter `A`–`Z` (U+0041–U+005A). -/
def Code (tag : String) : Prop := tag.toList.length = 3 ∧ ∀ c ∈ tag.toList, 'A' ≤ c ∧ c ≤ 'Z'

/-- A `Currency` the rule accepts: a code as its tag, and no payload. -/
inductive Currency : Typed → Prop
  | mk {tag : String} : Code tag → Currency (.unknown tag [])

/-- A `Money` the rule accepts: any amount, with a currency it accepts. -/
inductive Money : Typed → Prop
  | mk {a : String} {c : Typed} : Currency c → Money (.case "Money" [.decimal a, c])

/-- **The rule**, by type: which decoded values of each type the rule accepts. -/
def Valid : Type_ → Typed → Prop
  | .currency => Currency
  | .money => Money

/-! ## The checker -/

def isCapital (c : Char) : Bool := 'A' ≤ c && c ≤ 'Z'

def checkCode (tag : String) : Bool :=
  match tag.toList with
  | [a, b, c] => isCapital a && isCapital b && isCapital c
  | _ => false

def checkCurrency : Typed → Bool
  | .unknown tag [] => checkCode tag
  | _ => false

def checkMoney : Typed → Bool
  | .case tag [.decimal _, c] => tag == "Money" && checkCurrency c
  | _ => false

/-- The checker: whether the rule accepts a decoded value of the type `ty`. -/
def check : Type_ → Typed → Bool
  | .currency => checkCurrency
  | .money => checkMoney

/-! ## The checker computes the rule -/

theorem checkCode_iff (tag : String) : checkCode tag = true ↔ Code tag := by
  unfold checkCode Code
  match h : tag.toList with
  | [a, b, c] => simp [isCapital, and_assoc]
  | [] | [_] | [_, _] | _ :: _ :: _ :: _ :: _ => simp

theorem checkCurrency_iff (x : Typed) : checkCurrency x = true ↔ Currency x := by
  constructor
  · intro h
    unfold checkCurrency at h
    split at h
    · exact .mk ((checkCode_iff _).mp h)
    · simp at h
  · rintro ⟨hc⟩
    exact (checkCode_iff _).mpr hc

theorem checkMoney_iff (x : Typed) : checkMoney x = true ↔ Money x := by
  constructor
  · intro h
    unfold checkMoney at h
    split at h
    · simp only [Bool.and_eq_true, beq_iff_eq] at h
      obtain ⟨rfl, hc⟩ := h
      exact .mk ((checkCurrency_iff _).mp hc)
    · simp at h
  · rintro ⟨hc⟩
    simp [checkMoney, (checkCurrency_iff _).mpr hc]

/-- **The checker computes the rule**, for every type and decoded value. -/
theorem check_iff (ty : Type_) (x : Typed) : check ty x = true ↔ Valid ty x := by
  cases ty
  · exact checkMoney_iff x
  · exact checkCurrency_iff x

/-! ## The rule as a codec -/

/-- The rule as a codec (§13.4): a check on the decoded value. -/
def codec (ty : Type_) : Codec Typed := Codec.check (check ty)

/-- The codec accepts exactly the values the schema decodes that the rule accepts, and holds them as decoded. -/
theorem codec_decode {ty : Type_} {v : Value} {x : Typed} :
    (codec ty).decode env (.ref ty.name) v = .ok x ↔ Schema.decode env (.ref ty.name) v = .ok x ∧ Valid ty x := by
  rw [codec, Codec.check_decode, check_iff]

/-- Decode, encode, decode is decode (`Codec.decode_encode`). -/
theorem codec_decode_encode {ty : Type_} {v : Value} {x : Typed}
    (h : (codec ty).decode env (.ref ty.name) v = .ok x) : (codec ty).decode env (.ref ty.name) (Schema.encode x) = .ok x :=
  Codec.check_decode_encode h

/-- The codec keeps the value, so every law of `Haus.Schema.Codec` holds for it. -/
theorem codec_keeps (ty : Type_) : (codec ty).Keeps := Codec.check_keeps _

/-! ## Both codecs in one value (§13.4)

When codecs apply at several places in one value, decoding runs them from
the inside out, and the first that rejects gives the error at its own place.
In a `Money`, the codec of its `Currency` runs first, at `$[1]`, then the
codec of `Money` at `$`. Together they accept exactly what the codec of
`Money` alone accepts (`decodeInsideOut_ok`), as its rule includes the
currency's: only the place of the error differs.
-/

/-- Whether the codec of an inner `Currency` rejects: for a `Money`, the codec of its currency. -/
def currencyRejects : Type_ → Typed → Bool
  | .money, .case _ [_, c] => !checkCurrency c
  | _, _ => false

/-- The place of the inner `Currency` of a `Money`: its second argument, `$[1]`. -/
def currencyPlace : List Seg := [.arg "Money" 1]

/-- **Decoding with both codecs**: the schema, then the codec of the `Currency` inside, then the type's own. -/
def decodeInsideOut (ty : Type_) (v : Value) : Except Error Typed :=
  match Schema.decode env (.ref ty.name) v with
  | .error e => .error e
  | .ok x =>
    if currencyRejects ty x then .error { Codec.rejected with path := currencyPlace }
    else if check ty x then .ok x else .error Codec.rejected

theorem check_of_currencyRejects {ty : Type_} {x : Typed} (h : currencyRejects ty x = true) : check ty x = false := by
  cases ty with
  | currency => simp [currencyRejects] at h
  | money =>
    simp only [check, checkMoney]
    split
    · simp_all [currencyRejects]
    · rfl

/-- **Inside out, the codecs accept what the type's own codec accepts**: only the place of a rejection moves. -/
theorem decodeInsideOut_ok {ty : Type_} {v : Value} {x : Typed} :
    decodeInsideOut ty v = .ok x ↔ (codec ty).decode env (.ref ty.name) v = .ok x := by
  rw [codec, Codec.check_decode]
  unfold decodeInsideOut
  cases hd : Schema.decode env (.ref ty.name) v with
  | error e => simp
  | ok y =>
    by_cases hc : currencyRejects ty y = true
    · simp only [hc, ↓reduceIte, reduceCtorEq, false_iff, Except.ok.injEq, not_and]
      rintro rfl
      simp [check_of_currencyRejects hc]
    · by_cases hk : check ty y = true
      · simp only [hc, hk, ↓reduceIte, Bool.false_eq_true, Except.ok.injEq]
        constructor
        · rintro rfl; exact ⟨rfl, hk⟩
        · exact fun h => h.1
      · simp only [hc, hk, ↓reduceIte, Bool.false_eq_true, reduceCtorEq, false_iff, Except.ok.injEq, not_and]
        rintro rfl; exact hk

private def rejectedAt (ty : Type_) (src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] =>
    match decodeInsideOut ty v with
    | .error e => some e.place
    | .ok _ => none
  | _ => none

#guard rejectedAt .money "Money(19.99, Eur)" == some "$[1]"
#guard rejectedAt .money "Money(19.99, EUR)" == none
#guard rejectedAt .currency "Eur" == some "$"

#guard check .currency (.unknown "EUR" [])
#guard !check .currency (.unknown "Eur" [])
#guard !check .currency (.unknown "EURO" [])
#guard !check .currency (.unknown "CHF" [.num "1"])
#guard check .money (.case "Money" [.decimal "19.90", .unknown "USD" []])
#guard !check .money (.case "Money" [.decimal "1", .unknown "US" []])

end Haus.Rules.Money
