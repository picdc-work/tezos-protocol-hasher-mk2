(* Generates the Sarek kernel for tz1 vanity keys: per key,
   seed -> SHA-512 -> clamped scalar a -> A = aB (fixed-base table, 32 mixed
   additions of 8-bit windows) -> 1/Z -> compressed point -> Blake2b-160 ->
   base58 prefilter. Field arithmetic is ref10's radix 2^25.5 on int64
   scalars, emitted as straight-line code (private arrays would live in
   local memory). *)

let buf = Buffer.create (1 lsl 22)

let ind = ref 2

let line s =
  Buffer.add_string buf (String.make (2 * !ind) ' ') ;
  Buffer.add_string buf s ;
  Buffer.add_char buf '\n'

let linef fmt = Printf.ksprintf line fmt

let cnt = ref 0

let fresh pfx =
  incr cnt ;
  Printf.sprintf "%s%d" pfx !cnt

let let_ pfx e =
  let n = fresh pfx in
  linef "let %s = %s in" n e ;
  n

let mut_ pfx e =
  let n = fresh pfx in
  linef "let %s = mut (%s) in" n e ;
  n

let assign dst src = Array.iteri (fun i d -> linef "%s := %s ;" d src.(i)) dst

(* Sarek folds int64 literals through a 63-bit OCaml int: constants outside
   [-2^62, 2^62) come out wrong, so build them from two 32-bit halves. *)
let lit x =
  if Int64.compare x 0x4000000000000000L < 0 && Int64.compare x 0xC000000000000000L >= 0
  then Printf.sprintf "(%LdL)" x
  else
    Printf.sprintf "((%LdL lsl 32L) lor %LdL)" (Int64.shift_right x 32)
      (Int64.logand x 0xffffffffL)

(* ---------- field arithmetic, GF(2^255 - 19) ---------- *)

let bits i = if i land 1 = 0 then 26 else 25

let carry h i target ~round ~times19 =
  let b = bits i in
  let c =
    if round then let_ "c" (Printf.sprintf "(%s + %dL) asr %dL" h.(i) (1 lsl (b - 1)) b)
    else let_ "c" (Printf.sprintf "%s asr %dL" h.(i) b)
  in
  (match target with
  | Some t -> linef "%s := %s + %s%s ;" h.(t) h.(t) c (if times19 then " * 19L" else "")
  | None -> ()) ;
  linef "%s := %s - (%s lsl %dL) ;" h.(i) h.(i) c b

let reduce h =
  List.iter
    (fun (i, t) -> carry h i (Some t) ~round:true ~times19:(i = 9))
    [(0, 1); (4, 5); (1, 2); (5, 6); (2, 3); (6, 7); (3, 4); (7, 8); (4, 5); (8, 9); (9, 0); (0, 1)] ;
  h

let fe_mul f g =
  let g19 = Array.init 10 (fun j -> if j = 0 then "" else let_ "g" (g.(j) ^ " * 19L")) in
  let f2 = Array.init 10 (fun i -> if i land 1 = 1 then let_ "f" (f.(i) ^ " * 2L") else f.(i)) in
  let h =
    Array.init 10 (fun k ->
        let terms =
          List.init 10 (fun i ->
              let j = (k - i + 10) mod 10 in
              let fi = if i land 1 = 1 && j land 1 = 1 then f2.(i) else f.(i) in
              let gj = if i > k then g19.(j) else g.(j) in
              fi ^ " * " ^ gj)
        in
        mut_ "h" (String.concat " + " terms))
  in
  reduce h

let fe_sq f =
  let h =
    Array.init 10 (fun k ->
        let terms = ref [] in
        for i = 0 to 9 do
          for j = i to 9 do
            if (i + j) mod 10 = k then begin
              let c =
                (if i <> j then 2 else 1)
                * (if i land 1 = 1 && j land 1 = 1 then 2 else 1)
                * if i + j >= 10 then 19 else 1
              in
              terms :=
                (if c = 1 then f.(i) ^ " * " ^ f.(j)
                 else Printf.sprintf "%s * (%s * %dL)" f.(i) f.(j) c)
                :: !terms
            end
          done
        done ;
        mut_ "h" (String.concat " + " (List.rev !terms)))
  in
  reduce h

