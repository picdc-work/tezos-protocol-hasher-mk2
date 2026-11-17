(* The walk kernel for secp256k1 (tz2) against the host reference. *)

include Walk_check.Make (struct
  let scheme = Octez_vanity.Address.Tz2
  let curve = Octez_vanity.Curve_ref.secp256k1
  let kernel = Octez_vanity.Walk_run.secp256k1
  let suite = "walk_tz2"
end)

let () = run ()
