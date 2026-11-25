(* Errors (spec §8, §17): a code of the catalogue, a message, and a place. *)

type place =
  | At of int * int  (** 1-based line and column (columns in code points) *)
  | Path of string  (** a place in a value: [$], [$[3]] *)
  | Nowhere

type t = { code : string; message : string; place : place }

exception Haus_error of t

let raise_at code line column message =
  raise (Haus_error { code; message; place = At (line, column) })

let raise_path code path message = raise (Haus_error { code; message; place = Path path })

let to_string e =
  match e.place with
  | At (l, c) -> Printf.sprintf "%s at %d:%d: %s" e.code l c e.message
  | Path p -> Printf.sprintf "%s at %s: %s" e.code p e.message
  | Nowhere -> Printf.sprintf "%s: %s" e.code e.message

(* Text quoted in a message: control, bidi and line separator characters
   escaped, at most 40 characters as shown, a cut marked with … (spec §9). *)
let quote (s : string) =
  let b = Buffer.create 16 in
  let shown = ref 0 and cut = ref false in
  let i = ref 0 in
  let n = String.length s in
  while (not !cut) && !i < n do
    let c = Char.code s.[!i] in
    let len =
      if c < 0x80 then 1 else if c < 0xE0 then 2 else if c < 0xF0 then 3 else 4
    in
    let len = min len (n - !i) in
    let cp =
      if len = 1 then c
      else
        let cp = ref (c land (0xFF lsr (len + 1))) in
        for k = 1 to len - 1 do
          cp := (!cp lsl 6) lor (Char.code s.[!i + k] land 0x3F)
        done;
        !cp
    in
    let piece =
      if cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) || (cp >= 0x202A && cp <= 0x202E)
         || (cp >= 0x2066 && cp <= 0x2069) || cp = 0x2028 || cp = 0x2029
      then Printf.sprintf "\\u{%X}" cp
      else String.sub s !i len
    in
    let width = if String.length piece > len then String.length piece else 1 in
    if !shown + width > 39 && !i + len < n then cut := true
    else begin
      Buffer.add_string b piece;
      shown := !shown + width;
      i := !i + len
    end
  done;
  if !cut then Buffer.add_string b "…";
  Buffer.contents b
