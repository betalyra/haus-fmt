(* Values as the JSON of the test suite (test-suite/README.md, self-describing
   forms) for runners and tests. [prefix] is "_" for the suite's files, ""
   for the fuzzer's protocol. Not a JSON mapping of spec §16 (phase 2). *)

let add_json_string b s =
  Buffer.add_char b '"';
  let i = ref 0 in
  let n = String.length s in
  while !i < n do
    let c = s.[!i] in
    (match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.code c < 0x20 || c = '\x7f' -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c);
    incr i
  done;
  Buffer.add_char b '"'

let rec add ?(prefix = "_") b (v : Value.t) =
  let key k = add_json_string b (prefix ^ k); Buffer.add_char b ':' in
  match v with
  | Value.String s -> add_json_string b s
  | Value.Number n -> Buffer.add_char b '{'; key "num"; add_json_string b n; Buffer.add_char b '}'
  | Value.Bytes s ->
      Buffer.add_char b '{';
      key "bytes";
      Buffer.add_char b '"';
      String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
      Buffer.add_string b "\"}"
  | Value.Array xs ->
      Buffer.add_char b '[';
      List.iteri (fun i x -> if i > 0 then Buffer.add_char b ','; add ~prefix b x) xs;
      Buffer.add_char b ']'
  | Value.Record fs ->
      Buffer.add_char b '{';
      key "rec";
      Buffer.add_char b '{';
      List.iteri
        (fun i (k, x) ->
          if i > 0 then Buffer.add_char b ',';
          add_json_string b k;
          Buffer.add_char b ':';
          add ~prefix b x)
        fs;
      Buffer.add_string b "}}"
  | Value.Variant (t, args) ->
      Buffer.add_char b '{';
      key "tag";
      add_json_string b t;
      if args <> [] then begin
        Buffer.add_char b ',';
        key "args";
        Buffer.add_char b '[';
        List.iteri (fun i x -> if i > 0 then Buffer.add_char b ','; add ~prefix b x) args;
        Buffer.add_char b ']'
      end;
      Buffer.add_char b '}'

let to_string ?prefix v =
  let b = Buffer.create 64 in
  add ?prefix b v;
  Buffer.contents b
