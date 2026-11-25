(* Number literals (grammar.ebnf `number`, spec §2, §3): scanning,
   normalizing and the limits measured on them. *)

type literal = {
  stop : int;  (** index after the literal *)
  normalized : string;  (** the normalized literal of spec §2 *)
  hex_digits : int;  (** hex digits of a hex literal (its `_` not counted), else 0 *)
  exponent : string;  (** the exponent's digits without leading zeros ("" for none or zero) *)
}

let is_digit c = c >= '0' && c <= '9'
let is_hex c = is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
let is_bin c = c = '0' || c = '1'

(* A character that may not follow a number directly. *)
let is_follow c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit c || c = '_' || c = '.'

(* Digits converted from base 16 or 2 to decimal (big integers, base 10^9 limbs). *)
let to_decimal base (digits : string) =
  let limb = 1_000_000_000 in
  let limbs = ref [| 0 |] in
  let n = ref 1 in
  String.iter
    (fun c ->
      let d =
        if is_digit c then Char.code c - 48
        else if c >= 'a' then Char.code c - 87
        else Char.code c - 55
      in
      let carry = ref d in
      let a = !limbs in
      for i = 0 to !n - 1 do
        let x = (a.(i) * base) + !carry in
        a.(i) <- x mod limb;
        carry := x / limb
      done;
      if !carry > 0 then begin
        if !n = Array.length a then begin
          let b = Array.make (2 * !n) 0 in
          Array.blit a 0 b 0 !n;
          limbs := b
        end;
        !limbs.(!n) <- !carry;
        incr n
      end)
    digits;
  let b = Buffer.create (!n * 9) in
  Buffer.add_string b (string_of_int !limbs.(!n - 1));
  for i = !n - 2 downto 0 do
    Buffer.add_string b (Printf.sprintf "%09d" !limbs.(i))
  done;
  Buffer.contents b

(* Scans a literal at [i] of [s], reading before [stop]. [None] when the text
   there is no number literal (`invalid-number`). *)
let scan (s : string) (i : int) (stop : int) : literal option =
  let at j = if j < stop then s.[j] else '\000' in
  let has j = j < stop in
  (* [d] ("_"? [d])*: returns the end and the digits without `_` *)
  let run ok j =
    if not (has j && ok s.[j]) then None
    else begin
      let b = Buffer.create 16 in
      Buffer.add_char b s.[j];
      let j = ref (j + 1) in
      let continue = ref true in
      while !continue do
        if has !j && ok s.[!j] then (Buffer.add_char b s.[!j]; incr j)
        else if has !j && s.[!j] = '_' && has (!j + 1) && ok s.[!j + 1] then (
          Buffer.add_char b s.[!j + 1];
          j := !j + 2)
        else continue := false
      done;
      Some (!j, Buffer.contents b)
    end
  in
  let neg = has i && s.[i] = '-' in
  let j = if neg then i + 1 else i in
  let sign = if neg then "-" else "" in
  let finish j lit = if has j && is_follow s.[j] then None else Some { lit with stop = j } in
  if not (has j && is_digit s.[j]) then None
  else if s.[j] = '0' && (at (j + 1) = 'x' || at (j + 1) = 'b') then begin
    let hex = at (j + 1) = 'x' in
    match run (if hex then is_hex else is_bin) (j + 2) with
    | None -> None
    | Some (k, digits) ->
        let dec = to_decimal (if hex then 16 else 2) digits in
        finish k
          {
            stop = k;
            normalized = sign ^ dec;
            hex_digits = (if hex then String.length digits else 0);
            exponent = "";
          }
  end
  else begin
    let int_part =
      if s.[j] = '0' then Some (j + 1, "0")
      else match run is_digit j with None -> None | Some r -> Some r
    in
    match int_part with
    | None -> None
    | Some (k, int_digits) -> (
        let frac =
          if at k = '.' then match run is_digit (k + 1) with None -> None | Some (k2, d) -> Some (k2, "." ^ d)
          else Some (k, "")
        in
        match frac with
        | None -> None
        | Some (k, frac_digits) -> (
            let exp =
              if at k = 'e' || at k = 'E' then
                let k1 = k + 1 in
                let esign, k1 =
                  if at k1 = '+' then ("", k1 + 1) else if at k1 = '-' then ("-", k1 + 1) else ("", k1)
                in
                match run is_digit k1 with
                | None -> None
                | Some (k2, d) ->
                    let z = ref 0 in
                    while !z < String.length d && d.[!z] = '0' do incr z done;
                    let d = String.sub d !z (String.length d - !z) in
                    if d = "" then Some (k2, "e0", "") else Some (k2, "e" ^ esign ^ d, d)
              else Some (k, "", "")
            in
            match exp with
            | None -> None
            | Some (k, exp_text, exp_digits) ->
                finish k
                  {
                    stop = k;
                    normalized = sign ^ int_digits ^ frac_digits ^ exp_text;
                    hex_digits = 0;
                    exponent = exp_digits;
                  }))
  end

(* Whether exponent digits (no leading zeros) exceed [max]. *)
let exponent_exceeds digits max =
  let m = string_of_int max in
  String.length digits > String.length m
  || (String.length digits = String.length m && String.compare digits m > 0)

(* The normalized literal of a number built from [text], or [None] if [text]
   isn't a literal. *)
let normalize text =
  match scan text 0 (String.length text) with
  | Some l when l.stop = String.length text -> Some l.normalized
  | _ -> None

(* The exponent digits of a normalized literal ("" when it has none). *)
let exponent_of_normalized n =
  match String.index_opt n 'e' with
  | None -> ""
  | Some i ->
      let d = String.sub n (i + 1) (String.length n - i - 1) in
      let d = if String.length d > 0 && d.[0] = '-' then String.sub d 1 (String.length d - 1) else d in
      if d = "0" then "" else d
