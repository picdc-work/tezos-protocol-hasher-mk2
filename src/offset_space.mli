(** The space of key offsets of the address search: [0, 2^64), in chunks of
    2^20 offsets, so 2^44 chunks. Same shape as {!Nonce_space} (and the same
    range type, so that {!Multi_device} can split it), with other sizes. *)

val chunk_size : int
(** 2^20 offsets: one launch. *)

val n_chunks : int
(** 2^44. *)

type range = Nonce_space.range = {first_chunk : int; count : int}

val full : first_chunk:int -> range

val nth_chunk : range -> int -> int
(** [nth_chunk r i] = the [i]-th chunk of [r] (modulo 2^44). *)

val slice : range -> instance:int -> of_:int -> range
(** Contiguous slice [instance] of [of_]; slices are pairwise disjoint and
    cover the range exactly. *)

val offset : chunk:int -> index:int -> int64
(** Offset [chunk * 2^20 + index], below 2^64 (read it unsigned). *)
