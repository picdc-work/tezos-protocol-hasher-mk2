(* Exercise the real supervisor with controlled subprocesses, without two GPUs.
   An alarm interrupts a stalled supervisor so regressions cannot hang dune test. *)
open Octez_vanity

let value name =
  let rec find i =
    if Sys.argv.(i) = name then Sys.argv.(i + 1) else find (i + 1)
  in
  find 1

let arg name = int_of_string (value name)

let worker scenario =
  let index = arg "--device"
  and first = arg "--start"
  and count = arg "--count" in
  let stopped reason tested =
    Printf.eprintf "stopped reason=%s next_chunk=%d tested=%d matches=0\n%!"
      reason
      (first + (tested / Nonce_space.chunk_size))
      tested
  in
  Sys.set_signal Sys.sigterm
    (Sys.Signal_handle
       (fun _ ->
         stopped "interrupted" 0;
         exit 130));
  let ready = value "--ready" in
  if index = 1 then close_out (open_out_bin ready);
  if count = 0 then (
    prerr_endline "unexpected empty worker";
    exit 2);
  match scenario with
  | "completed" | "empty-slice" | "empty-range" ->
      stopped "completed" (count * Nonce_space.chunk_size)
  | _ when index = 0 -> (
      (* The peer must be ready to report its position when terminated. *)
      while not (Sys.file_exists ready) do
        Unix.sleepf 0.01
      done;
      match scenario with
      | "reported-failure" ->
          stopped "device-error" 0;
          (* A final record must not cause the supervisor to signal its sender. *)
          Unix.sleepf 0.1;
          exit 3
      | "silent-failure" -> exit 3
      | "bad-exit-after-receipt" ->
          stopped "completed" 0;
          exit 3
      | "missing-receipt" -> exit 0
      | "max-matches" ->
          print_endline "match";
          stopped "max-matches" 0
      | "interrupted" ->
          Unix.kill (Unix.getppid ()) Sys.sigint;
          Unix.sleepf 30.
      | _ -> failwith scenario)
  | _ -> Unix.sleepf 30.

let supervisor scenario =
  let dev = Device_search.cpu_device () in
  Sys.set_signal Sys.sigalrm
    (Sys.Signal_handle (fun _ -> Unix.kill (Unix.getpid ()) Sys.sigterm));
  ignore (Unix.alarm 2);
  let count =
    match scenario with "empty-slice" -> 1 | "empty-range" -> 0 | _ -> 2
  in
  let ready = Filename.temp_file "supervisor-peer" ".ready" in
  Sys.remove ready;
  let code =
    Fun.protect
      ~finally:(fun () -> if Sys.file_exists ready then Sys.remove ready)
      (fun () ->
        Multi_device.run ~exe:Sys.executable_name
          ~common_args:[ "--worker"; scenario; "--ready"; ready ]
          ~devices:[ (0, dev); (1, dev) ]
          ~range:{ Nonce_space.first_chunk = 1000; count }
          ~max_matches:(if scenario = "max-matches" then Some 1 else None)
          ())
  in
  ignore (Unix.alarm 0);
  exit code

let () =
  match Array.to_list Sys.argv with
  | _ :: "--worker" :: scenario :: _ -> worker scenario
  | [ _; scenario ] -> supervisor scenario
  | _ -> failwith "usage: supervisor-probe SCENARIO"
