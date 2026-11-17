type reason = Stopped of Search.stop_reason | Key_file_error

let reason_name = function Stopped r -> Search.reason_name r | Key_file_error -> "key-file-error"

let exit_code = function Stopped r -> Search.exit_code r | Key_file_error -> 4

type outcome = {reason : reason; next_chunk : int; tested : int; matches : int}

let default_threads = 4096

let default_batch = 256

type params = {
  scheme : Address.scheme;
  curve : Curve_ref.curve;
  kernel : Walk_run.kernel;
  target : Target.t;
  device : Device_search.device;
  k0 : Z.t;
  p0 : Curve_ref.point;
  threads : int;
  batch : int;
  key_dir : string;
  max_matches : int option;
  prefix : string;
  out : out_channel;
  err : out_channel;
}

type state = {
  mutable walker : Walk_run.t option;
  mutable tested : int;
  mutable matches : int;
  mutable covered : int;
  mutable stop : reason option;
  mutable rate_reported : bool;
  mutable last_launch : float;
}

let set_stop st r = if st.stop = None then st.stop <- Some r

let startup p =
  let rate = Target.expected_rate p.target in
  Printf.fprintf p.err "%sdevice: %s (%s)\n" p.prefix (Device_search.name p.device)
    (Device_search.framework p.device) ;
  Printf.fprintf p.err "%starget: %s%S, %s, %d prefilter interval(s), ~%.3g candidates per match\n%!"
    p.prefix (Address.name p.scheme) (Target.name p.target) (Search.case_mode_name p.target)
    (Array.length (Target.intervals p.target)) rate ;
  Printf.fprintf p.err "%skernel: walk %s, %d threads x %d offsets per launch\n%!" p.prefix
    (Address.name p.scheme) p.threads p.batch ;
  if String.length (Target.name p.target) < 3 then
    Printf.fprintf p.err "%swarning: target shorter than 3 characters, expect a very large output\n%!"
      p.prefix

let report_rate p st launch_time =
  st.rate_reported <- true ;
  let rate = float (p.threads * p.batch) /. launch_time in
  let per_match = Target.expected_rate p.target /. rate in
  Printf.fprintf p.err "%srate: %.3g offsets/s, estimated time per match: %s\n%!" p.prefix rate
    (Search.human_duration per_match) ;
  if per_match > 30. *. 86400. then
    Printf.fprintf p.err
      "%swarning: target effectively unreachable (~%.3g candidates per match, ~%s per match at this \
       rate)\n%!"
      p.prefix (Target.expected_rate p.target) (Search.human_duration per_match)

(* The walker positioned on [chunk]: the current one when it is there (it was
   advanced after the previous chunk), else a fresh one (first chunk, or the
   range wrapped around). *)
let walker_at p st chunk =
  match st.walker with
  | Some w when Walk_run.chunk w = chunk -> w
  | _ ->
      let w =
        Walk_run.create p.device p.kernel p.target ~threads:p.threads ~batch:p.batch ~p0:p.p0 ~chunk
      in
      st.walker <- Some w ;
      w

(* Host confirmation of one device hit, then key file and output line. *)
let handle_hit p st ~chunk index =
  let j = Offset_space.offset ~chunk ~index in
  match Walk_keys.confirm p.scheme p.curve p.target ~k0:p.k0 j with
  | None -> ()
  | Some (address, secret) -> (
      match Key_files.write_key ~dir:p.key_dir ~address p.scheme ~secret with
      | Error e ->
          Printf.fprintf p.err "%serror: key file: %s\n%!" p.prefix e ;
          set_stop st Key_file_error
      | Ok (Key_files.Existing path) ->
          (* found by an earlier run over the same range: not a new match *)
          Printf.fprintf p.err "%salready found: %s %s\n%!" p.prefix address path
      | Ok (Key_files.New path) -> (
          Printf.fprintf p.out "%s %s\n%!" address path ;
          st.matches <- st.matches + 1 ;
          match p.max_matches with
          | Some k when st.matches >= k -> set_stop st (Stopped Search.Max_matches)
          | _ -> ()))

