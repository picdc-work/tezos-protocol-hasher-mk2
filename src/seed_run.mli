(** Host side of the tz1 seed-search kernel (gen/gen_ed25519.ml): table,
    scratch vectors, launch of [threads * batch] consecutive seeds and its
    prefilter hits.

    Offset [j] stands for the seed {!Seed_keys.seed_of_offset} of the base.
    A launch starting at offset [start] covers the offsets
    [start .. start + threads * batch - 1]; thread [t] handles the [batch]
    offsets from [start + t * batch]. *)

type t

val create :
  ?cap:int ->
  Device_search.device ->
  Target.t ->
  base:string ->
  threads:int ->
  batch:int ->
  t
(** Builds the table (under a second) and the vectors. [cap] is the
    hit-buffer capacity (default: four times the expected number of hits per
    launch, between 1024 and 2^20). The target must be a tz1 target. Raises
    [Invalid_argument] on a non-positive parameter or a base that is not 32
    bytes. *)

val launch_size : t -> int
(** [threads * batch]. *)

val run : ?cap:int -> t -> start:int64 -> int list
(** Launches the seeds from offset [start] (read as an unsigned 64-bit
    offset, the counter wraps modulo 2^64) and returns the indices
    (sorted, without duplicates) within the launch whose key passes the
    prefilter. [cap] lowers the hit-buffer capacity (to exercise the
    re-run); when a launch overflows, its threads are re-run in halves. Fails
    if a single thread overflows. *)
