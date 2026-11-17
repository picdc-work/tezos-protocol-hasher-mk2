open Octez_vanity

let schemes = Address.[(Tz1, "tz1", 32, "edsk", "\x06\xa1\x9f", "\x0d\x0f\x3a\x07");
                       (Tz2, "tz2", 33, "spsk", "\x06\xa1\xa1", "\x11\xa2\xe0\xc9");
                       (Tz3, "tz3", 33, "p2sk", "\x06\xa1\xa4", "\x10\x51\xee\xbd");
                       (Tz4, "tz4", 48, "BLsk", "\x06\xa1\xa6", "\x03\x96\xc0\x28")]

let ok = function Ok x -> x | Error e -> Alcotest.fail e

let starts_with ~prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

(* AC-1: the secret key strings of Octez are reproduced from their bytes. *)
let octez_secrets () =
  List.iter
    (fun (scheme, tag, _, text, _, secret_prefix) ->
      let vectors = Octez_vectors.of_scheme tag in
      Alcotest.(check int) (tag ^ " vector count") 10 (List.length vectors) ;
      List.iter
        (fun (v : Octez_vectors.t) ->
          let secret = Octez_vectors.strip ~prefix:secret_prefix v.secret_key in
          Alcotest.(check int) "secret length" 32 (String.length secret) ;
          let encoded = ok (Address.secret_key scheme secret) in
          Alcotest.(check string) (tag ^ " secret") v.secret_key encoded ;
          Alcotest.(check int) "54 characters" 54 (String.length encoded) ;
          Alcotest.(check bool) ("starts with " ^ text) true (starts_with ~prefix:text encoded))
        vectors)
    schemes

(* The public key is the tail of the decoded base58 public key string. *)
let public_key_bytes (v : Octez_vectors.t) len =
  let raw = B58_decode.decode v.public_key in
  String.sub raw (String.length raw - len) len

let octez_addresses () =
  List.iter
    (fun (scheme, tag, pk_len, _, address_prefix, _) ->
      List.iter
        (fun (v : Octez_vectors.t) ->
          let pk = public_key_bytes v pk_len in
          Alcotest.(check int) "public key length" pk_len (String.length pk) ;
          let a = ok (Address.address scheme pk) in
          Alcotest.(check string) (tag ^ " address") v.address a ;
          Alcotest.(check int) "36 characters" 36 (String.length a) ;
          (* the address decodes to the documented prefix and a 20-byte digest *)
          let digest = Octez_vectors.strip ~prefix:address_prefix a in
          Alcotest.(check int) "digest length" 20 (String.length digest))
        (Octez_vectors.of_scheme tag))
    schemes

let extreme_digests () =
  List.iter
    (fun (scheme, tag, _, _, _, _) ->
      List.iter
        (fun byte ->
          let a = Address.address_of_digest scheme (String.make 20 byte) in
          Alcotest.(check int) (tag ^ " length") 36 (String.length a) ;
          Alcotest.(check bool) (tag ^ " text") true (starts_with ~prefix:tag a))
        ['\x00'; '\xff'])
    schemes

(* AC-3, EC-1, EC-2, FR-016. *)
let wrong_lengths () =
  List.iter
    (fun (scheme, tag, pk_len, _, _, _) ->
      List.iter
        (fun len ->
          match Address.address scheme (String.make len 'k') with
          | Ok _ -> Alcotest.failf "%s: %d-byte public key accepted" tag len
          | Error e ->
              Alcotest.(check bool)
                (Printf.sprintf "%s message names %d" tag pk_len)
                true
                (contains ~sub:(string_of_int pk_len) e))
        [0; pk_len - 1; pk_len + 1] ;
      List.iter
        (fun len ->
          let secret = String.make len 'S' in
          match Address.secret_key scheme secret with
          | Ok _ -> Alcotest.failf "%s: %d-byte secret accepted" tag len
          | Error e ->
              Alcotest.(check bool) "names 32" true (contains ~sub:"32" e) ;
              Alcotest.(check bool) "no secret bytes" false
                (len > 0 && contains ~sub:secret e))
        [0; 31; 33])
    schemes

let curve_check_is_not_done () =
  (* EC-2: a 33-byte key whose first byte is not 02/03 is still encoded. *)
  let a = ok (Address.address Address.Tz2 (String.make 33 '\x05')) in
  Alcotest.(check int) "36 characters" 36 (String.length a)

let leading_zero () =
  Alcotest.check_raises "payload starting with a zero byte"
    (Invalid_argument "Base58.check_encode: payload starts with a zero byte")
    (fun () -> ignore (Base58.check_encode "\000abc"))

let tests =
  ( "address",
    [
      Alcotest.test_case "Octez secret keys reproduced" `Quick octez_secrets;
      Alcotest.test_case "Octez addresses reproduced" `Quick octez_addresses;
      Alcotest.test_case "all-zero and all-ones digests" `Quick extreme_digests;
      Alcotest.test_case "wrong lengths give Error" `Quick wrong_lengths;
      Alcotest.test_case "no curve check on public keys" `Quick curve_check_is_not_done;
      Alcotest.test_case "leading zero byte refused" `Quick leading_zero;
    ] )
