(* The stream reader (spec §6, §7): reads input in chunks, one top-level
   value at a time, and gives what parsing the whole text gives.

   Bytes are checked for UTF-8 as they arrive. A scanner finds each top-level
   comma (outside strings, byte strings, comments and brackets) and counts the
   value's characters up to it (the value limit, before parsing); the text up
   to the comma is then parsed as one item with the parser. *)

type scan =
  | Normal
  | Line_comment
  | Block_comment of int
  | Str
  | Str_escape
  | Block_open
  | Block_body
  | Block_escape
  | Byte_string

type t = {
  lim : Limits.t;
  strict : bool;
  mutable buf : Bytes.t;
  mutable len : int;  (** bytes in [buf] *)
  mutable valid : int;  (** bytes of [buf] checked as UTF-8 *)
  mutable vline : int;  (** the position after the checked bytes *)
  mutable vcol : int;
  mutable seg : int;  (** where the current value's text starts *)
  mutable seg_line : int;
  mutable seg_col : int;
  mutable first : bool;  (** the current value is the first of the stream *)
  mutable started : bool;  (** the byte order mark is behind us *)
  mutable at : int;  (** the scanner's position *)
  mutable state : scan;
  mutable depth : int;
  mutable count : int;  (** characters of the current value so far *)
  mutable prev_ident : bool;
  mutable failed : Error.t option;
  mutable finished : bool;
}

let create ?(limits = Limits.default) ?(strict = false) () =
  {
    lim = limits;
    strict;
    buf = Bytes.create 4096;
    len = 0;
    valid = 0;
    vline = 1;
    vcol = 1;
    seg = 0;
    seg_line = 1;
    seg_col = 1;
    first = true;
    started = false;
    at = 0;
    state = Normal;
    depth = 0;
    count = 0;
    prev_ident = false;
    failed = None;
    finished = false;
  }

let append r (chunk : string) =
  let n = String.length chunk in
  if r.len + n > Bytes.length r.buf then begin
    (* drop what was read, then grow *)
    let keep = r.len - r.seg in
    let size = max (Bytes.length r.buf) (2 * (keep + n)) in
    let nb = Bytes.create size in
    Bytes.blit r.buf r.seg nb 0 keep;
    r.buf <- nb;
    r.len <- keep;
    r.valid <- r.valid - r.seg;
    r.at <- r.at - r.seg;
    r.seg <- 0
  end;
  Bytes.blit_string chunk 0 r.buf r.len n;
  r.len <- r.len + n

let byte r i = Char.code (Bytes.unsafe_get r.buf i)

(* Checks the new bytes for UTF-8; an incomplete sequence at the end waits for
   the next chunk (or the end). *)
let check_utf8 r ~final =
  let s = Bytes.unsafe_to_string r.buf in
  let rec go () =
    if r.valid < r.len then
      match Utf8.check s r.valid r.len with
      | Utf8.Valid k ->
          let b = byte r r.valid in
          if b = 10 then (r.vline <- r.vline + 1; r.vcol <- 1) else r.vcol <- r.vcol + 1;
          r.valid <- r.valid + k;
          go ()
      | Utf8.Incomplete when not final -> ()
      | Utf8.Invalid | Utf8.Incomplete ->
          Error.raise_at "invalid-utf8" r.vline r.vcol "the input is not valid UTF-8"
  in
  go ()

let value_too_long r =
  Error.raise_at "value-too-long" r.seg_line r.seg_col
    (Printf.sprintf "a value of the stream longer than %d characters" r.lim.max_value_length)

type found = Comma of int | Wait | Done

(* Scans the checked bytes for the next top-level comma. *)
let scan r ~final =
  let ident c = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c = 95 in
  let ahead k = if r.at + k < r.valid then byte r (r.at + k) else -1 in
  let enough k = r.at + k < r.valid || final in
  let count_char () =
    if byte r r.at land 0xC0 <> 0x80 then begin
      r.count <- r.count + 1;
      if r.count > r.lim.max_value_length then value_too_long r
    end
  in
  let step () = count_char (); r.at <- r.at + 1 in
  let rec go () =
    if r.at >= r.valid then if final then Done else Wait
    else
      let c = byte r r.at in
      match r.state with
      | Normal ->
          if c = 44 && r.depth = 0 then Comma r.at
          else if c = 34 then
            if not (enough 2) then Wait
            else if ahead 1 = 34 && ahead 2 = 34 then (step (); step (); step (); r.state <- Block_open; r.prev_ident <- false; go ())
            else (step (); r.state <- Str; r.prev_ident <- false; go ())
          else if c = 120 && not r.prev_ident then
            if not (enough 1) then Wait
            else if ahead 1 = 34 then (step (); step (); r.state <- Byte_string; r.prev_ident <- false; go ())
            else (step (); r.prev_ident <- true; go ())
          else if c = 47 then
            if not (enough 1) then Wait
            else if ahead 1 = 47 then (step (); step (); r.state <- Line_comment; r.prev_ident <- false; go ())
            else if ahead 1 = 42 then (step (); step (); r.state <- Block_comment 1; r.prev_ident <- false; go ())
            else (step (); go ())
          else begin
            if c = 91 || c = 123 || c = 40 then r.depth <- r.depth + 1
            else if c = 93 || c = 125 || c = 41 then r.depth <- max 0 (r.depth - 1);
            r.prev_ident <- ident c;
            step ();
            go ()
          end
      | Line_comment ->
          if c = 10 then r.state <- Normal;
          step ();
          go ()
      | Block_comment n ->
          if c = 47 || c = 42 then
            if not (enough 1) then Wait
            else if c = 47 && ahead 1 = 42 then (step (); step (); r.state <- Block_comment (n + 1); go ())
            else if c = 42 && ahead 1 = 47 then (step (); step (); r.state <- (if n = 1 then Normal else Block_comment (n - 1)); go ())
            else (step (); go ())
          else (step (); go ())
      | Str ->
          if c = 92 then r.state <- Str_escape else if c = 34 || c = 10 then r.state <- Normal;
          step ();
          go ()
      | Str_escape ->
          r.state <- Str;
          step ();
          go ()
      | Block_open ->
          if c = 10 then r.state <- Block_body;
          step ();
          go ()
      | Block_body ->
          if c = 92 then (r.state <- Block_escape; step (); go ())
          else if c = 34 then
            if not (enough 2) then Wait
            else if ahead 1 = 34 && ahead 2 = 34 then (step (); step (); step (); r.state <- Normal; go ())
            else (step (); go ())
          else (step (); go ())
      | Block_escape ->
          r.state <- Block_body;
          step ();
          go ()
      | Byte_string ->
          if c = 34 || c = 10 then r.state <- Normal;
          step ();
          go ()
  in
  go ()

(* Parses the text of one item, [seg, stop), with the parser. *)
let parse_item r stop =
  let s = Bytes.sub_string r.buf r.seg (stop - r.seg) in
  let st = Parser.make ~line:r.seg_line ~col:r.seg_col r.lim s in
  if r.first then Parser.start ~bom:false st;
  let v, comma = Parser.item st in
  (v, comma, st)

let next_item r st =
  r.seg <- r.seg + st.Parser.pos;
  r.seg_line <- st.line;
  r.seg_col <- st.col;
  r.first <- false;
  r.at <- r.seg;
  r.state <- Normal;
  r.depth <- 0;
  r.count <- 0;
  r.prev_ident <- false

(* The byte order mark at the start of the stream. *)
let skip_bom r ~final =
  if not r.started then
    if r.valid >= 3 || final then begin
      r.started <- true;
      if r.valid >= 3 && byte r 0 = 0xEF && byte r 1 = 0xBB && byte r 2 = 0xBF then begin
        r.seg <- 3;
        r.at <- 3;
        r.seg_col <- 2
      end
    end
    else if r.valid > 0 && byte r 0 <> 0xEF then r.started <- true

let run r ~final =
  let out = ref [] in
  check_utf8 r ~final;
  skip_bom r ~final;
  if r.started then begin
    let continue = ref true in
    while !continue do
      match scan r ~final with
      | Comma p ->
          let v, comma, st = parse_item r (p + 1) in
          if not comma then failwith "stream reader: the scanner and the parser disagree";
          Option.iter (fun v -> out := Cst.value v :: !out) v;
          next_item r st
      | Wait -> continue := false
      | Done ->
          (* the end: the rest is the last item(s) *)
          let rec last () =
            let v, comma, st = parse_item r r.len in
            match v with
            | Some v when comma ->
                out := Cst.value v :: !out;
                next_item r st;
                last ()
            | Some v ->
                if r.strict then
                  Error.raise_at "stream-truncated" st.line st.col
                    "the stream ends without a comma after its last value";
                out := Cst.value v :: !out
            | None -> ()
          in
          last ();
          continue := false
    done
  end;
  List.rev !out

let guard r f =
  match r.failed with
  | Some e -> raise (Error.Haus_error e)
  | None -> (
      try f () with Error.Haus_error e -> r.failed <- Some e; raise (Error.Haus_error e))

(* The values completed by a chunk. *)
let push r (chunk : string) =
  if r.finished then invalid_arg "Stream.push after finish";
  guard r (fun () ->
      append r chunk;
      run r ~final:false)

(* The values left at the end of the stream. *)
let finish r =
  if r.finished then []
  else begin
    r.finished <- true;
    guard r (fun () -> run r ~final:true)
  end

(* Reads a whole text in chunks of the given sizes, in turn. *)
let read_chunks ?limits ?strict (s : string) (sizes : int list) =
  let r = create ?limits ?strict () in
  let sizes = Array.of_list sizes in
  let out = ref [] in
  let at = ref 0 and k = ref 0 in
  while !at < String.length s do
    let n = min (String.length s - !at) sizes.(!k mod Array.length sizes) in
    out := List.rev_append (push r (String.sub s !at n)) !out;
    at := !at + n;
    incr k
  done;
  List.rev_append !out (finish r)
