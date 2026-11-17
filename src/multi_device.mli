(** Several devices: one worker process per device (research R7), each
    searching its own slice of the range. *)

val run :
  ?slice:(Nonce_space.range -> instance:int -> of_:int -> Nonce_space.range) ->
  ?slices:bool ->
  exe:string ->
  common_args:string list ->
  devices:(int * Device_search.device) list ->
  range:Nonce_space.range ->
  max_matches:int option ->
  unit ->
  int
(** Starts [exe common_args --device <i> --start <first> --count <count>]
    per device; forwards match lines to stdout (stopping everything after
    [max_matches] lines), prefixes worker diagnostics with [device=<i>],
    prints one [stopped device=<i> slice=<first>+<count> ...] line per
    device and a total [stopped ...] line; returns the exit code.

    [slice] splits the range (default {!Nonce_space.slice}; the address search
    passes {!Offset_space.slice}). With [~slices:false] (an address search
    without a base-key file, where a range means nothing) the children get no
    [--start] and [--count], and the [stopped device=<i>] lines have no
    [slice=]. *)
