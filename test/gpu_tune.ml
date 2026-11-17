(* Correctness-gated, warmed block-size sweep on an explicitly selected device.
   gpu_tune.exe DEVICE SECONDS_PER_SAMPLE REPEATS DUMP... *)
open Octez_vanity

let target name = Result.get_ok (Target.make ~case_mode:Target.Sensitive name)

let reference dump target =
  let hits = ref [] in
  for th = 9999 downto 0 do
    for lp = 99 downto 0 do
      let n = Nonce_space.make ~chunk:12345678 ~thread:th ~loop:lp in
      let digest = Dump.digest dump n in
      if Target.in_intervals target (Target.top64 digest) then
        hits := n :: !hits
    done
  done;
  !hits

let () =
  let requested = ref [] and args = ref [] in
  Arg.parse
    [
      ( "--variant",
        Arg.String
          (fun s ->
            match String.split_on_char ':' s with
            | [ block; interleave ] ->
                requested :=
                  (int_of_string block, int_of_string interleave) :: !requested
            | _ -> raise (Arg.Bad "expected BLOCK:INTERLEAVE")),
        "BLOCK:INTERLEAVE restrict the sweep (repeatable)" );
    ]
    (fun s -> args := s :: !args)
    "gpu_tune.exe [--variant BLOCK:INTERLEAVE] DEVICE SECONDS REPEATS DUMP...";
  match List.rev !args with
  | device :: seconds :: repeats :: paths when paths <> [] ->
      let seconds = float_of_string seconds
      and repeats = int_of_string repeats in
      if seconds <= 0. || repeats < 1 then
        invalid_arg "positive duration/repeats required";
      let dev =
        match Device_search.select device with
        | Ok [ (_, d) ] -> d
        | _ -> invalid_arg "select exactly one device"
      in
      Printf.eprintf "device=%s %s\n%!"
        (Device_search.framework dev)
        (Device_search.name dev);
      let variants =
        match !requested with
        | [] ->
            [|
              (64, 1);
              (64, 2);
              (128, 1);
              (128, 2);
              (256, 1);
              (256, 2);
              (512, 1);
              (512, 2);
            |]
        | xs -> Array.of_list (List.rev xs)
      in
      let check_target = target "Pa" and bench_target = target "zzzzzzzzz" in
      let cases =
        List.map
          (fun path ->
            let dump = Result.get_ok (Dump.load path) in
            let expected = reference dump check_target in
            let contexts =
              Array.map
                (fun (block_size, interleave) ->
                  let check =
                    Device_search.prepare ~block_size ~interleave dev dump
                      check_target
                  in
                  let got =
                    Device_search.run_chunk ~nthreads:10_000 check
                      ~chunk:12345678
                  in
                  if got <> expected then failwith "device/reference mismatch";
                  if
                    not
                      (List.for_all
                         (fun n -> Dump.digest dump n = Dump.digest_full dump n)
                         got)
                  then failwith "digestif mismatch";
                  Printf.eprintf
                    "verified F=%d block=%d interleave=%d hits=%d\n%!"
                    dump.final_block_length block_size interleave
                    (List.length got);
                  let ctx =
                    Device_search.prepare ~block_size ~interleave dev dump
                      bench_target
                  in
                  ignore (Device_search.run_chunk ctx ~chunk:0);
                  ctx)
                variants
            in
            (dump, contexts))
          paths
      in
      print_endline
        "final_block,mode,block,interleave,repeat,chunks,seconds,nonces_per_second";
      for repeat = 1 to repeats do
        List.iter
          (fun (dump, contexts) ->
            for i = 0 to Array.length variants - 1 do
              let k = (i + repeat - 1) mod Array.length variants in
              let ctx = contexts.(k) in
              let t0 = Unix.gettimeofday () in
              let chunks = ref 0 in
              while !chunks = 0 || Unix.gettimeofday () -. t0 < seconds do
                incr chunks;
                ignore (Device_search.run_chunk ctx ~chunk:!chunks)
              done;
              let dt = Unix.gettimeofday () -. t0 in
              Printf.printf "%d,%s,%d,%d,%d,%d,%.6f,%.0f\n%!"
                dump.Dump.final_block_length
                (match Device_search.mode ctx with
                | Kernel_a -> "A"
                | Host_penultimate -> "B-host"
                | Kernel_b -> "B-kernel"
                | Kernel_c -> "C")
                (fst variants.(k))
                (snd variants.(k))
                repeat !chunks dt
                (float (!chunks * Nonce_space.chunk_size) /. dt)
            done)
          cases
      done
  | _ ->
      prerr_endline
        "usage: gpu_tune.exe DEVICE SECONDS_PER_SAMPLE REPEATS DUMP...";
      exit 2
