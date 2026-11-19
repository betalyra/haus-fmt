import Haus.Stream.Correct
import Haus.Stream.Cost
import Haus.Linear.Bound

/-!
# The stream reader in linear time (plan phase P: P2 and P3 together)

A stream reader scans its chunks with one buffer (`splitB`, P2) and parses
each piece it finds (`parsePiece`: `parse`, P3). `readCost` adds both:
the steps of `splitB`, and for each piece and the text left at the end the
steps of `parseC` (which returns what `parse` returns, `parseC_eq`), and one
for the check for a byte order mark.

`readCost_le`: reading `n` characters in `p` chunks takes at most
`259 · n + 3 · p + 75` steps. The pieces and the commas between them are
parts of the input that don't overlap (`scan_length`), so their parsing
adds up to at most `256 · n` and a constant per piece, and a piece has a
comma.
-/

namespace Haus.Stream
open Haus Linear

/-- The characters held by where a scan stopped. -/
def Res.length : Res → Nat
  | .ok _ cur buf => cur.length + buf.length
  | .unbalanced t => t.length

/-- **The pieces don't overlap**: each with its comma, and what is left, are at most what was scanned. -/
theorem scan_length (f : Bool) (s : St) (cur t : Text) :
    ((scan f s cur t).1.map (·.length + 1)).sum + (scan f s cur t).2.length ≤ cur.length + t.length := by
  fun_induction scan f s cur t with
  | case1 => simp [Res.length]
  | case2 => simp [Res.length]
  | case3 s cur c r k s' h ih =>
    have := takeWhile_take_drop_length r k
    simp only [List.length_append, List.length_cons] at ih ⊢
    omega
  | case4 s cur c r h ih =>
    simp only [List.map_cons, List.sum_cons, List.length_nil, List.length_cons] at ih ⊢
    omega
  | case5 => simp [Res.length]
where
  takeWhile_take_drop_length (r : Text) (k : Nat) : (r.take k).length + (r.drop k).length = r.length := by
    simp only [List.length_take, List.length_drop]; omega

/-- The text a reader holds at the end: parsed as the last value. -/
def Res.text : Res → Text
  | .ok _ cur buf => cur ++ buf
  | .unbalanced t => t

theorem Res.text_length (r : Res) : r.text.length = r.length := by
  cases r <;> simp [Res.text, Res.length]

/-- The steps of a stream reader: scanning with one buffer, then parsing each piece and the rest. -/
def readCost (L : Limits) (chunks : List Text) : Nat :=
  (splitB chunks).steps + ((split chunks).pieces.map fun p => (parseC L p).2 + 1).sum +
    (parseC L (split chunks).res.text).2 + 1

theorem sum_parse_le (L : Limits) (ps : List Text) :
    (ps.map fun p => (parseC L p).2 + 1).sum ≤ 256 * (ps.map (·.length + 1)).sum := by
  induction ps with
  | nil => simp
  | cons p ps ih =>
    have := parseC_cost L p
    simp only [List.map_cons, List.sum_cons] at ih ⊢
    omega

/--
**Reading a stream takes linear time**: `n` characters in `p` chunks, split
anywhere, at most `259 · n + 3 · p + 75` steps, scanning and parsing
included.
-/
theorem readCost_le (L : Limits) (chunks : List Text) :
    readCost L chunks ≤ 259 * (chunks.map List.length).sum + 3 * chunks.length + 75 := by
  have h1 := splitB_steps chunks
  have h2 := scan_length true St₀ [] chunks.flatten
  have h3 := sum_parse_le L (split chunks).pieces
  have h4 := parseC_cost L (split chunks).res.text
  have e : split chunks = ⟨(scan true St₀ [] chunks.flatten).1, (scan true St₀ [] chunks.flatten).2⟩ := by
    rw [split_chunks, split_single]
  rw [Res.text_length] at h4
  rw [e] at h3 h4
  unfold readCost
  rw [e]
  simp only [List.length_nil, List.length_flatten] at h2 h3 h4 ⊢
  omega

end Haus.Stream
