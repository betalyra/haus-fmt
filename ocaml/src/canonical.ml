(* The canonical form, equality, order and hashing (spec §12). Nothing here
   recurses: a value of any depth is written with a stack of its own. *)

type work = V of Value.t | Lit of string | Key of string

let too_many path max =
  Error.raise_path "too-many-nodes" path
    (Printf.sprintf "the value would write more than %d values" max)

(* Adds the canonical form of [v] to [b]; errors at [path]. *)
let add ?(max_nodes = Limits.default.max_nodes) ?(path = "$") b (v : Value.t) =
  let nodes = ref 0 in
  let stack = ref [ V v ] in
  let push w = stack := w :: !stack in
  let rec push_list sep close = function
    | [] -> push (Lit close)
    | [ x ] -> push (Lit close); push (V x)
    | x :: rest -> push_list sep close rest; push (Lit sep); push (V x)
  in
  while !stack <> [] do
    let w = List.hd !stack in
    stack := List.tl !stack;
    match w with
    | Lit s -> Buffer.add_string b s
    | Key k -> Escape.add_key b k; Buffer.add_char b ':'
    | V v -> (
        incr nodes;
        if !nodes > max_nodes then too_many path max_nodes;
        match v with
        | Value.Number n -> Buffer.add_string b n
        | Value.String s -> Escape.add_string b s
        | Value.Bytes s -> Escape.add_bytes b s
        | Value.Array xs ->
            Buffer.add_char b '[';
            push_list "," "]" xs
        | Value.Record fs ->
            Buffer.add_char b '{';
            let sorted = List.stable_sort (fun (a, _) (c, _) -> String.compare a c) fs in
            let rec go = function
              | [] -> push (Lit "}")
              | [ (k, x) ] -> push (Lit "}"); push (V x); push (Key k)
              | (k, x) :: rest -> go rest; push (Lit ","); push (V x); push (Key k)
            in
            go sorted
        | Value.Variant (t, []) -> Buffer.add_string b t
        | Value.Variant (t, [ (Value.Record _ as r) ]) ->
            Buffer.add_string b t;
            push (V r)
        | Value.Variant (t, args) ->
            Buffer.add_string b t;
            Buffer.add_char b '(';
            push_list "," ")" args)
  done

let canonical ?max_nodes v =
  let b = Buffer.create 64 in
  add ?max_nodes b v;
  Buffer.contents b

let to_hex d = Digestif.SHA256.to_hex d

let hash ?max_nodes v = to_hex (Digestif.SHA256.digest_string (canonical ?max_nodes v))

let hash_all ?max_nodes (vs : Value.t list) =
  let b = Buffer.create 256 in
  List.iteri
    (fun i v ->
      if i > 0 then Buffer.add_char b ',';
      add ?max_nodes ~path:(Printf.sprintf "$[%d]" i) b v)
    vs;
  to_hex (Digestif.SHA256.digest_string (Buffer.contents b))

let compare ?max_nodes a b = Stdlib.compare (String.compare (canonical ?max_nodes a) (canonical ?max_nodes b)) 0

let equals ?max_nodes a b = String.equal (canonical ?max_nodes a) (canonical ?max_nodes b)
