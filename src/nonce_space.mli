(** The space of 16-digit nonces, split into chunks of 10^8. *)

val chunk_size : int
(** 10^8 nonces: one launch with the 8 launch digits fixed. *)

val n_chunks : int
(** 10^8 chunks. *)

val text : int64 -> string
(** Exactly 16 decimal digits, zero-padded. *)

val chunk : int64 -> int
(** [value / 10^8]: the launch digits. *)

val thread : int64 -> int
(** [(value / 100) mod 10^6]: the thread digits. *)

val loop : int64 -> int
(** [value mod 100]: the loop digits. *)

val make : chunk:int -> thread:int -> loop:int -> int64

val start_of_seed : int -> int
(** Deterministic starting chunk for a seed, in [\[0, 10^8)]. *)

type range = {first_chunk : int; count : int}

val full : first_chunk:int -> range
(** The whole space, starting at [first_chunk]. *)

val chunks : range -> int Seq.t
(** Chunks in increasing order, modulo 10^8. *)

val nth_chunk : range -> int -> int
(** [nth_chunk r i] = the [i]-th chunk of [r] (modulo 10^8). *)

val slice : range -> instance:int -> of_:int -> range
(** Contiguous slice [instance] of [of_]; slices are pairwise disjoint and
    cover the range exactly. *)

val resume : range -> next_chunk:int -> range
(** The part of [range] from [next_chunk] (which must be in the range, or
    the chunk right after it) to its end. *)

val parse_instance : string -> (int * int, string) result
(** ["I/N"] with [0 <= I < N]. *)
