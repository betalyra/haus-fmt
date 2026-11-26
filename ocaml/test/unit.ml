(* Unit tests for what the conformance suites don't cover: values built in
   code, writer limits, depth, the node limit, hashing details, options. *)

open Haus

let failures = ref 0
let passed = ref 0

let ok name cond =
  if cond then incr passed
  else begin
    incr failures;
    Printf.printf "FAIL %s\n%!" name
  end

let code f = match f () with _ -> "ok" | exception Error.Haus_error e -> e.code
let place f = match f () with _ -> None | exception Error.Haus_error e -> Some e.place

let num = Value.number
let n = num "1"

let () =
  (* constructors (spec §11 "Values built in code") *)
  ok "number normalizes 1E+05" ((match num "1E+05" with Value.Number s -> s | _ -> "") = "1e5");
  ok "number normalizes -0x0" ((match num "-0x0" with Value.Number s -> s | _ -> "") = "-0");
  ok "number 0b101" ((match num "0b1_01" with Value.Number s -> s | _ -> "") = "5");
  ok "number 01 rejected" (code (fun () -> num "01") = "invalid-number");
  ok "number NaN rejected" (code (fun () -> num "NaN") = "invalid-number");
  ok "number empty rejected" (code (fun () -> num "") = "invalid-number");
  ok "number with space rejected" (code (fun () -> num " 1") = "invalid-number");
  ok "number huge exponent built" (code (fun () -> num "3E70955681357760880162") = "ok");
  ok "tag lower rejected" (code (fun () -> Value.variant "lower" []) = "invalid-tag");
  ok "tag A-B rejected" (code (fun () -> Value.variant "A-B" []) = "invalid-tag");
  ok "tag with a lone surrogate's bytes is invalid-tag" (code (fun () -> Value.variant "\xed\xa0\x80" []) = "invalid-tag");
  ok "tag A + lone surrogate is invalid-tag" (code (fun () -> Value.variant "A\xed\xa0\x80" []) = "invalid-tag");
  ok "tag of invalid UTF-8 is invalid-tag" (code (fun () -> Value.variant "\xff" []) = "invalid-tag");
  ok "string bad utf8" (code (fun () -> Value.string "\xff") = "cannot-encode");
  ok "key twice" (code (fun () -> Value.record [ ("a", n); ("a", n) ]) = "duplicate-key");
  ok "key bad utf8" (code (fun () -> Value.record [ ("\xc0", n) ]) = "cannot-encode");

  (* writer limits (spec §11) *)
  let big = num (String.make 1001 '7') in
  ok "1001 digits: canonical fine" (String.length (Canonical.canonical big) = 1001);
  ok "1001 digits: writer refuses" (code (fun () -> Layout.write Layout.Compact big) = "number-too-long");
  ok "1000 digits written" (code (fun () -> Layout.write Layout.Compact (num (String.make 1000 '7'))) = "ok");
  ok "hex 830 digits normalized past limit" (code (fun () -> Layout.write Layout.Compact (num ("0x" ^ String.make 900 'f'))) = "number-too-long");
  ok "1e9999 writer refuses" (code (fun () -> Layout.write Layout.Compact (num "1e9999")) = "exponent-too-large");
  ok "1e6144 written" (code (fun () -> Layout.write Layout.Compact (num "1e6144")) = "ok");
  ok "error at $" (place (fun () -> Layout.write Layout.Compact big) = Some (Error.Path "$"));
  ok "error at $[1]" (place (fun () -> Layout.write_all Layout.Compact [ n; big ]) = Some (Error.Path "$[1]"));
  ok "error at $[0] alone" (place (fun () -> Layout.write_all Layout.Compact [ big ]) = Some (Error.Path "$[0]"));
  let rec nest k v = if k = 0 then v else nest (k - 1) (Value.array [ v ]) in
  ok "depth 256 written" (code (fun () -> Layout.write Layout.Pretty (nest 256 n)) = "ok");
  ok "depth 257 refused" (code (fun () -> Layout.write Layout.Compact (nest 257 n)) = "nesting-too-deep");
  let rec nest_payload k v = if k = 0 then v else nest_payload (k - 1) (Value.variant "S" [ Value.record [ ("a", v) ] ]) in
  ok "record payloads: one level each (256)" (code (fun () -> Layout.write Layout.Compact (nest_payload 256 n)) = "ok");
  ok "record payloads: 257 refused" (code (fun () -> Layout.write Layout.Compact (nest_payload 257 n)) = "nesting-too-deep");
  ok "empty array is a level" (code (fun () -> Layout.write Layout.Compact (nest 256 (Value.array []))) = "nesting-too-deep");

  (* the node limit: a value whose arrays share each other *)
  let rec dag k v = if k = 0 then v else dag (k - 1) (Value.array [ v; v ]) in
  let d = dag 40 n in
  ok "DAG canonical too-many-nodes" (code (fun () -> Canonical.canonical ~max_nodes:1_000_000 d) = "too-many-nodes");
  ok "DAG writer too-many-nodes" (code (fun () -> Layout.write ~limits:(Limits.make ~max_nodes:1000 ()) Layout.Compact d) = "too-many-nodes");
  ok "DAG hash_all at $[0]" (place (fun () -> Canonical.hash_all ~max_nodes:100 [ d ]) = Some (Error.Path "$[0]"));
  ok "T { a: 1 } is 3 values" (code (fun () -> Canonical.canonical ~max_nodes:3 (Value.variant "T" [ Value.record [ ("a", n) ] ])) = "ok"
                              && code (fun () -> Canonical.canonical ~max_nodes:2 (Value.variant "T" [ Value.record [ ("a", n) ] ])) = "too-many-nodes");

  (* canonical, hash, equals and compare at any depth *)
  let deep = nest 1_000_000 n in
  ok "canonical at depth 10^6" (String.length (Canonical.canonical deep) = 2_000_001);
  ok "equals at depth 10^6" (Canonical.equals deep deep);

  (* hashing *)
  ok "hash_all [] is sha256 of empty" (Canonical.hash_all [] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  ok "hash_all [v] = hash v" (Canonical.hash_all [ n ] = Canonical.hash n);
  ok "hash of 1,\"a\",Order{id:255}"
    (Canonical.hash_all (Parser.parse_all "1, \"a\", Order { id: 0xFF },")
    = Digestif.SHA256.(to_hex (digest_string "1,\"a\",Order{id:255}")));

  (* limits and options *)
  ok "unsupported depth" (code (fun () -> Limits.make ~max_depth:(Limits.max_supported_depth + 1) ()) = "unsupported-depth");
  ok "hex limit 829" (Limits.hex_digits Limits.default = 829);
  ok "negative indent rejected" (match Layout.options ~indent:(-1) () with _ -> false | exception Invalid_argument _ -> true);
  let lim = Limits.make ~max_depth:Limits.max_supported_depth () in
  let text = String.make Limits.max_supported_depth '[' ^ String.make Limits.max_supported_depth ']' in
  ok "parse at the maximum supported depth" (code (fun () -> Parser.parse ~limits:lim text) = "ok");
  ok "configured depth 3" (code (fun () -> Parser.parse ~limits:(Limits.make ~max_depth:3 ()) "[[[[1]]]]") = "nesting-too-deep");
  ok "configured string limit" (code (fun () -> Parser.parse ~limits:(Limits.make ~max_string_length:3 ()) "\"abcd\"") = "string-too-long");
  ok "configured key limit" (code (fun () -> Parser.parse ~limits:(Limits.make ~max_string_length:3 ()) "{ abcd: 1 }") = "key-too-long");
  ok "configured tag limit" (code (fun () -> Parser.parse ~limits:(Limits.make ~max_string_length:3 ()) "Abcd") = "tag-too-long");
  let l20 = Limits.make ~max_number_length:20 () in
  ok "number limit 20: hex limit 15" (Limits.hex_digits l20 = 15
                                     && code (fun () -> Parser.parse ~limits:l20 ("0x" ^ String.make 15 'f')) = "ok"
                                     && code (fun () -> Parser.parse ~limits:l20 ("0x" ^ String.make 16 'f')) = "number-too-long");
  let feed r parts = let vs = List.concat_map (Stream.push r) parts in vs @ Stream.finish r in

  (* the stream reader: strict mode and one value at a time *)
  let r = Stream.create ~strict:true () in
  let got = Stream.push r "1, [2" in
  ok "stream gives completed values" (List.length got = 1);
  ok "stream strict truncated" (code (fun () -> feed r [ "]" ]) = "stream-truncated");
  ok "stream BOM then BOM is a mistake" (code (fun () -> feed (Stream.create ()) [ "\xef\xbb"; "\xbf\xef\xbb\xbf1" ]) = "expected-value");
  ok "#haus after a comma" (code (fun () -> Stream.read_chunks "1,#haus 2" [ 1 ]) = "expected-value");

  (* writers from values *)
  let v = Parser.parse "{ b: 0xFF, a: x\"0A FF\", s: \"x\\ny\", p: P(1, 2) }" in
  ok "compact from value" (Layout.write Layout.Compact v = "{ b: 255, a: x\"0aff\", s: \"x\\ny\", p: P(1, 2) }");
  ok "minimised from value" (Layout.write Layout.Minimised v = "{b:255,a:x\"0aff\",s:\"x\\ny\",p:P(1,2)}");
  ok "pretty from value"
    (Layout.write Layout.Pretty v = "{\n  b: 255,\n  a: x\"0aff\",\n  s: \"\"\"\n    x\n    y\n    \"\"\",\n  p: P(1, 2),\n}");
  ok "write_all stream" (Layout.write_all Layout.Compact [ n; n ] = "1,\n1,\n");
  ok "write_all empty" (Layout.write_all Layout.Pretty [] = "");
  (* the stream option (spec §11): a comma after a single value too *)
  let stream = Layout.options ~stream:true () in
  ok "write_all one value" (Layout.write_all Layout.Compact [ n ] = "1\n");
  List.iter
    (fun (style, name) ->
      ok ("write_all stream, one value, " ^ name) (Layout.write_all ~options:stream style [ n ] = "1,\n");
      ok ("write_all stream, none, " ^ name) (Layout.write_all ~options:stream style [] = "");
      ok ("format stream, one item, " ^ name) (Layout.format ~options:stream style "1 // c" = (if style = Layout.Pretty then "1, // c\n" else "1,\n")))
    [ (Layout.Pretty, "pretty"); (Layout.Compact, "compact"); (Layout.Minimised, "minimised") ];
  ok "hex limit 0 for a number limit of 0" (Limits.hex_digits (Limits.make ~max_number_length:0 ()) = 0);

  Printf.printf "unit: %d passed, %d failed\n" !passed !failures;
  if !failures > 0 then exit 1
