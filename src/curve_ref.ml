(* Constants are written from the standards: RFC 8032 (Ed25519), SEC 2
   (secp256k1), FIPS 186-4 (P-256) and the BLS12-381 specification (the
   ZCash serialisation for G1). The tests check them against independent
   libraries. *)

let hex h = Z.of_string_base 16 h

let z_of_le s = Z.of_bits s

let z_to_be len z =
  String.init len (fun i ->
      Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * (len - 1 - i))) (Z.of_int 255))))

let ( %% ) a p = Z.erem a p

let inv x p = Z.invert x p

(* --- Short Weierstrass curves y^2 = x^3 + a x + b over F_p -------------- *)

type curve = {p : Z.t; a : Z.t; b : Z.t; n : Z.t; gx : Z.t; gy : Z.t}

type point = Infinity | Affine of Z.t * Z.t

let add_points c p1 p2 =
  match (p1, p2) with
  | Infinity, q | q, Infinity -> q
  | Affine (x1, y1), Affine (x2, y2) ->
      if Z.equal x1 x2 && not (Z.equal y1 y2) then Infinity
      else if Z.equal x1 x2 && Z.equal y1 Z.zero then Infinity
      else
        let slope =
          if Z.equal x1 x2 then
            Z.mul (Z.add (Z.mul (Z.of_int 3) (Z.mul x1 x1)) c.a) (inv (Z.mul (Z.of_int 2) y1) c.p)
          else Z.mul (Z.sub y2 y1) (inv (Z.sub x2 x1) c.p)
        in
        let slope = slope %% c.p in
        let x3 = (Z.sub (Z.sub (Z.mul slope slope) x1) x2) %% c.p in
        let y3 = (Z.sub (Z.mul slope (Z.sub x1 x3)) y1) %% c.p in
        Affine (x3, y3)

(* Double-and-add, most significant bit first. Not constant-time. *)
let scalar_mul c k pt =
  let result = ref Infinity in
  for i = Z.numbits k - 1 downto 0 do
    result := add_points c !result !result ;
    if Z.testbit k i then result := add_points c !result pt
  done ;
  !result

let secp256k1 =
  {
    p = hex "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F";
    a = Z.zero;
    b = Z.of_int 7;
    n = hex "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141";
    gx = hex "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798";
    gy = hex "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8";
  }

let p256 =
  let p = hex "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF" in
  {
    p;
    a = Z.sub p (Z.of_int 3);
    b = hex "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B";
    n = hex "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551";
    gx = hex "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296";
    gy = hex "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5";
  }

let bls12_381_g1 =
  {
    p =
      hex
        "1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB";
    a = Z.zero;
    b = Z.of_int 4;
    n = hex "73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001";
    gx =
      hex
        "17F1D3A73197D7942695638C4FA9AC0FC3688C4F9774B905A14E3A3F171BAC586C55E83FF97A1AEFFB3AF00ADB22C6BB";
    gy =
      hex
        "08B3F481E3AAA0F1A09E30ED741D8AE4FCF5E095D5D00AF600DB18CB2C04B3EDD03CC744A2888AE40CAA232946C5E7E1";
  }

(* A mistyped parameter is caught here, before any use. *)
let on_curve c (x, y) =
  Z.equal (Z.mul y y %% c.p) (Z.add (Z.add (Z.pow x 3) (Z.mul c.a x)) c.b %% c.p)

let () =
  List.iter
    (fun c -> assert (on_curve c (c.gx, c.gy)))
    [secp256k1; p256; bls12_381_g1]

let multiply_generator c k =
  match scalar_mul c k (Affine (c.gx, c.gy)) with
  | Affine (x, y) -> (x, y)
  | Infinity -> failwith "Curve_ref: the scalar is a multiple of the group order"

(* SEC1 compressed: 02 or 03 (parity of y), then x on 32 bytes. *)
let sec1_compressed (x, y) =
  String.make 1 (if Z.testbit y 0 then '\x03' else '\x02') ^ z_to_be 32 x

(* ZCash compressed G1: x on 48 bytes, bit 0x80 set, bit 0x20 set when y is
   the larger of the two roots, that is y > (p - 1) / 2. *)
let zcash_compressed c (x, y) =
  let bytes = Bytes.of_string (z_to_be 48 x) in
  let flags = if Z.gt y (Z.shift_right c.p 1) then 0xa0 else 0x80 in
  Bytes.set bytes 0 (Char.chr (Char.code (Bytes.get bytes 0) lor flags)) ;
  Bytes.to_string bytes

