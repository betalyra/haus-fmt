(* A small JSON reader, to compare the suite's .jsonl files as data. *)

type t = Null | Bool of bool | Num of string | Str of string | Arr of t list | Obj of (string * t) list

exception Bad of string

let parse (s : string) : t =
  let i = ref 0 in
  let n = String.length s in
  let peek () = if !i < n then s.[!i] else '\000' in
  let rec skip () = if !i < n && (s.[!i] = ' ' || s.[!i] = '\n' || s.[!i] = '\t' || s.[!i] = '\r') then (incr i; skip ()) in
  let expect c = skip (); if peek () <> c then raise (Bad (Printf.sprintf "expected %c at %d" c !i)); incr i in
  let str () =
    expect '"';
    let b = Buffer.create 16 in
    let rec go () =
      let c = peek () in
      incr i;
      match c with
      | '"' -> ()
      | '\\' ->
          let e = peek () in
          incr i;
          (match e with
          | 'n' -> Buffer.add_char b '\n'
          | 'r' -> Buffer.add_char b '\r'
          | 't' -> Buffer.add_char b '\t'
          | 'b' -> Buffer.add_char b '\b'
          | 'f' -> Buffer.add_char b '\012'
          | 'u' ->
              let hex () = let v = int_of_string ("0x" ^ String.sub s !i 4) in i := !i + 4; v in
              let u = hex () in
              let cp =
                if u >= 0xD800 && u < 0xDC00 && peek () = '\\' then begin
                  i := !i + 2;
                  let lo = hex () in
                  0x10000 + ((u - 0xD800) lsl 10) + (lo - 0xDC00)
                end
                else u
              in
              Buffer.add_utf_8_uchar b (Uchar.of_int cp)
          | c -> Buffer.add_char b c);
          go ()
      | c -> Buffer.add_char b c; go ()
    in
    go ();
    Buffer.contents b
  in
  let rec value () =
    skip ();
    match peek () with
    | '{' ->
        incr i;
        skip ();
        if peek () = '}' then (incr i; Obj [])
        else
          let rec go acc =
            let k = str () in
            expect ':';
            let v = value () in
            skip ();
            if peek () = ',' then (incr i; go ((k, v) :: acc)) else (expect '}'; Obj (List.rev ((k, v) :: acc)))
          in
          go []
    | '[' ->
        incr i;
        skip ();
        if peek () = ']' then (incr i; Arr [])
        else
          let rec go acc =
            let v = value () in
            skip ();
            if peek () = ',' then (incr i; go (v :: acc)) else (expect ']'; Arr (List.rev (v :: acc)))
          in
          go []
    | '"' -> Str (str ())
    | 't' -> i := !i + 4; Bool true
    | 'f' -> i := !i + 5; Bool false
    | 'n' -> i := !i + 4; Null
    | _ ->
        let st = !i in
        while !i < n && (match s.[!i] with '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true | _ -> false) do incr i done;
        Num (String.sub s st (!i - st))
  in
  let v = value () in
  skip ();
  if !i <> n then raise (Bad "trailing text");
  v

let rec normalize = function
  | Arr xs -> Arr (List.map normalize xs)
  | Obj fs -> Obj (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, v) -> (k, normalize v)) fs))
  | x -> x

let equal a b = normalize a = normalize b
