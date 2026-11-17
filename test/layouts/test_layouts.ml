(* Every final-block length 1..128: the host mid-state path agrees with
   digestif over the full dump (layout cases A, B and C). *)
open Octez_vanity

module B2 = Digestif.Make_BLAKE2B (struct
  let digest_size = 32
end)

let synthetic f =
  let line = "(* Vanity nonce: 0000000000000000 *)\n" in
  let st = Random.State.make [|f|] in
  let body = 1024 + f - String.length line in
  String.init body (fun _ -> Char.chr (32 + Random.State.int st 90)) ^ line

let check_f f () =
  let path = Filename.temp_file "layout" ".dump" in
  let oc = open_out_bin path in
  output_string oc (synthetic f) ;
  close_out oc ;
  match Dump.load path with
  | Error e -> Alcotest.fail e
  | Ok d ->
      let st = Random.State.make [|f; 1|] in
      for _ = 1 to 20 do
        let n = Random.State.int64 st 10_000_000_000_000_000L in
        let b = Bytes.copy d.Dump.data in
        Bytes.blit_string (Nonce_space.text n) 0 b d.digits_offset 16 ;
        let expected = B2.(to_raw_string (digest_bytes b)) in
        if Dump.digest d n <> expected then Alcotest.failf "F=%d nonce %Ld" f n ;
        if Dump.digest_full d n <> expected then Alcotest.failf "full F=%d" f
      done ;
      let case = if f >= 20 then Dump.A else if f >= 6 then Dump.B else Dump.C in
      if d.layout_case <> case then Alcotest.failf "case F=%d" f

let () =
  Alcotest.run "layouts"
    [("final block length", List.init 128 (fun i -> Alcotest.test_case (string_of_int (i + 1)) `Quick (check_f (i + 1))))]
