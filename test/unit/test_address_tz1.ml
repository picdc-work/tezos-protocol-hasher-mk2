(* tz1 seed arithmetic of the address search: the seed of an offset (carry
   across bytes, wrap at 2^64), the base-key file rules and the host
   confirmation. The seed is recomputed here with Zarith, independently of
   Seed_keys, and the key of a seed is checked with mirage-crypto-ec. *)

open Octez_vanity

let two64 = Z.shift_left Z.one 64

let be64 z =
  String.init 8 (fun i -> Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * (7 - i))) (Z.of_int 255))))

let base_with_counter counter =
  String.init 24 (fun i -> Char.chr ((i * 41 + 5) land 255)) ^ be64 counter

let expected_seed ~base j =
  let u = Z.of_bits (String.init 8 (fun i -> base.[31 - i])) in
  let sum = Z.erem (Z.add u j) two64 in
  String.sub base 0 24
  ^ be64 sum

let unsigned_offset j = Z.logand (Z.of_int64 j) (Z.pred two64)

let check_seed name ~base j =
  Alcotest.(check string) name (expected_seed ~base (unsigned_offset j)) (Seed_keys.seed_of_offset ~base j)

let carry_and_wrap () =
  let base = base_with_counter (Z.of_string_base 16 "00000000ffffff00") in
  List.iter (fun j -> check_seed (Printf.sprintf "carry, offset %Ld" j) ~base j) [0L; 255L; 256L; 257L; 100000L] ;
  Alcotest.(check string) "carry into byte 3" "\x00\x00\x00\x01\x00\x00\x00\x00"
    (String.sub (Seed_keys.seed_of_offset ~base 0x100L) 24 8) ;
  let near = base_with_counter (Z.sub two64 (Z.of_int 3)) in
  List.iter (fun j -> check_seed (Printf.sprintf "wrap, offset %Ld" j) ~base:near j) [0L; 2L; 3L; 4L; 1000L; -1L] ;
  Alcotest.(check string) "wraps to zero" (String.make 8 '\x00') (String.sub (Seed_keys.seed_of_offset ~base:near 3L) 24 8) ;
  Alcotest.(check string) "prefix untouched" (String.sub near 0 24) (String.sub (Seed_keys.seed_of_offset ~base:near 5L) 0 24) ;
  let top = base_with_counter (Z.pred two64) in
  Alcotest.(check string) "all ones plus one" (String.make 8 '\x00') (String.sub (Seed_keys.seed_of_offset ~base:top 1L) 24 8) ;
  (* offsets from 2^63 on are read unsigned *)
  check_seed "offset 2^63" ~base Int64.min_int

let words () =
  let base = base_with_counter (Z.of_int 258) in
  Alcotest.(check int) "three prefix words" 3 (Array.length (Seed_keys.prefix_words base)) ;
  Alcotest.(check int64) "counter" 258L (Seed_keys.counter base) ;
  Alcotest.(check int64) "counter of an offset" 260L (Seed_keys.counter_of_offset ~base 2L) ;
  Alcotest.(check int64) "first word is the first 8 bytes big-endian" (String.get_int64_be base 0)
    (Seed_keys.prefix_words base).(0)

let random_base () =
  Alcotest.(check int) "32 bytes" 32 (String.length (Seed_keys.random_base ())) ;
  Alcotest.(check bool) "fresh" true (Seed_keys.random_base () <> Seed_keys.random_base ())

let target name =
  match Target.make ~kind:(Address.target_kind Address.Tz1) name with
  | Ok t -> t
  | Error e -> Alcotest.fail e

let confirm () =
  let t = target "a" and base = base_with_counter (Z.of_int 7) in
  let found = ref 0 in
  for j = 0 to 300 do
    let seed = Seed_keys.seed_of_offset ~base (Int64.of_int j) in
    match Seed_keys.confirm t ~base (Int64.of_int j) with
    | Some (address, secret) ->
        incr found ;
        Alcotest.(check string) "secret is the seed" seed secret ;
        Alcotest.(check bool) "matches" true (Target.matches t address) ;
        (match Mirage_crypto_ec.Ed25519.priv_of_octets seed with
        | Error _ -> Alcotest.fail "seed refused"
        | Ok priv ->
            let pk = Mirage_crypto_ec.Ed25519.(pub_to_octets (pub_of_priv priv)) in
            Alcotest.(check (result string string)) "address of the public key" (Ok address)
              (Address.address Address.Tz1 pk))
    | None -> ()
  done ;
  if !found < 1 || !found > 60 then Alcotest.failf "implausible number of matches: %d" !found

