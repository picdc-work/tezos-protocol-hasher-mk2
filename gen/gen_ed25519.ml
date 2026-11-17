(* Generates the Ed25519 seed-search kernel of the tz1 address search as a
   Sarek kernel module.

   Usage: gen_ed25519.exe search WBITS   the search kernel (WBITS: 4 or 8)
          gen_ed25519.exe probe STAGE    a test kernel writing the
                                         intermediate values of each stage

   Candidates. Each thread handles [bsz] consecutive seeds. A seed is the
   first 24 bytes of the base (words seedw.(0..2), big-endian) followed by
   the 64-bit big-endian counter u + j (an int64 that wraps): the counter of
   thread th is read from ctrs.(th) and incremented per seed, so the kernel
   never converts an index to int64 (Sarek has no such conversion).

   Per seed (RFC 8032 section 5.1.5). 1. SHA-512 of the 32-byte seed, one
   block: words 0..2 and the counter, then 0x80, zeros and the length 256
   bits (Sha512_emit). 2. The scalar a: the first 32 digest bytes read
   little-endian, so each of H0..H3 is byte-swapped; clamped (low 3 bits of
   byte 0 cleared, bit 255 cleared and bit 254 set). 3. A = a B by windows
   of WBITS bits: the table [tab] holds, for window i and digit d, the point
   d * 2^(WBITS i) B as (y+x, y-x, 2 d x y) in Montgomery limbs (30 int64
   per entry, d = 0 being the neutral element (1, 1, 0)), at
   ((i * 2^WBITS) + d) * 30. The accumulator is in extended coordinates
   (X:Y:Z:T) and each window adds its entry with the mixed addition
   add-2008-hwcd-3 (a = -1, Z2 = 1), which is complete on Ed25519 (d is not a
   square): digit 0, doubling and the neutral element need no special case,
   and Z never becomes 0. The loop is two nested loops, over the 4 words of
   the scalar and over the 64/WBITS digits of the word in hand (shifted down
   by WBITS each step), with one inlined mixed addition. The table index
   needs an int32 digit, built bit by bit from the int64 digit (no
   conversion in Sarek). 4. X, Y, Z of every seed go to scratch vectors and
   the prefix products of Z to [pre]; one inversion per thread (Montgomery's
   trick), then x = X/Z, y = Y/Z out of Montgomery form with three products
   (the inverse out of Montgomery form once, then X and Y times it). 5. The
   public key: y little-endian, bit 255 = parity of x, as the first four
   words of a Blake2b message of 32 bytes (h and vinit from the host, digest
   length 20, t0 = 32, f0 folded in) and the prefix 06 a1 9f for the
   prefilter. A hit is recorded as (thread, index in the thread's batch).

   The probe kernel computes the same values for one seed per thread, with
   one inversion per seed, up to STAGE: 1 SHA-512, 2 clamped scalar, 3
   affine x and y, 4 encoded key and Blake2b words. It writes 39 int64 per
   seed: H0..H7, scalar words 0..3, x limbs, y limbs, key words 0..3,
   Blake2b words 0..2. *)

open Field_emit

let f = List.find (fun f -> f.name = "ed25519") fields

let one_mont = limbs (Z.erem (Z.shift_left Z.one (limb_bits * f.n)) f.prime) f.n

let probe_width = 39

(* --- SHA-512 and the scalar ------------------------------------------- *)

let bswap x =
  String.concat " lor "
    (List.init 8 (fun i ->
         Printf.sprintf "(((%s lsr %dL) land 255L) lsl %dL)" x (8 * i) (56 - (8 * i))))

(* H0..H7 of the seed made of the words [w0..w2] and the counter [cnt]. *)
let emit_digest ~constants ~cnt =
  let block = Array.make 16 "0L" in
  block.(0) <- "seedw0" ;
  block.(1) <- "seedw1" ;
  block.(2) <- "seedw2" ;
  block.(3) <- cnt ;
  block.(4) <- bind "pad" (Sha512_emit.safe_literal Int64.min_int) ;
  block.(15) <- "256L" ;
  Sha512_emit.compress ~bind ~constants block

(* The four clamped little-endian words of the scalar. *)
let emit_scalar h =
  let clear_top = bind "sc" (Sha512_emit.safe_literal Int64.max_int) in
  let set_bit_254 = bind "sc" (Sha512_emit.safe_literal 0x4000000000000000L) in
  let word i = bind "sc" (bswap h.(i)) in
  let s0 = word 0 and s1 = word 1 and s2 = word 2 and s3 = word 3 in
  let c0 = bind "sc" (Printf.sprintf "%s land 0xfffffffffffffff8L" s0) in
  let c3 = bind "sc" (Printf.sprintf "(%s land %s) lor %s" s3 clear_top set_bit_254) in
  [|c0; s1; s2; c3|]

(* --- Fixed-base multiplication ------------------------------------------ *)

(* The int32 digit of the int64 [dg] (below 2^wbits), by its bits. *)
let digit32 wbits =
  String.concat " + "
    (List.init wbits (fun b ->
         let v = 1 lsl b in
         Printf.sprintf "(if (dg land %dL) = 0L then 0l else %dl)" v v))

(* Mixed addition acc <- acc + (ypx, ymx, kxy), complete (see the header). *)
let emit_madd ~x ~y ~z ~t ~ypx ~ymx ~kxy =
  let a = emit_mul f (emit_sub f y x) ymx in
  let b = emit_mul f (emit_add f y x) ypx in
  let c = emit_mul f t kxy in
  let d = emit_add f z z in
  let e = emit_sub f b a and ff = emit_sub f d c and g = emit_add f d c and h = emit_add f b a in
  let x3 = emit_mul f e ff and y3 = emit_mul f g h in
  let t3 = emit_mul f e h and z3 = emit_mul f ff g in
  let assign dst src = Array.iteri (fun j s -> line "%s := %s ;" dst.(j) s) src in
  assign x x3 ; assign y y3 ; assign z z3 ; assign t t3

(* Declares the accumulator, runs the windows over the scalar words [s];
   returns the names of the mutable X, Y, Z. *)
let emit_windows ~wbits s =
  let per_word = 64 / wbits in
  let x = names "ax" f.n and y = names "ay" f.n and z = names "az" f.n and t = names "at" f.n in
  let declare r vals = Array.iteri (fun j v -> line "let %s = mut %dL in" r.(j) v) vals in
  declare x (Array.make f.n 0) ;
  declare y one_mont ;
  declare z one_mont ;
  declare t (Array.make f.n 0) ;
  line "for k = 0l to 3l do" ;
  line "let wd = if k = 0l then %s else if k = 1l then %s else if k = 2l then %s else %s in" s.(0)
    s.(1) s.(2) s.(3) ;
  line "let cur = mut wd in" ;
  line "for m = 0l to %dl do" (per_word - 1) ;
  line "let dg = cur land %dL in" ((1 lsl wbits) - 1) ;
  line "let d32 = %s in" (digit32 wbits) ;
  line "let slot = ((k * %dl + m) * %dl + d32) * 30l in" per_word (1 lsl wbits) ;
  line "let slot2 = slot + 10l in" ;
  line "let slot3 = slot + 20l in" ;
  let ypx = load f "tab" "slot" "yp" in
  let ymx = load f "tab" "slot2" "ym" in
  let kxy = load f "tab" "slot3" "kx" in
  emit_madd ~x ~y ~z ~t ~ypx ~ymx ~kxy ;
  line "cur := cur lsr %dL" wbits ;
  line "done" ;
  line "done ;" ;
  (x, y, z)

(* --- Encoding and hashing ----------------------------------------------- *)

(* Bits [64 k, 64 k + 64) of the 255-bit value in 28-bit limbs [v]. *)
let word_expr v k =
  let lo = 64 * k in
  let terms = ref [] in
  Array.iteri
    (fun j vj ->
      let start = limb_bits * j in
      if start + limb_bits > lo && start < lo + 64 then
        terms :=
          (if start >= lo then Printf.sprintf "(%s lsl %dL)" vj (start - lo)
           else Printf.sprintf "(%s lsr %dL)" vj (lo - start))
          :: !terms)
    v ;
  String.concat " lor " (List.rev !terms)

(* The four words of the public key: y little-endian, bit 255 = parity of x. *)
let emit_key_words ~x ~y =
  Array.init 4 (fun k ->
      let w = word_expr y k in
      bind "kw" (if k = 3 then Printf.sprintf "%s lor ((%s land 1L) lsl 63L)" w x.(0) else w))

(* Blake2b-20 of the 32-byte key; the names of the digest words [outs]. *)
let emit_blake kw ~outs =
  let m = Array.init 16 (fun i -> if i < 4 then kw.(i) else "0L") in
  Blake_emit.compress ~tprefix:"bt" buf "" ~tag:"w" ~hin:(names "hw" 8) ~vin:(names "vw" 8) ~m ~outs

let load_blake_constants () =
  for i = 0 to 7 do
    line "let hw%d = h.(%dl) in" i i ;
    line "let vw%d = vinit.(%dl) in" i i
  done

(* Affine x, y out of Montgomery form given X, Y and the Montgomery inverse of Z. *)
let emit_affine ~x ~y ~inv =
  let raw_one = Array.init f.n (fun j -> if j = 0 then "1L" else "0L") in
  let plain_inv = emit_mul f inv raw_one in
  (emit_mul f x plain_inv, emit_mul f y plain_inv)

(* --- Search kernel -------------------------------------------------------- *)

let search_params =
  "(ctrs : int64 vector) (seedw : int64 vector) (tab : int64 vector) (px : int64 vector) (py : int64 vector) (pz : int64 vector) (pre : int64 vector) (ebits : int64 vector) (nbits : int32) (bsz : int32) (h : int64 vector) (vinit : int64 vector) (lo : int64 vector) (hi : int64 vector) (nint : int32) (hit_count : int32 vector) (hit_thread : int32 vector) (hit_index : int32 vector) (cap : int32) (first_thread : int32) (nthreads : int32)"

let kernel_start name params guard =
  line "let %s =" name ;
  line "  [%%kernel" ;
  line "    fun %s ->" params ;
  line "      let open Sarek_stdlib.Std in" ;
  line "      let gid = global_thread_id in" ;
  line "      if %s then begin" guard

(* Phase 1: for each seed of the batch, X, Y, Z to the scratch vectors and the
   running product of Z to [pre]. Returns the names of the total product. *)
let emit_seeds ~wbits =
  let acc = names "pa" f.n in
  Array.iteri (fun j v -> line "let %s = mut %dL in" acc.(j) v) one_mont ;
  line "let cnt = mut ctrs.(th) in" ;
  let constants = Sha512_emit.emit_constants ~bind in
  line "for e = 0l to bsz - 1l do" ;
  let scalar = emit_scalar (emit_digest ~constants ~cnt:"cnt") in
  let x, y, z = emit_windows ~wbits scalar in
  line "let at = first + e * %dl in" f.n ;
  store "px" "at" x ;
  store "py" "at" y ;
  store "pz" "at" z ;
  let prod = emit_mul f acc z in
  Array.iteri (fun j p -> line "%s := %s ;" acc.(j) p) prod ;
  store "pre" "at" acc ;
  line "cnt := cnt + 1L ;" ;
  line "()" ;
  line "done ;" ;
  acc

(* Phase 2: backwards over the batch, the inverse of each Z, the point, its
   hash and the prefilter. *)
let emit_points ~inv_total =
  let cur = names "ia" f.n in
  Array.iteri (fun j r -> line "let %s = mut %s in" cur.(j) r) inv_total ;
  line "for s = 0l to bsz - 1l do" ;
  line "let e = bsz - 1l - s in" ;
  line "let at = first + e * %dl in" f.n ;
  line "let before = first + (if e > 0l then e - 1l else 0l) * %dl in" f.n ;
  let one = Array.map (Printf.sprintf "%dL") one_mont in
  let pm =
    Array.mapi
      (fun j q -> bind "o" (Printf.sprintf "if e > 0l then %s else %s" q one.(j)))
      (load f "pre" "before" "q")
  in
  let inv_e = emit_mul f cur pm in
  let next = emit_mul f cur (load f "pz" "at" "z") in
  Array.iteri (fun j n -> line "%s := %s ;" cur.(j) n) next ;
  let x, y = emit_affine ~x:(load f "px" "at" "x") ~y:(load f "py" "at" "y") ~inv:inv_e in
  emit_blake (emit_key_words ~x ~y) ~outs:[0] ;
  let record = ["hit_thread.(k) <- th ;"; "hit_index.(k) <- e"] in
  List.iter (line "%s")
    (Blake_emit.filter_lines ~top:(Blake_emit.prefilter_top ~prefix:"0x06a19f0000000000L") ~record) ;
  line "()" ;
  line "done ;"

let search_kernel ~wbits =
  kernel_start "search" search_params "gid < nthreads" ;
  line "        let th = first_thread + gid in" ;
  line "        let first = th * bsz * %dl in" f.n ;
  for i = 0 to 2 do
    line "let seedw%d = seedw.(%dl) in" i i
  done ;
  load_blake_constants () ;
  let total = emit_seeds ~wbits in
  emit_points ~inv_total:(emit_pow_loop f ~x:total) ;
  footer ()

(* --- Probe kernel ------------------------------------------------------- *)

let probe_params =
  "(ctrs : int64 vector) (seedw : int64 vector) (tab : int64 vector) (ebits : int64 vector) (nbits : int32) (h : int64 vector) (vinit : int64 vector) (dbg : int64 vector) (count : int32)"

let probe_store at values =
  Array.iteri (fun j v -> line "dbg.(base + %dl) <- %s ;" (at + j) v) values

let probe_kernel ~wbits ~stage =
  kernel_start "probe" probe_params "gid < count" ;
  line "        let base = gid * %dl in" probe_width ;
  for i = 0 to 2 do
    line "let seedw%d = seedw.(%dl) in" i i
  done ;
  if stage >= 4 then load_blake_constants () ;
  let constants = Sha512_emit.emit_constants ~bind in
  let digest = emit_digest ~constants ~cnt:(bind "cn" "ctrs.(gid)") in
  probe_store 0 digest ;
  if stage >= 2 then begin
    let scalar = emit_scalar digest in
    probe_store 8 scalar ;
    if stage >= 3 then begin
      let x, y, z = emit_windows ~wbits scalar in
      let ax, ay = emit_affine ~x ~y ~inv:(emit_pow_loop f ~x:z) in
      probe_store 12 ax ;
      probe_store 22 ay ;
      if stage >= 4 then begin
        let kw = emit_key_words ~x:ax ~y:ay in
        probe_store 32 kw ;
        emit_blake kw ~outs:[0; 1; 2] ;
        probe_store 36 [|"w_0"; "w_1"; "w_2"|]
      end
    end
  end ;
  footer ()

let () =
  let usage () = prerr_endline "usage: gen_ed25519 search WBITS | probe STAGE" ; exit 2 in
  let arg =
    match Sys.argv with [|_; _; n|] -> (try int_of_string n with _ -> usage ()) | _ -> usage ()
  in
  line "(* GENERATED by gen/gen_ed25519.ml (%s) -- do not edit. *)" Sys.argv.(1) ;
  line "[@@@warning \"-26-27\"]\n" ;
  (match Sys.argv.(1) with
  | "search" when arg = 4 || arg = 8 -> search_kernel ~wbits:arg
  | "probe" when arg >= 1 && arg <= 4 -> probe_kernel ~wbits:8 ~stage:arg
  | _ -> usage ()) ;
  print_string (Buffer.contents buf)
