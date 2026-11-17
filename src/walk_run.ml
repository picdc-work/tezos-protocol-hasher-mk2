module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute

type i64v = (int64, Bigarray.int64_elt) Vector.t

type i32v = (int32, Bigarray.int32_elt) Vector.t

type kernel = {curve : Curve_ref.curve; spec : Field_run.spec; ir : Sarek_ir_types.kernel}

let secp256k1 =
  {
    curve = Curve_ref.secp256k1;
    spec = List.find (fun s -> s.Field_run.name = "secp256k1") Field_run.specs;
    ir = Field_run.ir_of Walk_secp256k1.walk;
  }

type t = {
  dev : Device_search.device;
  kernel : kernel;
  threads : int;
  batch : int;
  mutable chunk : int;
  mutable cur_x : i64v;
  mutable cur_y : i64v;
  mutable next_x : i64v;
  mutable next_y : i64v;
  tab_x : i64v;
  tab_y : i64v;
  pre : i64v;
  ebits : i64v;
  nbits : int;
  h : i64v;
  vinit : i64v;
  lo : i64v;
  hi : i64v;
  nint : int;
  hit_count : i32v;
  hit_thread : i32v;
  hit_index : i32v;
  cap : int;
}

let chunk t = t.chunk

let chunk_size t = t.threads * t.batch

let vec64 a =
  let v = Vector.create Vector.int64 (max 1 (Array.length a)) in
  Array.iteri (Vector.set v) a ;
  v

let coords = function
  | Curve_ref.Infinity -> invalid_arg "Walk_run: point at infinity"
  | Curve_ref.Affine (x, y) -> (x, y)

(* [count] points start, start + step, start + 2 step, ... *)
let progression curve ~start ~step count =
  let points = Array.make count start in
  for i = 1 to count - 1 do
    points.(i) <- Curve_ref.add_points curve points.(i - 1) step
  done ;
  points

let pack_points k points =
  let mont = Field_run.to_mont k.spec in
  let xs = Array.map (fun p -> mont (fst (coords p))) points in
  let ys = Array.map (fun p -> mont (snd (coords p))) points in
  (Field_run.pack k.spec xs, Field_run.pack k.spec ys)

(* Base points of [chunk]: P0 + (chunk * size + t * batch) G. *)
let base_points k ~p0 ~threads ~batch ~chunk =
  let c = k.curve in
  let g = Curve_ref.generator c in
  let offset = Z.mul (Z.of_int chunk) (Z.of_int (threads * batch)) in
  let start = Curve_ref.add_points c p0 (Curve_ref.scalar_mul c offset g) in
  progression c ~start ~step:(Curve_ref.scalar_mul c (Z.of_int batch) g) threads

(* i G for i = 1 .. batch - 1, then the stride (threads * batch) G. *)
let table_points k ~threads ~batch =
  let c = k.curve in
  let g = Curve_ref.generator c in
  let multiples = progression c ~start:g ~step:g (max 1 (batch - 1)) in
  let stride = Curve_ref.scalar_mul c (Z.of_int (threads * batch)) g in
  Array.append (Array.sub multiples 0 (batch - 1)) [|stride|]

(* Blake2b with a 20-byte digest, one final block of 33 bytes: chaining
   value and v8..v15 (t0 = 33, f0 set). *)
let blake_constants () =
  let iv = Blake2b.iv in
  let vinit = Array.copy iv in
  vinit.(4) <- Int64.logxor vinit.(4) 33L ;
  vinit.(6) <- Int64.lognot vinit.(6) ;
  (vec64 (Blake2b.init ~len:20 ()), vec64 vinit)

let default_cap target size =
  let expected = float size /. Target.expected_rate target in
  int_of_float (Float.min (float (1 lsl 20)) (Float.max 1024. (4. *. expected)))

let create ?cap dev k target ~threads ~batch ~p0 ~chunk =
  if threads < 1 || batch < 1 || chunk < 0 then invalid_arg "Walk_run.create" ;
  let cur_x, cur_y = pack_points k (base_points k ~p0 ~threads ~batch ~chunk) in
  let tab_x, tab_y = pack_points k (table_points k ~threads ~batch) in
  let h, vinit = blake_constants () in
  let ebits, nbits = Field_run.exponent_bits k.spec in
  let ivs = Target.intervals target in
  let cap = match cap with Some c -> c | None -> default_cap target (threads * batch) in
  let scratch n = Vector.create Vector.int64 (max 1 n) in
  {
    dev;
    kernel = k;
    threads;
    batch;
    chunk;
    cur_x;
    cur_y;
    next_x = scratch (threads * k.spec.n);
    next_y = scratch (threads * k.spec.n);
    tab_x;
    tab_y;
    pre = scratch (threads * batch * k.spec.n);
    ebits;
    nbits;
    h;
    vinit;
    lo = vec64 (Array.map fst ivs);
    hi = vec64 (Array.map snd ivs);
    nint = Array.length ivs;
    hit_count = Vector.create Vector.int32 1;
    hit_thread = Vector.create Vector.int32 cap;
    hit_index = Vector.create Vector.int32 cap;
    cap;
  }

let block = 256

(* Launches threads [first, first + n); returns the number of hits counted
   (possibly above [cap], in which case only the first [cap] are stored). *)
let launch t ~cap ~first ~n =
  Vector.set t.hit_count 0 0l ;
  let i32 x = Execute.Int32 (Int32.of_int x) in
  Execute.run_vectors ~device:t.dev ~ir:t.kernel.ir
    ~args:
      Execute.
        [
          Vec t.cur_x; Vec t.cur_y; Vec t.next_x; Vec t.next_y; Vec t.tab_x; Vec t.tab_y;
          Vec t.pre; Vec t.ebits; i32 t.nbits; i32 t.batch; Vec t.h; Vec t.vinit; Vec t.lo;
          Vec t.hi; i32 t.nint; Vec t.hit_count; Vec t.hit_thread; Vec t.hit_index; i32 cap;
          i32 first; i32 n;
        ]
    ~block:(Execute.dims1d block) ~grid:(Execute.dims1d ((n + block - 1) / block)) () ;
  Transfer.flush t.dev ;
  Int32.to_int (Vector.get t.hit_count 0)

let stored_hits t count =
  List.init count (fun k ->
      (Int32.to_int (Vector.get t.hit_thread k) * t.batch) + Int32.to_int (Vector.get t.hit_index k))

let run ?cap t =
  let cap = match cap with Some k -> min k t.cap | None -> t.cap in
  let rec go first n acc =
    if n = 0 then acc
    else
      let count = launch t ~cap ~first ~n in
      if count <= cap then stored_hits t count @ acc
      else if n = 1 then failwith "Walk_run: hit buffer overflow on a single thread"
      else
        let half = n / 2 in
        go (first + half) (n - half) (go first half acc)
  in
  List.sort_uniq compare (go 0 t.threads [])

let decode t xs ys =
  let spec = t.kernel.spec in
  let x = Field_run.unpack spec xs t.threads and y = Field_run.unpack spec ys t.threads in
  Array.mapi (fun i xi -> (Field_run.of_mont spec xi, Field_run.of_mont spec y.(i))) x

let next_state t = decode t t.next_x t.next_y

let state t = decode t t.cur_x t.cur_y

let advance t =
  let x = t.cur_x and y = t.cur_y in
  t.cur_x <- t.next_x ;
  t.cur_y <- t.next_y ;
  t.next_x <- x ;
  t.next_y <- y ;
  t.chunk <- t.chunk + 1
