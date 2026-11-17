(* Prototype: GPU vanity search for Tezos protocol hashes with Sarek.

   proto_bench hash    <dump> <nonce>
   proto_bench devices
   proto_bench check   <dump> <name> <framework> <high> <nthreads>
   proto_bench bench   <dump> <name> <framework> <seconds> [nthreads] *)

open Hasher
module Device = Spoc_core.Device
module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute

let init_devices () =
  Sarek_native.Native_plugin.init () ;
  Sarek_cuda.Cuda_plugin.init () ;
  Sarek_cuda.Cuda_c_plugin.init () ;
  Device.init ()

let find_device fw =
  let devs = init_devices () in
  match Array.find_opt (fun d -> d.Device.framework = fw) devs with
  | Some d -> d
  | None -> failwith ("no device for framework " ^ fw)

let ir =
  let _, kirc = Blake_kernel.search in
  match kirc.Sarek.Kirc_types.body_ir with
  | Some ir -> ir
  | None -> failwith "no IR"

let per_thread = 100 (* 10^low_digits *)

let max_threads = 1_000_000 (* 10^mid_digits *)

let cap = 1 lsl 16

type ctx = {
  l : Ref.layout;
  dev : Device.t;
  h : (int64, Bigarray.int64_elt) Vector.t;
  vinit : (int64, Bigarray.int64_elt) Vector.t;
  tmpl : (int64, Bigarray.int64_elt) Vector.t;
  mida : (int64, Bigarray.int64_elt) Vector.t;
  midb : (int64, Bigarray.int64_elt) Vector.t;
  lo : (int64, Bigarray.int64_elt) Vector.t;
  hi : (int64, Bigarray.int64_elt) Vector.t;
  nint : int;
  ivs : (int64 * int64) array;
  hit_count : (int32, Bigarray.int32_elt) Vector.t;
  hit_gid : (int32, Bigarray.int32_elt) Vector.t;
  hit_d : (int32, Bigarray.int32_elt) Vector.t;
  wa : int;
  wl1 : int;
  sl1 : int;
  wl2 : int;
  sl2 : int;
}

let vec64 a =
  let v = Vector.create Vector.int64 (Array.length a) in
  Array.iteri (Vector.set v) a ;
  v

let setup l dev name =
  let q = l.Ref.q in
  let word b = b / 8 and shift b = 8 * (b mod 8) in
  let wa = word (q + 8) in
  let mid g =
    let s = Printf.sprintf "%06d" g in
    let a = ref 0L and b = ref 0L in
    String.iteri
      (fun j c ->
        let pos = q + 8 + j in
        let x = Int64.shift_left (Int64.of_int (Char.code c)) (shift pos) in
        if word pos = wa then a := Int64.logor !a x else b := Int64.logor !b x)
      s ;
    (!a, !b)
  in
  let mida = Vector.create Vector.int64 max_threads in
  let midb = Vector.create Vector.int64 max_threads in
  for g = 0 to max_threads - 1 do
    let a, b = mid g in
    Vector.set mida g a ;
    Vector.set midb g b
  done ;
  let vinit = Array.copy Ref.iv in
  vinit.(4) <- Int64.logxor vinit.(4) (Int64.of_int l.len) ;
  vinit.(6) <- Int64.lognot vinit.(6) ;
  let ivs = Ref.intervals name in
  Printf.eprintf "target %S: %d prefilter interval(s)\n%!" name (Array.length ivs) ;
  {
    l;
    dev;
    h = vec64 l.mid_state;
    vinit = vec64 vinit;
    tmpl = Vector.create Vector.int64 16;
    mida;
    midb;
    lo = vec64 (Array.map fst ivs);
    hi = vec64 (Array.map snd ivs);
    nint = Array.length ivs;
    ivs;
    hit_count = Vector.create Vector.int32 1;
    hit_gid = Vector.create Vector.int32 cap;
    hit_d = Vector.create Vector.int32 cap;
    wa;
    wl1 = word (q + 14);
    sl1 = shift (q + 14);
    wl2 = word (q + 15);
    sl2 = shift (q + 15);
  }

(* Template for a given value of the 8 high digits: digits of the final block
   with middle/low digit bytes zeroed. *)
let set_template c high =
  let l = c.l in
  let blk = Bytes.sub l.data l.last_off (l.len - l.last_off) in
  Bytes.blit_string (Printf.sprintf "%08d" high) 0 blk l.q 8 ;
  Bytes.fill blk (l.q + 8) 8 '\000' ;
  let w = Ref.words_of_block blk 0 (Bytes.length blk) in
  Array.iteri (Vector.set c.tmpl) w

