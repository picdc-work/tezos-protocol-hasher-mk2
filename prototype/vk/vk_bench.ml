(* Prototype: GPU tz1 vanity keys with Sarek.

   vk_bench ref <seed hex>                       reference pk / tz1 / edsk
   vk_bench devices
   vk_bench check <framework> <nthreads> <kper>   device == reference, all keys
   vk_bench bench <framework> <seconds> <nthreads> <kper> <word> [ci] *)

module R = Ref25519
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
  match Array.find_opt (fun d -> d.Device.framework = fw) (init_devices ()) with
  | Some d -> d
  | None -> failwith ("no device for framework " ^ fw)

let ir =
  let _, kirc = Vk_kernel.keygen in
  match kirc.Sarek.Kirc_types.body_ir with Some ir -> ir | None -> failwith "no IR"

let vec64 a =
  let v = Vector.create Vector.int64 (Array.length a) in
  Array.iteri (Vector.set v) a ;
  v

let random_words () =
  let ic = open_in_bin "/dev/urandom" in
  let s = really_input_string ic 32 in
  close_in ic ;
  Array.init 4 (fun i -> String.get_int64_be s (8 * i))

let cap = 1 lsl 16

type ctx = {
  dev : Device.t;
  seed : (int64, Bigarray.int64_elt) Vector.t;
  tbl : (int64, Bigarray.int64_elt) Vector.t;
  lo : (int64, Bigarray.int64_elt) Vector.t;
  hi : (int64, Bigarray.int64_elt) Vector.t;
  nint : int;
  hit_count : (int32, Bigarray.int32_elt) Vector.t;
  hit_gid : (int32, Bigarray.int32_elt) Vector.t;
  hit_k : (int32, Bigarray.int32_elt) Vector.t;
  dbg : (int64, Bigarray.int64_elt) Vector.t;
}

let setup dev ivs ndbg =
  let t = Unix.gettimeofday () in
  let tbl = vec64 (R.table ()) in
  Printf.eprintf "fixed-base table: %.1fs\n%!" (Unix.gettimeofday () -. t) ;
  let ivs = if Array.length ivs = 0 then [|(0L, -1L)|] else ivs in
  {
    dev;
    seed = Vector.create Vector.int64 4;
    tbl;
    lo = vec64 (Array.map fst ivs);
    hi = vec64 (Array.map snd ivs);
    nint = Array.length ivs;
    hit_count = Vector.create Vector.int32 1;
    hit_gid = Vector.create Vector.int32 cap;
    hit_k = Vector.create Vector.int32 cap;
    dbg = Vector.create Vector.int64 (max 7 ndbg);
  }

let launch c base ~dbgon nthreads kper =
  Array.iteri (Vector.set c.seed) base ;
  Vector.set c.hit_count 0 0l ;
  let block = 128 in
  let grid = (nthreads + block - 1) / block in
  let i32 n = Execute.Int32 (Int32.of_int n) in
  Execute.run_vectors ~device:c.dev ~ir
    ~args:
      Execute.
        [
          Vec c.seed; Vec c.tbl; Vec c.lo; Vec c.hi; i32 c.nint; Vec c.hit_count;
          Vec c.hit_gid; Vec c.hit_k; i32 cap; Vec c.dbg; i32 (if dbgon then 1 else 0);
          i32 kper; i32 nthreads;
        ]
    ~block:(Execute.dims1d block) ~grid:(Execute.dims1d grid) () ;
  Transfer.flush c.dev ;
  let n = Int32.to_int (Vector.get c.hit_count 0) in
  if n > cap then Printf.eprintf "warning: %d hits, %d kept\n%!" n cap ;
  List.init (min n cap) (fun i ->
      (Int32.to_int (Vector.get c.hit_gid i), Int32.to_int (Vector.get c.hit_k i)))

let words_le s = Array.init (String.length s / 8) (fun i -> String.get_int64_le s (8 * i))

let cmd_ref seedhex =
  let seed = String.init 32 (fun i -> Char.chr (int_of_string ("0x" ^ String.sub seedhex (2 * i) 2))) in
  let pk = R.public_key seed in
  Printf.printf "pk   %s\nedpk %s\ntz1  %s\nedsk %s\n" (R.hex pk) (R.edpk pk) (R.tz1 pk) (R.edsk seed)

