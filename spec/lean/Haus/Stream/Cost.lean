import Haus.Stream.Chunks

/-!
# Streams in linear time (plan phase P, steps P1 and P2; design review S17, C6)

Spec §7: reading takes time linear in the input. `Haus.Stream` reads with
lists, where taking the front of a buffer costs nothing, so it says nothing
about time. This file models the buffer the bindings keep, gives every
operation its real cost, and counts.

**P1, the cost model.** A reader `Buf` keeps one buffer `bytes` (Rust's
`Vec<u8>`, TypeScript's string), the offset `start` where the current value
begins and the offset `pos` up to which it has been scanned. Its field
`steps` counts what it does, next to the result:

* receiving a chunk appends it: one step per character (amortized: a growing
  buffer copies each byte a bounded number of times);
* the scanner: one step per `step` (each looks at most three characters) and
  one where it stops (end of the buffer, waiting, an unbalanced bracket);
* a piece is a slice of the buffer (`Buf.cur`), passed to the parser
  without copying; parsing it is the parser's cost (step P3);
* dropping the first `start` bytes of the buffer moves the others to the
  front: one step per byte moved.

`Buf.push` drops the bytes of the values completed by a chunk once, after
scanning it (Rust's reader since S17). `Buf.pushOld` is the design before
S17: it drops each value's bytes as soon as its comma is found.

`Buf.mark` is a ghost field for the proof (where the scan stood at the last
drop); the reader never reads it.

**What is proven.**

* `splitB_view`, `splitOld_view`: both readers find exactly the pieces of
  `split` (so, by `read_correct`, they read what `parse` reads), whatever
  the chunks.
* **P2**, `splitB_steps`: reading `n` characters in `p` chunks takes at
  most `3 · n + 3 · p + 6` steps. Each character is appended once,
  scanned once, and moved at most once: after it has been moved it is at
  the front of the buffer, before the next comma (`mark ≤ start`), so the
  next drop removes it.
* `splitOld_steps_vals`: the design before S17 takes at least
  `k · (k + 1)` steps for `k` values `0,` in one chunk (`2 · k`
  characters);
  `splitOld_not_linear`: no bound `c · (n + p + 1)` holds for it.
-/

namespace Haus.Stream
open Haus

/-! ## The scanner's stops -/

/-- The scanner waits only when fewer than three characters are left. -/
theorem step_wait_lt {s : St} {c : Char} {r : Text} (h : step false s (c :: r) = .wait) : r.length < 2 := by
  cases hm : s.mode <;> simp only [step, hm] at h <;>
    by_cases hs : c = '/' <;> by_cases hq : c = '"' <;> by_cases ha : c = '*' <;> by_cases hb : c = '\\' <;>
    simp_all <;> (repeat' split at h) <;> simp_all <;> omega

/-! ## P1: the buffer and its costs -/

/-- A stream reader with one buffer, as the bindings keep it, counting its steps. -/
structure Buf where
  /-- The characters received and not yet dropped. -/
  bytes : Text := []
  /-- Where the current value starts in `bytes`. -/
  start : Nat := 0
  /-- How far `bytes` has been scanned. -/
  pos : Nat := 0
  st : St := {}
  /-- The texts of the values completed so far. -/
  pieces : List Text := []
  /-- The text up to an unbalanced closing bracket, once one was found. -/
  stop : Option Text := none
  /-- Steps taken so far. -/
  steps : Nat := 0
  /-- Ghost: where `pos` stood after the last drop. -/
  mark : Nat := 0

/-- The current value's text: a slice of the buffer. -/
def Buf.cur (b : Buf) : Text := (b.bytes.drop b.start).take (b.pos - b.start)

/-- What the reader of `Haus.Stream` would hold. -/
def Buf.view (b : Buf) : Reader :=
  ⟨b.pieces, match b.stop with
    | some t => .unbalanced t
    | none => .ok b.st b.cur (b.bytes.drop b.pos)⟩

/-- Scans from `pos` to the end of the buffer, or until it must wait or finds an unbalanced bracket. -/
def Buf.scan (final : Bool) (b : Buf) : Buf :=
  match _h : b.bytes.drop b.pos with
  | [] => { b with steps := b.steps + 1 }
  | c :: r =>
    match step final b.st (c :: r) with
    | .wait => { b with steps := b.steps + 1 }
    | .adv k s => Buf.scan final { b with pos := b.pos + k + 1, st := s, steps := b.steps + 1 }
    | .cut => Buf.scan final
        { b with pieces := b.pieces ++ [b.cur], start := b.pos + 1, pos := b.pos + 1, steps := b.steps + 1 }
    | .unbalanced =>
        { b with stop := some ((b.bytes.drop b.start).take (b.pos + 1 - b.start)), steps := b.steps + 1 }
termination_by b.bytes.length - b.pos
decreasing_by all_goals (have := congrArg List.length _h; simp only [List.length_drop, List.length_cons] at this; omega)

/-- Drops the bytes of the completed values: the rest moves to the front, a step per byte. -/
def Buf.drain (b : Buf) : Buf :=
  if b.stop.isSome ∨ b.start = 0 then b
  else { b with bytes := b.bytes.drop b.start, start := 0, pos := b.pos - b.start, mark := b.pos - b.start,
                steps := b.steps + (b.bytes.length - b.start) }

/-- Receives a chunk: appends it, scans, and drops the completed values once. -/
def Buf.push (b : Buf) (chunk : Text) : Buf :=
  match b.stop with
  | some _ => { b with steps := b.steps + 1 }
  | none => ({ b with bytes := b.bytes ++ chunk, steps := b.steps + chunk.length }.scan false).drain

/-- The input has ended: scans what is left without waiting. -/
def Buf.finish (b : Buf) : Buf :=
  let b := b.push []
  match b.stop with
  | some _ => b
  | none => b.scan true

/-- Splits the text arriving as `chunks` into the texts of its top-level values. -/
def splitB (chunks : List Text) : Buf := (chunks.foldl Buf.push {}).finish

/-! ### The design before S17 -/

/-- As `Buf.scan`, but each value's bytes are dropped as soon as its comma is found. -/
def Buf.scanOld (final : Bool) (b : Buf) : Buf :=
  match _h : b.bytes.drop b.pos with
  | [] => { b with steps := b.steps + 1 }
  | c :: r =>
    match step final b.st (c :: r) with
    | .wait => { b with steps := b.steps + 1 }
    | .adv k s => Buf.scanOld final { b with pos := b.pos + k + 1, st := s, steps := b.steps + 1 }
    | .cut => Buf.scanOld final
        { b with pieces := b.pieces ++ [b.cur], bytes := b.bytes.drop (b.pos + 1), start := 0, pos := 0,
                 steps := b.steps + 1 + (b.bytes.length - (b.pos + 1)) }
    | .unbalanced =>
        { b with stop := some ((b.bytes.drop b.start).take (b.pos + 1 - b.start)), steps := b.steps + 1 }
termination_by b.bytes.length - b.pos
decreasing_by all_goals (have := congrArg List.length _h; simp only [List.length_drop, List.length_cons] at this; (try simp only [List.length_drop]); omega)

def Buf.pushOld (b : Buf) (chunk : Text) : Buf :=
  match b.stop with
  | some _ => { b with steps := b.steps + 1 }
  | none => { b with bytes := b.bytes ++ chunk, steps := b.steps + chunk.length }.scanOld false

def Buf.finishOld (b : Buf) : Buf :=
  let b := b.pushOld []
  match b.stop with
  | some _ => b
  | none => b.scanOld true

def splitOld (chunks : List Text) : Buf := (chunks.foldl Buf.pushOld {}).finishOld

/-! ## The readers compute `split` -/

private theorem take_sub_add {X : Text} {d k : Nat} {c : Char} {r : Text} (h : X.drop d = c :: r) :
    X.take (d + (k + 1)) = X.take d ++ c :: r.take k := by
  rw [List.take_add, h]; rfl

/-- What `Buf.scan` does is what `scan` does on the current value and the rest. -/
theorem Buf.scan_view (f : Bool) (b : Buf) (hs : b.stop = none) (hp : b.start ≤ b.pos) :
    (b.scan f).view = ⟨b.pieces ++ (Stream.scan f b.st b.cur (b.bytes.drop b.pos)).1,
      (Stream.scan f b.st b.cur (b.bytes.drop b.pos)).2⟩ := by
  fun_induction Buf.scan f b with
  | case1 b h => simp [Buf.view, Buf.cur, hs, h, Stream.scan]
  | case2 b c r h hst =>
    rw [h, Stream.scan, hst]; simp [Buf.view, Buf.cur, hs, h]
  | case3 b c r h k s hst ih =>
    rw [ih hs (by simp; omega), h, Stream.scan, hst]
    have hd : (b.bytes.drop b.start).drop (b.pos - b.start) = c :: r := by
      rw [List.drop_drop, Nat.add_sub_cancel' hp, h]
    have e1 : Buf.cur { b with pos := b.pos + k + 1, st := s, steps := b.steps + 1 } = b.cur ++ c :: r.take k := by
      simp only [Buf.cur]
      rw [show b.pos + k + 1 - b.start = (b.pos - b.start) + (k + 1) by omega, take_sub_add hd]
    have e2 : b.bytes.drop (b.pos + k + 1) = r.drop k := by
      rw [show b.pos + k + 1 = b.pos + (k + 1) by omega, ← List.drop_drop, h]; rfl
    simp only [e1, e2]
  | case4 b c r h hst ih =>
    rw [ih hs (by simp), h, Stream.scan, hst]
    have e2 : b.bytes.drop (b.pos + 1) = r := by
      rw [← List.drop_drop, h]; rfl
    simp [Buf.cur, e2]
  | case5 b c r h hst =>
    rw [h, Stream.scan, hst]
    have hd : (b.bytes.drop b.start).drop (b.pos - b.start) = c :: r := by
      rw [List.drop_drop, Nat.add_sub_cancel' hp, h]
    have e1 : (b.bytes.drop b.start).take (b.pos + 1 - b.start) = b.cur ++ [c] := by
      rw [show b.pos + 1 - b.start = (b.pos - b.start) + (0 + 1) by omega, take_sub_add hd]; simp [Buf.cur]
    simp [Buf.view, e1]

/-- Well-formed: offsets within the buffer. -/
structure Buf.Ok (b : Buf) : Prop where
  start_le : b.start ≤ b.pos
  pos_le : b.pos ≤ b.bytes.length

/-- Scanning without waiting stays within the buffer and keeps it; `pos` only grows. -/
theorem Buf.scan_ok (b : Buf) (hb : b.Ok) :
    (b.scan false).Ok ∧ (b.scan false).bytes = b.bytes ∧ b.pos ≤ (b.scan false).pos := by
  fun_induction Buf.scan false b with
  | case1 b h => exact ⟨⟨hb.1, hb.2⟩, rfl, Nat.le_refl _⟩
  | case2 b c r h hst => exact ⟨⟨hb.1, hb.2⟩, rfl, Nat.le_refl _⟩
  | case3 b c r h k s hst ih =>
    have := step_adv_le hst
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    obtain ⟨h1, h2, h3⟩ := ih ⟨by simp; have := hb.start_le; omega, by simp; omega⟩
    exact ⟨h1, h2, by simp at h3; omega⟩
  | case4 b c r h hst ih =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    obtain ⟨h1, h2, h3⟩ := ih ⟨by simp, by simp; omega⟩
    exact ⟨h1, h2, by simp at h3; omega⟩
  | case5 b c r h hst => exact ⟨⟨hb.1, hb.2⟩, rfl, Nat.le_refl _⟩

theorem Buf.drain_view (b : Buf) (hb : b.Ok) : b.drain.view = b.view := by
  unfold Buf.drain
  split
  · rfl
  · rename_i h
    have hp := hb.start_le
    simp only [Buf.view, Buf.cur, List.drop_drop, Nat.add_zero, Nat.sub_zero]
    rw [Nat.add_sub_cancel' hp]

theorem Buf.drain_ok (b : Buf) (hb : b.Ok) : b.drain.Ok := by
  unfold Buf.drain
  split
  · exact hb
  · exact ⟨by simp, by simp; have := hb.pos_le; omega⟩

theorem Buf.push_view (b : Buf) (hb : b.Ok) (chunk : Text) :
    (b.push chunk).view = b.view.push chunk ∧ (b.push chunk).Ok := by
  unfold Buf.push
  split
  · rename_i t h
    refine ⟨?_, hb.1, hb.2⟩
    simp [Buf.view, h, Reader.push]
  · rename_i h
    let b' : Buf := { b with bytes := b.bytes ++ chunk, steps := b.steps + chunk.length }
    have hb' : b'.Ok := ⟨hb.start_le, by simp [b']; have := hb.pos_le; omega⟩
    obtain ⟨h1, -, -⟩ := Buf.scan_ok b' hb'
    refine ⟨?_, Buf.drain_ok _ h1⟩
    rw [Buf.drain_view _ h1, Buf.scan_view false b' h hb.start_le]
    have hp := hb.pos_le
    have e1 : b'.cur = b.cur := by
      simp only [b', Buf.cur, List.drop_append_of_le_length (Nat.le_trans hb.start_le hp)]
      exact List.take_append_of_le_length (by simp; omega)
    have e2 : b'.bytes.drop b'.pos = b.bytes.drop b.pos ++ chunk := List.drop_append_of_le_length hp
    simp only [Buf.view, h, Reader.push, e1, e2]
    rfl

theorem Buf.finish_view (b : Buf) (hb : b.Ok) : b.finish.view = b.view.finish := by
  obtain ⟨h1, h2⟩ := Buf.push_view b hb []
  unfold Buf.finish Reader.finish
  simp only
  rw [← h1]
  split
  · rename_i t h
    simp [Reader.close, Buf.view, h]
  · rename_i h
    rw [Buf.scan_view _ _ h h2.start_le]
    simp [Reader.close, Buf.view, h]

theorem foldl_push_view (cs : List Text) (b : Buf) (hb : b.Ok) :
    (cs.foldl Buf.push b).view = cs.foldl Reader.push b.view ∧ (cs.foldl Buf.push b).Ok := by
  induction cs generalizing b with
  | nil => exact ⟨rfl, hb⟩
  | cons c cs ih =>
    obtain ⟨h1, h2⟩ := Buf.push_view b hb c
    simp only [List.foldl_cons, ← h1]
    exact ih _ h2

/-- **The reader with one buffer finds the pieces of `split`.** -/
theorem splitB_view (cs : List Text) : (splitB cs).view = split cs := by
  obtain ⟨h1, h2⟩ := foldl_push_view cs {} ⟨Nat.le_refl _, Nat.zero_le _⟩
  rw [splitB, Buf.finish_view _ h2, h1]
  rfl

/-! ## P2: the reader is linear -/

/-- One scan: a step per character it passes, and one where it stops. -/
theorem Buf.scan_steps (f : Bool) (b : Buf) : (b.scan f).steps ≤ b.steps + (b.bytes.length - b.pos) + 1 := by
  fun_induction Buf.scan f b with
  | case1 => simp
  | case2 => simp
  | case3 b c r h k s hst ih =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    simp only at ih; omega
  | case4 b c r h hst ih =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    simp only at ih; omega
  | case5 => simp

/-- What a scan without waiting keeps: its steps, the ghost mark, where the current value starts. -/
theorem Buf.scan_facts (b : Buf) :
    (b.scan false).steps ≤ b.steps + ((b.scan false).pos - b.pos) + 1 ∧ (b.scan false).mark = b.mark ∧
    ((b.scan false).start = b.start ∨ b.pos < (b.scan false).start) ∧
    ((b.scan false).stop = none → (b.scan false).bytes.length ≤ (b.scan false).pos + 2) ∧
    (b.scan false).bytes = b.bytes ∧ b.pos ≤ (b.scan false).pos := by
  fun_induction Buf.scan false b with
  | case1 b h =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_nil] at hl
    simp; omega
  | case2 b c r h hst =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    have := step_wait_lt hst
    simp; omega
  | case3 b c r h k s hst ih =>
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := ih
    simp only at h1 h2 h3 h4 h5 h6
    refine ⟨by omega, h2, by omega, h4, h5, by omega⟩
  | case4 b c r h hst ih =>
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := ih
    simp only at h1 h2 h3 h4 h5 h6
    refine ⟨by omega, h2, by omega, h4, h5, by omega⟩
  | case5 => simp

/--
The invariant of the amortized bound, after `n` characters in `p` chunks.
`pos - mark` characters have been scanned since the last drop and not yet
moved: they are the potential that pays for the next drop.
-/
structure Buf.Inv (b : Buf) (n p : Nat) : Prop where
  ok : b.Ok
  len_le : b.bytes.length ≤ n
  mark_le : b.mark ≤ b.pos
  mark_start : b.start = 0 ∨ b.mark ≤ b.start
  ahead : b.stop = none → b.bytes.length ≤ b.pos + 2
  steps : b.steps + (b.pos - b.mark) ≤ n + 2 * (n - b.bytes.length + b.pos) + 3 * p

theorem Buf.inv_empty : Buf.Inv {} 0 0 :=
  ⟨⟨Nat.le_refl _, Nat.zero_le _⟩, by simp, Nat.le_refl _, .inl rfl, by simp, by simp⟩

theorem Buf.push_inv {b : Buf} {n p : Nat} (hb : b.Inv n p) (c : Text) : (b.push c).Inv (n + c.length) (p + 1) := by
  have ⟨⟨o1, o2⟩, i1, i2, i3, i4, i5⟩ := hb
  unfold Buf.push
  split
  · exact ⟨⟨o1, o2⟩, by simp; omega, i2, i3, by simp_all, by simp; omega⟩
  · rename_i hs
    generalize hb1 : ({ b with bytes := b.bytes ++ c, steps := b.steps + c.length } : Buf) = b1
    have hok : b1.Ok := by subst hb1; exact ⟨o1, by simp; omega⟩
    obtain ⟨j1, j2, j3, j4, j5, j6⟩ := Buf.scan_facts b1
    obtain ⟨⟨k1, k2⟩, -, -⟩ := Buf.scan_ok b1 hok
    generalize hb2 : b1.scan false = b2 at j1 j2 j3 j4 j5 j6 k1 k2
    have e1 : b1.bytes.length = b.bytes.length + c.length := by subst hb1; simp
    have e2 : b1.steps = b.steps + c.length := by subst hb1; rfl
    have e3 : b1.pos = b.pos := by subst hb1; rfl
    have e4 : b1.start = b.start := by subst hb1; rfl
    have e5 : b1.mark = b.mark := by subst hb1; rfl
    have k2' := k2
    have j4' := j4
    rw [j5, e1] at k2 j4
    unfold Buf.drain
    split
    · rename_i hd
      refine ⟨⟨k1, by rw [j5, e1]; exact k2⟩, by rw [j5, e1]; omega, by omega, by omega, by rw [j5, e1]; exact j4, ?_⟩
      rw [j5, e1]; omega
    · rename_i hd
      simp only [not_or, Bool.not_eq_true, Option.isSome_eq_false_iff, Option.isNone_iff_eq_none] at hd
      have := j4 hd.1
      have := j4' hd.1
      refine ⟨⟨by simp, by simp; omega⟩, by simp [j5, e1]; omega, by simp, .inl rfl, by simp [j5, e1]; omega, ?_⟩
      simp only [List.length_drop, j5, e1]
      omega

theorem Buf.foldl_inv (cs : List Text) {b : Buf} {n p : Nat} (hb : b.Inv n p) :
    (cs.foldl Buf.push b).Inv (n + (cs.map List.length).sum) (p + cs.length) := by
  induction cs generalizing b n p with
  | nil => simpa using hb
  | cons c cs ih =>
    have := ih (Buf.push_inv hb c)
    simp only [List.foldl_cons, List.map_cons, List.sum_cons, List.length_cons] at this ⊢
    rw [show n + (c.length + (cs.map List.length).sum) = n + c.length + (cs.map List.length).sum by omega,
      show p + (cs.length + 1) = p + 1 + cs.length by omega]
    exact this

/--
**P2: the stream reader is linear.** Reading `n` characters arriving in `p`
chunks, split anywhere, takes at most `3 · n + 3 · p + 6` steps, buffer
operations included.
-/
theorem splitB_steps (cs : List Text) :
    (splitB cs).steps ≤ 3 * (cs.map List.length).sum + 3 * cs.length + 6 := by
  have h := Buf.push_inv (Buf.foldl_inv cs Buf.inv_empty) []
  simp only [Nat.zero_add, List.length_nil, Nat.add_zero] at h
  unfold splitB Buf.finish
  generalize (cs.foldl Buf.push {}).push [] = b at h ⊢
  have ⟨⟨o1, o2⟩, i1, i2, i3, i4, i5⟩ := h
  simp only
  split
  · omega
  · rename_i hs
    have := Buf.scan_steps true b
    have := i4 hs
    omega

/-! ## The design before S17 -/

theorem Buf.scanOld_view (f : Bool) (b : Buf) (hs : b.stop = none) (hp : b.start ≤ b.pos) :
    (b.scanOld f).view = ⟨b.pieces ++ (Stream.scan f b.st b.cur (b.bytes.drop b.pos)).1,
      (Stream.scan f b.st b.cur (b.bytes.drop b.pos)).2⟩ := by
  fun_induction Buf.scanOld f b with
  | case1 b h => simp [Buf.view, Buf.cur, hs, h, Stream.scan]
  | case2 b c r h hst =>
    rw [h, Stream.scan, hst]; simp [Buf.view, Buf.cur, hs, h]
  | case3 b c r h k s hst ih =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    rw [ih hs (by simp; omega), h, Stream.scan, hst]
    have hd : (b.bytes.drop b.start).drop (b.pos - b.start) = c :: r := by
      rw [List.drop_drop, Nat.add_sub_cancel' hp, h]
    have e1 : Buf.cur { b with pos := b.pos + k + 1, st := s, steps := b.steps + 1 } = b.cur ++ c :: r.take k := by
      simp only [Buf.cur]
      rw [show b.pos + k + 1 - b.start = (b.pos - b.start) + (k + 1) by omega, take_sub_add hd]
    have e2 : b.bytes.drop (b.pos + k + 1) = r.drop k := by
      rw [show b.pos + k + 1 = b.pos + (k + 1) by omega, ← List.drop_drop, h]; rfl
    simp only [e1, e2]
  | case4 b c r h hst ih =>
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    rw [ih hs (Nat.le_refl _), h, Stream.scan, hst]
    have e2 : b.bytes.drop (b.pos + 1) = r := by
      rw [← List.drop_drop, h]; rfl
    simp [Buf.cur, e2]
  | case5 b c r h hst =>
    rw [h, Stream.scan, hst]
    have hd : (b.bytes.drop b.start).drop (b.pos - b.start) = c :: r := by
      rw [List.drop_drop, Nat.add_sub_cancel' hp, h]
    have e1 : (b.bytes.drop b.start).take (b.pos + 1 - b.start) = b.cur ++ [c] := by
      rw [show b.pos + 1 - b.start = (b.pos - b.start) + (0 + 1) by omega, take_sub_add hd]; simp [Buf.cur]
    simp [Buf.view, e1]

theorem Buf.scanOld_ok (b : Buf) (hb : b.Ok) : (b.scanOld false).Ok := by
  fun_induction Buf.scanOld false b with
  | case1 b h => exact ⟨hb.1, hb.2⟩
  | case2 b c r h hst => exact ⟨hb.1, hb.2⟩
  | case3 b c r h k s hst ih =>
    have := step_adv_le hst
    have hl := congrArg List.length h; simp only [List.length_drop, List.length_cons] at hl
    exact ih ⟨by simp; have := hb.start_le; omega, by simp; omega⟩
  | case4 b c r h hst ih => exact ih ⟨Nat.le_refl _, Nat.zero_le _⟩
  | case5 b c r h hst => exact ⟨hb.1, hb.2⟩

theorem Buf.pushOld_view (b : Buf) (hb : b.Ok) (chunk : Text) :
    (b.pushOld chunk).view = b.view.push chunk ∧ (b.pushOld chunk).Ok := by
  unfold Buf.pushOld
  split
  · rename_i t h
    refine ⟨?_, hb.1, hb.2⟩
    simp [Buf.view, h, Reader.push]
  · rename_i h
    let b' : Buf := { b with bytes := b.bytes ++ chunk, steps := b.steps + chunk.length }
    have hb' : b'.Ok := ⟨hb.start_le, by simp [b']; have := hb.pos_le; omega⟩
    refine ⟨?_, Buf.scanOld_ok _ hb'⟩
    rw [Buf.scanOld_view false b' h hb.start_le]
    have hp := hb.pos_le
    have e1 : b'.cur = b.cur := by
      simp only [b', Buf.cur, List.drop_append_of_le_length (Nat.le_trans hb.start_le hp)]
      exact List.take_append_of_le_length (by simp; omega)
    have e2 : b'.bytes.drop b'.pos = b.bytes.drop b.pos ++ chunk := List.drop_append_of_le_length hp
    simp only [Buf.view, h, Reader.push, e1, e2]
    rfl

theorem Buf.finishOld_view (b : Buf) (hb : b.Ok) : b.finishOld.view = b.view.finish := by
  obtain ⟨h1, h2⟩ := Buf.pushOld_view b hb []
  unfold Buf.finishOld Reader.finish
  simp only
  rw [← h1]
  split
  · rename_i t h
    simp [Reader.close, Buf.view, h]
  · rename_i h
    rw [Buf.scanOld_view _ _ h h2.start_le]
    simp [Reader.close, Buf.view, h]

/-- The design before S17 finds the same pieces: it differs only in cost. -/
theorem splitOld_view (cs : List Text) : (splitOld cs).view = split cs := by
  have key : ∀ (cs : List Text) (b : Buf), b.Ok →
      (cs.foldl Buf.pushOld b).view = cs.foldl Reader.push b.view ∧ (cs.foldl Buf.pushOld b).Ok := by
    intro cs
    induction cs with
    | nil => exact fun b hb => ⟨rfl, hb⟩
    | cons c cs ih =>
      intro b hb
      obtain ⟨h1, h2⟩ := Buf.pushOld_view b hb c
      simp only [List.foldl_cons, ← h1]
      exact ih _ h2
  obtain ⟨h1, h2⟩ := key cs {} ⟨Nat.le_refl _, Nat.zero_le _⟩
  rw [splitOld, Buf.finishOld_view _ h2, h1]
  rfl

/-- `k` values `0,`. -/
def vals (k : Nat) : Text := (List.replicate k ['0', ',']).flatten

theorem vals_succ (k : Nat) : vals (k + 1) = '0' :: ',' :: vals k := by
  simp [vals, List.replicate_succ]

theorem vals_length (k : Nat) : (vals k).length = 2 * k := by
  induction k with
  | zero => rfl
  | succ k ih => rw [vals_succ]; simp [ih]; omega

/-- Each value's comma drops it and moves all the values after it. -/
theorem Buf.scanOld_vals (k : Nat) (b : Buf) (h1 : b.bytes = vals k) (h2 : b.pos = 0) (h3 : b.st = {}) :
    (b.scanOld false).steps = b.steps + k * (k + 1) + 1 := by
  induction k generalizing b with
  | zero =>
    unfold Buf.scanOld
    split
    · simp
    · rename_i h; simp [h1, h2, vals] at h
  | succ k ih =>
    have hd : b.bytes.drop b.pos = '0' :: ',' :: vals k := by rw [h1, h2, vals_succ]; rfl
    unfold Buf.scanOld
    split
    · rename_i h; rw [hd] at h; cases h
    · rename_i c r h
      rw [hd] at h; injection h with hc hr; subst hc hr
      have s1 : step false b.st ('0' :: ',' :: vals k) = .adv 0 {} := by rw [h3]; simp [step]
      simp only [s1]
      have hd2 : b.bytes.drop (b.pos + 0 + 1) = ',' :: vals k := by rw [h1, h2, vals_succ]; rfl
      unfold Buf.scanOld
      split
      · rename_i h; simp only at h; rw [hd2] at h; cases h
      · rename_i c r h
        simp only at h; rw [hd2] at h; injection h with hc hr; subst hc hr
        have s2 : step false {} (',' :: vals k) = .cut := by simp [step]
        simp only [s2]
        rw [ih _ (by simp [h1, h2, vals_succ]) rfl rfl]
        simp only [h1, h2, vals_length]
        simp only [Nat.add_mul, Nat.mul_add, Nat.mul_one, Nat.one_mul]
        omega

theorem Buf.steps_le_scanOld (f : Bool) (b : Buf) : b.steps ≤ (b.scanOld f).steps := by
  fun_induction Buf.scanOld f b <;> simp_all <;> omega

theorem Buf.steps_le_finishOld (b : Buf) : b.steps ≤ b.finishOld.steps := by
  have h0 : b.steps ≤ (b.pushOld []).steps := by
    unfold Buf.pushOld; split
    · simp
    · exact Buf.steps_le_scanOld false { b with bytes := b.bytes ++ [], steps := b.steps + ([] : Text).length }
  unfold Buf.finishOld
  simp only
  split
  · exact h0
  · exact Nat.le_trans h0 (Buf.steps_le_scanOld true _)

/--
**The design before S17 is quadratic**: `k` values `0,` in one chunk,
`2 · k` characters, take at least `k · (k + 1)` steps: each comma moves all
the characters after it.
-/
theorem splitOld_steps_vals (k : Nat) : k * (k + 1) ≤ (splitOld [vals k]).steps := by
  unfold splitOld
  simp only [List.foldl_cons, List.foldl_nil]
  refine Nat.le_trans ?_ (Buf.steps_le_finishOld _)
  unfold Buf.pushOld
  simp only
  rw [Buf.scanOld_vals k _ (by simp) rfl rfl]
  omega

/-- **No linear bound holds for it**, whatever the constant. -/
theorem splitOld_not_linear :
    ¬ ∃ c, ∀ cs : List Text, (splitOld cs).steps ≤ c * ((cs.map List.length).sum + cs.length + 1) := by
  rintro ⟨c, h⟩
  have h2 := h [vals (2 * c + 1)]
  have e : ([vals (2 * c + 1)].map List.length).sum + [vals (2 * c + 1)].length + 1 = 2 * (2 * c + 1 + 1) := by
    simp [vals_length]; omega
  rw [e, ← Nat.mul_assoc] at h2
  have h1 := Nat.le_trans (splitOld_steps_vals (2 * c + 1)) h2
  have := Nat.le_of_mul_le_mul_right h1 (by omega : 0 < 2 * c + 1 + 1)
  omega

end Haus.Stream
