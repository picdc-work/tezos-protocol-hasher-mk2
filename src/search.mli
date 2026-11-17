(** The search driver: walks a range of chunks on one device, confirms
    hits on the host, prints matches, handles stop conditions. *)

type stop_reason = Completed | Max_matches | Timeout | Interrupted | Device_error

val reason_name : stop_reason -> string

type outcome = {
  reason : stop_reason;
  next_chunk : int;  (** first chunk not fully covered *)
  tested : int;  (** nonces tested in fully covered chunks *)
  matches : int;
}

val exit_code : stop_reason -> int
(** 0, 3 (device error) or 130 (interrupted). *)

val install_signal_handlers : unit -> unit
(** SIGINT and SIGTERM set a flag checked between launches. *)

val run :
  ?max_matches:int ->
  ?timeout:float ->
  ?progress:float ->
  ?label:string ->
  dump:Dump.t ->
  target:Target.t ->
  device:Device_search.device ->
  range:Nonce_space.range ->
  out:out_channel ->
  err:out_channel ->
  unit ->
  outcome
(** Prints the start-up summary, the matches (flushed one by one on [out]),
    optional progress records, and the final [stopped ...] line (prefixed
    by [label] if given) on [err]. *)
