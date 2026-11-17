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
