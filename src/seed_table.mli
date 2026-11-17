(** The fixed-base table of the tz1 kernel (gen/gen_ed25519.ml), built from
    the Ed25519 constants of {!Curve_ref}.

    For window [i] (of [window_bits] bits of the scalar) and digit [d] in
    [0, 2^window_bits), the entry is the point [d * 2^(window_bits * i) B]
    as the three field elements [y + x], [y - x] and [2 d x y], each in
    Montgomery form on 10 limbs of 28 bits: 30 int64 at
    [((i * 2^window_bits) + d) * 30]. Digit 0 is the neutral element [(1, 1,
    0)]. The table has 256 / window_bits windows. *)

val window_bits : int
(** 8: 32 windows of 256 entries, 245 760 int64 (1.9 MB). *)

val entry_size : int
(** 30. *)

val windows : window_bits:int -> int

val build : window_bits:int -> (int64, Bigarray.int64_elt) Spoc_core.Vector.t
(** Takes under a second. *)
