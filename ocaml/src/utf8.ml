(* UTF-8: validation, decoding and encoding. *)

type check =
  | Valid of int  (** a complete, valid sequence of this many bytes *)
  | Invalid  (** the bytes here are no valid UTF-8 *)
  | Incomplete  (** a valid prefix of a sequence, cut by the end *)

(* The sequence starting at [i] of [s], looking at bytes before [stop]. Rejects
   overlong forms, surrogates and code points above U+10FFFF. *)
let check s i stop =
  let b0 = Char.code (String.unsafe_get s i) in
  if b0 < 0x80 then Valid 1
  else
    let need, lo, hi =
      if b0 >= 0xC2 && b0 <= 0xDF then (2, 0x80, 0xBF)
      else if b0 = 0xE0 then (3, 0xA0, 0xBF)
      else if b0 >= 0xE1 && b0 <= 0xEC then (3, 0x80, 0xBF)
      else if b0 = 0xED then (3, 0x80, 0x9F)
      else if b0 >= 0xEE && b0 <= 0xEF then (3, 0x80, 0xBF)
      else if b0 = 0xF0 then (4, 0x90, 0xBF)
      else if b0 >= 0xF1 && b0 <= 0xF3 then (4, 0x80, 0xBF)
      else if b0 = 0xF4 then (4, 0x80, 0x8F)
      else (0, 0, 0)
    in
    if need = 0 then Invalid
    else
      let rec go k =
        if k = need then Valid need
        else if i + k >= stop then Incomplete
        else
          let b = Char.code (String.unsafe_get s (i + k)) in
          let lo, hi = if k = 1 then (lo, hi) else (0x80, 0xBF) in
          if b < lo || b > hi then Invalid else go (k + 1)
      in
      go 1

(* The length of the sequence whose first byte is [b] (valid input only). *)
let length_of_lead b = if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4

(* The code point at [i] (valid input only). *)
let decode s i =
  let b0 = Char.code (String.unsafe_get s i) in
  if b0 < 0x80 then b0
  else if b0 < 0xE0 then ((b0 land 0x1F) lsl 6) lor (Char.code s.[i + 1] land 0x3F)
  else if b0 < 0xF0 then
    ((b0 land 0x0F) lsl 12) lor ((Char.code s.[i + 1] land 0x3F) lsl 6) lor (Char.code s.[i + 2] land 0x3F)
  else
    ((b0 land 0x07) lsl 18)
    lor ((Char.code s.[i + 1] land 0x3F) lsl 12)
    lor ((Char.code s.[i + 2] land 0x3F) lsl 6)
    lor (Char.code s.[i + 3] land 0x3F)

let add b cp = Buffer.add_utf_8_uchar b (Uchar.of_int cp)

(* The first byte of [s] that isn't UTF-8, if any. *)
let first_invalid s =
  let n = String.length s in
  let rec go i =
    if i >= n then None
    else match check s i n with Valid k -> go (i + k) | Invalid | Incomplete -> Some i
  in
  go 0

let is_valid s = first_invalid s = None

(* Code points in [s] (valid input). *)
let length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* The line and column of byte offset [upto] in [s]: lines end at LF, columns
   count code points (spec §8). *)
let position s upto =
  let line = ref 1 and col = ref 1 in
  for i = 0 to upto - 1 do
    let c = Char.code (String.unsafe_get s i) in
    if c = 10 then (incr line; col := 1) else if c land 0xC0 <> 0x80 then incr col
  done;
  (!line, !col)

let is_control cp = cp < 0x20 || (cp >= 0x7F && cp <= 0x9F)
let is_bidi cp = (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2066 && cp <= 0x2069)
