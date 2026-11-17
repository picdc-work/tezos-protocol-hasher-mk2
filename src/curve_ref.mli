(** Host reference: public key bytes and address from a secret, written with
    Zarith for Ed25519, secp256k1, P-256 and BLS12-381 (G1, minimal public
    key variant).

    This is a reference, not a signer: it is neither constant-time nor
    optimised, and must never be used to protect a key. It is checked in the
    tests against [mirage-crypto-ec], [secp256k1-internal] and [bls12-381],
    RFC 8032 and the Octez key encoding vectors. *)

val public_key : Address.scheme -> string -> (string, string) result
(** [public_key scheme secret] for the 32 bytes Octez stores for a key, the
    bytes Octez hashes into the address:
    - [Tz1]: RFC 8032 section 5.1.5 applied to the seed, 32 bytes;
    - [Tz2], [Tz3]: the scalar read big-endian, SEC1 compressed point, 33
      bytes;
    - [Tz4]: the scalar read little-endian, ZCash compressed G1 point, 48
      bytes.
    [Error] for a secret of the wrong length and, for [Tz2], [Tz3] and
    [Tz4], for a scalar that is zero or not below the group order (it is
    never reduced). No message contains secret bytes. *)

val address : Address.scheme -> string -> (string, string) result
(** [public_key] followed by {!Address.address}. *)

(** {1 Short Weierstrass interface}

    [y^2 = x^3 + a x + b] over [F_p], for secp256k1, P-256 and BLS12-381 G1.
    Not constant-time. *)

type curve = {p : Z.t; a : Z.t; b : Z.t; n : Z.t; gx : Z.t; gy : Z.t}
(** Field prime, curve coefficients, group order and generator. *)

type point = Infinity | Affine of Z.t * Z.t

val secp256k1 : curve

val p256 : curve

val bls12_381_g1 : curve

val generator : curve -> point

val add_points : curve -> point -> point -> point
(** Group law, doubling and the point at infinity included. *)

val scalar_mul : curve -> Z.t -> point -> point
(** [scalar_mul c k pt] for [k >= 0]. *)

val affine : point -> (Z.t * Z.t, string) result
(** Affine coordinates; [Error] for [Infinity]. *)
