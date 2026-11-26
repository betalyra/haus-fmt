(* The fuzzer's runner (fuzz/README.md): reads DIR/00000.haus … DIR/{N-1}.haus
   and prints one line per file.

     runner DIR N                       parse:      ok <values> | err LINE COLUMN CODE REASON
     runner --stream DIR N              the stream reader, in chunks of [1,2,3,5,8,13,64][(i+k) % 7]
     runner --canonical DIR N           ok <canonical forms as a JSON array>
     runner --format STYLE [--indent N] [--width N] DIR N    ok <the formatted text as a JSON string>
     runner --write STYLE [--indent N] [--width N] DIR N     ok {"values": [...], "file": ...}
     (with --stream too: formatted and written with the stream option of spec §11; "file" stays the key)
   Every mode's error is err LINE COLUMN CODE REASON, 0 0 where there is no place.

   Values are printed in the fuzzer's JSON encoding (num, bytes, rec, tag,
   args: the suite's keys without their underscore, as fuzz/src/runners.ts). *)

open Haus

let sizes = [| 1; 2; 3; 5; 8; 13; 64 |]

let one_line s = String.map (fun c -> if c = '\n' || c = '\r' then ' ' else c) s

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Json_out.add_json_string b s;
  Buffer.contents b

let json_array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]"

let err (e : Error.t) =
  match e.place with
  | Error.At (l, c) -> Printf.sprintf "err %d %d %s %s" l c e.code (one_line e.message)
  | _ -> Printf.sprintf "err 0 0 %s %s" e.code (one_line e.message)

let chunked i text =
  let r = Stream.create () in
  let out = ref [] in
  let at = ref 0 and k = ref 0 in
  while !at < String.length text do
    let n = min (String.length text - !at) sizes.((i + !k) mod 7) in
    out := List.rev_append (Stream.push r (String.sub text !at n)) !out;
    at := !at + n;
    incr k
  done;
  List.rev_append !out (Stream.finish r)

let style_of = function
  | "pretty" -> Layout.Pretty
  | "compact" -> Layout.Compact
  | "minimised" | "minimized" -> Layout.Minimised
  | s -> failwith ("unknown style " ^ s)

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let mode = ref `Parse and indent = ref None and width = ref None and stream = ref false in
  let rec opts = function
    | "--stream" :: r -> stream := true; opts r
    | "--canonical" :: r -> mode := `Canonical; opts r
    | "--format" :: s :: r -> mode := `Format (style_of s); opts r
    | "--write" :: s :: r -> mode := `Write (style_of s); opts r
    | "--indent" :: n :: r -> indent := Some (int_of_string n); opts r
    | "--width" :: n :: r -> width := Some (int_of_string n); opts r
    | rest -> rest
  in
  let dir, n = match opts args with [ d; n ] -> (d, int_of_string n) | _ -> failwith "usage: runner [mode] DIR N" in
  (* [--stream] alone reads through the stream reader; with [--format] or
     [--write] it is the stream option of spec §11. *)
  if !stream && !mode = `Parse then mode := `Stream;
  let options = Layout.options ?indent:!indent ?width:!width ~stream:!stream () in
  for i = 0 to n - 1 do
    let text = In_channel.with_open_bin (Filename.concat dir (Printf.sprintf "%05d.haus" i)) In_channel.input_all in
    let line =
      try
        match !mode with
        | `Parse -> "ok " ^ json_array (Json_out.to_string ~prefix:"") (Parser.parse_all text)
        | `Stream -> "ok " ^ json_array (Json_out.to_string ~prefix:"") (chunked i text)
        | `Canonical -> "ok " ^ json_array (fun v -> json_string (Canonical.canonical v)) (Parser.parse_all text)
        | `Format style -> "ok " ^ json_string (Layout.format ~options style text)
        | `Write style ->
            let vs = Parser.parse_all text in
            (* "file" is write_all, with the stream option under --stream. *)
            Printf.sprintf "ok {\"values\":%s,\"file\":%s}"
              (json_array (fun v -> json_string (Layout.write ~options style v)) vs)
              (json_string (Layout.write_all ~options style vs))
      with Error.Haus_error e -> err e
    in
    print_endline line
  done
