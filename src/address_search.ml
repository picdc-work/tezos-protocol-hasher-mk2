type reason = Stopped of Search.stop_reason | Key_file_error

let reason_name = function Stopped r -> Search.reason_name r | Key_file_error -> "key-file-error"

let exit_code = function Stopped r -> Search.exit_code r | Key_file_error -> 4

type outcome = {reason : reason; next_chunk : int; tested : int; matches : int}

let default_threads = 4096

let default_batch = 256

(* What the search loop needs from a way of enumerating candidates: run a
   chunk (possibly as several launches), confirm an offset, describe itself.
   [stop ()] is checked before each launch (it also looks at the interrupt
   flag and the timeout); [on_hits] gets the chunk indices that pass the
   prefilter after each launch; the result is the number of offsets
   searched, the chunk size when the whole chunk was. *)
type engine = {
  describe : string;
  run_chunk : chunk:int -> stop:(unit -> bool) -> on_hits:(int list -> unit) -> int;
  confirm : int64 -> (string * string) option;
}

type base = Scalar of Z.t | Seed_base of string

type params = {
  scheme : Address.scheme;
  engine : engine;
  target : Target.t;
  device : Device_search.device;
  key_dir : string;
  max_matches : int option;
  prefix : string;
  out : out_channel;
  err : out_channel;
}

type state = {
  mutable tested : int;
  mutable matches : int;
  mutable covered : int;
  mutable stop : reason option;
  mutable rate_reported : bool;
  mutable last_launch : float;
  mutable last_searched : int;
}

let set_stop st r = if st.stop = None then st.stop <- Some r

let startup p =
  let rate = Target.expected_rate p.target in
  Printf.fprintf p.err "%sdevice: %s (%s)\n" p.prefix (Device_search.name p.device)
    (Device_search.framework p.device) ;
  Printf.fprintf p.err "%starget: %s%S, %s, %d prefilter interval(s), ~%.3g candidates per match\n%!"
    p.prefix (Address.name p.scheme) (Target.name p.target) (Search.case_mode_name p.target)
    (Array.length (Target.intervals p.target)) rate ;
  Printf.fprintf p.err "%skernel: %s\n%!" p.prefix p.engine.describe ;
  if String.length (Target.name p.target) < 3 then
    Printf.fprintf p.err "%swarning: target shorter than 3 characters, expect a very large output\n%!"
      p.prefix

let report_rate p st =
  st.rate_reported <- true ;
  let rate = float st.last_searched /. st.last_launch in
  let per_match = Target.expected_rate p.target /. rate in
  Printf.fprintf p.err "%srate: %.3g offsets/s, estimated time per match: %s\n%!" p.prefix rate
    (Search.human_duration per_match) ;
  if per_match > 30. *. 86400. then
    Printf.fprintf p.err
      "%swarning: target effectively unreachable (~%.3g candidates per match, ~%s per match at this \
       rate)\n%!"
      p.prefix (Target.expected_rate p.target) (Search.human_duration per_match)

(* Host confirmation of one device hit, then key file and output line. *)
let handle_hit p st ~chunk index =
  let j = Offset_space.offset ~chunk ~index in
  match p.engine.confirm j with
  | None -> ()
  | Some (address, secret) -> (
      match Key_files.write_key ~dir:p.key_dir ~address p.scheme ~secret with
      | Error e ->
          Printf.fprintf p.err "%serror: key file: %s\n%!" p.prefix e ;
          set_stop st Key_file_error
      | Ok (Key_files.Existing path) ->
          (* found by an earlier run over the same range: not a new match *)
          Printf.fprintf p.err "%salready found: %s %s\n%!" p.prefix address path ;
      | Ok (Key_files.New path) -> (
          Printf.fprintf p.out "%s %s\n%!" address path ;
          st.matches <- st.matches + 1 ;
          match p.max_matches with
          | Some k when st.matches >= k -> set_stop st (Stopped Search.Max_matches)
          | _ -> ()))

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

(* Sets the stop reason when the interrupt flag is set or the timeout has
   passed; true when the search must stop. *)
let signal_stop st ~timeout clock =
  if st.stop = None then
    if Atomic.get Search.interrupted then set_stop st (Stopped Interrupted)
    else if
      match timeout with Some s -> Unix.gettimeofday () -. clock.t0 >= s | None -> false
    then set_stop st (Stopped Timeout) ;
  st.stop <> None

let stop_requested st ~range ~timeout clock =
  if st.covered >= range.Offset_space.count then set_stop st (Stopped Completed)
  else ignore (signal_stop st ~timeout clock)

let run_chunk p st ~timeout clock chunk =
  let t_launch = Unix.gettimeofday () in
  let searched =
    p.engine.run_chunk ~chunk
      ~stop:(fun () -> signal_stop st ~timeout clock)
      ~on_hits:(List.iter (fun index -> if st.stop = None then handle_hit p st ~chunk index))
  in
  st.last_launch <- Unix.gettimeofday () -. t_launch ;
  st.last_searched <- searched ;
  if searched = Offset_space.chunk_size && st.stop = None then begin
    st.covered <- st.covered + 1 ;
    st.tested <- st.tested + Offset_space.chunk_size
  end

