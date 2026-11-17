(* SHA-512 emitter (FIPS 180-4) for gen_ed25519.ml: one compression of a
   single block, fully unrolled on immutable int64 scalars. The 64-bit
   additions wrap, as Sarek's int64 do.

   The constants are not typed: FIPS 180-4 defines them as the first 64 bits
   of the fractional parts of the square roots of the first 8 primes (initial
   value) and of the cube roots of the first 80 primes (round constants),
   which Zarith computes exactly. The tests compare the digests with
   Digestif. *)

let primes count =
  let rec go acc n =
    if List.length acc = count then List.rev acc
    else if List.for_all (fun p -> n mod p <> 0) acc then go (n :: acc) (n + 1)
    else go acc (n + 1)
  in
  go [] 2

let mod64 = Z.shift_left Z.one 64

(* floor(root_k(p) * 2^64) mod 2^64: the fractional bits of the root *)
let frac_bits ~root p =
  let scaled = Z.mul (Z.of_int p) (Z.shift_left Z.one (64 * root)) in
  Z.erem (Z.root scaled root) mod64

(* A 64-bit constant as a kernel expression. A hexadecimal literal whose two
   top bits differ is read wrongly by the kernel front end (it seems to go
   through a 63-bit integer: 0x5be0cd19137e2179L becomes 0xdbe0cd19137e2179L,
   0x8000000000000000L becomes 0), so such constants are built from two
   32-bit halves. *)
let safe_literal v =
  let top = Int64.to_int (Int64.shift_right_logical v 62) in
  if top = 0 || top = 3 then Printf.sprintf "0x%LxL" v
  else
    Printf.sprintf "((0x%LxL lsl 32L) lor 0x%LxL)" (Int64.shift_right_logical v 32)
      (Int64.logand v 0xffffffffL)

let literal z = safe_literal (Z.to_int64_unsigned z)

let initial_values = List.map (frac_bits ~root:2) (primes 8)

let round_constants = Array.of_list (List.map (frac_bits ~root:3) (primes 80))

let rotr x n = Printf.sprintf "((%s lsr %dL) lor (%s lsl %dL))" x n x (64 - n)

(* Binds the 8 initial values and the 80 round constants; to be called once,
   before the loops of the kernel. *)
let emit_constants ~bind =
  ( Array.map (fun z -> bind "kc" (literal z)) round_constants,
    Array.of_list (List.map (fun z -> bind "kv" (literal z)) initial_values) )

(* Emits the compression of the block [w] (16 expressions, the words of the
   message block) from the initial hash value [iv] (names of [emit_constants]); returns the 8 names of the
   final hash words H0 .. H7. [bind] emits "let <fresh> = expr in" and
   returns the name. *)
let compress ~bind ~constants:(round_names, iv) w =
  let words = Array.make 80 "" in
  Array.blit w 0 words 0 16 ;
  let sigma0 x = Printf.sprintf "(%s lxor %s lxor (%s lsr 7L))" (rotr x 1) (rotr x 8) x in
  let sigma1 x = Printf.sprintf "(%s lxor %s lxor (%s lsr 6L))" (rotr x 19) (rotr x 61) x in
  for t = 16 to 79 do
    words.(t) <-
      bind "sw"
        (Printf.sprintf "%s + %s + %s + %s" (sigma1 words.(t - 2)) words.(t - 7)
           (sigma0 words.(t - 15)) words.(t - 16))
  done ;
  let v = Array.copy iv in
  for t = 0 to 79 do
    let a = v.(0) and b = v.(1) and c = v.(2) and e = v.(4) and f = v.(5) and g = v.(6) in
    let big1 = Printf.sprintf "(%s lxor %s lxor %s)" (rotr e 14) (rotr e 18) (rotr e 41) in
    let big0 = Printf.sprintf "(%s lxor %s lxor %s)" (rotr a 28) (rotr a 34) (rotr a 39) in
    let ch = Printf.sprintf "((%s land %s) lxor ((%s lxor 0xffffffffffffffffL) land %s))" e f e g in
    let maj = Printf.sprintf "((%s land %s) lxor (%s land %s) lxor (%s land %s))" a b a c b c in
    let t1 =
      bind "st"
        (Printf.sprintf "%s + %s + %s + %s + %s" v.(7) big1 ch round_names.(t)
           words.(t))
    in
    let t2 = bind "sm" (Printf.sprintf "%s + %s" big0 maj) in
    v.(7) <- v.(6) ;
    v.(6) <- v.(5) ;
    v.(5) <- v.(4) ;
    v.(4) <- bind "se" (Printf.sprintf "%s + %s" v.(3) t1) ;
    v.(3) <- v.(2) ;
    v.(2) <- v.(1) ;
    v.(1) <- v.(0) ;
    v.(0) <- bind "sa" (Printf.sprintf "%s + %s" t1 t2)
  done ;
  Array.mapi (fun i x -> bind "sh" (Printf.sprintf "%s + %s" x iv.(i))) v
