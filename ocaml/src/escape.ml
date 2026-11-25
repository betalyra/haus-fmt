(* Writing strings, keys and byte strings (spec §11, §12). *)

(* Characters written as \u{…} in every string: control characters, bidi
   controls and the line and paragraph separators. *)
let needs_u cp = Utf8.is_control cp || Utf8.is_bidi cp || cp = 0x2028 || cp = 0x2029

let add_u b cp = Buffer.add_string b (Printf.sprintf "\\u{%X}" cp)

(* A "…" string written from its value, with the minimal escapes. *)
let add_string b (s : string) =
  Buffer.add_char b '"';
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    (match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | _ ->
        let cp = Utf8.decode s !i in
        if needs_u cp then add_u b cp
        else Buffer.add_string b (String.sub s !i (Utf8.length_of_lead (Char.code c))));
    i := !i + Utf8.length_of_lead (Char.code c)
  done;
  Buffer.add_char b '"'

let string s =
  let b = Buffer.create (String.length s + 2) in
  add_string b s;
  Buffer.contents b

(* A key: bare when it is an identifier, else a string. *)
let add_key b k = if Value.is_ident k then Buffer.add_string b k else add_string b k

let key k =
  let b = Buffer.create (String.length k + 2) in
  add_key b k;
  Buffer.contents b

(* A byte string written from its value: lowercase hex. *)
let add_bytes b (s : string) =
  Buffer.add_string b "x\"";
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.add_char b '"'

(* A "…" string's source spelling, with raw U+2028 and U+2029 written as
   escapes (spec §11). *)
let source_string (src : string) =
  let has_sep =
    let rec go i = i + 2 < String.length src && ((src.[i] = '\xE2' && src.[i + 1] = '\x80' && (src.[i + 2] = '\xA8' || src.[i + 2] = '\xA9')) || go (i + 1)) in
    go 0
  in
  if not has_sep then src
  else begin
    let b = Buffer.create (String.length src + 8) in
    let i = ref 0 in
    while !i < String.length src do
      if !i + 2 < String.length src && src.[!i] = '\xE2' && src.[!i + 1] = '\x80'
         && (src.[!i + 2] = '\xA8' || src.[!i + 2] = '\xA9')
      then begin
        add_u b (if src.[!i + 2] = '\xA8' then 0x2028 else 0x2029);
        i := !i + 3
      end
      else begin
        Buffer.add_char b src.[!i];
        incr i
      end
    done;
    Buffer.contents b
  end
