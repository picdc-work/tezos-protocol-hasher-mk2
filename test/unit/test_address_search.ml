(* Pieces of the address search that need no device: offset-to-key
   arithmetic, host confirmation, key files, base-key files, offset space. *)

open Octez_vanity

let curve = Curve_ref.secp256k1

let n = curve.Curve_ref.n

(* Throwaway scalars, not keys anyone uses. *)
let k0 = Z.of_string_base 16 "1d9c5f0b7a3e48126c0f6e9ab2d4713ef05a8c64b91e2d37a6f4c8105be39d27"

let kind = Address.target_kind Address.Tz2

let target name = match Target.make ~kind name with Ok t -> t | Error e -> Alcotest.fail e

let z = Alcotest.testable Z.pp_print Z.equal

(* --- offsets and keys --- *)

let key_arithmetic () =
  let key ~k0 j = Walk_keys.key_of_offset curve ~k0 j in
  Alcotest.check z "no wrap" (Z.add k0 (Z.of_int 5)) (key ~k0 5L) ;
  Alcotest.check z "wrap to 0" Z.zero (key ~k0:(Z.pred n) 1L) ;
  Alcotest.check z "wrap to 1" Z.one (key ~k0:(Z.pred n) 2L) ;
  Alcotest.check z "wrap, k0 = n-3" (Z.of_int 2) (key ~k0:(Z.sub n (Z.of_int 3)) 5L) ;
  (* an offset with the top bit set is read unsigned *)
  Alcotest.check z "unsigned 2^64-1"
    (Z.erem (Z.add k0 (Z.pred (Z.shift_left Z.one 64))) n)
    (key ~k0 (-1L)) ;
  Alcotest.check z "unsigned 2^63"
    (Z.erem (Z.add k0 (Z.shift_left Z.one 63)) n)
    (key ~k0 Int64.min_int)

let offset_matches_point =
  QCheck.Test.make ~count:20 ~name:"key of offset j has the point P0 + j G"
    QCheck.(int_bound 1_000_000)
    (fun j ->
      let g = Curve_ref.generator curve in
      let p0 = Curve_ref.scalar_mul curve k0 g in
      let walked = Curve_ref.add_points curve p0 (Curve_ref.scalar_mul curve (Z.of_int j) g) in
      let key = Walk_keys.key_of_offset curve ~k0 (Int64.of_int j) in
      Curve_ref.scalar_mul curve key g = walked)

let scalar_bytes () =
  List.iter
    (fun k ->
      let bytes = Walk_keys.scalar_to_bytes k in
      Alcotest.(check int) "32 bytes" 32 (String.length bytes) ;
      Alcotest.check z "roundtrip" k (Walk_keys.scalar_of_bytes bytes))
    [Z.one; k0; Z.pred n; Z.of_int 256]

let random_scalar_range () =
  for _ = 1 to 50 do
    let k = Walk_keys.random_scalar curve in
    if Z.sign k <= 0 || Z.geq k n then Alcotest.fail "scalar out of [1, n-1]"
  done ;
  if Z.equal (Walk_keys.random_scalar curve) (Walk_keys.random_scalar curve) then
    Alcotest.fail "two draws are equal"

let confirm_finds_matches () =
  let t = target "a" in
  let found = ref 0 in
  for j = 0 to 2000 do
    match Walk_keys.confirm Address.Tz2 curve t ~k0 (Int64.of_int j) with
    | Some (address, secret) ->
        incr found ;
        Alcotest.(check bool) "target matches" true (Target.matches t address) ;
        Alcotest.check z "secret is the key of the offset"
          (Walk_keys.key_of_offset curve ~k0 (Int64.of_int j))
          (Walk_keys.scalar_of_bytes secret) ;
        Alcotest.(check (result string string)) "address of the secret" (Ok address)
          (Curve_ref.address Address.Tz2 secret)
    | None -> ()
  done ;
  if !found < 10 || !found > 500 then Alcotest.failf "implausible number of matches: %d" !found

let confirm_skips_zero_key () =
  (* k0 = n - 1: offset 1 is the key 0, which has no address *)
  let t = target "a" in
  Alcotest.(check bool) "key 0 skipped" true
    (Walk_keys.confirm Address.Tz2 curve t ~k0:(Z.pred n) 1L = None)

(* --- key files --- *)

let temp_dir () = Filename.temp_dir "key_files" ""

let rm_rf dir =
  Array.iter (fun f -> Sys.remove (Filename.concat dir f)) (Sys.readdir dir) ;
  Unix.rmdir dir

let with_dir f =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let mode path = (Unix.stat path).Unix.st_perm

let read path = In_channel.with_open_bin path In_channel.input_all

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let secret = Walk_keys.scalar_to_bytes k0

let encoded = match Address.secret_key Address.Tz2 secret with Ok e -> e | Error e -> failwith e

