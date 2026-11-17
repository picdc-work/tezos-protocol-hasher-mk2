type stop_reason = Completed | Max_matches | Timeout | Interrupted | Device_error

let reason_name = function
  | Completed -> "completed"
  | Max_matches -> "max-matches"
  | Timeout -> "timeout"
  | Interrupted -> "interrupted"
  | Device_error -> "device-error"

type outcome = {reason : stop_reason; next_chunk : int; tested : int; matches : int}

let exit_code = function
  | Completed | Max_matches | Timeout -> 0
  | Device_error -> 3
  | Interrupted -> 130

let interrupted = Atomic.make false

let install_signal_handlers () =
  let h = Sys.Signal_handle (fun _ -> Atomic.set interrupted true) in
  Sys.set_signal Sys.sigint h ;
  Sys.set_signal Sys.sigterm h

let human_duration s =
  if s = infinity then "forever"
  else if s < 120. then Printf.sprintf "%.1f s" s
  else if s < 7200. then Printf.sprintf "%.1f min" (s /. 60.)
  else if s < 172800. then Printf.sprintf "%.1f h" (s /. 3600.)
  else Printf.sprintf "%.1f days" (s /. 86400.)

let case_mode_name t =
  match Target.case_mode t with Target.Insensitive -> "case-insensitive" | Sensitive -> "case-sensitive"

let run ?max_matches ?timeout ?progress ?label ~dump ~target ~device ~range ~out ~err () =
  let prefix = match label with Some l -> l ^ " " | None -> "" in
  let rate_per_match = Target.expected_rate target in
  Printf.fprintf err "%sdevice: %s (%s)\n" prefix (Device_search.name device)
    (Device_search.framework device) ;
  Printf.fprintf err "%sdump: %s, %d bytes, layout case %s (final block %d bytes)\n" prefix
    dump.Dump.path dump.length (Dump.case_name dump.layout_case) dump.final_block_length ;
  Printf.fprintf err "%starget: %S, %s, %d prefilter interval(s), ~%.3g candidates per match\n%!"
    prefix (Target.name target) (case_mode_name target)
    (Array.length (Target.intervals target)) rate_per_match ;
  if String.length (Target.name target) < 3 then
    Printf.fprintf err "%swarning: target shorter than 3 characters, expect a very large output\n%!" prefix ;
  let ctx = Device_search.prepare device dump target in
  Printf.fprintf err "%skernel: %s\n%!" prefix (Device_search.mode_name (Device_search.mode ctx)) ;
  let t0 = Unix.gettimeofday () in
  let tested = ref 0 and matches = ref 0 and covered = ref 0 in
  let last_progress = ref t0 and tested_at_last = ref 0 in
  let reason = ref None in
  let stop r = if !reason = None then reason := Some r in
  let rate_reported = ref false in
  (try
     while !reason = None do
       if !covered >= range.Nonce_space.count then stop Completed
       else if Atomic.get interrupted then stop Interrupted
       else if (match timeout with Some s -> Unix.gettimeofday () -. t0 >= s | None -> false)
       then stop Timeout
       else begin
         let chunk = Nonce_space.nth_chunk range !covered in
         let t_launch = Unix.gettimeofday () in
         let hits = Device_search.run_chunk ctx ~chunk in
         let launch_time = Unix.gettimeofday () -. t_launch in
         List.iter
           (fun n ->
             if !reason = None then begin
               let hash = Protocol_hash.of_digest (Dump.digest dump n) in
               if Target.matches target hash then begin
                 Printf.fprintf out "%s %s\n%!" hash (Nonce_space.text n) ;
                 incr matches ;
                 match max_matches with
                 | Some k when !matches >= k -> stop Max_matches
                 | _ -> ()
               end
             end)
           hits ;
         if !reason = None then begin
           incr covered ;
           tested := !tested + Nonce_space.chunk_size
         end ;
         let now = Unix.gettimeofday () in
         (* the first launch includes JIT compilation and table uploads:
            report the rate of the second one (or of the first if the range
            has a single chunk) *)
         if (not !rate_reported) && (!covered >= 2 || !reason <> None || !covered >= range.count)
         then begin
           rate_reported := true ;
           let rate = float Nonce_space.chunk_size /. launch_time in
           let per_match = rate_per_match /. rate in
           Printf.fprintf err "%srate: %.3g nonces/s, estimated time per match: %s\n%!" prefix
             rate (human_duration per_match) ;
           if per_match > 30. *. 86400. then
             Printf.fprintf err
               "%swarning: target effectively unreachable (~%.3g candidates per match, ~%s per match at this rate)\n%!"
               prefix rate_per_match (human_duration per_match)
         end ;
         match progress with
         | Some every when now -. !last_progress >= every ->
             let rate = float (!tested - !tested_at_last) /. (now -. !last_progress) in
             Printf.fprintf err "%sprogress elapsed=%.0f rate=%.0f tested=%d next_chunk=%d matches=%d\n%!"
               prefix (now -. t0) rate !tested
               (Nonce_space.nth_chunk range !covered)
               !matches ;
             last_progress := now ;
             tested_at_last := !tested
         | _ -> ()
       end
     done
   with e ->
     Printf.fprintf err "%serror: device failure: %s\n%!" prefix (Printexc.to_string e) ;
     stop Device_error) ;
  let reason = Option.get !reason in
  let next_chunk = Nonce_space.nth_chunk range !covered in
  Printf.fprintf err "%sstopped reason=%s next_chunk=%d tested=%d matches=%d\n%!" prefix
    (reason_name reason) next_chunk !tested !matches ;
  {reason; next_chunk; tested = !tested; matches = !matches}
