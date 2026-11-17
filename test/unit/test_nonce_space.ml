open Octez_vanity

let text () =
  Alcotest.(check string) "zero" "0000000000000000" (Nonce_space.text 0L) ;
  Alcotest.(check string) "max" "9999999999999999" (Nonce_space.text 9999999999999999L) ;
  Alcotest.(check string) "mid" "0822971470637657" (Nonce_space.text 822971470637657L)

let gen_nonce = QCheck.map Int64.abs QCheck.int64 |> QCheck.map (fun x -> Int64.rem x 10_000_000_000_000_000L)

let roundtrip =
  QCheck.Test.make ~count:1000 ~name:"chunk/thread/loop roundtrip" gen_nonce (fun n ->
      let c = Nonce_space.chunk n and t = Nonce_space.thread n and l = Nonce_space.loop n in
      c = Int64.to_int (Int64.div n 100_000_000L)
      && t = Int64.to_int (Int64.rem (Int64.div n 100L) 1_000_000L)
      && l = Int64.to_int (Int64.rem n 100L)
      && Nonce_space.make ~chunk:c ~thread:t ~loop:l = n
      && String.length (Nonce_space.text n) = 16)

let seed () =
  for s = 0 to 1000 do
    let c = Nonce_space.start_of_seed s in
    if c < 0 || c >= Nonce_space.n_chunks then Alcotest.fail "out of range" ;
    if c <> Nonce_space.start_of_seed s then Alcotest.fail "not deterministic"
  done

let chunks_wrap () =
  let r = {Nonce_space.first_chunk = Nonce_space.n_chunks - 2; count = 4} in
  Alcotest.(check (list int)) "wrap" [Nonce_space.n_chunks - 2; Nonce_space.n_chunks - 1; 0; 1]
    (List.of_seq (Nonce_space.chunks r))

let gen_range =
  QCheck.(
    map
      (fun (f, c, n) -> ({Nonce_space.first_chunk = f; count = c}, n))
      (triple
         (int_bound (Nonce_space.n_chunks - 1))
         (int_range 1 5000)
         (int_range 1 64)))

let slices_partition =
  QCheck.Test.make ~count:500 ~name:"instance slices are disjoint and cover the range" gen_range
    (fun (r, n) ->
      let all = List.of_seq (Nonce_space.chunks r) in
      let parts =
        List.concat_map
          (fun i -> List.of_seq (Nonce_space.chunks (Nonce_space.slice r ~instance:i ~of_:n)))
          (List.init n Fun.id)
      in
      parts = all)

let resume_rest =
  QCheck.Test.make ~count:500 ~name:"resume = remaining chunks"
    QCheck.(pair (int_bound (Nonce_space.n_chunks - 1)) (pair (int_range 1 5000) (int_range 0 5000)))
    (fun (f, (c, k)) ->
      let k = k mod (c + 1) in
      let r = {Nonce_space.first_chunk = f; count = c} in
      let next_chunk = Nonce_space.nth_chunk r k in
      let rest = Nonce_space.resume r ~next_chunk in
      List.of_seq (Nonce_space.chunks rest)
      = List.filteri (fun i _ -> i >= k) (List.of_seq (Nonce_space.chunks r)))

let instance () =
  Alcotest.(check (result (pair int int) string)) "1/2" (Ok (1, 2)) (Nonce_space.parse_instance "1/2") ;
  List.iter
    (fun s ->
      match Nonce_space.parse_instance s with
      | Ok _ -> Alcotest.failf "accepted %S" s
      | Error _ -> ())
    ["2/2"; "a/b"; "-1/2"; "1"; "0/0"]

let tests =
  ( "nonce_space",
    [
      Alcotest.test_case "text" `Quick text;
      QCheck_alcotest.to_alcotest roundtrip;
      Alcotest.test_case "seed" `Quick seed;
      Alcotest.test_case "chunks wrap" `Quick chunks_wrap;
      QCheck_alcotest.to_alcotest slices_partition;
      QCheck_alcotest.to_alcotest resume_rest;
      Alcotest.test_case "parse instance" `Quick instance;
    ] )
