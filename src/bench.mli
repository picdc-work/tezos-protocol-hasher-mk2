(** [--bench]: search throughput per device. *)

val run :
  dump:Dump.t -> seconds:float -> Device_search.device list -> (string * string * float) list
(** For each device: (framework, name, nonces per second), measured over
    consecutive whole chunks for about [seconds] after one warm-up launch,
    with a 9-character target so that the filter cost is realistic. *)
