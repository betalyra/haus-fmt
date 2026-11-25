(* The limits of spec §7. *)

type t = {
  max_depth : int;  (** nesting depth of records, arrays and payloads *)
  max_number_length : int;  (** characters in one number literal *)
  max_exponent : int;  (** absolute exponent *)
  max_string_length : int;  (** characters in a string, key, tag or byte string *)
  max_value_length : int;  (** characters in one top-level value of a stream *)
  max_nodes : int;  (** values written for one value built in code *)
}

(* The parser and the writers recurse once per level of nesting. OCaml 5 runs
   OCaml code on stacks that grow on demand (up to the runtime's limit, 1 GiB
   by default), on the main domain and on every other one alike, so the
   bound is chosen well below what that allows. *)
let max_supported_depth = 100_000

let default =
  {
    max_depth = 256;
    max_number_length = 1000;
    max_exponent = 6144;
    max_string_length = 16 * 1024 * 1024;
    max_value_length = 64 * 1024 * 1024;
    max_nodes = 64 * 1024 * 1024;
  }

(* The hex digit limit follows the number limit n: the largest h with
   16^h <= 10^(n-1) (spec §7). *)
let hex_digits t =
  let n = t.max_number_length in
  if n < 1 then 0
  else
    let h = int_of_float (Float.of_int (n - 1) /. Float.log10 16.) in
    (* guard against rounding at the boundary: h*log10(16) <= n-1 *)
    let fits h = Float.of_int h *. Float.log10 16. <= Float.of_int (n - 1) +. 1e-9 in
    let h = ref h in
    while not (fits !h) do decr h done;
    while fits (!h + 1) do incr h done;
    !h

let make ?(max_depth = default.max_depth) ?(max_number_length = default.max_number_length)
    ?(max_exponent = default.max_exponent) ?(max_string_length = default.max_string_length)
    ?(max_value_length = default.max_value_length) ?(max_nodes = default.max_nodes) () =
  if max_depth > max_supported_depth || max_depth < 0 then
    raise
      (Error.Haus_error
         {
           code = "unsupported-depth";
           message =
             Printf.sprintf "depth limit %d: this binding supports nesting depths from 0 to %d"
               max_depth max_supported_depth;
           place = Error.Nowhere;
         });
  if max_number_length < 0 || max_exponent < 0 || max_string_length < 0 || max_value_length < 0
     || max_nodes < 0
  then invalid_arg "Limits.make: a limit is a whole number of zero or more";
  { max_depth; max_number_length; max_exponent; max_string_length; max_value_length; max_nodes }
