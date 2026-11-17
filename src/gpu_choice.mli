(** Choosing GPUs: CUDA/PTX before CUDA/C before HIP, and discrete GPUs
    before integrated ones (APUs sharing host memory, such as the GPU of a
    Ryzen CPU, are much slower and would hold back a multi-device search,
    whose slices are equal). Pure, so that it can be tested without devices. *)

type 'a candidate = {item : 'a; framework : string; integrated : bool}

val preference : string list
(** ["CUDA/PTX"; "CUDA/C"; "HIP"]. *)

val best : 'a candidate list -> 'a candidate option
(** First discrete GPU in framework preference order, else the first
    integrated one; [None] without GPU. *)

val first_of_framework : string -> 'a candidate list -> 'a candidate option
(** First discrete device of that framework, else its first device. *)

val all_gpus : 'a candidate list -> 'a candidate list
(** CUDA/PTX and HIP devices (CUDA/C aliases would search a CUDA GPU
    twice), discrete only, unless every such device is integrated. In list
    order. *)
