(** The address search driver: walks a range of chunks of offsets on one
    device through an {!engine}, confirms every device hit on the host, writes
    the key file of each match and prints its address.

    For the walk schemes (tz2, tz3, tz4) the base scalar [k0] never leaves
    this process: the device sees public points only. For tz1 the device
    receives the base (see {!Seed_run}): it computes every candidate seed.
    Nothing secret is printed, logged or put in an error message. *)

type reason = Stopped of Search.stop_reason | Key_file_error
    (** [Key_file_error]: a key file could not be created, for instance
        because it exists. *)

val reason_name : reason -> string
(** The names of {!Search.reason_name}, and ["key-file-error"]. *)

val exit_code : reason -> int
(** {!Search.exit_code}, and 4 for [Key_file_error]. *)

type outcome = {reason : reason; next_chunk : int; tested : int; matches : int}

type engine = {
  describe : string;  (** The text of the [kernel:] start-up line. *)
  run_chunk : chunk:int -> stop:(unit -> bool) -> on_hits:(int list -> unit) -> int;
      (** Searches a chunk, as one or several launches. [stop ()] is called
          before each launch (it checks the interrupt flag and the timeout,
          and says whether the search is already stopping, for instance
          after [--max-matches]); when it answers true the chunk is
          abandoned. [on_hits] receives, after each launch, the indices
          within the chunk that pass the prefilter. Returns the number of
          offsets searched: {!Offset_space.chunk_size} when the whole chunk
          was, which is the only case where the chunk counts as covered. *)
  confirm : int64 -> (string * string) option;
      (** Host confirmation of an offset: [Some (address, secret)] when it
          matches the target. The secret is what {!Address.secret_key}
          encodes. *)
}
(** A way of enumerating candidates on a device. The walk of tz2, tz3 and
    tz4 and the seed enumeration of tz1 are two engines. *)

type base =
  | Scalar of Z.t  (** the base scalar [k0] of the walk schemes *)
  | Seed_base of string  (** the 32-byte base of tz1 *)

val default_threads : int
(** 4096: threads of a walk launch. *)

val default_batch : int
(** 256 (threads times batch is the chunk size, 2^20). *)

val default_seed_threads : int
(** 4096. *)

val default_seed_batch : int
(** 16: a tz1 launch is 2^16 seeds, a chunk 16 launches (measured on the
    Native backend, see the README). *)

val make_engine :
  ?threads:int ->
  ?batch:int ->
  scheme:Address.scheme ->
  target:Target.t ->
  device:Device_search.device ->
  base ->
  engine
(** The engine of a scheme: the walk for tz2, tz3, tz4 (base [Scalar]; the
    chunk size must be [threads * batch]), the seed enumeration for tz1 (base
    [Seed_base]; [threads * batch] must divide the chunk size). Nothing is
    built on the device before the first chunk. Raises [Invalid_argument] for
    a base of the wrong kind or a bad geometry. *)

val run :
  ?max_matches:int ->
  ?timeout:float ->
  ?progress:float ->
  ?label:string ->
  scheme:Address.scheme ->
  target:Target.t ->
  device:Device_search.device ->
  engine:engine ->
  range:Offset_space.range ->
  key_dir:string ->
  out:out_channel ->
  err:out_channel ->
  unit ->
  outcome
(** Prints the start-up summary, the matches (one line
    [<address> <key file path>], flushed one by one on [out]), optional
    progress records and the final [stopped ...] line on [err], in the
    format of {!Search.run}. The range is walked in order from its first
    chunk; after [reason=max-matches] the chunk in progress is searched again
    on resume and may produce matches already written (their key files then
    exist: the resumed run stops with [Key_file_error]). *)
