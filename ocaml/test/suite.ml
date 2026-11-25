(* Runs the conformance suite's text-core directories (test-suite/README.md)
   and prints pass counts per directory. Exits 1 on any failure. *)

open Haus

let root =
  let rec up d n =
    if Sys.file_exists (Filename.concat d "test-suite/README.md") then Filename.concat d "test-suite"
    else if n = 0 then failwith "test-suite not found"
    else up (Filename.dirname d) (n - 1)
  in
  match Sys.getenv_opt "HAUS_SUITE" with Some d -> d | None -> up (Sys.getcwd ()) 8

let verbose = Sys.getenv_opt "VERBOSE" <> None

let read_file path = In_channel.with_open_bin path In_channel.input_all

let files dir ext =
  Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ext) |> List.sort compare

(* counters per directory *)
let results : (string * int ref * int ref) list ref = ref []
let failures = ref 0

let counter name =
  match List.find_opt (fun (n, _, _) -> n = name) !results with
  | Some (_, p, f) -> (p, f)
  | None ->
      let p = ref 0 and f = ref 0 in
      results := !results @ [ (name, p, f) ];
      (p, f)

let check dir name ok detail =
  let p, f = counter dir in
  if ok then incr p
  else begin
    incr f;
    incr failures;
    if verbose || !f <= 15 then Printf.printf "FAIL %s %s: %s\n%!" dir name (detail ())
  end

let err_str = function
  | Error.Haus_error e -> Error.to_string e
  | e -> Printexc.to_string e

let code_of f = match f () with _ -> None | exception Error.Haus_error e -> Some e

(* fields of a suite record *)
let field v k = match v with Value.Record fs -> List.assoc_opt k fs | _ -> None
let str v k = match field v k with Some (Value.String s) -> s | _ -> failwith ("no string " ^ k)
let int_field v k = match field v k with Some (Value.Number n) -> Some (int_of_string n) | _ -> None
let is_true v k = match field v k with Some (Value.Variant ("True", [])) -> true | _ -> false

(* ── valid ── *)
let valid () =
  let dir = Filename.concat root "valid" in
  List.iter
    (fun f ->
      let base = Filename.chop_suffix f ".haus" in
      let text = read_file (Filename.concat dir f) in
      match Parser.parse_all text with
      | exception e -> check "valid" base false (fun () -> err_str e)
      | vs ->
          let expected = read_file (Filename.concat dir (base ^ ".jsonl")) in
          let lines = String.split_on_char '\n' expected |> List.filter (( <> ) "") in
          let ok =
            List.length lines = List.length vs
            && List.for_all2
                 (fun l v ->
                   let mine = Printf.sprintf "{\"_haus\":1,\"_value\":%s}" (Json_out.to_string v) in
                   Json.equal (Json.parse l) (Json.parse mine))
                 lines vs
          in
          check "valid" base ok (fun () -> "values differ from .jsonl");
          let canon = read_file (Filename.concat dir (base ^ ".canonical")) in
          let mine = String.concat "" (List.map (fun v -> Canonical.canonical v ^ "\n") vs) in
          check "valid-canonical" base (canon = mine) (fun () -> Printf.sprintf "expected %S got %S" canon mine);
          let h = String.trim (read_file (Filename.concat dir (base ^ ".hash"))) in
          let mine = Canonical.hash_all vs in
          check "valid-hash" base (h = mine) (fun () -> h ^ " vs " ^ mine);
          (* the stream reader, in chunks, gives the same values *)
          let streamed = try Some (Stream.read_chunks text [ 1; 2; 3; 5; 8; 13; 64 ]) with _ -> None in
          check "valid-stream" base
            (match streamed with Some s -> List.length s = List.length vs && List.for_all2 (fun a b -> Canonical.equals a b) s vs | None -> false)
            (fun () -> "stream reader differs"))
    (files dir ".haus")

(* ── invalid ── *)
let invalid () =
  let dir = Filename.concat root "invalid" in
  List.iter
    (fun f ->
      let base = Filename.chop_suffix f ".haus" in
      let text = read_file (Filename.concat dir f) in
      let want = String.trim (read_file (Filename.concat dir (base ^ ".error"))) in
      (match code_of (fun () -> Parser.parse_all text) with
      | Some e -> check "invalid" base (e.code = want) (fun () -> Printf.sprintf "want %s got %s" want (Error.to_string e))
      | None -> check "invalid" base false (fun () -> "accepted; want " ^ want));
      (* the stream reader reports the same code (whole text and in chunks) *)
      match code_of (fun () -> Stream.read_chunks text [ 1; 2; 3; 5; 8; 13; 64 ]) with
      | Some e -> check "invalid-stream" base (e.code = want) (fun () -> Printf.sprintf "want %s got %s" want (Error.to_string e))
      | None -> check "invalid-stream" base false (fun () -> "accepted; want " ^ want))
    (files dir ".haus")

