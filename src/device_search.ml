module Device = Spoc_core.Device
module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute

type device = Device.t

let devices =
  let all =
    lazy
      (Sarek_native.Native_plugin.init () ;
       Sarek_cuda.Cuda_plugin.init () ;
       Sarek_cuda.Cuda_c_plugin.init () ;
       Device.init ())
  in
  fun () -> Lazy.force all

let framework d = d.Device.framework

let name d = d.Device.name

let find fw = Array.find_opt (fun d -> framework d = fw) (devices ())

let best_gpu () =
  match find "CUDA/PTX" with
  | Some d -> Ok d
  | None -> (
      match find "CUDA/C" with
      | Some d -> Ok d
      | None ->
          Error
            "no GPU device found (frameworks tried: CUDA/PTX, CUDA/C); use \
             --cpu to search on the CPU")

let cpu_device () =
  match find "Native" with Some d -> d | None -> failwith "no Native device"

type mode = Kernel_a | Host_penultimate | Kernel_b | Kernel_c

let mode_name = function
  | Kernel_a -> "one compression per nonce"
  | Host_penultimate -> "one compression per nonce (next-to-last block per chunk on host)"
  | Kernel_b -> "next-to-last block per thread, final block per nonce"
  | Kernel_c -> "two compressions per nonce"

let ir_of (_, kirc) =
  match kirc.Sarek.Kirc_types.body_ir with
  | Some ir -> ir
  | None -> failwith "kernel without IR"

let threads_per_chunk = 1_000_000

type i64v = (int64, Bigarray.int64_elt) Vector.t

type i32v = (int32, Bigarray.int32_elt) Vector.t

type ctx = {
  dev : device;
  dump : Dump.t;
  mode : mode;
  ir : Sarek_ir_types.kernel;
  origin : int;  (** byte offset of word 0 of the 32-word space *)
  h : i64v;
  vinit : i64v;
  tmpl : i64v;
  mida : i64v;
  midb : i64v;
  wa : int;
  wl1 : int;
  sl1 : int;
  wl2 : int;
  sl2 : int;
  lo : i64v;
  hi : i64v;
  nint : int;
  hit_count : i32v;
  hit_thread : i32v;
  hit_loop : i32v;
  cap : int;
}

let mode c = c.mode

let device c = c.dev

let default_cap c = c.cap

let vec64 a =
  let v = Vector.create Vector.int64 (max 1 (Array.length a)) in
  Array.iteri (Vector.set v) a ;
  v

let prepare dev (dump : Dump.t) target =
  let origin = dump.final_block_offset - 128 in
  let d = dump.digits_offset in
  let word pos = (pos - origin) / 8 and shift pos = 8 * ((pos - origin) mod 8) in
  let mode =
    match dump.layout_case with
    | Dump.A -> Kernel_a
    | Dump.B -> if d + 8 >= dump.final_block_offset then Host_penultimate else Kernel_b
    | Dump.C -> Kernel_c
  in
  let ir =
    ir_of
      (match mode with
      | Kernel_a | Host_penultimate -> Kernels.search_a
      | Kernel_b -> Kernels.search_b
      | Kernel_c -> Kernels.search_c)
  in
  let wa = word (d + 8) in
  let mida = Vector.create Vector.int64 threads_per_chunk in
  let midb = Vector.create Vector.int64 threads_per_chunk in
  for g = 0 to threads_per_chunk - 1 do
    let s = Printf.sprintf "%06d" g in
    let a = ref 0L and b = ref 0L in
    String.iteri
      (fun j c ->
        let pos = d + 8 + j in
        let x = Int64.shift_left (Int64.of_int (Char.code c)) (shift pos) in
        if word pos = wa then a := Int64.logor !a x else b := Int64.logor !b x)
      s ;
    Vector.set mida g !a ;
    Vector.set midb g !b
  done ;
  let vinit = Array.make 16 0L in
  Array.blit Blake2b.iv 0 vinit 0 8 ;
  Array.blit Blake2b.iv 0 vinit 8 8 ;
  vinit.(4) <- Int64.logxor vinit.(4) (Int64.of_int dump.final_block_offset) ;
  vinit.(12) <- Int64.logxor vinit.(12) (Int64.of_int dump.length) ;
  vinit.(14) <- Int64.lognot vinit.(14) ;
  let ivs = Target.intervals target in
  let expected = 1e8 /. Target.expected_rate target in
  let cap = int_of_float (Float.min (float (1 lsl 24)) (Float.max 1024. (4. *. expected))) in
  {
    dev;
    dump;
    mode;
    ir;
    origin;
    h = vec64 dump.base_state;
    vinit = vec64 vinit;
    tmpl = Vector.create Vector.int64 32;
    mida;
    midb;
    wa;
    wl1 = word (d + 14);
    sl1 = shift (d + 14);
    wl2 = word (d + 15);
    sl2 = shift (d + 15);
    lo = vec64 (Array.map fst ivs);
    hi = vec64 (Array.map snd ivs);
    nint = Array.length ivs;
    hit_count = Vector.create Vector.int32 1;
    hit_thread = Vector.create Vector.int32 cap;
    hit_loop = Vector.create Vector.int32 cap;
    cap;
  }

