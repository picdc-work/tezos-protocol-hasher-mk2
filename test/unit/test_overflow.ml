(* Research R9: a launch whose hit buffer overflows is re-run in halves;
   forcing a tiny capacity must give exactly the same hits. *)
open Octez_vanity

let synthetic () =
  let line = "(* Vanity nonce: 0000000000000000 *)\n" in
  let st = Random.State.make [|46; 1|] in
  let body = 4096 + 46 - String.length line in
  let path = Filename.temp_file "overflow" ".dump" in
  let oc = open_out_bin path in
  output_string oc (String.init body (fun _ -> Char.chr (32 + Random.State.int st 90)) ^ line) ;
  close_out oc ;
  match Dump.load path with Ok d -> d | Error e -> Alcotest.fail e

let forced_subdivision () =
  let dump = synthetic () in
  let target = match Target.make "p" with Ok t -> t | Error e -> Alcotest.fail e in
  let ctx = Device_search.prepare (Device_search.cpu_device ()) dump target in
  let normal = Device_search.run_chunk ~nthreads:10_000 ctx ~chunk:31 in
  let forced = Device_search.run_chunk ~nthreads:10_000 ~cap:64 ctx ~chunk:31 in
  Alcotest.(check bool) "many hits" true (List.length normal > 64 * 10) ;
  Alcotest.(check (list int64)) "same hits with cap 64" normal forced

let tests = ("overflow", [Alcotest.test_case "forced sub-launches" `Quick forced_subdivision])
