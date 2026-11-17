(** Host Blake2b-256 (no key), with access to the chaining value. *)

val iv : int64 array

val init : unit -> int64 array
(** Fresh chaining value for a 32-byte digest (IV with [h0 ^= 0x01010020]). *)

val compress : int64 array -> int64 array -> t0:int64 -> last:bool -> unit
(** [compress h m ~t0 ~last] compresses the 16-word block [m] into [h] in
    place; [t0] is the byte counter after this block. *)

val words_of_block : Bytes.t -> int -> int -> int64 array
(** [words_of_block b off len]: little-endian words of [len <= 128] bytes,
    zero-padded to 128 bytes. *)

val digest_of_state : int64 array -> string
(** The 32-byte digest of a final chaining value. *)

val digest : string -> string
