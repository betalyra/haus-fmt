(** haus values (spec §1). The type is private: values are built with the
    constructors below, which build only haus values (spec §11, "Values built
    in code"), or by the parser. *)

type t = private
  | Number of string  (** the normalized literal (spec §2) *)
  | String of string  (** UTF-8 *)
  | Bytes of string  (** the bytes *)
  | Array of t list
  | Record of (string * t) list  (** keys in the order given or written *)
  | Variant of string * t list  (** the tag and its arguments *)

val number : string -> t
(** A number from a literal in any spelling (`1E+05`, `0xFF`), normalized.
    Fails with `invalid-number` when the text isn't a literal. A literal past
    the limits is still a number: writers reject it. *)

val string : string -> t
(** Fails with `cannot-encode` when the text isn't UTF-8. *)

val bytes : string -> t
val array : t list -> t

val record : (string * t) list -> t
(** Fails with `duplicate-key`, or `cannot-encode` for a key that isn't UTF-8. *)

val variant : string -> t list -> t
(** Fails with `invalid-tag` for a tag that isn't [[A-Z][A-Za-z0-9_]*], a tag
    that isn't UTF-8 (a lone surrogate's bytes) included: the tag rule is
    checked before encoding. *)

val is_tag : string -> bool
val is_ident : string -> bool

(** Constructors without checks, for the parser, which has checked already. *)
module Unsafe : sig
  val number : string -> t
  val string : string -> t
  val bytes : string -> t
  val array : t list -> t
  val record : (string * t) list -> t
  val variant : string -> t list -> t
end