let cases path = Parser.parse_all (read_file (Filename.concat root path))

(* ── positions ── *)
let positions () =
  List.iteri
    (fun i c ->
      let text = str c "text" and code = str c "code" in
      let line = Option.get (int_field c "line") and column = Option.get (int_field c "column") in
      let name = Printf.sprintf "#%d %S" i (if String.length text > 40 then String.sub text 0 40 else text) in
      let run () = if is_true c "document" then ignore (Parser.parse text) else ignore (Parser.parse_all text) in
      match code_of run with
      | Some e ->
          check "positions" name (e.code = code && e.place = Error.At (line, column)) (fun () ->
              Printf.sprintf "want %s %d:%d got %s" code line column (Error.to_string e))
      | None -> check "positions" name false (fun () -> "accepted"))
    (cases "positions/cases.haus")

(* ── equality ── *)
let equality () =
  List.iteri
    (fun i c ->
      let a = Option.get (field c "a") and b = Option.get (field c "b") in
      let equal = is_true c "equal" in
      let order = match field c "order" with Some (Value.Number n) -> int_of_string n | _ -> 99 in
      let name = Printf.sprintf "#%d %s" i (Canonical.canonical c) in
      check "equality" name
        (Canonical.equals a b = equal && Canonical.equals b a = equal
        && Canonical.compare a b = order && Canonical.compare b a = -order)
        (fun () -> Printf.sprintf "equals %b compare %d" (Canonical.equals a b) (Canonical.compare a b)))
    (cases "equality/cases.haus")

(* ── stream ── *)
let splits text =
  let n = String.length text in
  [ [ text ]; List.init n (fun i -> String.make 1 text.[i]) ]
  @ List.init (max 0 (n - 1)) (fun k -> [ String.sub text 0 (k + 1); String.sub text (k + 1) (n - k - 1) ])

let read_parts ?limits ?strict parts =
  let r = Stream.create ?limits ?strict () in
  let out = List.concat_map (Stream.push r) parts in
  out @ Stream.finish r

let same_values a b = List.length a = List.length b && List.for_all2 Canonical.equals a b

let stream_limits () =
  List.iteri
    (fun i c ->
      let text = str c "text" in
      let limits = Limits.make ~max_value_length:(Option.get (int_field c "maxValueLength")) () in
      let strict = is_true c "strict" in
      let name = Printf.sprintf "#%d %S" i text in
      let expect = Option.get (field c "result") in
      List.iter
        (fun parts ->
          let got = try Ok (read_parts ~limits ~strict parts) with Error.Haus_error e -> Error e in
          let ok =
            match (expect, got) with
            | Value.Variant ("Ok", [ Value.Array vs ]), Ok got -> same_values vs got
            | Value.Variant ("Err", [ Value.String code ]), Error e ->
                e.code = code
                && (match (int_field c "line", int_field c "column") with
                   | Some l, Some col -> e.place = Error.At (l, col)
                   | _ -> true)
            | _ -> false
          in
          check "stream" name ok (fun () ->
              Printf.sprintf "split %s: %s" (String.concat "|" parts)
                (match got with Ok vs -> "ok " ^ String.concat "," (List.map Canonical.canonical vs) | Error e -> Error.to_string e)))
        (splits text);
      match field c "whole" with
      | Some (Value.Variant ("Ok", [ Value.Array vs ])) ->
          check "stream" (name ^ " whole")
            (try same_values vs (Parser.parse_all text) with _ -> false)
            (fun () -> "whole parse differs")
      | _ -> ())
    (cases "stream/limits.cases.haus")

let stream_document () =
  List.iteri
    (fun i c ->
      let text = str c "text" in
      let name = Printf.sprintf "#%d %S" i text in
      let got = try Ok (Parser.parse text) with Error.Haus_error e -> Error e in
      let ok =
        match (Option.get (field c "result"), got) with
        | Value.Variant ("Ok", [ v ]), Ok g -> Canonical.equals v g
        | Value.Variant ("Err", [ Value.String code ]), Error e -> e.code = code
        | _ -> false
      in
      check "stream-document" name ok (fun () -> match got with Ok v -> Canonical.canonical v | Error e -> Error.to_string e))
    (cases "stream/document.cases.haus")

let () =
  valid ();
  invalid ();
  positions ();
  equality ();
  stream_limits ();
  stream_document ();
  Format_suite.run ~root ~check;
  List.iter (fun (n, p, f) -> Printf.printf "%-22s %4d passed %4d failed\n" n !p !f) !results;
  if !failures > 0 then exit 1
