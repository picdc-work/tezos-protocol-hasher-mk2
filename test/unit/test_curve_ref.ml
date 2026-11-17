(* US-3: the Zarith host reference against the oracle libraries
   (mirage-crypto-ec, secp256k1-internal, bls12-381), RFC 8032 and Octez. *)

open Octez_vanity

let hex = Octez_vectors.hex

let of_hex h = Octez_vectors.of_hex (String.concat "" (String.split_on_char ' ' h))

let ok = function Ok x -> x | Error e -> Alcotest.fail e

(* --- Oracles ------------------------------------------------------------ *)

let secp_ctx = lazy (Libsecp256k1.External.Context.create ~sign:true ~verify:false ())

let oracle_secp256k1 secret =
  let open Libsecp256k1.External in
  let ctx = Lazy.force secp_ctx in
  match Key.read_sk ctx (Bigstring.of_string secret) with
  | Error _ -> None
  | Ok sk ->
      let pk = Key.neuterize_exn ctx sk in
      Some (Bigstring.to_string (Key.to_bytes ~compress:true ctx pk))

let oracle_ed25519 seed =
  match Mirage_crypto_ec.Ed25519.priv_of_octets seed with
  | Error _ -> None
  | Ok priv ->
      Some (Mirage_crypto_ec.Ed25519.(pub_to_octets (pub_of_priv priv)))

(* mirage-crypto-ec gives the compressed SEC1 form directly (compress:true). *)
let oracle_p256 secret =
  match Mirage_crypto_ec.P256.Dsa.priv_of_octets secret with
  | Error _ -> None
  | Ok priv ->
      Some (Mirage_crypto_ec.P256.Dsa.(pub_to_octets ~compress:true (pub_of_priv priv)))

(* The BLS secret is read little-endian; G1.one is the standard generator. *)
let oracle_bls secret =
  match Bls12_381.Fr.of_bytes_opt (Bytes.of_string secret) with
  | None -> None
  | Some scalar ->
      Some (Bytes.to_string (Bls12_381.G1.to_compressed_bytes (Bls12_381.G1.mul Bls12_381.G1.one scalar)))

let oracle = function
  | Address.Tz1 -> oracle_ed25519
  | Tz2 -> oracle_secp256k1
  | Tz3 -> oracle_p256
  | Tz4 -> oracle_bls

let library = function
  | Address.Tz1 | Tz3 -> "mirage-crypto-ec"
  | Tz2 -> "secp256k1-internal"
  | Tz4 -> "bls12-381"

(* --- Group orders, written from the standards -------------------------- *)

let order = function
  | Address.Tz1 -> None
  | Tz2 -> Some (Z.of_string_base 16 "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
  | Tz3 -> Some (Z.of_string_base 16 "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
  | Tz4 -> Some (Z.of_string_base 16 "73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001")

let secret_of_z scheme z =
  let be = String.init 32 (fun i -> Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * (31 - i))) (Z.of_int 255)))) in
  match scheme with
  | Address.Tz4 -> String.init 32 (fun i -> be.[31 - i])
  | _ -> be

(* A scalar in [1, order - 1] drawn from the generator state. *)
let draw_scalar rng n =
  let raw = String.init 40 (fun _ -> Char.chr (Random.State.int rng 256)) in
  let z = Z.of_bits (String.init 40 (fun i -> raw.[i])) in
  Z.add Z.one (Z.rem z (Z.pred n))

let draw_secret rng scheme =
  match order scheme with
  | None -> String.init 32 (fun _ -> Char.chr (Random.State.int rng 256))
  | Some n -> secret_of_z scheme (draw_scalar rng n)

(* --- Tests -------------------------------------------------------------- *)

(* The orders written above must be the oracles' own: order - 1 is accepted,
   order is rejected. *)
let orders_match_oracles () =
  List.iter
    (fun scheme ->
      match order scheme with
      | None -> ()
      | Some n ->
          Alcotest.(check bool) "order - 1 accepted" true
            (oracle scheme (secret_of_z scheme (Z.pred n)) <> None) ;
          Alcotest.(check bool) "order rejected" true
            (oracle scheme (secret_of_z scheme n) = None))
    Address.schemes ;
  Alcotest.(check bool) "BLS order = Fr.order" true
    (Z.equal (Option.get (order Address.Tz4)) Bls12_381.Fr.order)

(* AC-8 *)
let random_secrets scheme () =
  let rng = Random.State.make [|8; Hashtbl.hash (Address.name scheme)|] in
  for i = 1 to 100 do
    let secret = draw_secret rng scheme in
    let expected = Option.get (oracle scheme secret) in
    let got = ok (Curve_ref.public_key scheme secret) in
    Alcotest.(check int) "public key length" (Address.public_key_length scheme) (String.length got) ;
    if got <> expected then
      Alcotest.failf "%s secret #%d: public key %s, %s says %s" (Address.name scheme) i
        (hex got) (library scheme) (hex expected)
  done

(* AC-9: RFC 8032 section 7.1. *)
let rfc8032 =
  [
    ("TEST 1", "9d61b19deffd5a60ba844af492ec2cc4 4449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a 0ee172f3daa62325af021a68f707511a");
    ("TEST 2", "4ccd089b28ff96da9db6c346ec114e0f 5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc 9c982ccf2ec4968cc0cd55f12af4660c");
    ("TEST 3", "c5aa8df43f9f837bedb7442f31dcb7b1 66d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f058 0816ed13ba3303ac5deb911548908025");
    ("TEST 1024", "f5e5767cf153319517630f226876b86c 8160cc583bc013744c6bf255f5cc0ee5",
     "278117fc144c72340f67d0f2316e8386 ceffbf2b2428c9c51fef7c597f1d426e");
    ("TEST SHA(abc)", "833fe62409237b9d62ec77587520911e 9a759cec1d19755b7da901b96dca3d42",
     "ec172b93ad5e563bf4932c70e1245034 c35467ef2efd4d64ebf819683467e2bf");
  ]