let loop p st ~range ~timeout ~progress clock =
  while st.stop = None do
    stop_requested st ~range ~timeout clock ;
    if st.stop = None then begin
      run_chunk p st ~timeout clock (Offset_space.nth_chunk range st.covered) ;
      (* the first launch includes JIT compilation and table uploads: report
         the rate of the second one *)
      if (not st.rate_reported) && st.covered >= 2 then report_rate p st ;
      report_progress p st ~progress ~range clock
    end
  done

(* The walk of tz2, tz3 and tz4 (see Walk_run): the base scalar [k0] stays on
   the host, the device sees public points only. The walker is created on the
   first chunk and moves on to the next one after each chunk; a chunk out of
   sequence (the range wrapped around) gets a fresh walker. *)
let walk_engine ~threads ~batch ~scheme ~target ~device ~k0 =
  if threads * batch <> Offset_space.chunk_size then invalid_arg "Address_search: chunk size" ;
  let curve, kernel =
    match (Walk_keys.curve_of scheme, Walk_run.kernel_of scheme) with
    | Ok curve, Ok kernel -> (curve, kernel)
    | _ -> invalid_arg "Address_search: unsupported scheme"
  in
  let p0 = lazy (Curve_ref.scalar_mul curve k0 (Curve_ref.generator curve)) in
  let walker = ref None in
  let walker_at chunk =
    match !walker with
    | Some w when Walk_run.chunk w = chunk -> w
    | _ ->
        let w =
          Walk_run.create device kernel target ~threads ~batch ~p0:(Lazy.force p0) ~chunk
        in
        walker := Some w ;
        w
  in
  {
    describe =
      Printf.sprintf "walk %s, %d threads x %d offsets per launch" (Address.name scheme) threads
        batch;
    run_chunk =
      (fun ~chunk ~stop:_ ~on_hits ->
        let w = walker_at chunk in
        on_hits (Walk_run.run w) ;
        Walk_run.advance w ;
        Offset_space.chunk_size);
    confirm = (fun j -> Walk_keys.confirm scheme curve target ~k0 j);
  }

(* tz1: the seeds of the base are enumerated on the device (see Seed_run),
   which therefore knows the base. A chunk is [chunk_size / (threads *
   batch)] launches, with [stop] checked before each. *)
let seed_engine ~threads ~batch ~target ~device ~base =
  let launch = threads * batch in
  if launch < 1 || Offset_space.chunk_size mod launch <> 0 then
    invalid_arg "Address_search: launch size" ;
  let launches = Offset_space.chunk_size / launch in
  let runner = lazy (Seed_run.create device target ~base ~threads ~batch) in
  {
    describe =
      Printf.sprintf
        "seeds tz1 (ed25519, %d-bit windows), %d threads x %d seeds per launch, %d launches per chunk"
        Seed_table.window_bits threads batch launches;
    run_chunk =
      (fun ~chunk ~stop ~on_hits ->
        let rec go part =
          if part = launches || stop () then part * launch
          else begin
            let first = part * launch in
            let start = Offset_space.offset ~chunk ~index:first in
            on_hits (List.map (fun i -> first + i) (Seed_run.run (Lazy.force runner) ~start)) ;
            go (part + 1)
          end
        in
        go 0);
    confirm = (fun j -> Seed_keys.confirm target ~base j);
  }

let default_seed_threads = 4096

let default_seed_batch = 16

let make_engine ?threads ?batch ~scheme ~target ~device base =
  match (scheme, base) with
  | Address.Tz1, Seed_base base ->
      seed_engine
        ~threads:(Option.value threads ~default:default_seed_threads)
        ~batch:(Option.value batch ~default:default_seed_batch)
        ~target ~device ~base
  | Address.Tz1, Scalar _ | (Tz2 | Tz3 | Tz4), Seed_base _ ->
      invalid_arg "Address_search.make_engine: base of the wrong kind"
  | (Tz2 | Tz3 | Tz4), Scalar k0 ->
      walk_engine
        ~threads:(Option.value threads ~default:default_threads)
        ~batch:(Option.value batch ~default:default_batch)
        ~scheme ~target ~device ~k0

let run ?max_matches ?timeout ?progress ?label ~scheme ~target ~device ~engine ~range ~key_dir ~out
    ~err () =
  let p =
    {
      scheme; engine; target; device; key_dir; max_matches;
      prefix = (match label with Some l -> l ^ " " | None -> "");
      out; err;
    }
  in
  startup p ;
  let t0 = Unix.gettimeofday () in
  let st =
    {tested = 0; matches = 0; covered = 0; stop = None; rate_reported = false; last_launch = 0.;
     last_searched = 0}
  in
  let clock = {t0; last_progress = t0; tested_at_last = 0} in
  (try loop p st ~range ~timeout ~progress clock
   with e ->
     Printf.fprintf err "%serror: device failure: %s\n%!" p.prefix (Printexc.to_string e) ;
     set_stop st (Stopped Device_error)) ;
  if (not st.rate_reported) && st.last_launch > 0. then report_rate p st ;
  let reason = Option.get st.stop in
  let next_chunk = Offset_space.nth_chunk range st.covered in
  Printf.fprintf err "%sstopped reason=%s next_chunk=%d tested=%d matches=%d\n%!" p.prefix
    (reason_name reason) next_chunk st.tested st.matches ;
  {reason; next_chunk; tested = st.tested; matches = st.matches}