let fe_add f g = Array.init 10 (fun i -> let_ "a" (f.(i) ^ " + " ^ g.(i)))

let fe_sub f g = Array.init 10 (fun i -> let_ "a" (f.(i) ^ " - " ^ g.(i)))

(* x^(2^n) *)
let sq_n f n =
  let r = fe_sq f in
  if n = 1 then r
  else begin
    let t = Array.map (fun x -> mut_ "q" x) r in
    linef "for %s = 1 to %d do" (fresh "it") (n - 1) ;
    incr ind ;
    assign t (fe_sq t) ;
    decr ind ;
    line "done ;" ;
    t
  end

(* z^(p-2), ref10 pow225521 *)
let fe_invert z =
  let t0 = fe_sq z in
  let t1 = sq_n t0 2 in
  let t1 = fe_mul z t1 in
  let t0 = fe_mul t0 t1 in
  let t2 = fe_sq t0 in
  let t1 = fe_mul t1 t2 in
  let t2 = sq_n t1 5 in
  let t1 = fe_mul t2 t1 in
  let t2 = sq_n t1 10 in
  let t2 = fe_mul t2 t1 in
  let t3 = sq_n t2 20 in
  let t2 = fe_mul t3 t2 in
  let t2 = sq_n t2 10 in
  let t1 = fe_mul t2 t1 in
  let t2 = sq_n t1 50 in
  let t2 = fe_mul t2 t1 in
  let t3 = sq_n t2 100 in
  let t2 = fe_mul t3 t2 in
  let t2 = sq_n t2 50 in
  let t1 = fe_mul t2 t1 in
  let t1 = sq_n t1 5 in
  fe_mul t1 t0

(* Canonical little-endian encoding as 4 int64 words (ref10 fe_tobytes). *)
let fe_tobytes f =
  let h = Array.map (fun x -> mut_ "h" x) f in
  let q = mut_ "r" (Printf.sprintf "(19L * %s + %dL) asr 25L" h.(9) (1 lsl 24)) in
  for i = 0 to 9 do
    linef "%s := (%s + %s) asr %dL ;" q h.(i) q (bits i)
  done ;
  linef "%s := %s + 19L * %s ;" h.(0) h.(0) q ;
  for i = 0 to 8 do
    carry h i (Some (i + 1)) ~round:false ~times19:false
  done ;
  carry h 9 None ~round:false ~times19:false ;
  [|
    let_ "w" (Printf.sprintf "%s lor (%s lsl 26L) lor (%s lsl 51L)" h.(0) h.(1) h.(2));
    let_ "w" (Printf.sprintf "(%s lsr 13L) lor (%s lsl 13L) lor (%s lsl 38L)" h.(2) h.(3) h.(4));
    let_ "w" (Printf.sprintf "%s lor (%s lsl 25L) lor (%s lsl 51L)" h.(5) h.(6) h.(7));
    let_ "w" (Printf.sprintf "(%s lsr 13L) lor (%s lsl 12L) lor (%s lsl 38L)" h.(7) h.(8) h.(9));
  |]

(* ---------- SHA-512 of a 32-byte message ---------- *)

