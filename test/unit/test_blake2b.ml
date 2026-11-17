open Octez_vanity

module Ref = Digestif.Make_BLAKE2B (struct
  let digest_size = 32
end)

let hex s =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let abc () =
  Alcotest.(check string)
    "blake2b-256(abc)" "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
    (hex (Blake2b.digest "abc"))

module Ref20 = Digestif.Make_BLAKE2B (struct
  let digest_size = 20
end)

let gen_string = QCheck.(string_size Gen.(0 -- 1000))

let vs_digestif =
  QCheck.Test.make ~count:300 ~name:"digest = digestif" gen_string (fun s ->
      Blake2b.digest s = Ref.(to_raw_string (digest_string s)))

(* Chaining value over the leading full blocks, then the final block. *)
let incremental =
  QCheck.Test.make ~count:200 ~name:"chaining value + final = digest"
    QCheck.(string_size Gen.(1 -- 700))
    (fun s ->
      let b = Bytes.of_string s in
      let n = Bytes.length b in
      let last = (n - 1) / 128 * 128 in
      let h = Blake2b.init () in
      for i = 0 to (last / 128) - 1 do
        Blake2b.compress h
          (Blake2b.words_of_block b (i * 128) 128)
          ~t0:(Int64.of_int ((i + 1) * 128))
          ~last:false
      done ;
      Blake2b.compress h
        (Blake2b.words_of_block b last (n - last))
        ~t0:(Int64.of_int n) ~last:true ;
      Blake2b.digest_of_state h = Blake2b.digest s)

(* FR-004: a 20-byte digest, as used for Tezos addresses. *)
let vs_digestif_20 =
  QCheck.Test.make ~count:300 ~name:"20-byte digest = digestif" gen_string (fun s ->
      Blake2b.digest ~len:20 s = Ref20.(to_raw_string (digest_string s)))

let default_is_32 () =
  Alcotest.(check string) "default length" (Blake2b.digest "abc") (Blake2b.digest ~len:32 "abc")

let bad_length () =
  List.iter
    (fun len ->
      Alcotest.check_raises (Printf.sprintf "len %d" len)
        (Invalid_argument "Blake2b: digest length must be in 1..64")
        (fun () -> ignore (Blake2b.digest ~len "abc")))
    [0; 65; -1]

let tests =
  ( "blake2b",
    [
      Alcotest.test_case "abc" `Quick abc;
      Alcotest.test_case "default length is 32" `Quick default_is_32;
      Alcotest.test_case "length outside 1..64" `Quick bad_length;
    ]
    @ List.map QCheck_alcotest.to_alcotest [vs_digestif; incremental; vs_digestif_20] )
