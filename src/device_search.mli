(** Running the search kernels on one Sarek device. *)

type device = Spoc_core.Device.t

val devices : unit -> device array
(** Every device of the registered backends (Native, CUDA/PTX, CUDA/C, HIP),
    enumerated once. *)

val best_gpu : unit -> (device, string) result
(** First CUDA/PTX device, else first CUDA/C device, else first HIP device. *)

val cpu_device : unit -> device
(** The Native (CPU, OCaml domains) device. *)

val framework : device -> string

val name : device -> string

type ctx

type mode =
  | Kernel_a  (** case A *)
  | Host_penultimate
      (** case B, thread digits in the final block: the host compresses the
          next-to-last block once per chunk, then kernel A *)
  | Kernel_b  (** case B, thread digits in the next-to-last block *)
  | Kernel_c  (** case C *)

val prepare : device -> Dump.t -> Target.t -> ctx
(** Builds the device-side constants once (thread-digit patch tables,
    intervals, chaining value). *)

val mode : ctx -> mode

val mode_name : mode -> string

val device : ctx -> device

val default_cap : ctx -> int

val run_chunk : ?nthreads:int -> ?cap:int -> ctx -> chunk:int -> int64 list
(** Nonces of [chunk] (thread digits [0, nthreads), default 10^6, i.e. the
    whole chunk) whose top64 falls in the target's intervals. A launch whose
    hit buffer overflows is re-run in halves, so no hit is dropped. [cap]
    (tests only) lowers the hit-buffer capacity. The result is sorted. *)

val list_devices : unit -> (int * string * string) list
(** (index, framework, name) of every device. *)

val select : string -> ((int * device) list, string) result
(** A device index, a framework name ([CUDA/PTX], [CUDA/C], [HIP], [Native]:
    its first device) or [all-gpus] (every CUDA/PTX and HIP device).
    CUDA/C aliases are omitted to avoid searching a CUDA GPU twice. *)

val is_gpu : device -> bool