(* One launch: nonces high*10^8 + [0, nthreads*100). Returns raw hits. *)
let launch c high nthreads =
  set_template c high ;
  Vector.set c.hit_count 0 0l ;
  let block = 256 in
  let grid = (nthreads + block - 1) / block in
  Execute.run_vectors ~device:c.dev ~ir
    ~args:
      Execute.
        [
          Vec c.h;
          Vec c.vinit;
          Vec c.tmpl;
          Vec c.mida;
          Vec c.midb;
          Int32 (Int32.of_int c.wa);
          Int32 (Int32.of_int c.wl1);
          Int64 (Int64.of_int c.sl1);
          Int32 (Int32.of_int c.wl2);
          Int64 (Int64.of_int c.sl2);
          Vec c.lo;
          Vec c.hi;
          Int32 (Int32.of_int c.nint);
          Vec c.hit_count;
          Vec c.hit_gid;
          Vec c.hit_d;
          Int32 (Int32.of_int cap);
          Int32 (Int32.of_int nthreads);
        ]
    ~block:(Execute.dims1d block) ~grid:(Execute.dims1d grid) () ;
  Transfer.flush c.dev ;
  let n = Int32.to_int (Vector.get c.hit_count 0) in
  if n > cap then Printf.eprintf "warning: %d hits, only %d kept\n%!" n cap ;
  List.init (min n cap) (fun k ->
      let g = Int32.to_int (Vector.get c.hit_gid k) in
      let d = Int32.to_int (Vector.get c.hit_d k) in
      Int64.(add (mul (of_int high) 100_000_000L) (of_int ((g * per_thread) + d))))

let report c name nonce =
  let h = Ref.protocol_hash (Ref.digest_full c.l nonce) in
  if Ref.matches name h then (
    Printf.printf "%s %s\n%!" h (Ref.nonce_string nonce) ;
    true)
  else false

let cmd_hash path nonce =
  let l = Ref.load_dump path in
  let nonce = Int64.of_string nonce in
  let d1 = Ref.digest_of_words (Ref.digest_words l nonce) in
  let d2 = Ref.digest_full l nonce in
  if d1 <> d2 then failwith "mid-state digest differs from digestif" ;
  print_endline (Ref.protocol_hash d1)

let cmd_devices () =
  Array.iter
    (fun d -> Printf.printf "%-12s %s\n" d.Device.framework d.Device.name)
    (init_devices ())

(* Same nonce range on the device and with the OCaml reference: the raw
   prefilter hits must be identical, and so must the exact matches. *)
let cmd_check path name fw high nthreads =
  let l = Ref.load_dump path in
  let c = setup l (find_device fw) name in
  let t = Unix.gettimeofday () in
  let gpu = List.sort compare (launch c high nthreads) in
  let dt = Unix.gettimeofday () -. t in
  Printf.eprintf "device: %d raw hits in %.3fs\n%!" (List.length gpu) dt ;
  let cpu = ref [] in
  let t = Unix.gettimeofday () in
  for i = (nthreads * per_thread) - 1 downto 0 do
    let nonce = Int64.(add (mul (of_int high) 100_000_000L) (of_int i)) in
    let h = Ref.digest_words l nonce in
    if Ref.in_intervals c.ivs (Ref.top64 h.(0)) then cpu := nonce :: !cpu
  done ;
  let dt = Unix.gettimeofday () -. t in
  Printf.eprintf "OCaml reference: %d raw hits in %.3fs (%.0f nonces/s)\n%!"
    (List.length !cpu) dt
    (float (nthreads * per_thread) /. dt) ;
  let exact =
    List.filter
      (fun n -> Ref.matches name (Ref.protocol_hash (Ref.digest_full l n)))
      gpu
  in
  Printf.eprintf "exact matches (digestif re-hash of full dump): %d\n%!"
    (List.length exact) ;
  List.iter (fun n -> ignore (report c name n)) exact ;
  if gpu = !cpu then prerr_endline "CHECK OK: device and reference agree"
  else (
    prerr_endline "CHECK FAILED: device and reference differ" ;
    exit 1)

let cmd_bench path name fw seconds nthreads =
  let l = Ref.load_dump path in
  let c = setup l (find_device fw) name in
  Printf.eprintf "device: %s (%s), %d threads x %d nonces per launch\n%!"
    c.dev.Device.name fw nthreads per_thread ;
  (* warm-up: JIT + transfers of the constant tables *)
  ignore (launch c 0 nthreads) ;
  let high = ref (Random.self_init () ; Random.int 99_000_000 + 1) in
  let tested = ref 0 and found = ref 0 and raw = ref 0 in
  let t0 = Unix.gettimeofday () in
  while Unix.gettimeofday () -. t0 < seconds do
    let hits = launch c !high nthreads in
    raw := !raw + List.length hits ;
    List.iter (fun n -> if report c name n then incr found) hits ;
    tested := !tested + (nthreads * per_thread) ;
    incr high
  done ;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf
    "tested %d nonces in %.2fs: %.3f Mnonces/s (%d raw hits, %d exact)\n%!"
    !tested dt
    (float !tested /. dt /. 1e6)
    !raw !found

let () =
  match Array.to_list Sys.argv |> List.tl with
  | ["hash"; p; n] -> cmd_hash p n
  | ["devices"] -> cmd_devices ()
  | ["check"; p; name; fw; high; nt] ->
      cmd_check p name fw (int_of_string high) (int_of_string nt)
  | ["bench"; p; name; fw; s] -> cmd_bench p name fw (float_of_string s) max_threads
  | ["bench"; p; name; fw; s; nt] ->
      cmd_bench p name fw (float_of_string s) (int_of_string nt)
  | _ ->
      prerr_endline "see header of bin/proto_bench.ml for usage" ;
      exit 2