(* --- Ed25519 (RFC 8032 section 5.1.5) ----------------------------------- *)

let ed_p = Z.sub (Z.shift_left Z.one 255) (Z.of_int 19)

let ed_d = (Z.neg (Z.of_int 121665) |> fun n -> Z.mul n (inv (Z.of_int 121666) ed_p)) %% ed_p

let ed_sqrt_minus_one = Z.powm (Z.of_int 2) (Z.div (Z.pred ed_p) (Z.of_int 4)) ed_p

(* x with x^2 = (y^2 - 1) / (d y^2 + 1) and the requested parity. *)
let ed_recover_x y ~odd =
  let y2 = Z.mul y y in
  let x2 = Z.mul (Z.pred y2 %% ed_p) (inv (Z.succ (Z.mul ed_d y2) %% ed_p) ed_p) %% ed_p in
  let x = Z.powm x2 (Z.div (Z.add ed_p (Z.of_int 3)) (Z.of_int 8)) ed_p in
  let x = if Z.equal (Z.mul x x %% ed_p) x2 then x else Z.mul x ed_sqrt_minus_one %% ed_p in
  assert (Z.equal (Z.mul x x %% ed_p) x2) ;
  if Z.testbit x 0 = odd then x else Z.sub ed_p x

let ed_base =
  let y = Z.mul (Z.of_int 4) (inv (Z.of_int 5) ed_p) %% ed_p in
  (ed_recover_x y ~odd:false, y)

(* Complete addition law of the twisted Edwards curve -x^2 + y^2 = 1 + d x^2 y^2. *)
let ed_add (x1, y1) (x2, y2) =
  let dxy = Z.mul ed_d (Z.mul (Z.mul x1 x2) (Z.mul y1 y2)) in
  let x3 = Z.mul (Z.add (Z.mul x1 y2) (Z.mul x2 y1)) (inv (Z.succ dxy %% ed_p) ed_p) in
  let y3 = Z.mul (Z.add (Z.mul y1 y2) (Z.mul x1 x2)) (inv (Z.sub Z.one dxy %% ed_p) ed_p) in
  (x3 %% ed_p, y3 %% ed_p)

let ed_scalar_mul k pt =
  let result = ref (Z.zero, Z.one) in
  for i = Z.numbits k - 1 downto 0 do
    result := ed_add !result !result ;
    if Z.testbit k i then result := ed_add !result pt
  done ;
  !result

let ed25519_public_key seed =
  let h = Digestif.SHA512.(to_raw_string (digest_string seed)) in
  let lower = Bytes.of_string (String.sub h 0 32) in
  Bytes.set lower 0 (Char.chr (Char.code (Bytes.get lower 0) land 248)) ;
  Bytes.set lower 31 (Char.chr (Char.code (Bytes.get lower 31) land 127 lor 64)) ;
  let x, y = ed_scalar_mul (z_of_le (Bytes.to_string lower)) ed_base in
  let encoded = Bytes.of_string (String.init 32 (fun i -> Char.chr (Z.to_int (Z.logand (Z.shift_right y (8 * i)) (Z.of_int 255))))) in
  if Z.testbit x 0 then Bytes.set encoded 31 (Char.chr (Char.code (Bytes.get encoded 31) lor 0x80)) ;
  Bytes.to_string encoded

(* --- Entry points --------------------------------------------------------- *)

let scalar_result c ~little_endian secret scheme encode =
  let k = if little_endian then z_of_le secret else Base58.z_of_be secret in
  if Z.sign k = 0 || Z.geq k c.n then
    Error (Printf.sprintf "%s secret scalar must be in [1, order - 1]" (Address.name scheme))
  else Ok (encode (multiply_generator c k))

let public_key scheme secret =
  if String.length secret <> Address.secret_length then
    Error
      (Printf.sprintf "%s secret key must have %d bytes, got %d" (Address.name scheme)
         Address.secret_length (String.length secret))
  else
    match scheme with
    | Address.Tz1 -> Ok (ed25519_public_key secret)
    | Tz2 -> scalar_result secp256k1 ~little_endian:false secret scheme sec1_compressed
    | Tz3 -> scalar_result p256 ~little_endian:false secret scheme sec1_compressed
    | Tz4 ->
        scalar_result bls12_381_g1 ~little_endian:true secret scheme (zcash_compressed bls12_381_g1)

let address scheme secret = Result.bind (public_key scheme secret) (Address.address scheme)
