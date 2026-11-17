(* Host-side reference: Blake2b-256 with mid-state, protocol-hash encoding,
   base58 intervals for the GPU prefilter, and exact matching. *)

let iv =
  [|
    0x6a09e667f3bcc908L;
    0xbb67ae8584caa73bL;
    0x3c6ef372fe94f82bL;
    0xa54ff53a5f1d36f1L;
    0x510e527fade682d1L;
    0x9b05688c2b3e6c1fL;
    0x1f83d9abfb41bd6bL;
    0x5be0cd19137e2179L;
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

let rotr x n =
  Int64.logor (Int64.shift_right_logical x n) (Int64.shift_left x (64 - n))

(* Compress block [m] (16 words) into chaining value [h] (in place). *)
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

let words_of_block (b : Bytes.t) off len =
  let blk = Bytes.make 128 '\000' in
  Bytes.blit b off blk 0 len ;
  Array.init 16 (fun i -> Bytes.get_int64_le blk (8 * i))

(* Layout of a dump: the 16 nonce digits are at [digits_off]; the final
   Blake2b block starts at [last_off]. *)
type layout = {
  data : Bytes.t;  (** whole dump *)
  len : int;
  last_off : int;
  digits_off : int;
  q : int;  (** offset of the first digit inside the final block *)
  mid_state : int64 array;  (** chaining value before the final block *)
}

let marker = "(* Vanity nonce: "

let load_dump path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let data = Bytes.create len in
  really_input ic data 0 len ;
  close_in ic ;
  let tail = " *)\n" in
  let digits_off = len - 20 in
  let ok =
    len > 100
    && Bytes.sub_string data (len - 4) 4 = tail
    && Bytes.sub_string data (digits_off - String.length marker)
         (String.length marker)
       = marker
    && Bytes.for_all
         (fun c -> c >= '0' && c <= '9')
         (Bytes.sub data digits_off 16)
  in
  if not ok then
    failwith "dump must end with \"(* Vanity nonce: <16 digits> *)\\n\"" ;
  let last_off = (len - 1) / 128 * 128 in
  if digits_off < last_off then
    failwith
      "prototype limitation: nonce digits straddle two Blake2b blocks" ;
  let h = Array.copy iv in
  h.(0) <- Int64.logxor h.(0) 0x01010020L ;
  let nblocks = last_off / 128 in
  for i = 0 to nblocks - 1 do
    compress h
      (words_of_block data (i * 128) 128)
      ~t0:(Int64.of_int ((i + 1) * 128))
      ~last:false
  done ;
  {data; len; last_off; digits_off; q = digits_off - last_off; mid_state = h}

let nonce_string n = Printf.sprintf "%016Ld" n

(* Final block words for a given full nonce. *)
let final_block l nonce =
  let blk = Bytes.sub l.data l.last_off (l.len - l.last_off) in
  Bytes.blit_string (nonce_string nonce) 0 blk l.q 16 ;
  words_of_block blk 0 (Bytes.length blk)

let digest_words l nonce =
  let h = Array.copy l.mid_state in
  compress h (final_block l nonce) ~t0:(Int64.of_int l.len) ~last:true ;
  h

let digest_of_words h =
  let b = Bytes.create 32 in
  for i = 0 to 3 do
    Bytes.set_int64_le b (8 * i) h.(i)
  done ;
  Bytes.to_string b

(* Independent check through digestif on the full dump. *)
module B2 = Digestif.Make_BLAKE2B (struct
  let digest_size = 32
end)

let digest_full l nonce =
  let d = Bytes.copy l.data in
  Bytes.blit_string (nonce_string nonce) 0 d l.digits_off 16 ;
  B2.to_raw_string (B2.digest_bytes d)

(* --- base58 --- *)

let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let b58_index c = String.index alphabet c

let z_of_be s =
  String.fold_left
    (fun acc c -> Z.add (Z.shift_left acc 8) (Z.of_int (Char.code c)))
    Z.zero s

let b58_encode_z n =
  let z58 = Z.of_int 58 in
  let rec go n acc =
    if Z.equal n Z.zero then acc
    else
      let q, r = Z.div_rem n z58 in
      go q (String.make 1 alphabet.[Z.to_int r] ^ acc)
  in
  go n ""

let prefix = "\002\170"

let protocol_hash digest =
  let payload = prefix ^ digest in
  let sha s = Digestif.SHA256.(to_raw_string (digest_string s)) in
  let chk = String.sub (sha (sha payload)) 0 4 in
  b58_encode_z (z_of_be (payload ^ chk))

(* Matching rule of the reference C hasher: case-insensitive, from the 3rd
   character. *)
let matches name hash =
  let n = String.length name in
  String.length hash >= n + 2
  && String.lowercase_ascii (String.sub hash 2 n) = name

(* Intervals on top64 = (0x02aa || digest || checksum) >> 240 such that
   any hash matching [name] has its top64 in one of them. Sorted, merged. *)
let intervals name =
  let nbytes = 38 in
  let total_bits = nbytes * 8 in
  let nmin = Z.shift_left (Z.of_int 0x02aa) (total_bits - 16) in
  let nmax = Z.pred (Z.shift_left (Z.of_int 0x02ab) (total_bits - 16)) in
  let ndigits = String.length (b58_encode_z nmin) in
  assert (ndigits = String.length (b58_encode_z nmax)) ;
  let variants c =
    List.filter
      (fun a -> Char.lowercase_ascii a = c)
      (List.init (String.length alphabet) (String.get alphabet))
  in
  let rec combos = function
    | [] -> [""]
    | c :: rest ->
        let tails = combos rest in
        List.concat_map
          (fun v -> List.map (fun t -> String.make 1 v ^ t) tails)
          (variants c)
  in
  let name_chars = List.init (String.length name) (String.get name) in
  List.iter
    (fun c ->
      if variants c = [] then
        failwith (Printf.sprintf "character %C cannot appear in a hash" c))
    name_chars ;
  let p58 k = Z.pow (Z.of_int 58) k in
  let acc = ref [] in
  String.iter
    (fun second ->
      List.iter
        (fun v ->
          let pre = "P" ^ String.make 1 second ^ v in
          let k = String.length pre in
          let lo = ref Z.zero in
          String.iteri
            (fun i c ->
              lo := Z.add !lo (Z.mul (Z.of_int (b58_index c)) (p58 (ndigits - 1 - i))))
            pre ;
          let hi = Z.pred (Z.add !lo (p58 (ndigits - k))) in
          let lo = Z.max !lo nmin and hi = Z.min hi nmax in
          if Z.leq lo hi then
            acc :=
              ( Z.to_int64 (Z.shift_right lo (total_bits - 64)),
                Z.to_int64 (Z.shift_right hi (total_bits - 64)) )
              :: !acc)
        (combos name_chars))
    alphabet ;
  let sorted = List.sort compare !acc in
  let rec merge = function
    | (a, b) :: (c, d) :: rest when c <= Int64.succ b ->
        merge ((a, Int64.max b d) :: rest)
    | x :: rest -> x :: merge rest
    | [] -> []
  in
  Array.of_list (merge sorted)

(* The same top64 the kernel computes, from digest word 0. *)
let top64 h0 =
  let b i = Int64.logand (Int64.shift_right_logical h0 (8 * i)) 255L in
  let ( |: ) = Int64.logor in
  0x02aa000000000000L
  |: Int64.shift_left (b 0) 40
  |: Int64.shift_left (b 1) 32
  |: Int64.shift_left (b 2) 24
  |: Int64.shift_left (b 3) 16
  |: Int64.shift_left (b 4) 8
  |: b 5

let in_intervals iv t =
  Array.exists (fun (lo, hi) -> lo <= t && t <= hi) iv
