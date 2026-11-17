(* The walk kernel for BLS12-381 G1 (tz4) against the host reference. *)

include Walk_check.Make (struct
  let scheme = Octez_vanity.Address.Tz4
  let curve = Octez_vanity.Curve_ref.bls12_381_g1
  let kernel = Octez_vanity.Walk_run.bls12_381
  let suite = "walk_tz4"
end)

let () = run ()
