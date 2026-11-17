let iv =
  [|
    0x6a09e667f3bcc908L; 0xbb67ae8584caa73bL; 0x3c6ef372fe94f82bL;
    0xa54ff53a5f1d36f1L; 0x510e527fade682d1L; 0x9b05688c2b3e6c1fL;
    0x1f83d9abfb41bd6bL; 0x5be0cd19137e2179L;
  |]

(* Row 9 is "... 15 11 9 14 3 ...": transposing 9/14 was a real bug. *)
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

let check_len len =
  if len < 1 || len > 64 then invalid_arg "Blake2b: digest length must be in 1..64"

let init ?(len = 32) () =
  check_len len ;
  let h = Array.copy iv in
  h.(0) <- Int64.logxor h.(0) (Int64.of_int (0x01010000 lor len)) ;
  h

let rotr x n =
  Int64.logor (Int64.shift_right_logical x n) (Int64.shift_left x (64 - n))

let compress h m ~t0 ~last =
  let v = Array.make 16 0L in
  Array.blit h 0 v 0 8 ;
  Array.blit iv 0 v 8 8 ;
  v.(12) <- Int64.logxor v.(12) t0 ;
  if last then v.(14) <- Int64.lognot v.(14) ;
  let g a b c d x y =
    v.(a) <- Int64.add (Int64.add v.(a) v.(b)) x ;
    v.(d) <- rotr (Int64.logxor v.(d) v.(a)) 32 ;
    v.(c) <- Int64.add v.(c) v.(d) ;
    v.(b) <- rotr (Int64.logxor v.(b) v.(c)) 24 ;
    v.(a) <- Int64.add (Int64.add v.(a) v.(b)) y ;
    v.(d) <- rotr (Int64.logxor v.(d) v.(a)) 16 ;
    v.(c) <- Int64.add v.(c) v.(d) ;
    v.(b) <- rotr (Int64.logxor v.(b) v.(c)) 63
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
  for i = 0 to 7 do
    h.(i) <- Int64.logxor h.(i) (Int64.logxor v.(i) v.(i + 8))
  done

let words_of_block b off len =
  let blk = Bytes.make 128 '\000' in
  Bytes.blit b off blk 0 len ;
  Array.init 16 (fun i -> Bytes.get_int64_le blk (8 * i))

let digest_of_state ?(len = 32) h =
  check_len len ;
  let b = Bytes.create 64 in
  for i = 0 to 7 do
    Bytes.set_int64_le b (8 * i) h.(i)
  done ;
  Bytes.sub_string b 0 len

let digest ?(len = 32) s =
  let b = Bytes.of_string s in
  let n = Bytes.length b in
  let h = init ~len () in
  if n = 0 then compress h (Array.make 16 0L) ~t0:0L ~last:true
  else begin
    let last = (n - 1) / 128 * 128 in
    for i = 0 to (last / 128) - 1 do
      compress h (words_of_block b (i * 128) 128) ~t0:(Int64.of_int ((i + 1) * 128)) ~last:false
    done ;
    compress h (words_of_block b last (n - last)) ~t0:(Int64.of_int n) ~last:true
  end ;
  digest_of_state ~len h
