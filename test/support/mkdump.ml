(* Synthetic dumps and an independent protocol-hash oracle (digestif +
   its own base58), used by tests.

   mkdump <F in 1..128> <seed> <out>     dump whose final Blake2b block has F bytes
   mkdump --size <L> <seed> <out>        dump of exactly L bytes
   mkdump --hash <dump> <16 digits>      protocol hash of the dump with that nonce *)

let line = "(* Vanity nonce: 0000000000000000 *)\n"

let write_dump len seed out =
  if len < String.length line + 1 then failwith "size too small" ;
  let body = len - String.length line in
  let state = ref (Int64.of_int ((seed * 2654435761) lor 1)) in
  let next () =
    (* xorshift64 *)
    let x = !state in
    let x = Int64.logxor x (Int64.shift_left x 13) in
    let x = Int64.logxor x (Int64.shift_right_logical x 7) in
    let x = Int64.logxor x (Int64.shift_left x 17) in
    state := x ;
    x
  in
  let b = Bytes.create len in
  for i = 0 to body - 1 do
    let r = Int64.to_int (Int64.logand (next ()) 0x3fL) in
    Bytes.set b i (Char.chr (32 + r + if r = 0 then 1 else 0))
  done ;
  Bytes.blit_string line 0 b body (String.length line) ;
  let oc = open_out_bin out in
  output_bytes oc b ;
  close_out oc

module B2 = Digestif.Make_BLAKE2B (struct
  let digest_size = 32
end)

let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let b58 s =
  let n =
    String.fold_left
      (fun acc c -> Z.add (Z.shift_left acc 8) (Z.of_int (Char.code c)))
      Z.zero s
  in
  let buf = Buffer.create 64 in
  let rec go n =
    if Z.gt n Z.zero then begin
      let q, r = Z.div_rem n (Z.of_int 58) in
      go q ;
      Buffer.add_char buf alphabet.[Z.to_int r]
    end
  in
  go n ;
  Buffer.contents buf

let hash path nonce =
  if String.length nonce <> 16 then failwith "nonce must have 16 digits" ;
  let ic = open_in_bin path in
  let d = really_input_string ic (in_channel_length ic) in
  close_in ic ;
  let d = Bytes.of_string d in
  Bytes.blit_string nonce 0 d (Bytes.length d - 20) 16 ;
  let digest = B2.(to_raw_string (digest_bytes d)) in
  let payload = "\002\170" ^ digest in
  let sha s = Digestif.SHA256.(to_raw_string (digest_string s)) in
  b58 (payload ^ String.sub (sha (sha payload)) 0 4)

let () =
  match Array.to_list Sys.argv |> List.tl with
  | ["--hash"; path; nonce] -> print_endline (hash path nonce)
  | ["--size"; len; seed; out] ->
      write_dump (int_of_string len) (int_of_string seed) out
  | [f; seed; out] ->
      let f = int_of_string f in
      if f < 1 || f > 128 then failwith "F must be in 1..128" ;
      write_dump (1024 + f) (int_of_string seed) out
  | _ ->
      prerr_endline "usage: see header of test/support/mkdump.ml" ;
      exit 2
