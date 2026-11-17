let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let z58 = Z.of_int 58

let encode_z n =
  let buf = Buffer.create 64 in
  let rec go n =
    if Z.gt n Z.zero then begin
      let q, r = Z.div_rem n z58 in
      go q ;
      Buffer.add_char buf alphabet.[Z.to_int r]
    end
  in
  go n ;
  Buffer.contents buf

let z_of_be s =
  String.fold_left
    (fun acc c -> Z.add (Z.shift_left acc 8) (Z.of_int (Char.code c)))
    Z.zero s

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

let check_encode payload =
  if payload <> "" && payload.[0] = '\000' then
    invalid_arg "Base58.check_encode: payload starts with a zero byte" ;
  let checksum = String.sub (sha256 (sha256 payload)) 0 4 in
  encode_z (z_of_be (payload ^ checksum))
