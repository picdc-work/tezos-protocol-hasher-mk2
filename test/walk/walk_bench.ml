(* Throughput of the walk kernel on the Native backend (tz2 by default; pass
   tz3 or tz4 as the argument): one full chunk of 2^20 offsets per
   (threads, batch), table and state preparation excluded. *)

open Octez_vanity

let scheme =
  match Sys.argv with
  | [|_; "tz3"|] -> Address.Tz3
  | [|_; "tz4"|] -> Address.Tz4
  | _ -> Address.Tz2

let curve = match Walk_keys.curve_of scheme with Ok c -> c | Error e -> failwith e

let kernel = match Walk_run.kernel_of scheme with Ok k -> k | Error e -> failwith e

let p0 = Curve_ref.scalar_mul curve (Z.of_int 123456789) (Curve_ref.generator curve)

let target =
  match Target.make ~kind:(Address.target_kind scheme) "abc" with
  | Ok t -> t
  | Error e -> failwith e

let measure (threads, batch) =
  let w =
    Walk_run.create (Device_search.cpu_device ()) kernel target ~threads ~batch ~p0
      ~chunk:0
  in
  let start = Unix.gettimeofday () in
  let hits = Walk_run.run w in
  let elapsed = Unix.gettimeofday () -. start in
  Printf.printf "threads=%d batch=%d offsets=%d hits=%d time=%.2fs rate=%.0f keys/s\n%!" threads
    batch (threads * batch) (List.length hits) elapsed
    (float (threads * batch) /. elapsed)

let () =
  List.iter measure
    [(256, 4096); (1024, 1024); (2048, 512); (4096, 256); (8192, 128); (16384, 64); (65536, 16)]
