(* Generates src/kernels.ml: the Sarek search kernels, one per dump layout
   case (research R2), with every Blake2b compression fully unrolled
   (12 rounds x 8 G) on mutable int64 scalars. The PTX path ignores unroll
   pragmas, and indexing a private array at run time would spill to local
   memory, hence the generated straight-line code.

   Message words live in a 32-word space: words 0..15 are the next-to-last
   Blake2b block, 16..31 the final block. Case A only uses 16..31.

   Kernel parameters (common to all kernels):
   - h      : chaining value before the first block that is compressed here
   - vinit  : v8..v15 for the next-to-last block (0..7, t0 folded) and for
              the final block (8..15, t0 = L and f0 = ~0 folded)
   - tmpl   : 32 words, launch digits set, thread/loop digit bytes zero
   - mida/midb, wa : per-thread-digits patches for words wa and wa+1
   - wl1/sl1, wl2/sl2 : word and bit shift of the two loop digits
   - lo/hi/nint : sorted disjoint intervals on top64
   - hit_count/hit_thread/hit_loop/cap : hit buffer
   - first_thread/nthreads : thread digits = first_thread + global id *)

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

let buf = Buffer.create (1 lsl 20)

let p fmt = Printf.bprintf buf fmt

let tmp = ref 0

let fresh () =
  incr tmp ;
  Printf.sprintf "t%d" !tmp

(* One compression. [hin]: 8 chaining-value names; [vin]: 8 names for
   v8..v15; [m]: 16 message-word names. Binds [out_i] for i in [outs]. *)
let compress ind ~tag ~hin ~vin ~m ~outs =
  let v i = Printf.sprintf "v%s_%d" tag i in
  for i = 0 to 7 do
    p "%slet %s = mut %s in\n" ind (v i) hin.(i)
  done ;
  for i = 0 to 7 do
    p "%slet %s = mut %s in\n" ind (v (i + 8)) vin.(i)
  done ;
  let rot dst x y n =
    let t = fresh () in
    p "%slet %s = %s lxor %s in\n" ind t x y ;
    p "%s%s := (%s lsr %dL) lor (%s lsl %dL) ;\n" ind dst t n t (64 - n)
  in
  let g a b c d x y =
    let a = v a and b = v b and c = v c and d = v d in
    p "%s%s := %s + %s + %s ;\n" ind a a b m.(x) ;
    rot d d a 32 ;
    p "%s%s := %s + %s ;\n" ind c c d ;
    rot b b c 24 ;
    p "%s%s := %s + %s + %s ;\n" ind a a b m.(y) ;
    rot d d a 16 ;
    p "%s%s := %s + %s ;\n" ind c c d ;
    rot b b c 63
  in
  for r = 0 to 11 do
    let s = sigma.(r mod 10) in
    g 0 4 8 12 s.(0) s.(1) ;
    g 1 5 9 13 s.(2) s.(3) ;
    g 2 6 10 14 s.(4) s.(5) ;
    g 3 7 11 15 s.(6) s.(7) ;
    g 0 5 10 15 s.(8) s.(9) ;
    g 1 6 11 12 s.(10) s.(11) ;
    g 2 7 8 13 s.(12) s.(13) ;
    g 3 4 9 14 s.(14) s.(15)
  done ;
  List.iter
    (fun i ->
      p "%slet %s_%d = %s lxor %s lxor %s in\n" ind tag i hin.(i) (v i) (v (i + 8)))
    outs

(* Message words [first..first+15] of the 32-word space, with the
   thread-digit patches and, if [loop], the loop-digit patches. *)
let words ind ~name ~first ~loop =
  for i = 0 to 15 do
    let w = first + i in
    p "%slet %s%d = tb%d" ind name i w ;
    if loop then
      p " lor (if wl1 = %dl then p1 else 0L) lor (if wl2 = %dl then p2 else 0L)" w w ;
    p " in\n"
  done

let names fmt n = Array.init n (Printf.sprintf fmt)

