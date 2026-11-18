(* Host reference for Tezos tz1 vanity keys, independent of the device code:
   Ed25519 public key from a 32-byte seed (SHA-512, clamping, scalar
   multiplication in affine coordinates with Zarith), tz1 address, edsk
   encoding, the fixed-base table used by the kernel, and the base58
   prefilter intervals. *)

let p = Z.(sub (shift_left one 255) (of_int 19))

let md x = Z.erem x p

let inv x = Z.invert x p

let d = md Z.(mul (of_int (-121665)) (inv (of_int 121666)))

let base =
  ( Z.of_string
      "15112221349535400772501151409588531511454012693041857206046113283949847762202",
    md Z.(mul (of_int 4) (inv (of_int 5))) )

let zero = (Z.zero, Z.one)

(* Twisted Edwards addition, a = -1; complete since d is not a square. *)
let add (x1, y1) (x2, y2) =
  let t = md Z.(mul d (mul (mul x1 x2) (mul y1 y2))) in
  let x3 = md Z.(mul (add (mul x1 y2) (mul y1 x2)) (inv (add one t))) in
  let y3 = md Z.(mul (add (mul y1 y2) (mul x1 x2)) (inv (sub one t))) in
  (x3, y3)

let scalar_mult k pt =
  let r = ref zero in
  for i = Z.numbits k - 1 downto 0 do
    r := add !r !r ;
    if Z.testbit k i then r := add !r pt
  done ;
  !r

let le_bytes n z =
  String.init n (fun i ->
      Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * i)) (Z.of_int 255))))

let encode (x, y) =
  let b = Bytes.of_string (le_bytes 32 y) in
  if Z.testbit x 0 then
    Bytes.set b 31 (Char.chr (Char.code (Bytes.get b 31) lor 0x80)) ;
  Bytes.to_string b

let clamp h =
  let b = Bytes.of_string (String.sub h 0 32) in
  Bytes.set b 0 (Char.chr (Char.code (Bytes.get b 0) land 248)) ;
  Bytes.set b 31 (Char.chr (Char.code (Bytes.get b 31) land 127 lor 64)) ;
  Z.of_bits (Bytes.to_string b)

let public_key seed =
  let h = Digestif.SHA512.(to_raw_string (digest_string seed)) in
  encode (scalar_mult (clamp h) base)

module B160 = Digestif.Make_BLAKE2B (struct
  let digest_size = 20
end)

let pkh pk = B160.(to_raw_string (digest_string pk))

(* base58 *)
let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let b58_index c = String.index alphabet c

let b58_encode_z z =
  let rec go z acc =
    if Z.equal z Z.zero then acc
    else
      let q, r = Z.div_rem z (Z.of_int 58) in
      go q (String.make 1 alphabet.[Z.to_int r] ^ acc)
  in
  go z ""

let b58check payload =
  let sha s = Digestif.SHA256.(to_raw_string (digest_string s)) in
  let s = payload ^ String.sub (sha (sha payload)) 0 4 in
  let rec zeros i = if i < String.length s && s.[i] = '\000' then zeros (i + 1) else i in
  let n = Z.of_bits (String.init (String.length s) (fun i -> s.[String.length s - 1 - i])) in
  String.make (zeros 0) '1' ^ b58_encode_z n

let tz1_prefix = "\006\161\159"

let tz1 pk = b58check (tz1_prefix ^ pkh pk)

let edsk seed = b58check ("\013\015\058\007" ^ seed)

let edpk pk = b58check ("\013\015\037\217" ^ pk)

(* Radix 2^25.5 limbs (ref10): 26, 25, 26, 25, ... bits. *)
let limb_off = [|0; 26; 51; 77; 102; 128; 153; 179; 204; 230|]

let limbs z =
  Array.init 10 (fun i ->
      let bits = if i land 1 = 0 then 26 else 25 in
      Z.to_int64
        (Z.logand (Z.shift_right z limb_off.(i))
           (Z.pred (Z.shift_left Z.one bits))))

