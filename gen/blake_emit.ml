(* Blake2b emitters shared by gen_kernel.ml and gen_walk.ml: one fully
   unrolled compression (12 rounds x 8 G) on mutable int64 scalars, and the
   interval filter with hit recording. The output of gen_kernel.ml must stay
   byte-identical (roster/tz-vanity-foundation/kernels.main.sha256). *)

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

let tmp = ref 0

let fresh prefix =
  incr tmp ;
  Printf.sprintf "%s%d" prefix !tmp

(* One compression, printed to [out]. [hin]: 8 chaining-value names; [vin]:
   8 names for v8..v15; [m]: 16 message-word names. Binds [tag_i] for i in
   [outs]. [tprefix] names the temporaries. *)
let compress ?(tprefix = "t") out ind ~tag ~hin ~vin ~m ~outs =
  let p fmt = Printf.bprintf out fmt in
  let v i = Printf.sprintf "v%s_%d" tag i in
  for i = 0 to 7 do
    p "%slet %s = mut %s in\n" ind (v i) hin.(i)
  done ;
  for i = 0 to 7 do
    p "%slet %s = mut %s in\n" ind (v (i + 8)) vin.(i)
  done ;
  let rot dst x y n =
    let t = fresh tprefix in
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

(* Lines of the prefilter: [top] binds [top] (a 64-bit value, ending with
   "in"); binary search of [top] in the sorted intervals [lo]/[hi]; on a hit
   the lines [record] run with the slot [k] of the hit buffer (capacity
   [cap]). The names x, top, l, r, md, idx and k are used. *)
let filter_lines ~top ~record =
  top
  @ [
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
    ]
  @ List.map (fun l -> "      " ^ l) record
  @ ["    end"; "  end"; "end ;"]
