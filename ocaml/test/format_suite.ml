(* The format suite (test-suite/format/README.md). *)

open Haus

let read_file path = In_channel.with_open_bin path In_channel.input_all

let int_of v k =
  match v with
  | Value.Record fs -> (
      match List.assoc_opt k fs with Some (Value.Number n) -> Some (int_of_string n) | _ -> None)
  | _ -> None

let values text = List.map Canonical.canonical (Parser.parse_all text)

let drop_blank_lines s = String.split_on_char '\n' s |> List.filter (fun l -> String.trim l <> "") |> String.concat "\n"

let trim_line_ends s =
  String.split_on_char '\n' s
  |> List.map (fun l ->
         let n = ref (String.length l) in
         while !n > 0 && (l.[!n - 1] = ' ' || l.[!n - 1] = '\t') do decr n done;
         String.sub l 0 !n)
  |> String.concat "\n"

let run ~root ~check =
  let one dir_name input_dir out_dir base =
    let input = read_file (Filename.concat input_dir (base ^ ".haus")) in
    let opts =
      let p = Filename.concat out_dir (base ^ ".options") in
      if Sys.file_exists p then
        let v = Parser.parse (read_file p) in
        Layout.options ?indent:(int_of v "indent") ?width:(int_of v "width") ()
      else Layout.default_options
    in
    let fmt style text = Layout.format ~options:opts style text in
    let input_values = try Some (values input) with _ -> None in
    List.iter
      (fun (style, ext) ->
        let expected = read_file (Filename.concat out_dir (base ^ "." ^ ext)) in
        let name = base ^ "." ^ ext in
        match fmt style input with
        | exception e -> check dir_name name false (fun () -> Printexc.to_string e)
        | got ->
            check dir_name name (got = expected) (fun () -> Printf.sprintf "\n--- expected\n%s--- got\n%s---" expected got);
            let again = try fmt style got with e -> Printexc.to_string e in
            check (dir_name ^ "-idempotent") name (again = got) (fun () -> "\n" ^ again);
            check (dir_name ^ "-values") name
              ((try Some (values got) with _ -> None) = input_values)
              (fun () -> "values differ");
            if style = Layout.Pretty then
              check (dir_name ^ "-trimmed") name
                ((try Some (values (trim_line_ends got)) with _ -> None) = input_values)
                (fun () -> "trimmed pretty differs");
            if style = Layout.Minimised then begin
              let from_min = try fmt Layout.Pretty got with e -> Printexc.to_string e in
              let no_comments =
                Layout.format_items ~options:opts Layout.Pretty (Parser.document ~keep:false input)
              in
              check (dir_name ^ "-roundtrip") name
                (drop_blank_lines from_min = drop_blank_lines no_comments)
                (fun () -> "\n" ^ from_min ^ "---\n" ^ no_comments)
            end)
      [ (Layout.Pretty, "pretty"); (Layout.Compact, "compact"); (Layout.Minimised, "minimised") ]
  in
  let fdir = Filename.concat root "format" in
  List.iter
    (fun (sub, input_dir) ->
      let out_dir = Filename.concat fdir sub in
      let input_dir = match input_dir with Some d -> d | None -> out_dir in
      Sys.readdir out_dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".pretty")
      |> List.sort compare
      |> List.iter (fun f -> one ("format/" ^ sub) input_dir out_dir (Filename.chop_suffix f ".pretty")))
    [ ("cases", None); ("examples", None); ("valid", Some (Filename.concat root "valid")) ];
  (* options.cases.haus *)
  List.iteri
    (fun i c ->
      let input = match c with Value.Record fs -> (match List.assoc "input" fs with Value.String s -> s | _ -> "") | _ -> "" in
      let result = match c with Value.Record fs -> List.assoc "result" fs | _ -> assert false in
      let got =
        try Ok (Layout.format ~options:(Layout.options ?indent:(int_of c "indent") ?width:(int_of c "width") ()) Layout.Pretty input)
        with Invalid_argument _ -> Error ()
      in
      let ok =
        match (result, got) with
        | Value.Variant ("Ok", [ Value.String s ]), Ok g -> s = g
        | Value.Variant ("Rejected", []), Error () -> true
        | _ -> false
      in
      check "format/options" (string_of_int i) ok (fun () -> match got with Ok g -> g | Error () -> "rejected"))
    (Parser.parse_all (read_file (Filename.concat fdir "options.cases.haus")))
