(* US-2 for address kinds: superset of the prefilter, rate, errors, window. *)

open Octez_vanity

let alphabet = Base58.alphabet

let kind = Address.target_kind

let ok = function Ok t -> t | Error e -> Alcotest.fail e

let error = function Ok _ -> Alcotest.fail "expected Error" | Error e -> e

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let random_digest rng = String.init 20 (fun _ -> Char.chr (Random.State.int rng 256))

let address_of scheme d = Address.address_of_digest scheme d

(* The window, computed from the encodings of the all-zero and all-ones
   digests: the alphabet values between the characters at position 3. *)
let expected_window scheme =
  let at byte = (address_of scheme (String.make 20 byte)).[3] in
  let lo = String.index alphabet (at '\x00') and hi = String.index alphabet (at '\xff') in
  String.sub alphabet lo (hi - lo + 1)

let windows = List.map (fun s -> (s, Target.first_chars (kind s))) Address.schemes

let window_name (s, _) = "window " ^ Address.name s

(* Printed at registration, so that the lines are visible in the output even
   though Alcotest captures what the tests print. *)
let () =
  List.iter
    (fun (s, w) ->
      Printf.printf "window %s: %s (%d characters)\n%!" (Address.name s) w (String.length w))
    windows

let window (scheme, computed) () =
  Alcotest.(check string) "computed = from all-zero and all-ones addresses"
    (expected_window scheme) computed ;
  Alcotest.(check int) "24 values" 24 (String.length computed)

(* FR-007: every digest whose address matches has its top64 in the intervals. *)
let superset scheme name case_mode wanted () =
  let t = ok (Target.make ~kind:(kind scheme) ~case_mode name) in
  let rng = Random.State.make [|2026; 11; 17|] in
  let found = ref 0 and draws = ref 0 in
  while !found < wanted do
    incr draws ;
    let d = random_digest rng in
    if Target.matches t (address_of scheme d) then begin
      incr found ;
      if not (Target.in_intervals t (Target.top64_of (kind scheme) d)) then
        Alcotest.failf "%s %S: matching digest outside the intervals" (Address.name scheme) name
    end
  done

(* FR-007, EC-7: an 8-character name; a matching and a non-matching digest of
   the same top64 bucket both pass the prefilter, [matches] rejects one. *)
let same_bucket () =
  let scheme = Address.Tz1 in
  let k = kind scheme in
  let t = ok (Target.make ~kind:k ~case_mode:Target.Sensitive "abcdefgh") in
  let rng = Random.State.make [|8|] in
  let bucket_digest top =
    let head = String.init 5 (fun i -> Char.chr (Int64.to_int (Int64.shift_right_logical top (8 * (4 - i))) land 255)) in
    head ^ String.sub (random_digest rng) 0 15
  in
  let intervals = Target.intervals t in
  Alcotest.(check bool) "has intervals" true (Array.length intervals > 0) ;
  let top = fst intervals.(0) in
  let hit = ref None and miss = ref None and tries = ref 0 in
  while (!hit = None || !miss = None) && !tries < 2_000_000 do
    incr tries ;
    let d = bucket_digest top in
    if Target.matches t (address_of scheme d) then (if !hit = None then hit := Some d)
    else if !miss = None then miss := Some d
  done ;
  match (!hit, !miss) with
  | Some h, Some m ->
      Alcotest.(check bool) "same bucket" true
        (Target.top64_of k h = Target.top64_of k m) ;
      Alcotest.(check bool) "matching digest passes the prefilter" true
        (Target.in_intervals t (Target.top64_of k h)) ;
      Alcotest.(check bool) "non-matching digest passes the prefilter" true
        (Target.in_intervals t (Target.top64_of k m)) ;
      Alcotest.(check bool) "matches rejects the second" false (Target.matches t (address_of scheme m))
  | _ -> Alcotest.fail "no matching digest found in the bucket"

(* AC-5: measured prefilter rate within 20 % of 1 / expected_rate. *)
let rate scheme name case_mode () =
  let t = ok (Target.make ~kind:(kind scheme) ~case_mode name) in
  let rng = Random.State.make [|40; 2|] in
  let draws = 2_000_000 and hits = ref 0 in
  for _ = 1 to draws do
    if Target.in_intervals t (Target.top64_of (kind scheme) (random_digest rng)) then incr hits
  done ;
  let measured = float_of_int !hits /. float_of_int draws in
  let expected = 1. /. Target.expected_rate t in
  Printf.printf "%s %S: measured %.3e expected %.3e\n" (Address.name scheme) name measured expected ;
  Alcotest.(check bool) "within 20%" true (abs_float (measured -. expected) <= 0.2 *. expected)

(* FR-008: matches compares from position 3. *)
let matches_rule () =
  let rng = Random.State.make [|3|] in
  List.iter
    (fun (name, mode) ->
      let t = ok (Target.make ~kind:(kind Address.Tz2) ~case_mode:mode name) in
      for _ = 1 to 5000 do
        let a = address_of Address.Tz2 (random_digest rng) in
        let s = String.sub a 3 (String.length name) in
        let expected =
          match mode with Target.Sensitive -> s = name | Insensitive -> String.lowercase_ascii s = String.lowercase_ascii name
        in
        Alcotest.(check bool) "matches" expected (Target.matches t a)
      done)
    [("C", Target.Sensitive); ("c", Target.Insensitive); ("9a", Target.Insensitive)]

