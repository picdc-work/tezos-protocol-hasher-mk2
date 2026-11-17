(* Generates the walk kernel of an address search over a short-Weierstrass
   curve, as a Sarek kernel module (gen/gen_walk.exe NAME, NAME as in
   gen_field.ml: secp256k1 for tz2, p256 for tz3; the hashing part is the
   Tezos one: SEC1 compressed key, Blake2b-20, prefix 06 a1 a1 for tz2 and
   06 a1 a4 for tz3). The curve coefficient a never appears: the addition of
   two distinct points does not use it.

   Walk. Offset j stands for the point P0 + j G. A launch covers one chunk of
   T*B consecutive offsets with T threads, each thread handling B offsets
   from its affine base point C_t (state vectors sx/sy, Montgomery limbs,
   element t at t*n). The table (tx/ty) holds i*G for i = 1..B-1 followed by
   the stride point (T*B)*G, B entries in all. Per thread: the B differences
   tx_e - Cx are inverted together (Montgomery's trick, one exponentiation;
   prefix products in the scratch vector pre, B entries per thread), then
   C + table_e is an affine addition. Index 0 of the batch is C itself, and
   C + stride is the next state, written to the separate vectors ox/oy: a
   launch never modifies its inputs, so it can be repeated (overflow re-run
   in sub-ranges of threads, first_thread/nthreads).

   Zero difference. If C equals plus or minus a table point, one difference
   is zero, the batch product is zero and every point of the batch is wrong.
   The probability is about 2^-240 per batch. The kernel does not detect it:
   the host confirms every hit, so the effect is a missed batch, never a
   false result. (The next state of such a thread is wrong too; the host
   recomputes states when it resumes.)

   Per point. x leaves Montgomery form (product with 1), the parity of y
   gives the first byte 02/03; the 33-byte message is hashed with Blake2b
   (digest length 20: h and vinit come from the host, with the parameter word
   0x01010014, t0 = 33 and f0 = ~0 folded in). The prefilter is the binary
   search of top64 = 06a1a1 || digest[0..5) in the sorted intervals. A hit
   is recorded as (thread, index in batch), index 0 being C itself. The
   point C + stride (index B, the next state) is hashed like the others but
   its hits are dropped: it is index 0 of the next chunk.

   Loop. The point loop runs s = 0..B; index B - s is handled at step s (the
   batch is walked backwards by the back substitution), index 0 last, using
   clamped indices so that its inversion work is wasted but harmless. *)

open Field_emit

let one_mont f = limbs (Z.erem (Z.shift_left Z.one (limb_bits * f.n)) f.prime) f.n

let kernel_params =
  "(sx : int64 vector) (sy : int64 vector) (ox : int64 vector) (oy : int64 vector) (tx : int64 vector) (ty : int64 vector) (pre : int64 vector) (ebits : int64 vector) (nbits : int32) (bsz : int32) (h : int64 vector) (vinit : int64 vector) (lo : int64 vector) (hi : int64 vector) (nint : int32) (hit_count : int32 vector) (hit_thread : int32 vector) (hit_index : int32 vector) (cap : int32) (first_thread : int32) (nthreads : int32)"

(* Byte [b] (little-endian index) of the 256-bit value held in 28-bit limbs. *)
let byte_expr limbs b =
  let bit = 8 * b in
  let li = bit / limb_bits and off = bit mod limb_bits in
  if off + 8 <= limb_bits then Printf.sprintf "((%s lsr %dL) land 255L)" limbs.(li) off
  else
    Printf.sprintf "(((%s lsr %dL) lor (%s lsl %dL)) land 255L)" limbs.(li) off limbs.(li + 1)
      (limb_bits - off)

(* The 16 words of the message 02|03 || x big-endian (33 bytes, zero padded):
   x byte b sits at message position 32 - b. *)
let message_words ~ylow ~x =
  let terms = Array.make 16 [] in
  terms.(0) <- [Printf.sprintf "(2L + (%s land 1L))" ylow] ;
  for b = 0 to 31 do
    let pos = 32 - b in
    terms.(pos / 8) <-
      Printf.sprintf "(%s lsl %dL)" (byte_expr x b) (8 * (pos mod 8)) :: terms.(pos / 8)
  done ;
  Array.map (fun ts -> bind "mw" (if ts = [] then "0L" else String.concat " lor " ts)) terms

(* The address prefix (3 bytes) of the scheme that uses the curve. *)
let prefix_of f =
  match f.name with
  | "secp256k1" -> "0x06a1a1"
  | "p256" -> "0x06a1a4"
  | other -> prerr_endline ("gen_walk: no address scheme for " ^ other) ; exit 2

let prefilter_top f =
  [
    "let x = w_0 in";
    "let top =";
    Printf.sprintf "  %s0000000000L" (prefix_of f);
    "  lor ((x land 255L) lsl 32L)";
    "  lor (((x lsr 8L) land 255L) lsl 24L)";
    "  lor (((x lsr 16L) land 255L) lsl 16L)";
    "  lor (((x lsr 24L) land 255L) lsl 8L)";
    "  lor ((x lsr 32L) land 255L)";
    "in";
  ]