(* The 32-word space for a chunk: launch digits written, thread and loop
   digit bytes zeroed. *)
let set_template c ~chunk =
  let dump = c.dump in
  let space = Bytes.make 256 '\000' in
  let src = max c.origin 0 in
  Bytes.blit dump.Dump.data src space (src - c.origin) (dump.length - src) ;
  let d = dump.digits_offset - c.origin in
  Bytes.blit_string (Printf.sprintf "%08d" chunk) 0 space d 8 ;
  Bytes.fill space (d + 8) 8 '\000' ;
  let words = Array.init 32 (fun i -> Bytes.get_int64_le space (8 * i)) in
  Array.iteri (Vector.set c.tmpl) words ;
  if c.mode = Host_penultimate then begin
    let h = Array.copy dump.base_state in
    Blake2b.compress h (Array.sub words 0 16)
      ~t0:(Int64.of_int dump.final_block_offset) ~last:false ;
    Array.iteri (Vector.set c.h) h
  end

let launch c ~cap ~first ~n =
  Vector.set c.hit_count 0 0l ;
  let block = 256 in
  let grid = (n + block - 1) / block in
  Execute.run_vectors ~device:c.dev ~ir:c.ir
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
          Vec c.hit_thread;
          Vec c.hit_loop;
          Int32 (Int32.of_int cap);
          Int32 (Int32.of_int first);
          Int32 (Int32.of_int n);
        ]
    ~block:(Execute.dims1d block) ~grid:(Execute.dims1d grid) () ;
  Transfer.flush c.dev ;
  Int32.to_int (Vector.get c.hit_count 0)

let run_chunk ?(nthreads = threads_per_chunk) ?cap c ~chunk =
  let cap = match cap with Some k -> min k c.cap | None -> c.cap in
  set_template c ~chunk ;
  let rec go first n acc =
    if n = 0 then acc
    else
      let count = launch c ~cap ~first ~n in
      if count > cap && n > 1 then
        let half = n / 2 in
        go (first + half) (n - half) (go first half acc)
      else begin
        if count > cap then failwith "hit buffer overflow on a single thread" ;
        let acc = ref acc in
        for k = 0 to count - 1 do
          let th = Int32.to_int (Vector.get c.hit_thread k) in
          let lp = Int32.to_int (Vector.get c.hit_loop k) in
          acc := Nonce_space.make ~chunk ~thread:th ~loop:lp :: !acc
        done ;
        !acc
      end
  in
  List.sort_uniq compare (go 0 nthreads [])

let is_gpu d = List.mem (framework d) ["CUDA/PTX"; "CUDA/C"]

let list_devices () =
  Array.to_list (Array.mapi (fun i d -> (i, framework d, name d)) (devices ()))

let select s =
  let all = Array.to_list (Array.mapi (fun i d -> (i, d)) (devices ())) in
  match int_of_string_opt s with
  | Some i -> (
      match List.assoc_opt i all with
      | Some d -> Ok [(i, d)]
      | None ->
          Error
            (Printf.sprintf "device %S: no such device index (see --list-devices)" s))
  | None -> (
      if s = "all-gpus" then
        match List.filter (fun (_, d) -> framework d = "CUDA/PTX") all with
        | [] -> Error "device \"all-gpus\": no GPU device found"
        | l -> Ok l
      else
        match List.find_opt (fun (_, d) -> framework d = s) all with
        | Some x -> Ok [x]
        | None ->
            Error
              (Printf.sprintf
                 "device %S: no such device or framework (see --list-devices)" s))
