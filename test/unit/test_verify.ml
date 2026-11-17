open Octez_vanity

let hash path nonce =
  match Dump.load path with
  | Error e -> Alcotest.fail e
  | Ok d -> (
      match Verify.hash d nonce with Ok h -> h | Error e -> Alcotest.fail e)

let c_pairs () =
  Fixtures.skip_unless_exists (Fixtures.ref_dir ()) ;
  List.iter
    (fun (dump, nonce, expected) ->
      if Sys.file_exists dump then Alcotest.(check string) nonce expected (hash dump nonce))
    (Fixtures.c_hasher_pairs "../vectors/c_hasher_pairs.txt")

let released (name, nonce, expected) () =
  Alcotest.(check string) name expected (hash (Fixtures.protocol_dump name) nonce)

let bad_nonce () =
  match Dump.load (Filename.concat (Fixtures.ref_dir ()) "proto_to_hash.txt") with
  | Error _ -> Alcotest.skip ()
  | Ok d ->
      List.iter
        (fun n ->
          match Verify.hash d n with
          | Ok _ -> Alcotest.failf "accepted %S" n
          | Error _ -> ())
        ["12345"; "01234567890123x5"; "01234567890123456"]

let tests =
  ( "verify",
    [Alcotest.test_case "C hasher pairs" `Quick c_pairs; Alcotest.test_case "bad nonces" `Quick bad_nonce]
    @ List.map (fun ((n, _, _) as r) -> Alcotest.test_case n `Slow (released r)) Fixtures.released )