let write_key () =
  with_dir (fun dir ->
      match Key_files.write_key ~dir ~address:"tz2Test" Address.Tz2 ~secret with
      | Error e -> Alcotest.fail e
      | Ok (Key_files.Existing _) -> Alcotest.fail "reported an existing file in an empty directory"
      | Ok (Key_files.New path) -> (
          Alcotest.(check string) "path" (Filename.concat dir "tz2Test.key") path ;
          Alcotest.(check int) "mode 0600" 0o600 (mode path) ;
          Alcotest.(check string) "one line" (encoded ^ "\n") (read path) ;
          Alcotest.(check bool) "spsk" true (String.sub encoded 0 4 = "spsk") ;
          (* the same key again: reported as existing, file untouched *)
          match Key_files.write_key ~dir ~address:"tz2Test" Address.Tz2 ~secret with
          | Ok (Key_files.Existing again) ->
              Alcotest.(check string) "same path" path again ;
              Alcotest.(check string) "unchanged" (encoded ^ "\n") (read path)
          | Ok (Key_files.New _) -> Alcotest.fail "wrote the same key file twice"
          | Error e -> Alcotest.fail e))

let write_key_umask () =
  let old = Unix.umask 0 in
  Fun.protect ~finally:(fun () -> ignore (Unix.umask old)) (fun () ->
      with_dir (fun dir ->
          match Key_files.write_key ~dir ~address:"tz2Test" Address.Tz2 ~secret with
          | Error e -> Alcotest.fail e
          | Ok (Key_files.Existing _) -> Alcotest.fail "unexpected existing file"
          | Ok (Key_files.New path) ->
              Alcotest.(check int) "mode 0600 under umask 0" 0o600 (mode path)))

let no_overwrite () =
  with_dir (fun dir ->
      let path = Filename.concat dir "tz2Test.key" in
      Out_channel.with_open_bin path (fun oc -> output_string oc "precious\n") ;
      (match Key_files.write_key ~dir ~address:"tz2Test" Address.Tz2 ~secret with
      | Ok _ -> Alcotest.fail "overwrote an existing key file"
      | Error e ->
          Alcotest.(check bool) "names the path" true (contains ~sub:"tz2Test.key" e) ;
          Alcotest.(check bool) "no secret in the message" false (contains ~sub:encoded e)) ;
      Alcotest.(check string) "untouched" "precious\n" (read path) ;
      (* twice in a row: the second write fails, the first file stays *)
      match Key_files.write_key ~dir ~address:"tz2Other" Address.Tz2 ~secret with
      | Error e -> Alcotest.fail e
      | Ok (Key_files.Existing _) -> Alcotest.fail "unexpected existing file"
      | Ok (Key_files.New first) -> (
          match Key_files.write_key ~dir ~address:"tz2Other" Address.Tz2 ~secret:(String.make 32 '\001') with
          | Ok _ -> Alcotest.fail "second write succeeded"
          | Error _ -> Alcotest.(check string) "first kept" (encoded ^ "\n") (read first)))

let write_key_missing_dir () =
  match Key_files.write_key ~dir:"/nonexistent-dir-xyz" ~address:"tz2Test" Address.Tz2 ~secret with
  | Ok _ -> Alcotest.fail "wrote into a missing directory"
  | Error e -> Alcotest.(check bool) "no secret" false (contains ~sub:encoded e)

(* --- base-key files --- *)

let hex64 k = Z.format "%064x" k

let parse_base_key () =
  let ok s = match Key_files.parse_base_key curve s with Ok k -> k | Error e -> Alcotest.fail e in
  let bad name s =
    match Key_files.parse_base_key curve s with
    | Ok _ -> Alcotest.failf "accepted %s" name
    | Error e -> Alcotest.(check bool) (name ^ ": no secret in message") false (contains ~sub:s e && s <> "")
  in
  Alcotest.check z "plain" k0 (ok (hex64 k0)) ;
  Alcotest.check z "newline" k0 (ok (hex64 k0 ^ "\n")) ;
  Alcotest.check z "upper case" k0 (ok (String.uppercase_ascii (hex64 k0))) ;
  Alcotest.check z "one" Z.one (ok (hex64 Z.one)) ;
  Alcotest.check z "n-1" (Z.pred n) (ok (hex64 (Z.pred n))) ;
  bad "zero" (hex64 Z.zero) ;
  bad "n" (hex64 n) ;
  bad "63 characters" (String.sub (hex64 k0) 1 63) ;
  bad "65 characters" (hex64 k0 ^ "0") ;
  bad "not hex" (String.make 63 'a' ^ "g") ;
  bad "empty" "" ;
  bad "two lines" (hex64 k0 ^ "\n" ^ hex64 k0)

