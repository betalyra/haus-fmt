(* The syntax tree a document is parsed to: its values with their source
   spellings, and the comments, line breaks and commas between tokens, which
   the formatter (spec §11) lays out. *)

(* What stands between two tokens: line breaks, comments (their text as
   written, CR LF read as LF) and a separating comma. Spaces and tabs are not
   kept. *)
type trivia = Nl | Comment of string | Comma

type node =
  | Scalar of Value.t * spelling
  | Arr of items
  | Rec of fields
  | Tag of string
  | Args of string * items  (** Tag( … ) *)
  | Payload of string * fields  (** Tag { … } *)

and spelling =
  | Source of string  (** a number, `"…"` string or byte string as written *)
  | Block  (** a block string, written from its value *)
  | Generated  (** no source text: written from the value *)

(* The entries of a container (or of a file): the trivia after the opening
   bracket, then each entry with the trivia that follows it (up to the next
   entry or the closer, a comma included). *)
and items = { lead : trivia list; items : (node * trivia list) list }
and fields = { flead : trivia list; fields : (field * trivia list) list }

and field = {
  key : string;
  before_colon : trivia list;
  after_colon : trivia list;
  value : node;
}

let rec value (n : node) : Value.t =
  match n with
  | Scalar (v, _) -> v
  | Arr { items; _ } -> Value.Unsafe.array (List.map (fun (n, _) -> value n) items)
  | Rec { fields; _ } -> Value.Unsafe.record (List.map (fun (f, _) -> (f.key, value f.value)) fields)
  | Tag t -> Value.Unsafe.variant t []
  | Args (t, { items; _ }) -> Value.Unsafe.variant t (List.map (fun (n, _) -> value n) items)
  | Payload (t, f) -> Value.Unsafe.variant t [ value (Rec f) ]

(* A tree for a value built in code: no comments, every scalar written from
   its value. *)
let rec of_value (v : Value.t) : node =
  match v with
  | Value.Number _ | Value.String _ | Value.Bytes _ -> Scalar (v, Generated)
  | Value.Array xs -> Arr { lead = []; items = List.map (fun x -> (of_value x, [])) xs }
  | Value.Record fs -> Rec (fields_of fs)
  | Value.Variant (t, []) -> Tag t
  | Value.Variant (t, [ Value.Record fs ]) -> Payload (t, fields_of fs)
  | Value.Variant (t, args) -> Args (t, { lead = []; items = List.map (fun x -> (of_value x, [])) args })

and fields_of fs =
  {
    flead = [];
    fields =
      List.map (fun (k, x) -> ({ key = k; before_colon = []; after_colon = []; value = of_value x }, [])) fs;
  }
