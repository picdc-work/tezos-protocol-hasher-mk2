(* Generates a Sarek kernel module for one prime field: multi-limb
   Montgomery arithmetic on mutable-free (SSA) int64 scalars, printed as
   straight-line code, like gen_kernel.ml.

   Usage: gen_field.exe NAME [OPS]   (NAME: ed25519 | secp256k1 | p256 | bls12_381;
   OPS: comma-separated subset of mul,add,sub,inv,batch_inv; default all)

   Limb layout. A field element is [n] limbs of 28 bits, least significant
   first, each held in an int64 and flattened in a vector: element [e] of a
   launch occupies [e*n .. e*n+n-1]. R = 2^(28 n), so n = 10 (R = 2^280)
   for the 255/256-bit primes and n = 14 (R = 2^392) for BLS12-381.

   Overflow bound for Montgomery multiplication (word-by-word, columns kept
   unnormalised, all quantities non-negative). Inputs are normalised limbs
   (< 2^28). Column k receives at most n products a_i*b_j (each < 2^56), at
   most n products m*p_j (each < 2^56, m < 2^28) and one carry from column
   k-1, itself below 2^37. Hence every column stays below
   2n*2^56 + 2^37 <= 28*2^56 + 2^37 < 2^61 < 2^63, and signed int64
   arithmetic never overflows or goes negative. The result before the final
   subtraction is below 2p < R, so it fits in n limbs and the carry out of
   the top limb is zero.

   Operations (operands and results are reduced, in [0, p)):
   - mul a b = a*b*R^-1 mod p (Montgomery product);
   - add, sub: modular addition and subtraction (form independent);
   - inv x = x^(p-2), the bits of p-2 (most significant first) passed in a
     vector; with x in Montgomery form the result is in Montgomery form.
     One inlined multiplication per loop iteration: step 2k squares the
     accumulator, step 2k+1 multiplies by x, committed only if bit k is 1;
   - batch_inv: Montgomery's trick, one batch per thread. A zero in a batch
     is outside the contract (the batch product is zero and every output of
     the batch is garbage). *)

let limb_bits = 28

let mask_value = (1 lsl limb_bits) - 1

let mask = Printf.sprintf "%dL" mask_value

type field = {name : string; prime : Z.t; n : int}

let hex h = Z.of_string_base 16 h

let fields =
  [
    {name = "ed25519"; prime = Z.sub (Z.shift_left Z.one 255) (Z.of_int 19); n = 10};
    {
      name = "secp256k1";
      prime = hex "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F";
      n = 10;
    };
    {
      name = "p256";
      prime = hex "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF";
      n = 10;
    };
    {
      name = "bls12_381";
      prime =
        hex
          "1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB";
      n = 14;
    };
  ]

let limbs z n =
  Array.init n (fun j ->
      Z.to_int (Z.logand (Z.shift_right z (limb_bits * j)) (Z.of_int mask_value)))

let buf = Buffer.create (1 lsl 20)

let line fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s ; Buffer.add_char buf '\n') fmt

let counter = ref 0

(* Emits [let <fresh> = expr in] and returns the fresh name. *)
let bind base expr =
  incr counter ;
  let v = Printf.sprintf "%s%d" base !counter in
  line "let %s = %s in" v expr ;
  v

(* -p^-1 mod 2^28 *)
let ninv f =
  let m = Z.shift_left Z.one limb_bits in
  Z.to_int (Z.erem (Z.neg (Z.invert f.prime m)) m)

(* Propagates carries over [n] unnormalised non-negative columns
   (starting with carry [carry]); returns the normalised limbs. *)
let normalise cols carry =
  let c = ref carry in
  Array.map
    (fun col ->
      let v = bind "v" (Printf.sprintf "%s + %s" col !c) in
      c := bind "c" (Printf.sprintf "(%s asr 28L)" v) ;
      bind "r" (Printf.sprintf "%s land %s" v mask))
    cols

(* r - p with borrow chain; selects r when the subtraction underflows. *)
let cond_sub f r =
  let pl = limbs f.prime f.n in
  let borrow = ref "0L" in
  let d =
    Array.mapi
      (fun j rj ->
        let v = bind "d" (Printf.sprintf "%s - %dL + %s" rj pl.(j) !borrow) in
        borrow := bind "b" (Printf.sprintf "(%s asr 28L)" v) ;
        bind "e" (Printf.sprintf "%s land %s" v mask))
      r
  in
  (* borrow is 0 (r >= p, keep d) or -1 (keep r) *)
  Array.mapi
    (fun j rj -> bind "o" (Printf.sprintf "%s lxor ((%s lxor %s) land %s)" d.(j) rj d.(j) !borrow))
    r

(* Word-by-word Montgomery product of limb names [a] and [b]. *)
let emit_mul f a b =
  let n = f.n in
  let pl = limbs f.prime n and ninv = ninv f in
  let t = Array.make (2 * n) "0L" in
  for i = 0 to n - 1 do
    for j = 0 to n - 1 do
      t.(i + j) <- bind "t" (Printf.sprintf "%s + %s * %s" t.(i + j) a.(i) b.(j))
    done ;
    let m = bind "m" (Printf.sprintf "((%s land %s) * %dL) land %s" t.(i) mask ninv mask) in
    for j = 0 to n - 1 do
      if pl.(j) <> 0 then
        t.(i + j) <- bind "t" (Printf.sprintf "%s + %s * %dL" t.(i + j) m pl.(j))
    done ;
    t.(i + 1) <- bind "t" (Printf.sprintf "%s + (%s asr 28L)" t.(i + 1) t.(i))
  done ;
  cond_sub f (normalise (Array.sub t n n) "0L")

