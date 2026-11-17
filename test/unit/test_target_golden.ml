(* FR-006 / AC-4: protocol-hash targets behave exactly as on main. The golden
   file was generated from the unmodified code (see its header); it is never
   regenerated here. *)

let read_golden () =
  let ic = open_in_bin (Fixtures.vector_path "target_protocol_golden.txt") in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic ;
  (* drop the header: the leading lines starting with '#' *)
  let rec skip pos =
    if pos < String.length content && content.[pos] = '#' then
      match String.index_from_opt content pos '\n' with
      | Some nl -> skip (nl + 1)
      | None -> String.length content
    else pos
  in
  let start = skip 0 in
  String.sub content start (String.length content - start)

let same_as_main () =
  Alcotest.(check string) "rendering equals the golden file" (read_golden ())
    (Target_golden.render ())

let tests =
  ("target_golden", [Alcotest.test_case "protocol-hash targets as on main" `Quick same_as_main])
