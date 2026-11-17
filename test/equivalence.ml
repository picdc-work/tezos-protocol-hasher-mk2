(* Device vs host reference on the same nonces.

   equivalence.exe [--target NAME] [--whole-chunks N] [--reference-chunk]

   Default check: for synthetic dumps of each layout (F = 46: case A,
   F = 15: case B with host next-to-last block, F = 9: case B kernel,
   F = 3: case C) and proto_to_hash.txt when present, run 10^6 nonces of a
   chunk on every available backend (Native, CUDA/PTX, CUDA/C) and compare
   the raw prefilter hits with the pure-OCaml reference; every hit must also
   satisfy the exact rule when re-hashed through digestif. *)

open Octez_vanity

let target_name = ref "pa"

let whole_chunks = ref 0

let reference_chunk = ref false

let failures = ref 0

let synthetic f =
  let line = "(* Vanity nonce: 0000000000000000 *)\n" in
  let st = Random.State.make [|f; 99|] in
  let body = 5 * 128 * 1024 + f - String.length line in
  let s = String.init body (fun _ -> Char.chr (32 + Random.State.int st 90)) ^ line in
  let path = Filename.temp_file (Printf.sprintf "equiv-F%d-" f) ".dump" in
  let oc = open_out_bin path in
  output_string oc s ;
  close_out oc ;
  path

let load path =
  match Dump.load path with Ok d -> d | Error e -> failwith e

let reference_hits dump target ~chunk ~nthreads =
  let acc = ref [] in
  for th = nthreads - 1 downto 0 do
    for lp = 99 downto 0 do
      let n = Nonce_space.make ~chunk ~thread:th ~loop:lp in
      if Target.in_intervals target (Target.top64 (Dump.digest dump n)) then
        acc := n :: !acc
    done
  done ;
  !acc

(* Reference over a whole chunk, split across domains. *)
let reference_chunk_hits dump target ~chunk =
  let nd = 16 in
  let per = 1_000_000 / nd in
  let doms =
    List.init nd (fun i ->
        Domain.spawn (fun () ->
            let acc = ref [] in
            for th = ((i + 1) * per) - 1 downto i * per do
              for lp = 99 downto 0 do
                let n = Nonce_space.make ~chunk ~thread:th ~loop:lp in
                if Target.in_intervals target (Target.top64 (Dump.digest dump n))
                then acc := n :: !acc
              done
            done ;
            !acc))
  in
  List.sort compare (List.concat_map Domain.join doms)

let report label ok =
  Printf.printf "%s %s\n%!" (if ok then "CHECK OK    " else "CHECK FAILED") label ;
  if not ok then incr failures

let exact_ok dump target hits =
  List.for_all
    (fun n -> Target.matches target (Protocol_hash.of_digest (Dump.digest_full dump n)))
    hits

let gpus () =
  List.filter
    (fun d -> List.mem (Device_search.framework d) ["CUDA/PTX"; "CUDA/C"])
    (Array.to_list (Device_search.devices ()))

let check_dump label path target =
  let dump = load path in
  let chunk = 12345678 and nthreads = 10_000 in
  let t = Unix.gettimeofday () in
  let expected = reference_hits dump target ~chunk ~nthreads in
  Printf.printf "%s: case %s, F=%d, reference %d hits in %.1fs\n%!" label
    (Dump.case_name dump.layout_case) dump.final_block_length (List.length expected)
    (Unix.gettimeofday () -. t) ;
  let devs = Device_search.cpu_device () :: gpus () in
  List.iter
    (fun dev ->
      let ctx = Device_search.prepare dev dump target in
      let got = Device_search.run_chunk ~nthreads ctx ~chunk in
      report
        (Printf.sprintf "%s on %s [%s]: %d hits" label (Device_search.framework dev)
           (Device_search.mode_name (Device_search.mode ctx)) (List.length got))
        (got = expected && exact_ok dump target got))
    devs

let check_whole_chunks path target n =
  match gpus () with
  | [] -> print_endline "SKIP whole-chunk check: no CUDA device"
  | gpu :: _ ->
      let dump = load path in
      let g = Device_search.prepare gpu dump target in
      let c = Device_search.prepare (Device_search.cpu_device ()) dump target in
      for i = 0 to n - 1 do
        let chunk = 4242 + i in
        let a = Device_search.run_chunk g ~chunk in
        let b = Device_search.run_chunk c ~chunk in
        report
          (Printf.sprintf "whole chunk %d: %s %d hits vs Native %d hits" chunk
             (Device_search.framework gpu) (List.length a) (List.length b))
          (a = b)
      done

let check_reference_chunk path target =
  match gpus () with
  | [] -> print_endline "SKIP reference-chunk check: no CUDA device"
  | gpu :: _ ->
      let dump = load path in
      let chunk = 777 in
      let a = Device_search.run_chunk (Device_search.prepare gpu dump target) ~chunk in
      let t = Unix.gettimeofday () in
      let b = reference_chunk_hits dump target ~chunk in
      report
        (Printf.sprintf "reference chunk %d (10^8 nonces): %s %d hits vs reference %d hits (%.0fs)"
           chunk (Device_search.framework gpu) (List.length a) (List.length b)
           (Unix.gettimeofday () -. t))
        (a = b)

let () =
  Arg.parse
    [
      ("--target", Arg.Set_string target_name, "NAME target (default pa)");
      ("--whole-chunks", Arg.Set_int whole_chunks, "N compare N whole chunks GPU vs Native");
      ("--reference-chunk", Arg.Set reference_chunk, " compare one whole chunk GPU vs reference");
    ]
    (fun _ -> ())
    "equivalence.exe [options]" ;
  let target =
    match Target.make !target_name with Ok t -> t | Error e -> failwith e
  in
  let real = Fixtures.ref_file "proto_to_hash.txt" in
  let main_dump = match real with Some f -> f | None -> synthetic 46 in
  if !whole_chunks > 0 then check_whole_chunks main_dump target !whole_chunks
  else if !reference_chunk then check_reference_chunk main_dump target
  else begin
    List.iter
      (fun f -> check_dump (Printf.sprintf "synthetic F=%d" f) (synthetic f) target)
      [46; 15; 9; 3] ;
    Option.iter (fun f -> check_dump "proto_to_hash.txt" f target) real
  end ;
  if !failures > 0 then (
    Printf.printf "%d check(s) failed\n" !failures ;
    exit 1)