let header name =
  p
    {|
let %s =
  [%%kernel
    fun (h : int64 vector) (vinit : int64 vector) (tmpl : int64 vector)
        (mida : int64 vector) (midb : int64 vector) (wa : int32)
        (wl1 : int32) (sl1 : int64) (wl2 : int32) (sl2 : int64)
        (lo : int64 vector) (hi : int64 vector) (nint : int32)
        (hit_count : int32 vector) (hit_thread : int32 vector)
        (hit_loop : int32 vector) (cap : int32) (first_thread : int32)
        (nthreads : int32) ->
      let open Sarek_stdlib.Std in
      let gid = global_thread_id in
      if gid < nthreads then begin
        let th = first_thread + gid in
        let ma = mida.(th) in
        let mb = midb.(th) in
|}
    name ;
  for i = 0 to 7 do
    p "        let h%d = h.(%dl) in\n" i i
  done ;
  for i = 0 to 7 do
    p "        let ip%d = vinit.(%dl) in\n" i i
  done ;
  for i = 0 to 7 do
    p "        let if%d = vinit.(%dl) in\n" i (i + 8)
  done ;
  (* template words with thread-digit patches (loop patches added later) *)
  for w = 0 to 31 do
    p
      "        let tb%d = tmpl.(%dl) lor (if wa = %dl then ma else 0L) lor (if \
       wa + 1l = %dl then mb else 0L) in\n"
      w w w w
  done

let loop_open ind =
  p "%slet c1 = mut 48L in\n" ind ;
  p "%sfor d1 = 0 to 9 do\n" ind ;
  p "%s  let c2 = mut 48L in\n" ind ;
  p "%s  for d2 = 0 to 9 do\n" ind ;
  p "%s    let p1 = c1 lsl sl1 in\n" ind ;
  p "%s    let p2 = c2 lsl sl2 in\n" ind

let filter_and_record ind ~out0 =
  List.iter
    (fun l -> p "%s%s\n" ind l)
    [
      "let x = " ^ out0 ^ " in";
      "let top =";
      "  0x02aa000000000000L";
      "  lor ((x land 255L) lsl 40L)";
      "  lor (((x lsr 8L) land 255L) lsl 32L)";
      "  lor (((x lsr 16L) land 255L) lsl 24L)";
      "  lor (((x lsr 24L) land 255L) lsl 16L)";
      "  lor (((x lsr 32L) land 255L) lsl 8L)";
      "  lor ((x lsr 40L) land 255L)";
      "in";
      "let l = mut 0l in";
      "let r = mut nint in";
      "while l < r do";
      "  let md = (l + r) / 2l in";
      "  if lo.(md) <= top then l := md + 1l else r := md";
      "done ;";
      "let idx = l - 1l in";
      "if idx >= 0l then begin";
      "  if top <= hi.(idx) then begin";
      "    let k = atomic_add_global_int32 hit_count 0l 1l in";
      "    if k < cap then begin";
      "      hit_thread.(k) <- th ;";
      "      hit_loop.(k) <- (d1 * 10l) + d2";
      "    end";
      "  end";
      "end ;";
    ]

let loop_close ind =
  p "%s    c2 := c2 + 1L\n" ind ;
  p "%s  done ;\n" ind ;
  p "%s  c1 := c1 + 1L\n" ind ;
  p "%sdone\n" ind

let footer () = p "      end]\n"

let hs = names "h%d" 8

let ips = names "ip%d" 8

let ifs = names "if%d" 8

(* Case A: one compression of words 16..31 per nonce. *)
let kernel_a () =
  header "search_a" ;
  let ind = "        " in
  loop_open ind ;
  let ind' = ind ^ "    " in
  words ind' ~name:"m" ~first:16 ~loop:true ;
  compress ind' ~tag:"f" ~hin:hs ~vin:ifs ~m:(names "m%d" 16) ~outs:[0] ;
  filter_and_record ind' ~out0:"f_0" ;
  loop_close ind ;
  footer ()

(* Case B: next-to-last block once per thread, final block per nonce. *)
let kernel_b () =
  header "search_b" ;
  let ind = "        " in
  words ind ~name:"q" ~first:0 ~loop:false ;
  compress ind ~tag:"s" ~hin:hs ~vin:ips ~m:(names "q%d" 16)
    ~outs:[0; 1; 2; 3; 4; 5; 6; 7] ;
  loop_open ind ;
  let ind' = ind ^ "    " in
  words ind' ~name:"m" ~first:16 ~loop:true ;
  compress ind' ~tag:"f" ~hin:(names "s_%d" 8) ~vin:ifs ~m:(names "m%d" 16)
    ~outs:[0] ;
  filter_and_record ind' ~out0:"f_0" ;
  loop_close ind ;
  footer ()

(* Case C: both blocks per nonce. *)
let kernel_c () =
  header "search_c" ;
  let ind = "        " in
  loop_open ind ;
  let ind' = ind ^ "    " in
  words ind' ~name:"q" ~first:0 ~loop:true ;
  compress ind' ~tag:"s" ~hin:hs ~vin:ips ~m:(names "q%d" 16)
    ~outs:[0; 1; 2; 3; 4; 5; 6; 7] ;
  words ind' ~name:"m" ~first:16 ~loop:true ;
  compress ind' ~tag:"f" ~hin:(names "s_%d" 8) ~vin:ifs ~m:(names "m%d" 16)
    ~outs:[0] ;
  filter_and_record ind' ~out0:"f_0" ;
  loop_close ind ;
  footer ()

let () =
  p "(* GENERATED by gen/gen_kernel.ml -- do not edit. *)\n[@@@warning \"-26-27\"]\n" ;
  kernel_a () ;
  kernel_b () ;
  kernel_c () ;
  print_string (Buffer.contents buf)
