(** Host side of the walk kernel (gen/gen_walk.ml): tables, per-thread
    state, launch of one chunk and its prefilter hits.

    Offset [j] stands for the point [P0 + j G]. A chunk is [threads * batch]
    consecutive offsets (2^20 in the product); thread [t] handles offsets
    [t * batch .. (t + 1) * batch - 1] of the chunk, starting from the base
    point [P0 + (c * size + t * batch) G] of chunk [c]. *)

type kernel
(** A curve with its field description and generated walk kernel. *)

val secp256k1 : kernel

type t

val create :
  ?cap:int ->
  Device_search.device ->
  kernel ->
  Target.t ->
  threads:int ->
  batch:int ->
  p0:Curve_ref.point ->
  chunk:int ->
  t
(** Builds the tables and the state of [chunk]. [cap] is the hit-buffer
    capacity (default: four times the expected number of hits per chunk,
    between 1024 and 2^20). The target must be of the kind the kernel hashes
    (tz2). Raises [Invalid_argument] on a non-positive parameter or a base
    point at infinity. *)

val chunk : t -> int

val chunk_size : t -> int
(** [threads * batch]. *)

val run : ?cap:int -> t -> int list
(** Launches the current chunk and returns the offsets within the chunk
    (sorted, without duplicates) whose point passes the prefilter. [cap]
    lowers the hit-buffer capacity (to exercise the re-run); when a launch
    overflows, its threads are re-run in halves. Does not change the state:
    it can be called again. Fails if a single thread overflows. *)

val next_state : t -> (Z.t * Z.t) array
(** Affine base points the last {!run} computed for chunk [chunk + 1], one
    per thread. *)

val state : t -> (Z.t * Z.t) array
(** Current base points of the chunk. *)

val advance : t -> unit
(** After a successful {!run}: the next state becomes the current one and the
    chunk number increases. *)