(* Hash the point (xs, ys) in Montgomery form and record a prefilter hit. *)
let emit_hash_and_filter f ~xs ~ys =
  let raw_one = Array.init f.n (fun j -> if j = 0 then "1L" else "0L") in
  let x = emit_mul f xs raw_one and y = emit_mul f ys raw_one in
  let m = message_words ~ylow:y.(0) ~x in
  Blake_emit.compress ~tprefix:"bt" buf "" ~tag:"w" ~hin:(names "hw" 8) ~vin:(names "vw" 8) ~m
    ~outs:[0] ;
  let record = ["hit_thread.(k) <- th ;"; "hit_index.(k) <- pidx"] in
  (* index B is the next chunk's index 0: never recorded *)
  line "let nint = if pidx < bsz then nint else 0l in" ;
  List.iter (line "%s") (Blake_emit.filter_lines ~top:(prefilter_top f) ~record)

(* pre[e] = D_0 ... D_e with D_e = tx_e - Cx, then the inverse of the total. *)
let emit_prefix_and_inverse f ~cx =
  let n = f.n in
  line "let first = th * bsz * %dl in" n ;
  let d0 = emit_sub f (load f "tx" "0l" "u") cx in
  store "pre" "first" d0 ;
  let acc = names "pa" n in
  Array.iteri (fun j d -> line "let %s = mut %s in" acc.(j) d) d0 ;
  line "for e = 1l to bsz - 1l do" ;
  line "let at = first + e * %dl in" n ;
  line "let toff = e * %dl in" n ;
  let d = emit_sub f (load f "tx" "toff" "x") cx in
  let prod = emit_mul f acc d in
  Array.iteri (fun j pj -> line "%s := %s ;" acc.(j) pj) prod ;
  store "pre" "at" acc ;
  line "()" ;
  line "done ;" ;
  emit_pow_loop f ~x:acc

(* Affine addition C + T given the inverse of (Tx - Cx). *)
let emit_addition f ~cx ~cy ~txe ~tye ~inv_e =
  let lam = emit_mul f (emit_sub f tye cy) inv_e in
  let x3 = emit_sub f (emit_sub f (emit_mul f lam lam) cx) txe in
  let y3 = emit_sub f (emit_mul f lam (emit_sub f cx x3)) cy in
  (x3, y3)

let select cond a b = Array.mapi (fun j aj -> bind "o" (Printf.sprintf "if %s then %s else %s" cond aj b.(j))) a

let emit_step f ~cx ~cy ~cur =
  let n = f.n in
  line "for s = 0l to bsz do" ;
  line "let pidx = bsz - s in" ;
  line "let e0 = if pidx > 0l then pidx - 1l else 0l in" ;
  line "let toff = e0 * %dl in" n ;
  line "let before = first + (if e0 > 0l then e0 - 1l else 0l) * %dl in" n ;
  let txe = load f "tx" "toff" "x" and tye = load f "ty" "toff" "y" in
  let dx = emit_sub f txe cx in
  let pm = select "e0 > 0l" (load f "pre" "before" "q") (Array.map (Printf.sprintf "%dL") (one_mont f)) in
  let inv_e = emit_mul f cur pm in
  let next = emit_mul f cur dx in
  Array.iteri (fun j nj -> line "%s := %s ;" cur.(j) nj) next ;
  let x3, y3 = emit_addition f ~cx ~cy ~txe ~tye ~inv_e in
  line "if s = 0l then begin" ;
  store "ox" "base" x3 ;
  store "oy" "base" y3 ;
  line "()" ;
  line "end ;" ;
  let cond = "pidx = 0l" in
  emit_hash_and_filter f ~xs:(select cond cx x3) ~ys:(select cond cy y3) ;
  line "()" ;
  line "done ;"

let walk_kernel f =
  line "let walk =" ;
  line "  [%%kernel" ;
  line "    fun %s ->" kernel_params ;
  line "      let open Sarek_stdlib.Std in" ;
  line "      let gid = global_thread_id in" ;
  line "      if gid < nthreads then begin" ;
  line "        let th = first_thread + gid in" ;
  line "        let base = th * %dl in" f.n ;
  let cx = load f "sx" "base" "cx" and cy = load f "sy" "base" "cy" in
  for i = 0 to 7 do
    line "let hw%d = h.(%dl) in" i i ;
    line "let vw%d = vinit.(%dl) in" i i
  done ;
  let r = emit_prefix_and_inverse f ~cx in
  let cur = names "ia" f.n in
  Array.iteri (fun j rj -> line "let %s = mut %s in" cur.(j) rj) r ;
  emit_step f ~cx ~cy ~cur ;
  footer ()

let () =
  let f =
    match List.find_opt (fun f -> Array.length Sys.argv > 1 && f.name = Sys.argv.(1)) fields with
    | Some f -> f
    | None -> prerr_endline "usage: gen_walk NAME" ; exit 2
  in
  line "(* GENERATED by gen/gen_walk.ml for %s -- do not edit. *)" f.name ;
  line "[@@@warning \"-26-27\"]\n" ;
  walk_kernel f ;
  print_string (Buffer.contents buf)
