type worker = {
  index : int;
  slice : Nonce_space.range;
  pid : int;
  out_fd : Unix.file_descr;
  err_fd : Unix.file_descr;
  out_buf : Buffer.t;
  err_buf : Buffer.t;
  mutable open_fds : int;  (** bit 1: stdout pipe open, bit 2: stderr pipe open *)
  mutable stopped : (string * int * int) option;  (** reason, tested, matches *)
  mutable status : Unix.process_status option;
}

let starts_with ~prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

(* "stopped reason=R next_chunk=C tested=T matches=M" *)
let parse_stopped line =
  let fields = List.tl (String.split_on_char ' ' line) in
  let get k =
    List.find_map
      (fun f ->
        match String.index_opt f '=' with
        | Some i when String.sub f 0 i = k -> Some (String.sub f (i + 1) (String.length f - i - 1))
        | _ -> None)
      fields
  in
  match (get "reason", get "tested", get "matches") with
  | Some r, Some t, Some m -> Some (r, int_of_string t, int_of_string m)
  | _ -> None

let run ~exe ~common_args ~devices ~range ~max_matches =
  let n = List.length devices in
  let terminate = ref false in
  let workers =
    List.filter_map
      (fun (k, (index, _dev)) ->
        let slice = Nonce_space.slice range ~instance:k ~of_:n in
        if slice.count = 0 then None
        else begin
          let out_r, out_w = Unix.pipe ~cloexec:true () in
          let err_r, err_w = Unix.pipe ~cloexec:true () in
          let argv =
            Array.of_list
              ((exe :: common_args)
              @ [
                  "--device"; string_of_int index; "--start";
                  string_of_int slice.first_chunk; "--count"; string_of_int slice.count;
                ])
          in
          let pid = Unix.create_process exe argv Unix.stdin out_w err_w in
          Unix.close out_w ;
          Unix.close err_w ;
          Some {
            index; slice; pid; out_fd = out_r; err_fd = err_r; out_buf = Buffer.create 4096;
            err_buf = Buffer.create 4096; open_fds = 3; stopped = None; status = None;
          }
        end)
      (List.mapi (fun k dev -> (k, dev)) devices)
  in
  let kill_all () =
    List.iter
      (fun w ->
        (* A worker with a final record is already exiting. Signalling it
           could replace its device-error record with an interruption. *)
        if w.status = None && w.stopped = None then
          try Unix.kill w.pid Sys.sigterm with Unix.Unix_error _ -> ())
      workers
  in
  let forward _ = terminate := true ; kill_all () in
  Sys.set_signal Sys.sigint (Sys.Signal_handle forward) ;
  Sys.set_signal Sys.sigterm (Sys.Signal_handle forward) ;
  let printed = ref 0 and max_reached = ref false in
  let device_failed = ref false in
  let device_failure () =
    if not !device_failed then begin
      device_failed := true ;
      kill_all ()
    end
  in
  let on_out_line _w line =
    if not !max_reached then begin
      print_string (line ^ "\n") ;
      flush stdout ;
      incr printed ;
      match max_matches with
      | Some k when !printed >= k ->
          max_reached := true ;
          kill_all ()
      | _ -> ()
    end
  in
  let on_err_line w line =
    if starts_with ~prefix:"stopped " line then begin
      w.stopped <- parse_stopped line ;
      (match w.stopped with Some ("device-error", _, _) -> device_failure () | _ -> ()) ;
      Printf.eprintf "stopped device=%d slice=%d+%d %s\n%!" w.index w.slice.first_chunk
        w.slice.count
        (String.sub line 8 (String.length line - 8))
    end
    else Printf.eprintf "device=%d %s\n%!" w.index line
  in
  let chunk = Bytes.create 65536 in
  let drain buf handle w =
    let rec go () =
      match String.index_opt (Buffer.contents buf) '\n' with
      | Some i ->
          let s = Buffer.contents buf in
          handle w (String.sub s 0 i) ;
          let rest = String.sub s (i + 1) (String.length s - i - 1) in
          Buffer.clear buf ;
          Buffer.add_string buf rest ;
          go ()
      | None -> ()
    in
    go ()
  in
  let active () =
    List.concat_map
      (fun w ->
        (if w.open_fds land 1 <> 0 then [w.out_fd] else [])
        @ if w.open_fds land 2 <> 0 then [w.err_fd] else [])
      workers
  in
  let poll_statuses () =
    List.iter
      (fun w ->
        if w.status = None then
          match Unix.waitpid [Unix.WNOHANG] w.pid with
          | 0, _ -> ()
          | _, status ->
              w.status <- Some status ;
              (match status with Unix.WEXITED (0 | 130) -> () | _ -> device_failure ())
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> ())
      workers
  in
  let rec loop () =
    poll_statuses () ;
    match active () with
    | [] -> ()
    | fds ->
        (* Poll process exits too: a crashed worker may have no stopped record. *)
        (match Unix.select fds [] [] 0.2 with
        | ready, _, _ ->
            List.iter
              (fun fd ->
                let w = List.find (fun w -> w.out_fd = fd || w.err_fd = fd) workers in
                let is_out = fd = w.out_fd in
                let buf = if is_out then w.out_buf else w.err_buf in
                match Unix.read fd chunk 0 (Bytes.length chunk) with
                | 0 ->
                    Unix.close fd ;
                    w.open_fds <- w.open_fds land (if is_out then 2 else 1) ;
                    if w.open_fds = 0 && w.stopped = None then device_failure ()
                | k ->
                    Buffer.add_subbytes buf chunk 0 k ;
                    drain buf (if is_out then on_out_line else on_err_line) w
                | exception Unix.Unix_error (Unix.EINTR, _, _) -> ())
              ready
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()) ;
        loop ()
  in
  loop () ;
  let statuses =
    List.map
      (fun w ->
        let rec wait () =
          match Unix.waitpid [] w.pid with
          | _, s -> s
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        in
        (w, match w.status with Some s -> s | None -> wait ()))
      workers
  in
  let reasons = List.map (fun (w, _) -> match w.stopped with Some (r, _, _) -> r | None -> "device-error") statuses in
  let failed =
    List.exists
      (fun (_, s) -> match s with Unix.WEXITED (0 | 130) -> false | _ -> true)
      statuses
  in
  let reason =
    if !max_reached then "max-matches"
    else if !terminate then "interrupted"
    else if !device_failed || failed || List.mem "device-error" reasons then "device-error"
    else if List.mem "interrupted" reasons then "interrupted"
    else if List.mem "timeout" reasons then "timeout"
    else "completed"
  in
  let sum f = List.fold_left (fun acc w -> acc + match w.stopped with Some x -> f x | None -> 0) 0 workers in
  Printf.eprintf "stopped reason=%s tested=%d matches=%d\n%!" reason
    (sum (fun (_, t, _) -> t))
    (if !max_reached then !printed else sum (fun (_, _, m) -> m)) ;
  match reason with "interrupted" -> 130 | "device-error" -> 3 | _ -> 0
