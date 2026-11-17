open Octez_vanity

let ok ?case_mode n =
  match Target.make ?case_mode n with Ok t -> t | Error e -> Alcotest.fail e

let rejects ?case_mode name fragment () =
  match Target.make ?case_mode name with
  | Ok _ -> Alcotest.failf "%S accepted" name
  | Error e ->
      if not (Astring_like.contains e fragment) then
        Alcotest.failf "message %S does not mention %S" e fragment

let lengths () =
  ignore (ok "p") ;
  ignore (ok "abcdefghi") ;
  rejects "" "1 to 9" () ;
  rejects "abcdefghij" "1 to 9" ()

let intervals_shape () =
  List.iter
    (fun (case_mode, n) ->
      let t = ok ~case_mode n in
      let iv = Target.intervals t in
      if Array.length iv = 0 then Alcotest.failf "no interval for %s" n ;
      Array.iteri
        (fun i (lo, hi) ->
          if lo > hi then Alcotest.fail "lo > hi" ;
          if lo < 0L || hi < 0L then Alcotest.fail "top64 >= 2^63" ;
          if i > 0 && lo <= snd iv.(i - 1) then Alcotest.fail "not sorted/disjoint")
        iv)
    [(Target.Insensitive, "pa"); (Sensitive, "Pa"); (Insensitive, "ushuaia"); (Sensitive, "zzzzzzzzz")]

(* Random digests: any exact match must pass the prefilter. *)
let superset case_mode name () =
  let t = ok ~case_mode name in
  let st = Random.State.make [|42|] in
  let matches = ref 0 and tries = ref 0 in
  while !matches < 200 do
    incr tries ;
    let d = String.init 32 (fun _ -> Char.chr (Random.State.int st 256)) in
    if Target.matches t (Protocol_hash.of_digest d) then begin
      incr matches ;
      if not (Target.in_intervals t (Target.top64 d)) then
        Alcotest.failf "match outside intervals for %s" name
    end
  done

let rate () =
  let t = ok "pa" in
  let st = Random.State.make [|7|] in
  let n = 1_000_000 and hits = ref 0 in
  for _ = 1 to n do
    let d = String.init 32 (fun _ -> Char.chr (Random.State.int st 256)) in
    if Target.in_intervals t (Target.top64 d) then incr hits
  done ;
  let observed = float n /. float !hits in
  let expected = Target.expected_rate t in
  if abs_float (observed -. expected) /. expected > 0.2 then
    Alcotest.failf "expected_rate %.1f vs observed %.1f" expected observed

let lowercased () =
  let t = ok "PaRiS" in
  Alcotest.(check string) "name" "paris" (Target.name t)

let tests =
  ( "target",
    [
      Alcotest.test_case "lengths" `Quick lengths;
      Alcotest.test_case "invalid char 0" `Quick (rejects "paris0" "'0'");
      Alcotest.test_case "valid set in message" `Quick (rejects "paris0" "1-9, A-H, J-N, P-Z, a-k, m-z");
      Alcotest.test_case "sensitive I" `Quick (rejects ~case_mode:Target.Sensitive "Ib" "'I'");
      Alcotest.test_case "sensitive O" `Quick (rejects ~case_mode:Target.Sensitive "aO" "'O'");
      Alcotest.test_case "sensitive l" `Quick (rejects ~case_mode:Target.Sensitive "al" "'l'");
      Alcotest.test_case "insensitive lowercases" `Quick lowercased;
      Alcotest.test_case "intervals shape" `Quick intervals_shape;
      Alcotest.test_case "superset p (insensitive)" `Quick (superset Target.Insensitive "p");
      Alcotest.test_case "superset pa (insensitive)" `Quick (superset Target.Insensitive "pa");
      Alcotest.test_case "superset Pa (sensitive)" `Quick (superset Target.Sensitive "Pa");
      Alcotest.test_case "superset z (sensitive)" `Quick (superset Target.Sensitive "z");
      Alcotest.test_case "expected rate" `Quick rate;
    ] )