let sha_k =
  [|
    0x428a2f98d728ae22L; 0x7137449123ef65cdL; 0xb5c0fbcfec4d3b2fL; 0xe9b5dba58189dbbcL;
    0x3956c25bf348b538L; 0x59f111f1b605d019L; 0x923f82a4af194f9bL; 0xab1c5ed5da6d8118L;
    0xd807aa98a3030242L; 0x12835b0145706fbeL; 0x243185be4ee4b28cL; 0x550c7dc3d5ffb4e2L;
    0x72be5d74f27b896fL; 0x80deb1fe3b1696b1L; 0x9bdc06a725c71235L; 0xc19bf174cf692694L;
    0xe49b69c19ef14ad2L; 0xefbe4786384f25e3L; 0x0fc19dc68b8cd5b5L; 0x240ca1cc77ac9c65L;
    0x2de92c6f592b0275L; 0x4a7484aa6ea6e483L; 0x5cb0a9dcbd41fbd4L; 0x76f988da831153b5L;
    0x983e5152ee66dfabL; 0xa831c66d2db43210L; 0xb00327c898fb213fL; 0xbf597fc7beef0ee4L;
    0xc6e00bf33da88fc2L; 0xd5a79147930aa725L; 0x06ca6351e003826fL; 0x142929670a0e6e70L;
    0x27b70a8546d22ffcL; 0x2e1b21385c26c926L; 0x4d2c6dfc5ac42aedL; 0x53380d139d95b3dfL;
    0x650a73548baf63deL; 0x766a0abb3c77b2a8L; 0x81c2c92e47edaee6L; 0x92722c851482353bL;
    0xa2bfe8a14cf10364L; 0xa81a664bbc423001L; 0xc24b8b70d0f89791L; 0xc76c51a30654be30L;
    0xd192e819d6ef5218L; 0xd69906245565a910L; 0xf40e35855771202aL; 0x106aa07032bbd1b8L;
    0x19a4c116b8d2d0c8L; 0x1e376c085141ab53L; 0x2748774cdf8eeb99L; 0x34b0bcb5e19b48a8L;
    0x391c0cb3c5c95a63L; 0x4ed8aa4ae3418acbL; 0x5b9cca4f7763e373L; 0x682e6ff3d6b2b8a3L;
    0x748f82ee5defb2fcL; 0x78a5636f43172f60L; 0x84c87814a1f0ab72L; 0x8cc702081a6439ecL;
    0x90befffa23631e28L; 0xa4506cebde82bde9L; 0xbef9a3f7b2c67915L; 0xc67178f2e372532bL;
    0xca273eceea26619cL; 0xd186b8c721c0c207L; 0xeada7dd6cde0eb1eL; 0xf57d4f7fee6ed178L;
    0x06f067aa72176fbaL; 0x0a637dc5a2c898a6L; 0x113f9804bef90daeL; 0x1b710b35131c471bL;
    0x28db77f523047d84L; 0x32caab7b40c72493L; 0x3c9ebe0a15c9bebcL; 0x431d67c49c100d4cL;
    0x4cc5d4becb3e42b6L; 0x597f299cfc657e2aL; 0x5fcb6fab3ad6faecL; 0x6c44198c4a475817L;
  |]

let sha_iv =
  [|
    0x6a09e667f3bcc908L; 0xbb67ae8584caa73bL; 0x3c6ef372fe94f82bL; 0xa54ff53a5f1d36f1L;
    0x510e527fade682d1L; 0x9b05688c2b3e6c1fL; 0x1f83d9abfb41bd6bL; 0x5be0cd19137e2179L;
  |]

let rotr x n = Printf.sprintf "((%s lsr %dL) lor (%s lsl %dL))" x n x (64 - n)