let hex_file content =
  let path = Filename.temp_file "tz1base" ".key" in
  Out_channel.with_open_bin path (fun oc -> output_string oc content) ;
  Unix.chmod path 0o600 ;
  path

let base_file () =
  let ok s = match Key_files.parse_seed_base s with Ok b -> b | Error e -> Alcotest.fail e in
  Alcotest.(check string) "all zero accepted" (String.make 32 '\x00') (ok (String.make 64 '0')) ;
  Alcotest.(check string) "all ones accepted" (String.make 32 '\xff') (ok (String.make 64 'F' ^ "\n")) ;
  Alcotest.(check string) "bytes in order" ("\x01\x23" ^ String.make 30 '\x00') (ok ("0123" ^ String.make 60 '0')) ;
  List.iter
    (fun s -> Alcotest.(check bool) ("refused " ^ s) true (Result.is_error (Key_files.parse_seed_base s)))
    [""; "zz"; String.make 63 '0'; String.make 65 '0'; String.make 63 '0' ^ "g"] ;
  let path = Filename.temp_file "tz1base" ".key" in
  Sys.remove path ;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let created = match Key_files.load_or_create_seed_base path with Ok b -> b | Error e -> Alcotest.fail e in
      Alcotest.(check int) "mode 0600" 0o600 ((Unix.stat path).Unix.st_perm land 0o7777) ;
      Alcotest.(check int) "file length" 65 (Unix.stat path).Unix.st_size ;
      (match Key_files.load_or_create_seed_base path with
      | Ok again -> Alcotest.(check string) "reused" created again
      | Error e -> Alcotest.fail e) ;
      Unix.chmod path 0o644 ;
      Alcotest.(check bool) "wide mode refused" true (Result.is_error (Key_files.load_or_create_seed_base path)))

let table_entries () =
  (* digit 0 is the neutral element (1, 1, 0) and digit 1 of window 0 is the base point *)
  let spec = List.find (fun s -> s.Field_run.name = "ed25519") Field_run.specs in
  let table = Seed_table.build ~window_bits:Seed_table.window_bits in
  let element e =
    let limbs = Array.init 10 (fun j -> Spoc_core.Vector.get table ((e * 10) + j)) in
    Field_run.of_mont spec (Array.fold_right (fun l acc -> Z.logor (Z.shift_left acc 28) (Z.of_int64 l)) limbs Z.zero)
  in
  Alcotest.(check bool) "neutral y+x" true (Z.equal Z.one (element 0)) ;
  Alcotest.(check bool) "neutral y-x" true (Z.equal Z.one (element 1)) ;
  Alcotest.(check bool) "neutral 2dxy" true (Z.equal Z.zero (element 2)) ;
  let x, y = Curve_ref.ed25519_base in
  let p = Curve_ref.ed25519_prime in
  Alcotest.(check bool) "base y+x" true (Z.equal (Z.erem (Z.add y x) p) (element (3 * 1))) ;
  Alcotest.(check bool) "base y-x" true (Z.equal (Z.erem (Z.sub y x) p) (element ((3 * 1) + 1)))

let tests =
  ( "address_tz1",
    [
      Alcotest.test_case "seed of an offset: carry, wrap at 2^64" `Quick carry_and_wrap;
      Alcotest.test_case "prefix words and counter" `Quick words;
      Alcotest.test_case "random base" `Quick random_base;
      Alcotest.test_case "confirm finds matches" `Quick confirm;
      Alcotest.test_case "base-key file" `Quick base_file;
      Alcotest.test_case "table entries" `Quick table_entries;
    ] )
