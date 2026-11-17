(* tz4 key arithmetic of the address search: offset to key modulo r, the
   little-endian secret bytes, the base-key range check against r, host
   confirmation. The public key of a key is checked with bls12-381, not
   through Curve_ref's own encoder. Throwaway scalars only. *)

open Octez_vanity

let curve = Curve_ref.bls12_381_g1

let r = curve.Curve_ref.n

let k0 = Z.of_string_base 16 "1d9c5f0b7a3e48126c0f6e9ab2d4713ef05a8c64b91e2d37a6f4c8105be39d27"

let z = Alcotest.testable Z.pp_print Z.equal

let target name =
  match Target.make ~kind:(Address.target_kind Address.Tz4) name with
  | Ok t -> t
  | Error e -> Alcotest.fail e

let reverse = Walk_keys.reverse

let key_modulo_r () =
  let key ~k0 j = Walk_keys.key_of_offset curve ~k0 j in
  Alcotest.check z "no wrap" (Z.add k0 (Z.of_int 5)) (key ~k0 5L) ;
  Alcotest.check z "wrap to 0" Z.zero (key ~k0:(Z.pred r) 1L) ;
  Alcotest.check z "wrap to 1" Z.one (key ~k0:(Z.pred r) 2L) ;
  Alcotest.check z "unsigned 2^64-1"
    (Z.erem (Z.add k0 (Z.pred (Z.shift_left Z.one 64))) r)
    (key ~k0 (-1L)) ;
  Alcotest.(check bool) "reduced modulo r, not 2^256" true (Z.lt (key ~k0:(Z.pred r) 7L) (Z.of_int 8))

let little_endian_secret () =
  let secret k = Walk_keys.secret_of_scalar Address.Tz4 k in
  Alcotest.(check int) "32 bytes" 32 (String.length (secret k0)) ;
  Alcotest.(check string) "scalar 1" ("\x01" ^ String.make 31 '\x00') (secret Z.one) ;
  Alcotest.(check string) "scalar 256" ("\x00\x01" ^ String.make 30 '\x00') (secret (Z.of_int 256)) ;
  Alcotest.(check string) "reverse of the big-endian tz2 bytes"
    (Walk_keys.secret_of_scalar Address.Tz2 k0)
    (reverse (secret k0)) ;
  List.iter
    (fun k ->
      Alcotest.check z "roundtrip" k (Walk_keys.scalar_of_secret Address.Tz4 (secret k)) ;
      (* the library reads the Octez secret bytes little-endian *)
      match Bls12_381.Fr.of_bytes_opt (Bytes.of_string (secret k)) with
      | None -> Alcotest.fail "bls12-381 refuses the secret bytes"
      | Some fr -> Alcotest.check z "bls12-381 reads the same scalar" k (Bls12_381.Fr.to_z fr))
    [Z.one; k0; Z.pred r; Z.of_int 256]

(* P0 + j G of the walk is the public key of the key of offset j. *)
let offset_gives_public_key =
  QCheck.Test.make ~count:15 ~name:"tz4 offset j: P0 + j G is the bls12-381 key of k0 + j mod r"
    QCheck.(int_bound 1_000_000)
    (fun j ->
      let g = Curve_ref.generator curve in
      let p0 = Curve_ref.scalar_mul curve k0 g in
      let walked = Curve_ref.add_points curve p0 (Curve_ref.scalar_mul curve (Z.of_int j) g) in
      let key = Walk_keys.key_of_offset curve ~k0 (Int64.of_int j) in
      let fr = Bls12_381.Fr.of_z key in
      let expected = Bytes.to_string (Bls12_381.G1.to_compressed_bytes (Bls12_381.G1.mul Bls12_381.G1.one fr)) in
      match Curve_ref.affine walked with
      | Ok xy -> String.equal (Curve_ref.encode_public_key Address.Tz4 curve xy) expected
      | Error _ -> false)

let confirm_finds_matches () =
  let t = target "a" in
  let found = ref 0 in
  for j = 0 to 400 do
    match Walk_keys.confirm Address.Tz4 curve t ~k0 (Int64.of_int j) with
    | Some (address, secret) ->
        incr found ;
        Alcotest.(check bool) "target matches" true (Target.matches t address) ;
        Alcotest.check z "secret is the key of the offset"
          (Walk_keys.key_of_offset curve ~k0 (Int64.of_int j))
          (Walk_keys.scalar_of_secret Address.Tz4 secret) ;
        Alcotest.(check (result string string)) "address of the secret" (Ok address)
          (Curve_ref.address Address.Tz4 secret)
    | None -> ()
  done ;
  if !found < 1 || !found > 60 then Alcotest.failf "implausible number of matches: %d" !found

let confirm_skips_zero_key () =
  Alcotest.(check bool) "key 0 skipped" true
    (Walk_keys.confirm Address.Tz4 curve (target "a") ~k0:(Z.pred r) 1L = None)

let hex64 k = Z.format "%064x" k

let base_key_range () =
  let parse s = Key_files.parse_base_key curve s in
  Alcotest.check z "r - 1 accepted" (Z.pred r) (Result.get_ok (parse (hex64 (Z.pred r)))) ;
  Alcotest.check z "one accepted" Z.one (Result.get_ok (parse (hex64 Z.one))) ;
  List.iter
    (fun (name, k) ->
      match parse (hex64 k) with
      | Ok _ -> Alcotest.failf "accepted %s" name
      | Error e ->
          Alcotest.(check bool) (name ^ ": no secret in message") false
            (String.length e >= 64 && String.equal e (hex64 k)))
    [
      ("zero", Z.zero);
      ("r", r);
      ("r + 1", Z.succ r);
      ("2^255", Z.shift_left Z.one 255);
      ("2^256 - 1", Z.pred (Z.shift_left Z.one 256));
    ] ;
  (* a value that is a valid tz2 base key but not below r is refused for tz4 *)
  Alcotest.(check bool) "valid for secp256k1, refused for bls12-381" true
    (Result.is_ok (Key_files.parse_base_key Curve_ref.secp256k1 (hex64 (Z.succ r)))
    && Result.is_error (parse (hex64 (Z.succ r))))

let random_scalar_range () =
  for _ = 1 to 50 do
    let k = Walk_keys.random_scalar curve in
    if Z.sign k <= 0 || Z.geq k r then Alcotest.fail "scalar out of [1, r-1]"
  done

let tests =
  ( "address_tz4",
    [
      Alcotest.test_case "key of an offset modulo r" `Quick key_modulo_r;
      Alcotest.test_case "little-endian secret bytes" `Quick little_endian_secret;
      QCheck_alcotest.to_alcotest offset_gives_public_key;
      Alcotest.test_case "confirm finds matches" `Quick confirm_finds_matches;
      Alcotest.test_case "confirm skips key 0" `Quick confirm_skips_zero_key;
      Alcotest.test_case "base key range against r" `Quick base_key_range;
      Alcotest.test_case "random scalar range" `Quick random_scalar_range;
    ] )