let sha512_32 w =
  let w = Array.append w (Array.make 76 "") in
  w.(4) <- lit 0x8000000000000000L ;
  for i = 5 to 14 do w.(i) <- "0L" done ;
  w.(15) <- "256L" ;
  for t = 16 to 79 do
    let s0 = Printf.sprintf "(%s lxor %s lxor (%s lsr 7L))" (rotr w.(t - 15) 1) (rotr w.(t - 15) 8) w.(t - 15) in
    let s1 = Printf.sprintf "(%s lxor %s lxor (%s lsr 6L))" (rotr w.(t - 2) 19) (rotr w.(t - 2) 61) w.(t - 2) in
    w.(t) <- let_ "sw" (Printf.sprintf "%s + %s + %s + %s" s1 w.(t - 7) s0 w.(t - 16))
  done ;
  let s = Array.map lit sha_iv in
  for t = 0 to 79 do
    let a = s.(0) and b = s.(1) and c = s.(2) and dd = s.(3) in
    let e = s.(4) and f = s.(5) and g = s.(6) and h = s.(7) in
    let s1 = Printf.sprintf "(%s lxor %s lxor %s)" (rotr e 14) (rotr e 18) (rotr e 41) in
    let ch = Printf.sprintf "(%s lxor (%s land (%s lxor %s)))" g e f g in
    let t1 = let_ "st" (Printf.sprintf "%s + %s + %s + %s + %s" h s1 ch (lit sha_k.(t)) w.(t)) in
    let s0 = Printf.sprintf "(%s lxor %s lxor %s)" (rotr a 28) (rotr a 34) (rotr a 39) in
    let maj = Printf.sprintf "((%s land %s) lor (%s land (%s lor %s)))" a b c a b in
    let t2 = let_ "st" (Printf.sprintf "%s + %s" s0 maj) in
    let e' = let_ "se" (Printf.sprintf "%s + %s" dd t1) in
    let a' = let_ "sa" (Printf.sprintf "%s + %s" t1 t2) in
    s.(7) <- g ; s.(6) <- f ; s.(5) <- e ; s.(4) <- e' ;
    s.(3) <- c ; s.(2) <- b ; s.(1) <- a ; s.(0) <- a'
  done ;
  Array.init 4 (fun i -> let_ "hh" (Printf.sprintf "%s + %s" (lit sha_iv.(i)) s.(i)))

let bswap x =
  String.concat " lor "
    (List.init 8 (fun i ->
         Printf.sprintf "(((%s lsr %dL) land 255L) lsl %dL)" x (8 * i) (56 - (8 * i))))

(* ---------- Blake2b-160 of a 32-byte message ---------- *)

let b2_iv =
  [|
    0x6a09e667f3bcc908L; 0xbb67ae8584caa73bL; 0x3c6ef372fe94f82bL; 0xa54ff53a5f1d36f1L;
    0x510e527fade682d1L; 0x9b05688c2b3e6c1fL; 0x1f83d9abfb41bd6bL; 0x5be0cd19137e2179L;
  |]

let sigma =
  [|
    [|0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15|];
    [|14; 10; 4; 8; 9; 15; 13; 6; 1; 12; 0; 2; 11; 7; 5; 3|];
    [|11; 8; 12; 0; 5; 2; 15; 13; 10; 14; 3; 6; 7; 1; 9; 4|];
    [|7; 9; 3; 1; 13; 12; 11; 14; 2; 6; 5; 10; 4; 0; 15; 8|];
    [|9; 0; 5; 7; 2; 4; 10; 15; 14; 1; 11; 12; 6; 8; 3; 13|];
    [|2; 12; 6; 10; 0; 11; 8; 3; 4; 13; 7; 5; 15; 14; 1; 9|];
    [|12; 5; 1; 15; 14; 13; 4; 10; 0; 7; 6; 3; 9; 2; 8; 11|];
    [|13; 11; 7; 14; 12; 1; 3; 9; 5; 0; 15; 4; 8; 6; 2; 10|];
    [|6; 15; 14; 9; 11; 3; 0; 8; 12; 2; 13; 7; 1; 4; 10; 5|];
    [|10; 2; 8; 4; 7; 6; 1; 5; 15; 11; 9; 14; 3; 12; 13; 0|];
  |]

