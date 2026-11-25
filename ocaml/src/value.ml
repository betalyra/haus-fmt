(* haus values (spec §1). *)

type t =
  | Number of string
  | String of string
  | Bytes of string
  | Array of t list
  | Record of (string * t) list
  | Variant of string * t list

let fail code message = raise (Error.Haus_error { code; message; place = Error.Nowhere })

let is_tag s =
  String.length s > 0
  && (match s.[0] with 'A' .. 'Z' -> true | _ -> false)
  && String.for_all (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) s

let is_ident s =
  String.length s > 0
  && (match s.[0] with 'a' .. 'z' | '_' -> true | _ -> false)
  && String.for_all (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) s

let check_text what s =
  if not (Utf8.is_valid s) then fail "cannot-encode" (what ^ " that isn't valid UTF-8")

let number text =
  match Number.normalize text with
  | Some n -> Number n
  | None -> fail "invalid-number" ("not a number literal: " ^ Error.quote text)

let string s = check_text "a string" s; String s
let bytes b = Bytes b
let array xs = Array xs

let record fields =
  List.iter (fun (k, _) -> check_text "a key" k) fields;
  let seen = Hashtbl.create ~random:true (List.length fields) in
  List.iter
    (fun (k, _) ->
      if Hashtbl.mem seen k then fail "duplicate-key" ("the key " ^ Error.quote k ^ " twice");
      Hashtbl.add seen k ())
    fields;
  Record fields

(* The tag rule comes first: a tag that isn't UTF-8 (a lone surrogate's
   bytes) fails it, so it is `invalid-tag`, never `cannot-encode` (fuzz F1). *)
let variant tag args =
  if not (is_tag tag) then
    fail "invalid-tag" ("not a tag: " ^ if Utf8.is_valid tag then Error.quote tag else "(not UTF-8)");
  Variant (tag, args)

module Unsafe = struct
  let number n = Number n
  let string s = String s
  let bytes b = Bytes b
  let array xs = Array xs
  let record fs = Record fs
  let variant t a = Variant (t, a)
end
