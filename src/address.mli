(** Tezos tz1..tz4 addresses and secret-key encodings.

    An address is base58check of [prefix ‖ Blake2b-20(public key)]; a secret
    key is base58check of [prefix ‖ 32 bytes]. Encoders check lengths only:
    that a point is on the curve or a scalar in range is the business of
    [Curve_ref]. No error message contains secret bytes. *)

type scheme =
  | Tz1  (** Ed25519 *)
  | Tz2  (** secp256k1 *)
  | Tz3  (** P-256 *)
  | Tz4  (** BLS12-381, minimal public key variant *)

val schemes : scheme list

val name : scheme -> string
(** ["tz1"] .. ["tz4"]. *)

val public_key_length : scheme -> int
(** Bytes hashed to form the address: 32, 33, 33, 48. *)

val secret_length : int
(** 32 for every scheme. *)

val address_of_digest : scheme -> string -> string
(** [address_of_digest s d] for a 20-byte digest [d]: 36 characters starting
    with [name s]. Raises [Invalid_argument] on another length. *)

val address : scheme -> string -> (string, string) result
(** Address of public key bytes. [Error] names the expected length. *)

val secret_key : scheme -> string -> (string, string) result
(** Octez form of a 32-byte secret ([edsk], [spsk], [p2sk], [BLsk], 54
    characters). [Error] names the expected length and never repeats the
    input. *)

val target_kind : scheme -> Target.kind
(** The target kind of the scheme's addresses: fixed text [name s], no free
    character, 3-byte prefix, 20-byte digest, names of 1 to 8 characters. *)
