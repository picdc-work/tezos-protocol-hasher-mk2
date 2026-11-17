(* Base58check decoding, for tests only: the library never decodes. *)

let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

let to_z s =
  String.fold_left
    (fun acc c ->
      match String.index_opt alphabet c with
      | Some i -> Z.add (Z.mul acc (Z.of_int 58)) (Z.of_int i)
      | None -> failwith (Printf.sprintf "not a base58 character: %C" c))
    Z.zero s

let bytes_of_z n =
  let rec go n acc =
    if Z.equal n Z.zero then acc
    else go (Z.shift_right n 8) (String.make 1 (Char.chr (Z.to_int (Z.logand n (Z.of_int 255)))) ^ acc)
  in
  go n ""

(* Raw bytes (prefix included, checksum removed); verifies the checksum.
   Leading '1' characters stand for zero bytes. *)
let decode s =
  let rec leading i = if i < String.length s && s.[i] = '1' then leading (i + 1) else i in
  let zeros = leading 0 in
  let raw = String.make zeros '\000' ^ bytes_of_z (to_z s) in
  let n = String.length raw in
  if n < 5 then failwith "too short" ;
  let body = String.sub raw 0 (n - 4) in
  if String.sub (sha256 (sha256 body)) 0 4 <> String.sub raw (n - 4) 4 then
    failwith ("bad checksum: " ^ s) ;
  body