(* Fixed-base table: entry (pos, v) = v * 256^pos * B in Niels form
   (y + x, y - x, 2dxy), 30 limbs; pos in [0, 32), v in [0, 256). *)
let table () =
  let t = Array.make (32 * 256 * 30) 0L in
  let q = ref base in
  for pos = 0 to 31 do
    let acc = ref zero in
    for v = 0 to 255 do
      let x, y = !acc in
      let e = ((pos * 256) + v) * 30 in
      Array.blit (limbs (md (Z.add y x))) 0 t e 10 ;
      Array.blit (limbs (md (Z.sub y x))) 0 t (e + 10) 10 ;
      Array.blit (limbs (md Z.(mul (mul (of_int 2) d) (mul x y)))) 0 t (e + 20) 10 ;
      acc := add !acc !q
    done ;
    (* !acc = 256 * q *)
    q := !acc
  done ;
  t

(* Seed of key (gid, k): 4 big-endian words, word 0 xored with
   gid lor (k lsl 32). *)
let seed_words base_seed gid k =
  let w = Array.copy base_seed in
  w.(0) <- Int64.(logxor w.(0) (logor (of_int gid) (shift_left (of_int k) 32))) ;
  w

let seed_of_words w =
  String.concat ""
    (Array.to_list
       (Array.map
          (fun x ->
            String.init 8 (fun i ->
                Char.chr
                  (Int64.to_int
                     (Int64.logand (Int64.shift_right_logical x (8 * (7 - i))) 255L))))
          w))

(* Prefilter: intervals on top64 = first 8 bytes of 0x06a19f || pkh || cksum
   such that every address "tz1" ^ name (case-insensitive when [ci]) has its
   top64 inside one of them. *)
let intervals ~ci name =
  let nbytes = 27 in
  let total_bits = nbytes * 8 in
  let nmin = Z.shift_left (Z.of_int 0x06a19f) (total_bits - 24) in
  let nmax = Z.pred (Z.shift_left (Z.of_int 0x06a1a0) (total_bits - 24)) in
  let ndigits = String.length (b58_encode_z nmin) in
  assert (ndigits = String.length (b58_encode_z nmax)) ;
  let variants c =
    List.filter
      (fun a -> if ci then Char.lowercase_ascii a = Char.lowercase_ascii c else a = c)
      (List.init (String.length alphabet) (String.get alphabet))
  in
  let rec combos = function
    | [] -> [""]
    | c :: rest ->
        let tails = combos rest in
        List.concat_map (fun v -> List.map (fun t -> String.make 1 v ^ t) tails) (variants c)
  in
  let chars = List.init (String.length name) (String.get name) in
  List.iter
    (fun c -> if variants c = [] then failwith (Printf.sprintf "character %C not in base58" c))
    chars ;
  let p58 k = Z.pow (Z.of_int 58) k in
  let acc = ref [] in
  List.iter
    (fun v ->
      let pre = "tz1" ^ v in
      let k = String.length pre in
      let lo = ref Z.zero in
      String.iteri
        (fun i c -> lo := Z.add !lo (Z.mul (Z.of_int (b58_index c)) (p58 (ndigits - 1 - i))))
        pre ;
      let hi = Z.pred (Z.add !lo (p58 (ndigits - k))) in
      let lo = Z.max !lo nmin and hi = Z.min hi nmax in
      if Z.leq lo hi then
        acc :=
          ( Z.to_int64 (Z.shift_right lo (total_bits - 64)),
            Z.to_int64 (Z.shift_right hi (total_bits - 64)) )
          :: !acc)
    (combos chars) ;
  let rec merge = function
    | (a, b) :: (c, d) :: rest when c <= Int64.succ b -> merge ((a, Int64.max b d) :: rest)
    | x :: rest -> x :: merge rest
    | [] -> []
  in
  Array.of_list (merge (List.sort compare !acc))

let matches ~ci name addr =
  let s = String.sub addr 3 (String.length name) in
  if ci then String.lowercase_ascii s = String.lowercase_ascii name else s = name

let hex s = String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))
