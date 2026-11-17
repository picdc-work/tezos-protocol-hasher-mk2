open Octez_vanity

let vectors = "../vectors/c_hasher_pairs.txt"

let hash_of path nonce =
  match Dump.load path with
  | Error e -> Alcotest.fail e
  | Ok d -> Protocol_hash.of_digest (Dump.digest d (Int64.of_string nonce))

let c_pairs () =
  List.iter
    (fun (dump, nonce, expected) ->
      if Sys.file_exists dump then
        Alcotest.(check string) (Filename.basename dump ^ " " ^ nonce) expected (hash_of dump nonce))
    (Fixtures.c_hasher_pairs vectors) ;
  Fixtures.skip_unless_exists (Fixtures.ref_dir ())

let released (name, nonce, expected) () =
  let dump = Fixtures.protocol_dump name in
  let h = hash_of dump nonce in
  Alcotest.(check string) name expected h ;
  Alcotest.(check int) "length" 51 (String.length h) ;
  Alcotest.(check char) "first" 'P' h.[0]

let tests =
  ( "protocol_hash",
    Alcotest.test_case "C hasher pairs" `Quick c_pairs
    :: List.map
         (fun ((name, _, _) as r) -> Alcotest.test_case name `Slow (released r))
         Fixtures.released )