(* Returns the first 3 words of the 20-byte digest. *)
let blake2b160_32 m =
  let m = Array.append m (Array.make 12 "0L") in
  let h0 = Array.copy b2_iv in
  h0.(0) <- Int64.logxor h0.(0) 0x01010014L ;
  let v =
    Array.init 16 (fun i ->
        if i < 8 then lit h0.(i)
        else if i = 12 then lit (Int64.logxor b2_iv.(4) 32L)
        else if i = 14 then lit (Int64.lognot b2_iv.(6))
        else lit b2_iv.(i - 8))
  in
  let g a b c d x y =
    v.(a) <- let_ "b" (Printf.sprintf "%s + %s + %s" v.(a) v.(b) x) ;
    v.(d) <- let_ "b" (rotr (Printf.sprintf "(%s lxor %s)" v.(d) v.(a)) 32) ;
    v.(c) <- let_ "b" (Printf.sprintf "%s + %s" v.(c) v.(d)) ;
    v.(b) <- let_ "b" (rotr (Printf.sprintf "(%s lxor %s)" v.(b) v.(c)) 24) ;
    v.(a) <- let_ "b" (Printf.sprintf "%s + %s + %s" v.(a) v.(b) y) ;
    v.(d) <- let_ "b" (rotr (Printf.sprintf "(%s lxor %s)" v.(d) v.(a)) 16) ;
    v.(c) <- let_ "b" (Printf.sprintf "%s + %s" v.(c) v.(d)) ;
    v.(b) <- let_ "b" (rotr (Printf.sprintf "(%s lxor %s)" v.(b) v.(c)) 63)
  in
  for r = 0 to 11 do
    let s = sigma.(r mod 10) in
    g 0 4 8 12 m.(s.(0)) m.(s.(1)) ;
    g 1 5 9 13 m.(s.(2)) m.(s.(3)) ;
    g 2 6 10 14 m.(s.(4)) m.(s.(5)) ;
    g 3 7 11 15 m.(s.(6)) m.(s.(7)) ;
    g 0 5 10 15 m.(s.(8)) m.(s.(9)) ;
    g 1 6 11 12 m.(s.(10)) m.(s.(11)) ;
    g 2 7 8 13 m.(s.(12)) m.(s.(13)) ;
    g 3 4 9 14 m.(s.(14)) m.(s.(15))
  done ;
  Array.init 3 (fun i -> let_ "dg" (Printf.sprintf "%s lxor %s lxor %s" (lit h0.(i)) v.(i) v.(i + 8)))

(* ---------- kernel ---------- *)

