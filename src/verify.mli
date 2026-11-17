(** [--verify]: the protocol hash of a dump with a given nonce, computed
    with digestif over the full dump (independent of the search path). *)

val hash : Dump.t -> string -> (string, string) result
(** The nonce must be exactly 16 decimal digits. *)