let run_chunk p st chunk =
  let w = walker_at p st chunk in
  let t_launch = Unix.gettimeofday () in
  let hits = Walk_run.run w in
  st.last_launch <- Unix.gettimeofday () -. t_launch ;
  List.iter (fun index -> if st.stop = None then handle_hit p st ~chunk index) hits ;
  if st.stop = None then begin
    Walk_run.advance w ;
    st.covered <- st.covered + 1 ;
    st.tested <- st.tested + Offset_space.chunk_size
  end

type clock = {t0 : float; mutable last_progress : float; mutable tested_at_last : int}

let report_progress p st ~progress ~range clock =
  let now = Unix.gettimeofday () in
  match progress with
  | Some every when now -. clock.last_progress >= every ->
      let rate = float (st.tested - clock.tested_at_last) /. (now -. clock.last_progress) in
      Printf.fprintf p.err "%sprogress elapsed=%.0f rate=%.0f tested=%d next_chunk=%d matches=%d\n%!"
        p.prefix (now -. clock.t0) rate st.tested
        (Offset_space.nth_chunk range st.covered)
        st.matches ;
      clock.last_progress <- now ;
      clock.tested_at_last <- st.tested
  | _ -> ()

let stop_requested st ~range ~timeout clock =
  if st.covered >= range.Offset_space.count then set_stop st (Stopped Completed)
  else if Atomic.get Search.interrupted then set_stop st (Stopped Interrupted)
  else if
    match timeout with Some s -> Unix.gettimeofday () -. clock.t0 >= s | None -> false
  then set_stop st (Stopped Timeout)

let loop p st ~range ~timeout ~progress clock =
  while st.stop = None do
    stop_requested st ~range ~timeout clock ;
    if st.stop = None then begin
      run_chunk p st (Offset_space.nth_chunk range st.covered) ;
      (* the first launch includes JIT compilation and table uploads: report
         the rate of the second one *)
      if (not st.rate_reported) && st.covered >= 2 then report_rate p st st.last_launch ;
      report_progress p st ~progress ~range clock
    end
  done

let run ?max_matches ?timeout ?progress ?label ?(threads = default_threads)
    ?(batch = default_batch) ~scheme ~target ~device ~k0 ~range ~key_dir ~out ~err () =
  if threads * batch <> Offset_space.chunk_size then invalid_arg "Address_search.run: chunk size" ;
  let curve, kernel =
    match (Walk_keys.curve_of scheme, Walk_run.kernel_of scheme) with
    | Ok curve, Ok kernel -> (curve, kernel)
    | _ -> invalid_arg "Address_search.run: unsupported scheme"
  in
  let p =
    {
      scheme; curve; kernel; target; device; k0;
      p0 = Curve_ref.scalar_mul curve k0 (Curve_ref.generator curve);
      threads; batch; key_dir; max_matches;
      prefix = (match label with Some l -> l ^ " " | None -> "");
      out; err;
    }
  in
  startup p ;
  let t0 = Unix.gettimeofday () in
  let st =
    {walker = None; tested = 0; matches = 0; covered = 0; stop = None; rate_reported = false;
     last_launch = 0.}
  in
  let clock = {t0; last_progress = t0; tested_at_last = 0} in
  (try loop p st ~range ~timeout ~progress clock
   with e ->
     Printf.fprintf err "%serror: device failure: %s\n%!" p.prefix (Printexc.to_string e) ;
     set_stop st (Stopped Device_error)) ;
  if (not st.rate_reported) && st.last_launch > 0. then report_rate p st st.last_launch ;
  let reason = Option.get st.stop in
  let next_chunk = Offset_space.nth_chunk range st.covered in
  Printf.fprintf err "%sstopped reason=%s next_chunk=%d tested=%d matches=%d\n%!" p.prefix
    (reason_name reason) next_chunk st.tested st.matches ;
  {reason; next_chunk; tested = st.tested; matches = st.matches}
