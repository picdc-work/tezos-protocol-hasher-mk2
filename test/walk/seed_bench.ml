(* Throughput of the tz1 seed-search kernel on the Native backend: one launch
   per (threads, batch), the second of two (the first includes the table
   upload), and the time to build the table.
     dune exec test/walk/seed_bench.exe *)

open Octez_vanity

let target =
  match Target.make ~kind:(Address.target_kind Address.Tz1) "abc" with
  | Ok t -> t
  | Error e -> failwith e

let base = String.init 32 (fun i -> Char.chr ((i * 29 + 3) land 255))

let measure (threads, batch) =
  let t0 = Unix.gettimeofday () in
  let runner = Seed_run.create (Device_search.cpu_device ()) target ~base ~threads ~batch in
  let setup = Unix.gettimeofday () -. t0 in
  ignore (Seed_run.run runner ~start:0L) ;
  let start = Unix.gettimeofday () in
  let hits = Seed_run.run runner ~start:0L in
  let elapsed = Unix.gettimeofday () -. start in
  let size = Seed_run.launch_size runner in
  Printf.printf "threads=%d batch=%d seeds=%d hits=%d setup=%.2fs time=%.2fs rate=%.0f seeds/s\n%!"
    threads batch size (List.length hits) setup elapsed (float size /. elapsed)

let () =
  List.iter measure
    [(4096, 4); (4096, 8); (4096, 16); (8192, 4); (8192, 8); (8192, 16); (16384, 4); (16384, 8); (16384, 16); (32768, 8)]
