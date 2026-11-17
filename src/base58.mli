(** Base58check encoding (bitcoin alphabet), shared by protocol hashes,
    addresses and secret keys. Encoding only: nothing here decodes. *)

val alphabet : string

val encode_z : Z.t -> string
(** Plain base58 of a non-negative integer; [""] for zero. *)

val check_encode : string -> string
(** [check_encode payload] is the base58 form of
    [payload ‖ first 4 bytes of SHA-256(SHA-256 payload)]. Raises
    [Invalid_argument] if [payload] starts with a zero byte, because leading
    zero bytes would need leading ['1'] characters; no prefix used by this
    library starts with zero. *)

val z_of_be : string -> Z.t
(** Big-endian bytes as a non-negative integer. *)