let () =
  line "(* GENERATED by gen/gen_vk.ml -- do not edit. *)" ;
  line "[@@@warning \"-26-27\"]" ;
  line "let keygen =" ;
  line "  [%kernel" ;
  line
    "    fun (seed : int64 vector) (tbl : int64 vector) (lo : int64 vector) \
     (hi : int64 vector) (nint : int32) (hit_count : int32 vector) (hit_gid : \
     int32 vector) (hit_k : int32 vector) (cap : int32) (dbg : int64 vector) \
     (dbgon : int32) (kper : int32) (nthreads : int32) ->" ;
  ind := 3 ;
  line "let open Sarek_stdlib.Std in" ;
  line "let gid = global_thread_id in" ;
  line "if gid < nthreads then begin" ;
  incr ind ;
  (* gid as int64 without an int32 -> int64 conversion *)
  line "let gr = mut gid in" ;
  line "let g64 = mut 0L in" ;
  for b = 23 downto 0 do
    linef "if gr >= %dl then begin gr := gr - %dl ; g64 := g64 + %dL end ;" (1 lsl b) (1 lsl b) (1 lsl b)
  done ;
  line "let s0 = seed.(0) in let s1 = seed.(1) in let s2 = seed.(2) in let s3 = seed.(3) in" ;
  line "let kk = mut 0L in" ;
  line "for k = 0 to kper - 1l do" ;
  incr ind ;
  let w0 = let_ "sd" "s0 lxor (g64 lor (kk lsl 32L))" in
  let hh = sha512_32 [|w0; "s1"; "s2"; "s3"|] in
  let a = Array.map (fun x -> let_ "sc" (bswap x)) hh in
  let a0 = let_ "sc" (a.(0) ^ " land (-8L)") in
  let a3 = let_ "sc" (Printf.sprintf "(%s land %s) lor %s" a.(3) (lit 0x3FFFFFFFFFFFFFFFL) (lit 0x4000000000000000L)) in
  (* P = identity, extended coordinates *)
  let px = Array.init 10 (fun _ -> mut_ "px" "0L") in
  let py = Array.init 10 (fun i -> mut_ "py" (if i = 0 then "1L" else "0L")) in
  let pz = Array.init 10 (fun i -> mut_ "pz" (if i = 0 then "1L" else "0L")) in
  let pt = Array.init 10 (fun _ -> mut_ "pt" "0L") in
  linef "let s = mut %s in" a0 ;
  line "for pos = 0 to 31 do" ;
  incr ind ;
  linef "if pos = 8l then s := %s ;" a.(1) ;
  linef "if pos = 16l then s := %s ;" a.(2) ;
  linef "if pos = 24l then s := %s ;" a3 ;
  let nb =
    String.concat " + "
      (List.init 8 (fun b ->
           Printf.sprintf "(if (s land %dL) = 0L then 0l else %dl)" (1 lsl b) (1 lsl b)))
  in
  let nb = let_ "nb" nb in
  line "s := s lsr 8L ;" ;
  let e = let_ "e" (Printf.sprintf "((pos * 256l) + %s) * 30l" nb) in
  let q = Array.init 30 (fun i -> let_ "tq" (Printf.sprintf "tbl.(%s + %dl)" e i)) in
  let ypx = Array.sub q 0 10 and ymx = Array.sub q 10 10 and xy2d = Array.sub q 20 10 in
  (* ref10 ge_madd *)
  let rx = fe_add py px in
  let ry = fe_sub py px in
  let rz = fe_mul rx ypx in
  let ry = fe_mul ry ymx in
  let rt = fe_mul xy2d pt in
  let rx = fe_sub rz ry in
  let ry = fe_add rz ry in
  let t0 = fe_add pz pz in
  let rz = fe_add t0 rt in
  let rt = fe_sub t0 rt in
  (* ge_p1p1_to_p3 *)
  let nx = fe_mul rx rt in
  let ny = fe_mul ry rz in
  let nz = fe_mul rz rt in
  let nt = fe_mul rx ry in
  assign px nx ;
  assign py ny ;
  assign pz nz ;
  assign pt nt ;
  line "()" ;
  decr ind ;
  line "done ;" ;
  let zi = fe_invert pz in
  let x = fe_mul px zi in
  let y = fe_mul py zi in
  let yw = fe_tobytes y in
  let xw = fe_tobytes x in
  let pk3 = let_ "pk" (Printf.sprintf "%s lor ((%s land 1L) lsl 63L)" yw.(3) xw.(0)) in
  let pk = [|yw.(0); yw.(1); yw.(2); pk3|] in
  let dg = blake2b160_32 pk in
  let x = dg.(0) in
  linef
    "let top = %s lor ((%s land 255L) lsl 32L) lor (((%s lsr \
     8L) land 255L) lsl 24L) lor (((%s lsr 16L) land 255L) lsl 16L) lor (((%s \
     lsr 24L) land 255L) lsl 8L) lor ((%s lsr 32L) land 255L) in"
    (lit 0x06a19f0000000000L) x x x x x ;
  line "let l = mut 0l in" ;
  line "let r = mut nint in" ;
  line "while l < r do" ;
  line "  let md = (l + r) / 2l in" ;
  line "  if lo.(md) <= top then l := md + 1l else r := md" ;
  line "done ;" ;
  line "let idx = l - 1l in" ;
  line "if idx >= 0l then begin" ;
  line "  if top <= hi.(idx) then begin" ;
  line "    let hk = atomic_add_global_int32 hit_count 0l 1l in" ;
  line "    if hk < cap then begin hit_gid.(hk) <- gid ; hit_k.(hk) <- k end" ;
  line "  end" ;
  line "end ;" ;
  line "if dbgon = 1l then begin" ;
  line "  let o = ((gid * kper) + k) * 7l in" ;
  let outs =
    match Sys.getenv_opt "VK_DBG" with
    | Some "sha" -> [|a0; a.(1); a.(2); a3; "0L"; "0L"; "0L"|]
    | _ -> Array.append pk dg
  in
  Array.iteri (fun i w -> linef "  dbg.(o + %dl) <- %s ;" i w) outs ;
  line "  ()" ;
  line "end ;" ;
  line "kk := kk + 1L" ;
  decr ind ;
  line "done" ;
  decr ind ;
  line "end]" ;
  print_string (Buffer.contents buf)
