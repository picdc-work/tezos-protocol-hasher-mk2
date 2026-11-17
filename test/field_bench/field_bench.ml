(* field_bench.exe [COUNT]: Native throughput of the generated kernels.

   mul: COUNT Montgomery products in one launch (one per thread), best of 5
   launches, operand packing excluded. inv: 1000 inversions per launch. *)

open Octez_vanity

let count = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 1_000_000

let best_of runs f =
  let best = ref infinity in
  for _ = 1 to runs do
    let t = Unix.gettimeofday () in
    f () ;
    best := Float.min !best (Unix.gettimeofday () -. t)
  done ;
  !best

let random_elements p n =
  let st = Random.State.make [|7|] in
  Array.init n (fun _ ->
      Z.erem (Z.of_bits (String.init 56 (fun _ -> Char.chr (Random.State.int st 256)))) p)

let bench_mul (spec : Field_run.spec) (k : Field_set.kernels) =
  let xs = Field_run.pack spec (random_elements spec.prime count) in
  let ys = Field_run.pack spec (random_elements spec.prime count) in
  let out = Spoc_core.Vector.create Spoc_core.Vector.int64 (count * spec.n) in
  let args =
    Sarek.Execute.[Vec xs; Vec ys; Vec out; Int32 (Int32.of_int count)]
  in
  let t = best_of 5 (fun () -> Field_run.launch ~ir:k.mul args ~count) in
  Printf.printf "%-10s mul  %d products in %.3f s: %.2f M mul/s\n%!" spec.name count t
    (float count /. t /. 1e6)

let bench_inv (spec : Field_run.spec) (k : Field_set.kernels) =
  let n = 1000 in
  let xs = random_elements spec.prime n in
  let t = best_of 3 (fun () -> ignore (Field_run.inverse spec ~ir:k.inv xs)) in
  Printf.printf "%-10s inv  %d inversions in %.3f s: %.0f inv/s\n%!" spec.name n t (float n /. t)

let () =
  Printf.printf "Native devices: %s\n%!" (Device_search.name (Device_search.cpu_device ())) ;
  List.iter (fun (spec, k) -> bench_mul spec k ; bench_inv spec k) Field_set.all
