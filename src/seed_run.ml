module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute

type i64v = (int64, Bigarray.int64_elt) Vector.t

type i32v = (int32, Bigarray.int32_elt) Vector.t

let spec = List.find (fun s -> s.Field_run.name = "ed25519") Field_run.specs

let ir = lazy (Field_run.ir_of Seed_ed25519.search)

type t = {
  dev : Device_search.device;
  base : string;
  threads : int;
  batch : int;
  ctrs : i64v;
  seedw : i64v;
  tab : i64v;
  px : i64v;
  py : i64v;
  pz : i64v;
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

let vec64 a =
  let v = Vector.create Vector.int64 (max 1 (Array.length a)) in
  Array.iteri (Vector.set v) a ;
  v

let default_cap target size =
  let expected = float size /. Target.expected_rate target in
  int_of_float (Float.min (float (1 lsl 20)) (Float.max 1024. (4. *. expected)))

let create ?cap dev target ~base ~threads ~batch =
  if threads < 1 || batch < 1 || String.length base <> Seed_keys.base_length then
    invalid_arg "Seed_run.create" ;
  let h, vinit = Walk_run.blake_constants Address.(public_key_length Tz1) in
  let ebits, nbits = Field_run.exponent_bits spec in
  let ivs = Target.intervals target in
  let cap = match cap with Some c -> c | None -> default_cap target (threads * batch) in
  let scratch n = Vector.create Vector.int64 (max 1 n) in
  let per_seed = threads * batch * spec.n in
  {
    dev;
    base;
    threads;
    batch;
    ctrs = scratch threads;
    seedw = vec64 (Seed_keys.prefix_words base);
    tab = Seed_table.build ~window_bits:Seed_table.window_bits;
    px = scratch per_seed;
    py = scratch per_seed;
    pz = scratch per_seed;
    pre = scratch per_seed;
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

let launch_size t = t.threads * t.batch

let block = 256

(* Threads [first, first + n); returns the number of hits counted (possibly
   above [cap], in which case only the first [cap] are stored). *)
let launch t ~cap ~first ~n =
  Vector.set t.hit_count 0 0l ;
  let i32 x = Execute.Int32 (Int32.of_int x) in
  Execute.run_vectors ~device:t.dev ~ir:(Lazy.force ir)
    ~args:
      Execute.
        [
          Vec t.ctrs; Vec t.seedw; Vec t.tab; Vec t.px; Vec t.py; Vec t.pz; Vec t.pre;
          Vec t.ebits; i32 t.nbits; i32 t.batch; Vec t.h; Vec t.vinit; Vec t.lo; Vec t.hi;
          i32 t.nint; Vec t.hit_count; Vec t.hit_thread; Vec t.hit_index; i32 cap; i32 first;
          i32 n;
        ]
    ~block:(Execute.dims1d block) ~grid:(Execute.dims1d ((n + block - 1) / block)) () ;
  Transfer.flush t.dev ;
  Int32.to_int (Vector.get t.hit_count 0)

let stored_hits t count =
  List.init count (fun k ->
      (Int32.to_int (Vector.get t.hit_thread k) * t.batch) + Int32.to_int (Vector.get t.hit_index k))

(* The counter of thread [i] is u + start + i * batch (mod 2^64). *)
let set_counters t ~start =
  let first = Int64.add (Seed_keys.counter t.base) start in
  for i = 0 to t.threads - 1 do
    Vector.set t.ctrs i (Int64.add first (Int64.of_int (i * t.batch)))
  done

let run ?cap t ~start =
  set_counters t ~start ;
  let cap = match cap with Some k -> min k t.cap | None -> t.cap in
  let rec go first n acc =
    if n = 0 then acc
    else
      let count = launch t ~cap ~first ~n in
      if count <= cap then stored_hits t count @ acc
      else if n = 1 then failwith "Seed_run: hit buffer overflow on a single thread"
      else
        let half = n / 2 in
        go (first + half) (n - half) (go first half acc)
  in
  List.sort_uniq compare (go 0 t.threads [])