let cmd_check fw nthreads kper =
  let c = setup (find_device fw) [||] (nthreads * kper * 7) in
  let base = random_words () in
  for i = 0 to Vector.length c.dbg - 1 do Vector.set c.dbg i 0L done ;
  let t = Unix.gettimeofday () in
  ignore (launch c base ~dbgon:true nthreads kper) ;
  Printf.eprintf "device: %d keys in %.3fs\n%!" (nthreads * kper) (Unix.gettimeofday () -. t) ;
  let bad = ref 0 in
  for gid = 0 to nthreads - 1 do
    for k = 0 to kper - 1 do
      let seed = R.seed_of_words (R.seed_words base gid k) in
      let pk = R.public_key seed in
      let exp =
        match Sys.getenv_opt "VK_DBG" with
        | Some "sha" ->
            let h = Digestif.SHA512.(to_raw_string (digest_string seed)) in
            Array.append (words_le (R.le_bytes 32 (R.clamp h))) [|0L; 0L; 0L|]
        | _ -> Array.append (words_le pk) (words_le (R.pkh pk ^ "\000\000\000\000"))
      in
      let o = ((gid * kper) + k) * 7 in
      let got = Array.init 7 (fun i -> Vector.get c.dbg (o + i)) in
      if Sys.getenv_opt "VK_DBG" = None then got.(6) <- Int64.logand got.(6) 0xffffffffL ;
      if got <> exp then begin
        incr bad ;
        if !bad <= 3 then
          Printf.eprintf "MISMATCH gid=%d k=%d seed=%s\n  exp %s\n  got %s\n%!" gid k (R.hex seed)
            (String.concat " " (Array.to_list (Array.map (Printf.sprintf "%016Lx") exp)))
            (String.concat " " (Array.to_list (Array.map (Printf.sprintf "%016Lx") got)))
      end
    done
  done ;
  if !bad = 0 then Printf.eprintf "CHECK OK: %d keys, pk and Blake2b-160 identical\n%!" (nthreads * kper)
  else (Printf.eprintf "CHECK FAILED: %d keys differ\n%!" !bad ; exit 1)

(* All keys of one launch, for an external check: seed pk pkh (hex). *)
let cmd_dump fw nthreads kper =
  let c = setup (find_device fw) [||] (nthreads * kper * 7) in
  let base = random_words () in
  ignore (launch c base ~dbgon:true nthreads kper) ;
  let le w = String.concat "" (List.map (fun x -> let b = Bytes.create 8 in Bytes.set_int64_le b 0 x ; Bytes.to_string b) w) in
  for gid = 0 to nthreads - 1 do
    for k = 0 to kper - 1 do
      let o = ((gid * kper) + k) * 7 in
      let g i = Vector.get c.dbg (o + i) in
      Printf.printf "%s %s %s\n" (R.hex (R.seed_of_words (R.seed_words base gid k)))
        (R.hex (le [g 0; g 1; g 2; g 3])) (String.sub (R.hex (le [g 4; g 5; g 6])) 0 40)
    done
  done

let cmd_bench fw seconds nthreads kper word ci =
  let ivs = R.intervals ~ci word in
  Printf.eprintf "target tz1%s%s: %d interval(s)\n%!" word (if ci then " (case-insensitive)" else "")
    (Array.length ivs) ;
  let c = setup (find_device fw) ivs 0 in
  Printf.eprintf "device: %s (%s), %d threads x %d keys per launch\n%!" c.dev.Device.name fw nthreads kper ;
  let t = Unix.gettimeofday () in
  ignore (launch c (random_words ()) ~dbgon:false nthreads kper) ;
  Printf.eprintf "warm-up launch: %.2fs\n%!" (Unix.gettimeofday () -. t) ;
  let tested = ref 0 and raw = ref 0 and found = ref 0 in
  let t0 = Unix.gettimeofday () in
  while Unix.gettimeofday () -. t0 < seconds do
    let base = random_words () in
    let hits = launch c base ~dbgon:false nthreads kper in
    tested := !tested + (nthreads * kper) ;
    raw := !raw + List.length hits ;
    List.iter
      (fun (gid, k) ->
        let seed = R.seed_of_words (R.seed_words base gid k) in
        let pk = R.public_key seed in
        let a = R.tz1 pk in
        if R.matches ~ci word a then begin
          incr found ;
          Printf.printf "%s %s\n%!" a (R.edsk seed)
        end)
      hits
  done ;
  let dt = Unix.gettimeofday () -. t0 in
  Printf.eprintf "tested %d keys in %.2fs: %.0f keys/s (%d raw hits, %d exact)\n%!" !tested dt
    (float !tested /. dt) !raw !found

let () =
  match List.tl (Array.to_list Sys.argv) with
  | ["ref"; s] -> cmd_ref s
  | ["dump"; fw; nt; kp] -> cmd_dump fw (int_of_string nt) (int_of_string kp)
  | ["devices"] ->
      Array.iter (fun d -> Printf.printf "%-12s %s\n" d.Device.framework d.Device.name) (init_devices ())
  | ["check"; fw; nt; kp] -> cmd_check fw (int_of_string nt) (int_of_string kp)
  | ["bench"; fw; s; nt; kp; w] -> cmd_bench fw (float_of_string s) (int_of_string nt) (int_of_string kp) w false
  | ["bench"; fw; s; nt; kp; w; "ci"] ->
      cmd_bench fw (float_of_string s) (int_of_string nt) (int_of_string kp) w true
  | _ -> prerr_endline "see header of vk/vk_bench.ml" ; exit 2
