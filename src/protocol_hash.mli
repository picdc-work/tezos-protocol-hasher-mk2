(** Tezos protocol hash: base58check of [0x02aa ‖ digest]. *)

val prefix : string
(** ["\002\170"]. *)

val alphabet : string
(** The bitcoin base58 alphabet. *)

val b58_encode_z : Z.t -> string

val of_digest : string -> string
(** [of_digest d] for a 32-byte Blake2b-256 digest: 51 characters. *)
