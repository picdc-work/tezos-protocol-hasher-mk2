(* The walk kernel for P-256 (tz3) against the host reference. *)

include Walk_check.Make (struct
  let scheme = Octez_vanity.Address.Tz3
  let curve = Octez_vanity.Curve_ref.p256
  let kernel = Octez_vanity.Walk_run.p256
  let suite = "walk_tz3"
end)

let () = run ()
