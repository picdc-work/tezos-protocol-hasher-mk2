open Octez_vanity

let mkdump args =
  let out = Filename.temp_file "dump" ".txt" in
  let cmd = Printf.sprintf "../support/mkdump.exe %s %s" args (Filename.quote out) in
  if Sys.command cmd <> 0 then Alcotest.fail ("mkdump failed: " ^ cmd) ;
  out

let write contents =
  let out = Filename.temp_file "dump" ".txt" in
  let oc = open_out_bin out in
  output_string oc contents ;
  close_out oc ;
  out

let mkdump_hash path nonce =
  let ic =
    Unix.open_process_in
      (Printf.sprintf "../support/mkdump.exe --hash %s %s" (Filename.quote path) nonce)
  in
  let l = input_line ic in
  ignore (Unix.close_process_in ic) ;
  l

let padding = String.make 2000 'x'

let rejected name contents fragment () =
  match Dump.load (write contents) with
  | Ok _ -> Alcotest.failf "%s: accepted" name
  | Error e ->
      if not (Astring_like.contains e fragment) then
        Alcotest.failf "%s: message %S does not mention %S" name e fragment

let errors =
  [
    ("empty", "", "(* Vanity nonce: <16 digits> *)");
    ("newline only", "\n", "(* Vanity nonce: <16 digits> *)");
    ("TBD", padding ^ "(* Vanity nonce: TBD *)\n", "(* Vanity nonce: <16 digits> *)");
    ("no newline", padding ^ "(* Vanity nonce: 0000000000000000 *)", "(* Vanity nonce: <16 digits> *)");
    ("letters", padding ^ "(* Vanity nonce: 00000000000a0000 *)\n", "(* Vanity nonce: <16 digits> *)");
    ("bad marker", padding ^ "(* Vanity nonse: 0000000000000000 *)\n", "(* Vanity nonce: <16 digits> *)");
  ]

let unreadable () =
  match Dump.load "/nonexistent/proto_to_hash.txt" with
  | Ok _ -> Alcotest.fail "accepted"
  | Error e -> if not (Astring_like.contains e "/nonexistent") then Alcotest.fail e

let layout () =
  for f = 1 to 128 do
    match Dump.load (mkdump (Printf.sprintf "%d 7" f)) with
    | Error e -> Alcotest.fail e
    | Ok d ->
        Alcotest.(check int) "F" f d.Dump.final_block_length ;
        let expected = if f >= 20 then Dump.A else if f >= 6 then Dump.B else Dump.C in
        if d.layout_case <> expected then Alcotest.failf "wrong case for F=%d" f
  done

let sizes () =
  List.iter
    (fun len ->
      let path = mkdump (Printf.sprintf "--size %d 3" len) in
      match Dump.load path with
      | Error e -> Alcotest.fail e
      | Ok d ->
          Alcotest.(check int) "length" len d.length ;
          Alcotest.(check string)
            (Printf.sprintf "hash of %d-byte dump" len)
            (mkdump_hash path "0000000000000000")
            (Protocol_hash.of_digest (Dump.digest d 0L)))
    [1024; 10_485_760]

let tests =
  ( "dump",
    List.map (fun (n, c, f) -> Alcotest.test_case n `Quick (rejected n c f)) errors
    @ [
        Alcotest.test_case "unreadable" `Quick unreadable;
        Alcotest.test_case "layout cases" `Quick layout;
        Alcotest.test_case "size limits" `Quick sizes;
      ] )
