(* The parser of haus text (grammar.ebnf, spec §1–§8). *)

open Cst

type st = {
  s : string;
  mutable pos : int;
  stop : int;
  mutable line : int;
  mutable col : int;
  lim : Limits.t;
  hex_limit : int;
  keep : bool;  (** keep comments and line breaks (for the formatter) *)
}

let make ?(keep = false) ?(line = 1) ?(col = 1) ?(pos = 0) ?stop lim s =
  let stop = match stop with Some e -> e | None -> String.length s in
  { s; pos; stop; line; col; lim; hex_limit = Limits.hex_digits lim; keep }

let fail_at code line col msg = Error.raise_at code line col msg
let fail st code msg = fail_at code st.line st.col msg
let eof st = st.pos >= st.stop
let peek st = String.unsafe_get st.s st.pos
let byte_at st i = if i < st.stop then Char.code (String.unsafe_get st.s i) else -1

(* Advance over one ASCII character that isn't a line feed. *)
let adv1 st =
  st.pos <- st.pos + 1;
  st.col <- st.col + 1

(* Advance over one character. *)
let adv st =
  let c = Char.code (String.unsafe_get st.s st.pos) in
  if c = 10 then begin
    st.pos <- st.pos + 1;
    st.line <- st.line + 1;
    st.col <- 1
  end
  else begin
    st.pos <- st.pos + Utf8.length_of_lead c;
    st.col <- st.col + 1
  end

let cp st = Utf8.decode st.s st.pos

(* What a character is called in a message. *)
let describe st =
  if eof st then "the end of the input"
  else
    let c = cp st in
    if Utf8.is_control c || Utf8.is_bidi c || c = 0x2028 || c = 0x2029 || c = 0xFEFF then
      Printf.sprintf "U+%04X" c
    else "'" ^ Error.quote (String.sub st.s st.pos (Utf8.length_of_lead (Char.code (peek st)))) ^ "'"

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'

(* ── whitespace and comments ── *)

let comment_text st p =
  let raw = String.sub st.s p (st.pos - p) in
  if String.contains raw '\r' then begin
    let b = Buffer.create (String.length raw) in
    String.iteri
      (fun i c -> if not (c = '\r' && i + 1 < String.length raw && raw.[i + 1] = '\n') then Buffer.add_char b c)
      raw;
    Buffer.contents b
  end
  else raw

(* A character inside a comment other than a line break: control and bidi
   characters are refused. *)
let comment_char st =
  let c = cp st in
  if c = 9 then adv1 st
  else if Utf8.is_control c then fail st "control-character" (Printf.sprintf "raw control character U+%04X in a comment" c)
  else if Utf8.is_bidi c then fail st "bidi-control" (Printf.sprintf "raw bidirectional control U+%04X in a comment" c)
  else adv st

let line_comment st =
  let p = st.pos in
  adv1 st;
  adv1 st;
  let rec go () =
    if not (eof st) then
      match peek st with
      | '\n' -> ()
      | '\r' ->
          if byte_at st (st.pos + 1) = 10 then ()
          else fail st "lone-carriage-return" "a carriage return not followed by a line feed"
      | _ ->
          comment_char st;
          go ()
  in
  go ();
  comment_text st p

let block_comment st =
  let p = st.pos and l = st.line and c = st.col in
  adv1 st;
  adv1 st;
  let rec go depth =
    if eof st then fail_at "unterminated-comment" l c "a block comment that is never closed"
    else
      match peek st with
      | '/' when byte_at st (st.pos + 1) = 42 ->
          adv1 st;
          adv1 st;
          go (depth + 1)
      | '*' when byte_at st (st.pos + 1) = 47 ->
          adv1 st;
          adv1 st;
          if depth > 1 then go (depth - 1)
      | '\n' ->
          adv st;
          go depth
      | '\r' ->
          if byte_at st (st.pos + 1) = 10 then (adv1 st; go depth)
          else fail st "lone-carriage-return" "a carriage return not followed by a line feed"
      | _ ->
          comment_char st;
          go depth
  in
  go 1;
  comment_text st p

(* Whitespace and comments; with [keep], the line breaks and comments read. *)
let ws st =
  let acc = ref [] in
  let rec go () =
    if not (eof st) then
      match peek st with
      | ' ' | '\t' ->
          adv1 st;
          go ()
      | '\n' ->
          adv st;
          if st.keep then acc := Nl :: !acc;
          go ()
      | '\r' ->
          if byte_at st (st.pos + 1) = 10 then begin
            adv1 st;
            adv st;
            if st.keep then acc := Nl :: !acc;
            go ()
          end
          else fail st "lone-carriage-return" "a carriage return not followed by a line feed"
      | '/' -> (
          match byte_at st (st.pos + 1) with
          | 47 ->
              let t = line_comment st in
              if st.keep then acc := Comment t :: !acc;
              go ()
          | 42 ->
              let t = block_comment st in
              if st.keep then acc := Comment t :: !acc;
              go ()
          | _ -> fail st "stray-slash" "a '/' that starts no comment")
      | _ -> ()
  in
  go ();
  List.rev !acc

(* ── strings ── *)

let hex_value c =
  match c with
  | '0' .. '9' -> Char.code c - 48
  | 'a' .. 'f' -> Char.code c - 87
  | 'A' .. 'F' -> Char.code c - 55
  | _ -> -1

(* An escape at the backslash (spec §4), added to [b]; [line_end] is where
   the current line ends (an escape never crosses it). *)
let escape st b line_end =
  let l = st.line and c = st.col in
  adv1 st;
  if st.pos >= line_end then fail_at "invalid-escape" l c "a backslash at the end of the line or input"
  else
    match peek st with
    | '"' -> adv1 st; Buffer.add_char b '"'
    | '\\' -> adv1 st; Buffer.add_char b '\\'
    | 'n' -> adv1 st; Buffer.add_char b '\n'
    | 'r' -> adv1 st; Buffer.add_char b '\r'
    | 't' -> adv1 st; Buffer.add_char b '\t'
    | 'u' ->
        let bad () = fail_at "invalid-unicode-escape" l c "a \\u escape is \\u{ and 1 to 6 hex digits }, a Unicode scalar value" in
        adv1 st;
        if st.pos >= line_end || peek st <> '{' then bad ();
        adv1 st;
        let v = ref 0 and n = ref 0 in
        while st.pos < line_end && hex_value (peek st) >= 0 && !n < 7 do
          v := (!v * 16) + hex_value (peek st);
          incr n;
          adv1 st
        done;
        if !n = 0 || !n > 6 || st.pos >= line_end || peek st <> '}' then bad ();
        if !v > 0x10FFFF || (!v >= 0xD800 && !v <= 0xDFFF) then bad ();
        adv1 st;
        Utf8.add b !v
    | _ -> fail_at "invalid-escape" l c "an unknown escape"

let check_length st what code l c count =
  if count > st.lim.Limits.max_string_length then
    fail_at code l c (Printf.sprintf "%s longer than %d characters" what st.lim.max_string_length)

(* A "…" string at its opening quote: its value and its spelling. *)
let basic_string ?(key = false) st =
  let l = st.line and c = st.col and p = st.pos in
  adv1 st;
  let b = Buffer.create 16 in
  let count = ref 0 in
  let what, code = if key then ("a key", "key-too-long") else ("a string", "string-too-long") in
  let rec go () =
    if eof st then fail_at "unterminated-string" l c "a string with no closing quote"
    else
      match peek st with
      | '"' -> adv1 st
      | '\\' ->
          escape st b st.stop;
          incr count;
          check_length st what code l c !count;
          go ()
      | '\n' -> fail st "string-line-break" "a raw line break in a string: write \\n, or use a block string"
      | _ ->
          let x = cp st in
          if Utf8.is_control x then
            fail st "control-character" (Printf.sprintf "raw control character U+%04X in a string" x)
          else if Utf8.is_bidi x then
            fail st "bidi-control" (Printf.sprintf "raw bidirectional control U+%04X in a string" x);
          let n = Utf8.length_of_lead (Char.code (peek st)) in
          Buffer.add_string b (String.sub st.s st.pos n);
          adv st;
          incr count;
          check_length st what code l c !count;
          go ()
  in
  go ();
  (Buffer.contents b, String.sub st.s p (st.pos - p))

let is_triple st = byte_at st (st.pos + 1) = 34 && byte_at st (st.pos + 2) = 34

(* A block string at its opening quotes (spec §4). *)
let block_string st =
  let l = st.line and c = st.col in
  adv1 st; adv1 st; adv1 st;
  while (not (eof st)) && (peek st = ' ' || peek st = '\t') do adv1 st done;
  if eof st then fail st "block-string-opening" "a block string's content starts on the line after its opening quotes";
  (match peek st with
  | '\n' -> adv st
  | '\r' when byte_at st (st.pos + 1) = 10 -> adv1 st; adv st
  | _ -> fail st "block-string-opening" "text after a block string's opening quotes");
  let content = st.pos and content_line = st.line in
  (* 1. the closing quotes: the first three unescaped quotes *)
  let rec find i =
    if i >= st.stop then None
    else
      match String.unsafe_get st.s i with
      | '\\' -> find (i + 2)
      | '"' when byte_at st (i + 1) = 34 && byte_at st (i + 2) = 34 -> Some i
      | _ -> find (i + 1)
  in
  let close = match find content with Some i -> i | None -> fail_at "unterminated-block-string" l c "a block string with no closing quotes" in
  let line_start = match String.rindex_from_opt st.s (close - 1) '\n' with Some j when j >= content - 1 -> j + 1 | _ -> content in
  let indent = String.sub st.s line_start (close - line_start) in
  if not (String.for_all (fun ch -> ch = ' ' || ch = '\t') indent) then begin
    let ln, col = Utf8.position (String.sub st.s content (close - content)) (close - content) in
    fail_at "block-string-closing" (content_line + ln - 1) (if ln = 1 then col else col) "text before a block string's closing quotes on their line"
  end;
  (* 2. the content lines, [content, line_start) *)
  let b = Buffer.create 64 in
  let count = ref 0 in
  let first = ref true in
  let ilen = String.length indent in
  while st.pos < line_start do
    let eol = String.index_from st.s st.pos '\n' in
    let line_end = if eol > st.pos && st.s.[eol - 1] = '\r' then eol - 1 else eol in
    if not !first then (Buffer.add_char b '\n'; incr count);
    first := false;
    let starts = line_end - st.pos >= ilen && String.sub st.s st.pos ilen = indent in
    if starts then for _ = 1 to ilen do adv1 st done
    else begin
      let rec blank i = i >= line_end || ((st.s.[i] = ' ' || st.s.[i] = '\t') && blank (i + 1)) in
      if blank st.pos then (while st.pos < line_end do adv1 st done)
      else fail st "block-string-indent" "a block string line indented less than its closing quotes"
    end;
    while st.pos < line_end do
      (match peek st with
      | '\\' -> escape st b line_end
      | '\t' -> Buffer.add_char b '\t'; adv1 st
      | _ ->
          let x = cp st in
          if Utf8.is_control x then
            fail st "control-character" (Printf.sprintf "raw control character U+%04X in a block string" x)
          else if Utf8.is_bidi x then
            fail st "bidi-control" (Printf.sprintf "raw bidirectional control U+%04X in a block string" x);
          let n = Utf8.length_of_lead (Char.code (peek st)) in
          Buffer.add_string b (String.sub st.s st.pos n);
          adv st);
      incr count;
      check_length st "a string" "string-too-long" l c !count
    done;
    (* the line break *)
    if line_end < eol then adv1 st;
    adv st
  done;
  check_length st "a string" "string-too-long" l c !count;
  (* the closing line *)
  while st.pos < close do adv1 st done;
  adv1 st; adv1 st; adv1 st;
  Buffer.contents b

(* ── byte strings ── *)

let bytes st =
  let l = st.line and c = st.col and p = st.pos in
  adv1 st;
  adv1 st;
  let b = Buffer.create 16 in
  let count = ref 0 in
  let rec go () =
    while (not (eof st)) && (peek st = ' ' || peek st = '\t') do adv1 st; incr count done;
    if eof st then fail_at "unterminated-bytes" l c "a byte string with no closing quote"
    else
      match peek st with
      | '"' -> adv1 st
      | ch when hex_value ch >= 0 ->
          let dl = st.line and dc = st.col in
          adv1 st;
          if eof st then fail_at "unterminated-bytes" l c "a byte string with no closing quote"
          else if hex_value (peek st) < 0 then fail_at "bytes-odd-digits" dl dc "a byte with one hex digit: write two per byte"
          else begin
            Buffer.add_char b (Char.chr ((hex_value ch * 16) + hex_value (peek st)));
            adv1 st;
            count := !count + 2;
            check_length st "a byte string" "string-too-long" l c !count;
            go ()
          end
      | _ -> fail st "bytes-not-hex" ("a byte string holds " ^ describe st ^ ": only hex digits, spaces and tabs")
  in
  go ();
  check_length st "a byte string" "string-too-long" l c !count;
  (Buffer.contents b, String.sub st.s p (st.pos - p))

(* ── numbers, words ── *)

let number st =
  let l = st.line and c = st.col and p = st.pos in
  match Number.scan st.s st.pos st.stop with
  | None -> fail st "invalid-number" "not a number literal"
  | Some lit ->
      let len = lit.stop - p in
      if len > st.lim.max_number_length then
        fail_at "number-too-long" l c (Printf.sprintf "a number literal longer than %d characters" st.lim.max_number_length);
      if lit.hex_digits > st.hex_limit then
        fail_at "number-too-long" l c (Printf.sprintf "a hex literal with more than %d hex digits" st.hex_limit);
      if Number.exponent_exceeds lit.exponent st.lim.max_exponent then
        fail_at "exponent-too-large" l c (Printf.sprintf "an exponent larger than %d" st.lim.max_exponent);
      st.pos <- lit.stop;
      st.col <- st.col + len;
      Scalar (Value.Unsafe.number lit.normalized, Source (String.sub st.s p len))

let word st =
  let p = st.pos in
  while (not (eof st)) && is_ident_char (peek st) do adv1 st done;
  String.sub st.s p (st.pos - p)

(* ── values ── *)

let is_bare_tag = function Tag _ -> true | _ -> false

let open_level st depth =
  if depth + 1 > st.lim.Limits.max_depth then
    fail st "nesting-too-deep" (Printf.sprintf "nested deeper than %d levels" st.lim.max_depth)

(* After a value where a comma or a closer belongs. *)
let after_value st prev =
  match peek st with
  | ')' | ']' | '}' -> fail st "unexpected-closer" ("a closing bracket that doesn't fit: " ^ describe st)
  | ('(' | '{') when is_bare_tag prev ->
      fail st "payload-newline" "a payload must start on its tag's line (or a comma is missing)"
  | _ -> fail st "missing-comma" ("expected ',' between values, found " ^ describe st)

let rec value st depth : node =
  match peek st with
  | '{' -> Rec (record st depth)
  | '[' -> array st depth
  | '"' ->
      if is_triple st then
        let v = block_string st in
        Scalar (Value.Unsafe.string v, Block)
      else
        let v, src = basic_string st in
        Scalar (Value.Unsafe.string v, Source src)
  | 'x' when byte_at st (st.pos + 1) = 34 ->
      let v, src = bytes st in
      Scalar (Value.Unsafe.bytes v, Source src)
  | '-' | '0' .. '9' -> number st
  | '+' | '.' -> fail st "invalid-number" "a number starts with a digit or '-'"
  | 'A' .. 'Z' -> variant st depth
  | 'a' .. 'z' | '_' -> (
      let l = st.line and c = st.col in
      match word st with
      | "null" -> fail_at "null-literal" l c "haus has no null: write None (with a Maybe type), or leave the field out"
      | "true" | "false" -> fail_at "boolean-literal" l c "booleans are the tags True and False"
      | w -> fail_at "bare-identifier" l c ("a lowercase word where a value should be: " ^ Error.quote w))
  | _ -> fail st "expected-value" ("expected a value, found " ^ describe st)


(* Entries up to [closer], after the opening bracket and its trivia. *)
and entries st depth closer ol oc =
  let rec go acc =
    if eof st then fail_at "unclosed-bracket" ol oc "a bracket that is never closed"
    else if peek st = closer then (adv1 st; List.rev acc)
    else begin
      let v = value st depth in
      let t1 = ws st in
      if eof st then fail_at "unclosed-bracket" ol oc "a bracket that is never closed"
      else if peek st = closer then (adv1 st; List.rev ((v, t1) :: acc))
      else if peek st = ',' then begin
        adv1 st;
        let t2 = ws st in
        go ((v, if st.keep then t1 @ (Comma :: t2) else []) :: acc)
      end
      else after_value st v
    end
  in
  go []

and array st depth =
  let l = st.line and c = st.col in
  open_level st depth;
  adv1 st;
  let lead = ws st in
  let items = entries st (depth + 1) ']' l c in
  Arr { lead; items }

and key st seen =
  let l = st.line and c = st.col in
  let k =
    match peek st with
    | '"' ->
        if is_triple st then fail st "block-string-key" "a block string can't be a record key";
        fst (basic_string ~key:true st)
    | 'a' .. 'z' | '_' ->
        let w = word st in
        check_length st "a key" "key-too-long" l c (String.length w);
        w
    | 'A' .. 'Z' -> fail st "uppercase-key" "a key starts with a lowercase letter or '_': quote it, or it's a tag"
    | _ -> fail st "expected-key" ("expected a key, found " ^ describe st)
  in
  if Hashtbl.mem seen k then fail_at "duplicate-key" l c ("the key " ^ Error.quote k ^ " twice");
  Hashtbl.replace seen k ();
  k

and record st depth =
  let l = st.line and c = st.col in
  open_level st depth;
  adv1 st;
  let flead = ws st in
  let seen = Hashtbl.create ~random:true 8 in
  let rec go acc =
    if eof st then fail_at "unclosed-bracket" l c "a bracket that is never closed"
    else if peek st = '}' then (adv1 st; List.rev acc)
    else begin
      let k = key st seen in
      let before_colon = ws st in
      if eof st || peek st <> ':' then fail st "missing-colon" ("expected ':' after a key, found " ^ describe st);
      adv1 st;
      let after_colon = ws st in
      if eof st then fail st "expected-value" "expected a value, found the end of the input";
      let v = value st (depth + 1) in
      let f = { key = k; before_colon; after_colon; value = v } in
      let t1 = ws st in
      if eof st then fail_at "unclosed-bracket" l c "a bracket that is never closed"
      else if peek st = '}' then (adv1 st; List.rev ((f, t1) :: acc))
      else if peek st = ',' then begin
        adv1 st;
        let t2 = ws st in
        go ((f, if st.keep then t1 @ (Comma :: t2) else []) :: acc)
      end
      else after_value st v
    end
  in
  let fields = go [] in
  { flead; fields }

and variant st depth =
  let l = st.line and c = st.col in
  let t = word st in
  check_length st "a tag" "tag-too-long" l c (String.length t);
  let save_pos = st.pos and save_col = st.col in
  while (not (eof st)) && (peek st = ' ' || peek st = '\t') do adv1 st done;
  if (not (eof st)) && peek st = '(' then begin
    let pl = st.line and pc = st.col in
    open_level st depth;
    adv1 st;
    let lead = ws st in
    if (not (eof st)) && peek st = ')' then fail_at "empty-payload" pl pc "empty parentheses after a tag: write the tag alone";
    let items = entries st (depth + 1) ')' pl pc in
    Args (t, { lead; items })
  end
  else if (not (eof st)) && peek st = '{' then Payload (t, record st depth)
  else begin
    st.pos <- save_pos;
    st.col <- save_col;
    Tag t
  end

(* ── files ── *)

(* The start of a file: a byte order mark, and the version directive (spec §10). *)
let start ?(bom = true) st =
  if bom && byte_at st st.pos = 0xEF && byte_at st (st.pos + 1) = 0xBB && byte_at st (st.pos + 2) = 0xBF then begin
    st.pos <- st.pos + 3;
    st.col <- st.col + 1
  end;
  if (not (eof st)) && peek st = '#' && st.pos + 5 <= st.stop && String.sub st.s (st.pos + 1) 4 = "haus" then
    fail st "version-directive" "this file starts with #haus: it needs a newer version of haus"

(* One top-level item of a stream: [ws] [value ws] then a comma or the end.
   Returns the value, if any, and whether a comma ended it. *)
let item st =
  let _ = ws st in
  if eof st then (None, false)
  else begin
    let v = value st 0 in
    let _ = ws st in
    if eof st then (Some v, false)
    else if peek st = ',' then (adv1 st; (Some v, true))
    else after_value st v
  end

let check_utf8 s =
  match Utf8.first_invalid s with
  | None -> ()
  | Some i ->
      let l, c = Utf8.position s i in
      fail_at "invalid-utf8" l c "the input is not valid UTF-8"

(* The whole text as a file: its syntax tree. *)
let document ?(limits = Limits.default) ?(keep = true) (s : string) : items =
  check_utf8 s;
  let st = make ~keep limits s in
  start st;
  let lead = ws st in
  let rec go acc =
    if eof st then List.rev acc
    else begin
      let v = value st 0 in
      let t1 = ws st in
      if eof st then List.rev ((v, t1) :: acc)
      else if peek st = ',' then begin
        adv1 st;
        let t2 = ws st in
        go ((v, if keep then t1 @ (Comma :: t2) else []) :: acc)
      end
      else after_value st v
    end
  in
  let items = go [] in
  { lead; items }

(* Every value of the text (as `parseAll`). *)
let parse_all ?limits s = List.map (fun (n, _) -> Cst.value n) (document ?limits ~keep:false s).items

(* The one value of a single document (as `parse`, spec §6). *)
let parse ?limits s =
  match parse_all ?limits s with
  | [ v ] -> v
  | _ ->
      let l, c = Utf8.position s (String.length s) in
      fail_at "not-one-value" l c "expected exactly one value"