(* AC-6, FR-009. *)
let tz1 name = Target.make ~kind:(kind Address.Tz1) name

let error_cases () =
  let window = Target.first_chars (kind Address.Tz1) in
  let e = error (tz1 "j") in
  Alcotest.(check bool) "unreachable first character lists the window" true (contains ~sub:window e) ;
  Alcotest.(check bool) "names the character" true (contains ~sub:"'j'" e) ;
  Alcotest.(check bool) "9 characters" true (contains ~sub:"1 to 8 characters" (error (tz1 "abcdefghi"))) ;
  let e = error (tz1 "paris0") in
  Alcotest.(check bool) "invalid character" true (contains ~sub:"'0'" e && contains ~sub:"cannot appear" e) ;
  Alcotest.(check bool) "scheme prefix" true (contains ~sub:"only the part after tz1" (error (tz1 "tz1abc"))) ;
  Alcotest.(check bool) "scheme prefix in insensitive mode" true
    (contains ~sub:"only the part after tz1" (error (tz1 "Tz1abc"))) ;
  Alcotest.(check bool) "empty name" true (contains ~sub:"1 to 8 characters" (error (tz1 "")))

(* Order: length, characters, scheme prefix, reachability. *)
let error_precedence () =
  Alcotest.(check bool) "length before characters" true
    (contains ~sub:"1 to 8 characters" (error (tz1 "tz1abcde0")));
  let e = error (tz1 "tz1ab0") in
  Alcotest.(check bool) "characters before prefix" true (contains ~sub:"cannot appear" e) ;
  Alcotest.(check bool) "prefix before reachability" true
    (contains ~sub:"only the part after tz1" (error (tz1 "tz1abc")))

(* EC-4, EC-5, EC-6. *)
let edges () =
  let tz4 = kind Address.Tz4 in
  let max_name scheme =
    String.sub (address_of scheme (String.make 20 '\xff')) 3 8
  in
  let min_name scheme = String.sub (address_of scheme (String.make 20 '\x00')) 3 8 in
  ignore (ok (tz1 "K")) ;
  Alcotest.(check bool) "tz4: smallest address name is searchable" true
    (Result.is_ok (Target.make ~kind:tz4 ~case_mode:Target.Sensitive (min_name Address.Tz4))) ;
  Alcotest.(check bool) "tz4: largest address name is searchable" true
    (Result.is_ok (Target.make ~kind:tz4 ~case_mode:Target.Sensitive (max_name Address.Tz4))) ;
  Alcotest.(check bool) "tz4: beyond the maximum encoding" true
    (Result.is_error (Target.make ~kind:tz4 ~case_mode:Target.Sensitive "Yzzzzzzz")) ;
  Alcotest.(check bool) "tz1: below the minimum encoding" true
    (Result.is_error
       (Target.make ~kind:(kind Address.Tz1) ~case_mode:Target.Sensitive
          (String.make 1 (min_name Address.Tz1).[0] ^ "1111111")))

let case_insensitive_edge () =
  let k = kind Address.Tz1 in
  let both = ok (Target.make ~kind:k ~case_mode:Target.Insensitive "a") in
  let lower = ok (Target.make ~kind:k ~case_mode:Target.Sensitive "a") in
  Alcotest.(check bool) "A is outside the window" true (not (String.contains (Target.first_chars k) 'A')) ;
  Alcotest.(check bool) "a is inside" true (String.contains (Target.first_chars k) 'a') ;
  Alcotest.(check bool) "intervals for a only" true (Target.intervals both = Target.intervals lower)

let tests =
  ( "target_address",
    List.map (fun w -> Alcotest.test_case (window_name w) `Quick (window w)) windows
    @ [
        Alcotest.test_case "superset, tz2 name C, 200 matches" `Quick
          (superset Address.Tz2 "C" Target.Sensitive 200);
        Alcotest.test_case "superset, tz2 name 9a (insensitive), 200 matches" `Slow
          (superset Address.Tz2 "9a" Target.Insensitive 200);
        Alcotest.test_case "same bucket, 8-character name" `Slow same_bucket;
        Alcotest.test_case "rate, tz2 name C, 2000000 draws" `Slow (rate Address.Tz2 "C" Target.Sensitive);
        Alcotest.test_case "rate, tz2 name 9a, 2000000 draws" `Slow (rate Address.Tz2 "9a" Target.Insensitive);
        Alcotest.test_case "matches from position 3" `Quick matches_rule;
        Alcotest.test_case "error case: j, 9 characters, paris0, tz1abc" `Quick error_cases;
        Alcotest.test_case "error case: precedence" `Quick error_precedence;
        Alcotest.test_case "edge names" `Quick edges;
        Alcotest.test_case "case-insensitive edge" `Quick case_insensitive_edge;
      ] )
