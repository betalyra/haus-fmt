(* The three layouts of spec §11: pretty (keeps comments), compact and
   minimised; for documents (keeping spellings) and for values built in code. *)

open Cst

type style = Pretty | Compact | Minimised
type options = { indent : int; width : int }

let default_options = { indent = 2; width = 80 }

let options ?indent ?width () =
  let indent = Option.value indent ~default:2 and width = Option.value width ~default:80 in
  if indent < 0 then invalid_arg "Layout.options: a negative indent";
  if width < 0 then invalid_arg "Layout.options: a negative width";
  { indent; width }

(* ── Tag({ … }) is written Tag { … }, the comments in its parentheses moved
   into the braces (spec §11) ── *)

let normalize_payload = function
  | Args (t, { lead; items = [ (Rec f, g) ] }) ->
      let fields =
        match List.rev f.fields with
        | [] -> f.fields
        | (last, gl) :: rest -> List.rev ((last, gl @ g) :: rest)
      in
      let flead = if f.fields = [] then lead @ f.flead @ g else lead @ f.flead in
      Payload (t, { flead; fields })
  | n -> n

let is_multiline_string = function
  | Scalar (Value.String s, _) -> String.contains s '\n'
  | _ -> false

(* ── scalars ── *)

let add_scalar ~style b v sp =
  match (v, sp) with
  | (Value.Number _ | Value.Bytes _), Source s -> Buffer.add_string b s
  | Value.String _, Source s -> Buffer.add_string b (Escape.source_string s)
  | Value.String s, (Block | Generated) -> Escape.add_string b s
  | Value.Number n, _ -> Buffer.add_string b n
  | Value.Bytes s, _ -> Escape.add_bytes b s
  | _ -> ignore style; assert false

(* A block string from its value (spec §4, §11), its content at [ind]. *)
let add_block b ind (s : string) =
  Buffer.add_string b "\"\"\"\n";
  let pad = String.make ind ' ' in
  List.iter
    (fun line ->
      if line <> "" then begin
        Buffer.add_string b pad;
        let n = String.length line in
        let i = ref 0 in
        while !i < n do
          let c = line.[!i] in
          let len = Utf8.length_of_lead (Char.code c) in
          let last = !i + len = n in
          (match c with
          | '"' when !i + 2 < n && line.[!i + 1] = '"' && line.[!i + 2] = '"' -> Buffer.add_string b "\\\""
          | '\\' -> Buffer.add_string b "\\\\"
          | '\r' -> Buffer.add_string b "\\r"
          | '\t' -> if last then Buffer.add_string b "\\t" else Buffer.add_char b '\t'
          | ' ' -> if last then Buffer.add_string b "\\u{20}" else Buffer.add_char b ' '
          | _ ->
              let cp = Utf8.decode line !i in
              if Escape.needs_u cp then Escape.add_u b cp else Buffer.add_string b (String.sub line !i len));
          i := !i + len
        done
      end;
      Buffer.add_char b '\n')
    (String.split_on_char '\n' s);
  Buffer.add_string b pad;
  Buffer.add_string b "\"\"\""

(* ── single-line layouts ── *)

let rec add_inline ~min b n =
  let sp s = if not min then Buffer.add_string b s in
  let list f xs =
    List.iteri (fun i x -> if i > 0 then (Buffer.add_char b ','; sp " "); f x) xs
  in
  match normalize_payload n with
  | Scalar (v, s) -> add_scalar ~style:Compact b v s
  | Arr { items; _ } ->
      Buffer.add_char b '[';
      list (fun (x, _) -> add_inline ~min b x) items;
      Buffer.add_char b ']'
  | Rec f -> add_record ~min b f
  | Tag t -> Buffer.add_string b t
  | Payload (t, f) ->
      Buffer.add_string b t;
      sp " ";
      add_record ~min b f
  | Args (t, { items; _ }) ->
      Buffer.add_string b t;
      Buffer.add_char b '(';
      list (fun (x, _) -> add_inline ~min b x) items;
      Buffer.add_char b ')'

and add_record ~min b f =
  if f.fields = [] then Buffer.add_string b "{}"
  else begin
    Buffer.add_char b '{';
    if not min then Buffer.add_char b ' ';
    List.iteri
      (fun i (fd, _) ->
        if i > 0 then Buffer.add_string b (if min then "," else ", ");
        Escape.add_key b fd.key;
        Buffer.add_string b (if min then ":" else ": ");
        add_inline ~min b fd.value)
      f.fields;
    if not min then Buffer.add_char b ' ';
    Buffer.add_char b '}'
  end

(* ── pretty ── *)

let has_comment = List.exists (function Comment _ -> true | _ -> false)

