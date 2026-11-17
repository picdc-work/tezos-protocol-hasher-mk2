(** Seeds of the tz1 search: the base, the seed of an offset and the host
    confirmation of a device hit.

    A base is 32 bytes. The seed of offset [j] is the first 24 bytes of the
    base followed by the 64-bit big-endian value [u + j mod 2^64], [u] being
    the last 8 bytes of the base read big-endian. Every 32-byte value is a
    valid base. Nothing here prints or raises with secret bytes. *)

val base_length : int
(** 32. *)

val random_base : unit -> string
(** 32 bytes of [/dev/urandom]. Raises [Failure] if the device cannot be read
    (the message has no secret). *)

val prefix_words : string -> int64 array
(** The first 24 bytes of a base as three big-endian 64-bit words: the first
    three words of the SHA-512 block of every seed. *)

val counter : string -> int64
(** [u], the last 8 bytes of the base read big-endian (as an [int64]: the
    wrap-around of the sum is the one modulo 2^64). *)

val counter_of_offset : base:string -> int64 -> int64
(** [u + j mod 2^64]: the fourth word of the SHA-512 block of the seed of
    offset [j] (read as an unsigned 64-bit offset). *)

val seed_of_offset : base:string -> int64 -> string
(** The 32-byte seed of offset [j]. *)

val confirm : Target.t -> base:string -> int64 -> (string * string) option
(** [Some (address, seed)] when the Ed25519 address of the seed of the offset
    matches the target (derived with [Curve_ref.address Tz1]); [None]
    otherwise. *)