let emit_add f a b =
  let sum = Array.mapi (fun j aj -> bind "s" (Printf.sprintf "%s + %s" aj b.(j))) a in
  cond_sub f (normalise sum "0L")

let emit_sub f a b =
  let pl = limbs f.prime f.n in
  let borrow = ref "0L" in
  let d =
    Array.mapi
      (fun j aj ->
        let v = bind "d" (Printf.sprintf "%s - %s + %s" aj b.(j) !borrow) in
        borrow := bind "b" (Printf.sprintf "(%s asr 28L)" v) ;
        bind "e" (Printf.sprintf "%s land %s" v mask))
      a
  in
  (* borrow is -1 when a < b: add p back *)
  let masked = Array.mapi (fun j _ -> bind "q" (Printf.sprintf "%dL land %s" pl.(j) !borrow)) a in
  normalise (Array.mapi (fun j dj -> bind "w" (Printf.sprintf "%s + %s" dj masked.(j))) d) "0L"

let names prefix n = Array.init n (fun j -> Printf.sprintf "%s%d" prefix j)

(* [let <prefix>j = vec.(base + j) in] for every limb *)
let load f vec base prefix =
  Array.init f.n (fun j -> bind prefix (Printf.sprintf "%s.(%s + %dl)" vec base j))

let store vec base limbs =
  Array.iteri (fun j l -> line "%s.(%s + %dl) <- %s ;" vec base j l) limbs

let header kname params =
  line "let %s =" kname ;
  line "  [%%kernel" ;
  line "    fun %s ->" params ;
  line "      let open Sarek_stdlib.Std in" ;
  line "      let gid = global_thread_id in" ;
  line "      if gid < count then begin"

let footer () = line "        ()" ; line "      end]\n"

let binary_kernel f kname emit =
  header kname "(a : int64 vector) (b : int64 vector) (out : int64 vector) (count : int32)" ;
  line "        let base = gid * %dl in" f.n ;
  let a = load f "a" "base" "a" in
  let b = load f "b" "base" "b" in
  store "out" "base" (emit f a b) ;
  footer ()

(* Mutable accumulator r_j holding [init]; one multiplication per step. *)
let emit_pow_loop f ~x =
  let n = f.n in
  let one = limbs (Z.erem (Z.shift_left Z.one (limb_bits * n)) f.prime) n in
  let r = names "r" n in
  Array.iteri (fun j rj -> line "let %s = mut %dL in" rj one.(j)) r ;
  line "for k = 0 to 2l * nbits - 1l do" ;
  line "let squaring = (k mod 2l) = 0l in" ;
  line "let take = squaring || ebits.(k / 2l) = 1L in" ;
  let rhs = Array.mapi (fun j xj -> bind "o" (Printf.sprintf "if squaring then %s else %s" r.(j) xj)) x in
  let prod = emit_mul f r rhs in
  line "if take then begin" ;
  Array.iteri (fun j pj -> line "%s := %s ;" r.(j) pj) prod ;
  line "()" ;
  line "end" ;
  line "done ;" ;
  r

let inv_kernel f kname =
  header kname
    "(a : int64 vector) (ebits : int64 vector) (out : int64 vector) (nbits : int32) (count : int32)" ;
  line "        let base = gid * %dl in" f.n ;
  let x = load f "a" "base" "a" in
  let r = emit_pow_loop f ~x in
  store "out" "base" r ;
  footer ()

let batch_inv_kernel f kname =
  let n = f.n in
  header kname
    "(a : int64 vector) (pre : int64 vector) (ebits : int64 vector) (out : int64 vector) (nbits : int32) (bsz : int32) (count : int32)" ;
  line "        let first = gid * bsz * %dl in" n ;
  (* prefix products: pre[e] = x_0 ... x_e *)
  let x0 = load f "a" "first" "a" in
  store "pre" "first" x0 ;
  let acc = names "pa" n in
  Array.iteri (fun j xj -> line "let %s = mut %s in" acc.(j) xj) x0 ;
  line "for e = 1l to bsz - 1l do" ;
  line "let at = first + e * %dl in" n ;
  let xe = load f "a" "at" "x" in
  let prod = emit_mul f acc xe in
  Array.iteri (fun j pj -> line "%s := %s ;" acc.(j) pj) prod ;
  store "pre" "at" acc ;
  line "()" ;
  line "done ;" ;
  (* one inversion of the total product *)
  let r = emit_pow_loop f ~x:acc in
  let cur = names "ia" n in
  Array.iteri (fun j rj -> line "let %s = mut %s in" cur.(j) rj) r ;
  (* back substitution: inv_e = cur * pre[e-1]; cur <- cur * x_e *)
  line "for s = 0l to bsz - 2l do" ;
  line "let e = bsz - 1l - s in" ;
  line "let at = first + e * %dl in" n ;
  line "let before = at - %dl in" n ;
  let pe = load f "pre" "before" "q" in
  let inv_e = emit_mul f cur pe in
  store "out" "at" inv_e ;
  let xe2 = load f "a" "at" "y" in
  let next = emit_mul f cur xe2 in
  Array.iteri (fun j nj -> line "%s := %s ;" cur.(j) nj) next ;
  line "()" ;
  line "done ;" ;
  store "out" "first" cur ;
  footer ()
