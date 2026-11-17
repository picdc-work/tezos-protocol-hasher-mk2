(** The address search driver: walks a range of chunks of offsets on one
    device (see {!Walk_run}), confirms every device hit on the host, writes
    the key file of each match and prints its address.

    The base scalar [k0] never leaves this process: the device sees public
    points only. Nothing secret is printed, logged or put in an error
    message. *)

type reason = Stopped of Search.stop_reason | Key_file_error
    (** [Key_file_error]: a key file could not be created, for instance
        because it exists. *)

val reason_name : reason -> string
(** The names of {!Search.reason_name}, and ["key-file-error"]. *)

val exit_code : reason -> int
(** {!Search.exit_code}, and 4 for [Key_file_error]. *)

type outcome = {reason : reason; next_chunk : int; tested : int; matches : int}

val default_threads : int
(** 4096. *)

val default_batch : int
(** 256 (threads times batch is the chunk size, 2^20). *)

val run :
  ?max_matches:int ->
  ?timeout:float ->
  ?progress:float ->
  ?label:string ->
  ?threads:int ->
  ?batch:int ->
  scheme:Address.scheme ->
  target:Target.t ->
  device:Device_search.device ->
  k0:Z.t ->
  range:Offset_space.range ->
  key_dir:string ->
  out:out_channel ->
  err:out_channel ->
  unit ->
  outcome
(** Prints the start-up summary, the matches (one line
    [<address> <key file path>], flushed one by one on [out]), optional
    progress records and the final [stopped ...] line on [err], in the
    format of {!Search.run}. [threads * batch] must be {!Offset_space.chunk_size}.
    The range is walked in order from its first chunk; after
    [reason=max-matches] the chunk in progress is searched again on resume
    and may produce matches already written (their key files then exist: the
    resumed run stops with [Key_file_error]). *)