let rfc_vectors () =
  List.iter
    (fun (name, secret, public) ->
      Alcotest.(check string) name (hex (of_hex public))
        (hex (ok (Curve_ref.public_key Address.Tz1 (of_hex secret)))))
    rfc8032

(* AC-9: Octez tuples; the secret, public key and address strings all come
   from the Octez file. *)
let secret_prefixes =
  Address.[(Tz1, "tz1", "\x0d\x0f\x3a\x07"); (Tz2, "tz2", "\x11\xa2\xe0\xc9");
           (Tz3, "tz3", "\x10\x51\xee\xbd"); (Tz4, "tz4", "\x03\x96\xc0\x28")]

let octez_vectors (scheme, tag, secret_prefix) () =
  let pk_len = Address.public_key_length scheme in
  List.iter
    (fun (v : Octez_vectors.t) ->
      let secret = Octez_vectors.strip ~prefix:secret_prefix v.secret_key in
      let raw_pk = B58_decode.decode v.public_key in
      let pk = String.sub raw_pk (String.length raw_pk - pk_len) pk_len in
      Alcotest.(check string) (tag ^ " public key") (hex pk) (hex (ok (Curve_ref.public_key scheme secret))) ;
      Alcotest.(check string) (tag ^ " address") v.address (ok (Curve_ref.address scheme secret)))
    (Octez_vectors.of_scheme tag)

(* EC-9 *)
let ed25519_extremes () =
  List.iter
    (fun byte ->
      let seed = String.make 32 byte in
      Alcotest.(check string) "= oracle" (hex (Option.get (oracle_ed25519 seed)))
        (hex (ok (Curve_ref.public_key Address.Tz1 seed))))
    ['\x00'; '\xff']

(* AC-10, FR-014, FR-016: boundary scalars. *)
let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let boundaries scheme () =
  let n = Option.get (order scheme) in
  let rejected label secret =
    match Curve_ref.public_key scheme secret with
    | Ok _ -> Alcotest.failf "%s: %s accepted" (Address.name scheme) label
    | Error e ->
        Alcotest.(check bool) (label ^ ": no hex of the secret") false (contains ~sub:(hex secret) e) ;
        Alcotest.(check bool) (label ^ ": no raw bytes") false (contains ~sub:secret e) ;
        Alcotest.(check bool) (label ^ ": no encoding") false
          (contains ~sub:(ok (Address.secret_key scheme secret)) e)
  in
  rejected "zero" (secret_of_z scheme Z.zero) ;
  rejected "order" (secret_of_z scheme n) ;
  rejected "order + 1" (secret_of_z scheme (Z.succ n)) ;
  rejected "0xff * 32" (String.make 32 '\xff') ;
  let top = secret_of_z scheme (Z.pred n) in
  Alcotest.(check string) "order - 1" (hex (Option.get (oracle scheme top)))
    (hex (ok (Curve_ref.public_key scheme top)))

(* EC-11, and the wrong length for every scheme. *)
let wrong_lengths () =
  List.iter
    (fun scheme ->
      List.iter
        (fun len ->
          match Curve_ref.public_key scheme (String.make len 'S') with
          | Ok _ -> Alcotest.failf "%s: %d-byte secret accepted" (Address.name scheme) len
          | Error e ->
              Alcotest.(check bool) "names 32" true (contains ~sub:"32" e) ;
              Alcotest.(check bool) "no secret bytes" false (len > 0 && contains ~sub:(String.make len 'S') e))
        [0; 31; 33])
    Address.schemes

(* EC-10: below the order read little-endian, above it read big-endian. *)
let bls_little_endian () =
  let secret = "\xff" ^ String.make 31 '\000' in
  Alcotest.(check string) "= oracle" (hex (Option.get (oracle_bls secret)))
    (hex (ok (Curve_ref.public_key Address.Tz4 secret)))

let tests =
  ( "curve_ref",
    [Alcotest.test_case "orders equal the oracles'" `Quick orders_match_oracles]
    @ List.map
        (fun s ->
          Alcotest.test_case
            (Printf.sprintf "%s %s, 100" (Address.name s) (library s))
            `Quick (random_secrets s))
        Address.schemes
    @ [Alcotest.test_case "RFC 8032 7.1 vectors" `Quick rfc_vectors]
    @ List.map
        (fun ((_, tag, _) as t) ->
          Alcotest.test_case (Printf.sprintf "Octez %s vectors" tag) `Quick (octez_vectors t))
        secret_prefixes
    @ [Alcotest.test_case "ed25519 all-zero and all-ones seeds" `Quick ed25519_extremes]
    @ List.map
        (fun s ->
          Alcotest.test_case (Printf.sprintf "%s boundary secrets" (Address.name s)) `Quick (boundaries s))
        Address.[Tz2; Tz3; Tz4]
    @ [
        Alcotest.test_case "wrong secret lengths" `Quick wrong_lengths;
        Alcotest.test_case "bls little-endian" `Quick bls_little_endian;
      ] )
