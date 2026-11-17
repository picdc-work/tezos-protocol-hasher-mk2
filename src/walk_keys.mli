(** Key arithmetic of the address search: the base scalar [k0], the key of
    an offset, and the host confirmation of a device hit.

    Offset [j] stands for the key [k0 + j mod n] and the point
    [P0 + j G] with [P0 = k0 G]. Nothing here prints or raises with secret
    bytes. *)

val curve_of : Address.scheme -> (Curve_ref.curve, string) result
(** [Ok] for the schemes with a walk kernel (tz2). *)

val random_scalar : Curve_ref.curve -> Z.t
(** 32 bytes of [/dev/urandom], redrawn until [1 <= k < n]. Raises
    [Failure] if the device cannot be read (the message has no secret). *)

val scalar_of_bytes : string -> Z.t
(** Big-endian. *)

val scalar_to_bytes : Z.t -> string
(** 32 bytes, big-endian. The scalar must be below 2^256. *)

val key_of_offset : Curve_ref.curve -> k0:Z.t -> int64 -> Z.t
(** [(k0 + j) mod n], [j] read as an unsigned 64-bit offset. *)

val confirm :
  Address.scheme -> Curve_ref.curve -> Target.t -> k0:Z.t -> int64 -> (string * string) option
(** [Some (address, secret)] when the key of the offset is non-zero and its
    address matches the target ([secret] is the 32-byte scalar). [None] for
    a miss, and for the offset whose key would be 0. *)