let base_mode () =
  let ok m = Alcotest.(check bool) (Printf.sprintf "%04o accepted" m) true (Key_files.check_base_mode m = Ok ()) in
  let bad m =
    Alcotest.(check bool) (Printf.sprintf "%04o refused" m) true
      (Result.is_error (Key_files.check_base_mode m))
  in
  List.iter ok [0o600; 0o400; 0o200; 0o000] ;
  List.iter bad [0o644; 0o640; 0o604; 0o700; 0o660; 0o666; 0o1600; 0o4600]

let load_or_create () =
  with_dir (fun dir ->
      let path = Filename.concat dir "base.key" in
      let k = match Key_files.load_or_create_base curve path with Ok k -> k | Error e -> Alcotest.fail e in
      Alcotest.(check int) "created with mode 0600" 0o600 (mode path) ;
      Alcotest.(check string) "64 hex characters and a newline" (hex64 k ^ "\n") (read path) ;
      Alcotest.(check bool) "in range" true (Z.sign k > 0 && Z.lt k n) ;
      (match Key_files.load_or_create_base curve path with
      | Ok k' -> Alcotest.check z "reused" k k'
      | Error e -> Alcotest.fail e) ;
      Unix.chmod path 0o644 ;
      (match Key_files.load_or_create_base curve path with
      | Ok _ -> Alcotest.fail "accepted a file of mode 0644"
      | Error e ->
          Alcotest.(check bool) "message names the mode" true (contains ~sub:"0644" e) ;
          Alcotest.(check bool) "no secret in message" false (contains ~sub:(hex64 k) e)) ;
      Unix.chmod path 0o400 ;
      (match Key_files.load_or_create_base curve path with
      | Ok k' -> Alcotest.check z "read-only file accepted" k k'
      | Error e -> Alcotest.fail e) ;
      let garbage = Filename.concat dir "garbage.key" in
      Out_channel.with_open_bin garbage (fun oc -> output_string oc "not a key\n") ;
      Unix.chmod garbage 0o600 ;
      Alcotest.(check bool) "garbage refused" true
        (Result.is_error (Key_files.load_or_create_base curve garbage)) ;
      Alcotest.(check bool) "directory refused" true
        (Result.is_error (Key_files.load_or_create_base curve dir)))

(* --- offset space --- *)

let offset_space () =
  Alcotest.(check int) "2^44 chunks" (1 lsl 44) Offset_space.n_chunks ;
  Alcotest.(check int) "2^20 per chunk" 1048576 Offset_space.chunk_size ;
  let r = {Offset_space.first_chunk = Offset_space.n_chunks - 2; count = 5} in
  Alcotest.(check (list int)) "wrap"
    [Offset_space.n_chunks - 2; Offset_space.n_chunks - 1; 0; 1; 2]
    (List.init 5 (Offset_space.nth_chunk r)) ;
  Alcotest.(check int64) "last offset" (-1L)
    (Offset_space.offset ~chunk:(Offset_space.n_chunks - 1) ~index:(Offset_space.chunk_size - 1)) ;
  Alcotest.(check int64) "chunk 3 index 5" 3145733L (Offset_space.offset ~chunk:3 ~index:5)

let slices_partition =
  QCheck.Test.make ~count:200 ~name:"offset slices are disjoint and cover the range"
    QCheck.(triple (int_bound (Offset_space.n_chunks - 1)) (int_range 1 3000) (int_range 1 40))
    (fun (first_chunk, count, parts) ->
      let r = {Offset_space.first_chunk; count} in
      let chunks r = List.init r.Offset_space.count (Offset_space.nth_chunk r) in
      List.concat_map
        (fun i -> chunks (Offset_space.slice r ~instance:i ~of_:parts))
        (List.init parts Fun.id)
      = chunks r)

let tests =
  ( "address_search",
    [
      Alcotest.test_case "key arithmetic" `Quick key_arithmetic;
      QCheck_alcotest.to_alcotest offset_matches_point;
      Alcotest.test_case "scalar bytes" `Quick scalar_bytes;
      Alcotest.test_case "random scalar range" `Quick random_scalar_range;
      Alcotest.test_case "confirm finds matches" `Quick confirm_finds_matches;
      Alcotest.test_case "confirm skips key 0" `Quick confirm_skips_zero_key;
      Alcotest.test_case "key file" `Quick write_key;
      Alcotest.test_case "key file under umask 0" `Quick write_key_umask;
      Alcotest.test_case "key file never overwritten" `Quick no_overwrite;
      Alcotest.test_case "key file in a missing directory" `Quick write_key_missing_dir;
      Alcotest.test_case "parse base key" `Quick parse_base_key;
      Alcotest.test_case "base key mode" `Quick base_mode;
      Alcotest.test_case "load or create base key" `Quick load_or_create;
      Alcotest.test_case "offset space" `Quick offset_space;
      QCheck_alcotest.to_alcotest slices_partition;
    ] )