(* The comments of an entry's gap that stay on its line, and the rest. *)
let split_trailing g =
  let rec go acc = function
    | Comma :: rest -> go acc rest
    | Comment c :: rest -> if String.contains c '\n' then (List.rev (c :: acc), rest) else go (c :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  go [] g

(* Comments on their own lines, each with whether a blank line comes before
   it in the source, and whether one comes after the last of them. *)
let leading tr =
  let rec go acc blank run = function
    | [] -> (List.rev acc, blank)
    | Nl :: rest ->
        let run = run + 1 in
        go acc (blank || run >= 2) run rest
    | Comma :: rest -> go acc blank 0 rest
    | Comment c :: rest -> go ((c, blank) :: acc) false 0 rest
  in
  go [] false 0 tr

let width_of s = Utf8.length s

(* Whether a positional payload can be written inline: nothing in it spans
   lines or holds a comment. *)
let rec inlineable n =
  match normalize_payload n with
  | Scalar _ -> not (is_multiline_string n)
  | Arr { lead; items } -> items = [] && not (has_comment lead)
  | Rec f | Payload (_, f) -> f.fields = [] && not (has_comment f.flead)
  | Tag _ -> true
  | Args (_, { lead; items }) ->
      (not (has_comment lead))
      && List.for_all (fun (x, g) -> (not (has_comment g)) && inlineable x) items

type entry = { ekey : string option; moved : trivia list; node : node; gap : trivia list }

let rec render o b ~ind ~used ~tail n =
  match normalize_payload n with
  | Scalar (Value.String s, _) when String.contains s '\n' -> add_block b (ind + o.indent) s
  | Scalar (v, sp) -> add_scalar ~style:Pretty b v sp
  | Tag t -> Buffer.add_string b t
  | Arr { lead; items } ->
      container o b ~ind "[" "]" lead (List.map (fun (x, g) -> { ekey = None; moved = []; node = x; gap = g }) items)
  | Rec f -> record o b ~ind f
  | Payload (t, f) ->
      Buffer.add_string b t;
      Buffer.add_char b ' ';
      record o b ~ind f
  | Args (t, { lead; items }) as a ->
      let fits =
        inlineable a
        &&
        let ib = Buffer.create 64 in
        add_inline ~min:false ib a;
        used + width_of (Buffer.contents ib) + tail <= o.width
      in
      if fits then add_inline ~min:false b a
      else begin
        Buffer.add_string b t;
        container o b ~ind "(" ")" lead (List.map (fun (x, g) -> { ekey = None; moved = []; node = x; gap = g }) items)
      end

and record o b ~ind f =
  container o b ~ind "{" "}" f.flead
    (List.map
       (fun (fd, g) -> { ekey = Some fd.key; moved = fd.before_colon @ fd.after_colon; node = fd.value; gap = g })
       f.fields)

and container o b ~ind opener closer lead entries =
  if entries = [] && not (has_comment lead) then (Buffer.add_string b opener; Buffer.add_string b closer)
  else begin
    Buffer.add_string b opener;
    Buffer.add_char b '\n';
    body o b ~ind:(ind + o.indent) ~top:false lead entries;
    Buffer.add_string b (String.make ind ' ');
    Buffer.add_string b closer
  end

(* The lines of a container's entries (or a file's items), each ending in a
   line break. *)
and body o b ~ind ~top lead entries =
  let pad = String.make ind ' ' in
  let first = ref true in
  let line ?(blank = false) () = if blank && not !first then Buffer.add_char b '\n'; first := false in
  let comment ?blank c =
    line ?blank ();
    Buffer.add_string b pad;
    Buffer.add_string b c;
    Buffer.add_char b '\n'
  in
  let n = List.length entries in
  let comma = (not top) || n > 1 in
  let force = ref false in
  let pre = ref lead in
  List.iteri
    (fun i e ->
      let comments, entry_blank = leading !pre in
      let forced () = let f = !force in force := false; f in
      List.iter (fun (c, bl) -> let f = forced () in comment ~blank:(bl || f) c) comments;
      let moved = List.filter_map (function Comment c -> Some c | _ -> None) e.moved in
      if moved <> [] then begin
        let key_blank =
          let rec go run = function
            | Nl :: rest -> run + 1 >= 2 || go (run + 1) rest
            | Comma :: rest -> go 0 rest
            | _ -> false
          in
          go 0 e.moved
        in
        let f = forced () in
        let bl = entry_blank || key_blank || f in
        List.iteri (fun j c -> comment ~blank:(j = 0 && bl) c) moved;
        line ()
      end
      else begin
        let f = forced () in
        line ~blank:(entry_blank || f) ()
      end;
      let start = Buffer.length b in
      Buffer.add_string b pad;
      let used =
        match e.ekey with
        | Some k ->
            let kt = Escape.key k in
            Buffer.add_string b kt;
            Buffer.add_string b ": ";
            ind + width_of kt + 2
        | None -> ind
      in
      let vstart = Buffer.length b in
      render o b ~ind ~used ~tail:(if comma then 1 else 0) e.node;
      let multiline = String.contains (Buffer.sub b vstart (Buffer.length b - vstart)) '\n' in
      ignore start;
      if comma then Buffer.add_char b ',';
      let trail, rest = split_trailing e.gap in
      List.iter (fun c -> Buffer.add_char b ' '; Buffer.add_string b c) trail;
      Buffer.add_char b '\n';
      if top && multiline && i < n - 1 then force := true;
      pre := rest)
    entries;
  (* comments at the end *)
  let comments, _ = leading !pre in
  List.iter (fun (c, bl) -> comment ~blank:bl c) comments

(* ── documents ── *)

let format_items ?(options = default_options) style (doc : items) =
  let b = Buffer.create 1024 in
  (match style with
  | Pretty ->
      body options b ~ind:0 ~top:true doc.lead
        (List.map (fun (x, g) -> { ekey = None; moved = []; node = x; gap = g }) doc.items)
  | Compact | Minimised ->
      let many = List.length doc.items > 1 in
      List.iter
        (fun (x, _) ->
          add_inline ~min:(style = Minimised) b x;
          if many then Buffer.add_char b ',';
          Buffer.add_char b '\n')
        doc.items);
  Buffer.contents b

(* Formats a document (spec §11). *)
let format ?limits ?options style (text : string) =
  format_items ?options style (Parser.document ?limits ~keep:(style = Pretty) text)

(* ── values built in code ── *)

(* Checks every limit of §7 that a value can break (spec §11, "Values built
   in code"), without recursion; errors at [path]. *)
let check_limits ?(limits = Limits.default) path (v : Value.t) =
  let fail code msg = Error.raise_path code path msg in
  let nodes = ref 0 in
  let stack = ref [ (v, 0) ] in
  while !stack <> [] do
    let v, d = List.hd !stack in
    stack := List.tl !stack;
    incr nodes;
    if !nodes > limits.max_nodes then fail "too-many-nodes" "the value writes too many values";
    let str what code s =
      if Utf8.length s > limits.max_string_length then fail code (what ^ " longer than the string limit")
    in
    let deeper d' = if d' > limits.max_depth then fail "nesting-too-deep" "nested deeper than the depth limit" in
    match v with
    | Value.Number n ->
        if String.length n > limits.max_number_length then fail "number-too-long" "a number longer than the number limit";
        if Number.exponent_exceeds (Number.exponent_of_normalized n) limits.max_exponent then
          fail "exponent-too-large" "an exponent larger than the limit"
    | Value.String s -> str "a string" "string-too-long" s
    | Value.Bytes s -> if 2 * String.length s > limits.max_string_length then fail "string-too-long" "a byte string longer than the string limit"
    | Value.Array xs ->
        deeper (d + 1);
        List.iter (fun x -> stack := (x, d + 1) :: !stack) xs
    | Value.Record fs ->
        deeper (d + 1);
        List.iter (fun (k, x) -> str "a key" "key-too-long" k; stack := (x, d + 1) :: !stack) fs
    | Value.Variant (t, args) -> (
        str "a tag" "tag-too-long" t;
        match args with
        | [] -> ()
        | [ Value.Record fs ] ->
            deeper (d + 1);
            incr nodes;
            List.iter (fun (k, x) -> str "a key" "key-too-long" k; stack := (x, d + 1) :: !stack) fs
        | args ->
            deeper (d + 1);
            List.iter (fun x -> stack := (x, d + 1) :: !stack) args)
  done

(* Writes one value built in code. *)
let write ?limits ?(options = default_options) style (v : Value.t) =
  check_limits ?limits "$" v;
  let n = Cst.of_value v in
  let b = Buffer.create 256 in
  (match style with
  | Pretty -> render options b ~ind:0 ~used:0 ~tail:0 n
  | Compact -> add_inline ~min:false b n
  | Minimised -> add_inline ~min:true b n);
  Buffer.contents b

(* Writes values as a file: one value alone, several each with a comma. *)
let write_all ?limits ?options style (vs : Value.t list) =
  List.iteri (fun i v -> check_limits ?limits (Printf.sprintf "$[%d]" i) v) vs;
  format_items ?options style
    { lead = []; items = List.map (fun v -> (Cst.of_value v, [])) vs }
