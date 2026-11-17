(** Several devices: one worker process per device (research R7), each
    searching its own slice of the range. *)

val run :
  exe:string ->
  common_args:string list ->
  devices:(int * Device_search.device) list ->
  range:Nonce_space.range ->
  max_matches:int option ->
  int
(** Starts [exe common_args --device <i> --start <first> --count <count>]
    per device; forwards match lines to stdout (stopping everything after
    [max_matches] lines), prefixes worker diagnostics with [device=<i>],
    prints one [stopped device=<i> slice=<first>+<count> ...] line per
    device and a total [stopped ...] line; returns the exit code. *)
