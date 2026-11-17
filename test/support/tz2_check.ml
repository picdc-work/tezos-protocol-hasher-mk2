(* Independent recomputation of a tz2 address from a key file: base58
   decoding (test-only decoder), public key by secp256k1-internal, Blake2b-20
   by digestif, base58check written here. Does not use Octez_vanity.
   Prints only the address; never the secret. Usage: tz2_check KEYFILE *)

module Blake20 = Digestif.Make_BLAKE2B (struct
  let digest_size = 20
end)

let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

(* base58check of bytes without leading zero bytes after the prefix *)
let encode raw =
  let body = raw ^ String.sub (sha256 (sha256 raw)) 0 4 in
  let n = ref (String.fold_left (fun a c -> Z.add (Z.shift_left a 8) (Z.of_int (Char.code c))) Z.zero body) in
  let digits = Buffer.create 40 in
  while Z.sign !n > 0 do
    let q, r = Z.div_rem !n (Z.of_int 58) in
    Buffer.add_char digits alphabet.[Z.to_int r] ;
    n := q
  done ;
  let s = Buffer.contents digits in
  String.init (String.length s) (fun i -> s.[String.length s - 1 - i])

let die msg =
  prerr_endline ("tz2_check: " ^ msg) ;
  exit 1

let read_secret path =
  let line = In_channel.with_open_bin path In_channel.input_all in
  if line = "" || line.[String.length line - 1] <> '\n' || String.contains (String.trim line) '\n' then
    die "the key file must hold exactly one line" ;
  let raw = try B58_decode.decode (String.trim line) with Failure _ -> die "not a base58check string" in
  if String.length raw <> 36 || String.sub raw 0 4 <> "\x11\xa2\xe0\xc9" then die "not a secp256k1 secret key (spsk)" ;
  String.sub raw 4 32

let () =
  if Array.length Sys.argv <> 2 then die "usage: tz2_check KEYFILE" ;
  let secret = read_secret Sys.argv.(1) in
  let open Libsecp256k1.External in
  let ctx = Context.create ~sign:true ~verify:false () in
  match Key.read_sk ctx (Bigstring.of_string secret) with
  | Error _ -> die "invalid secret scalar"
  | Ok sk ->
      let pk = Bigstring.to_string (Key.to_bytes ~compress:true ctx (Key.neuterize_exn ctx sk)) in
      let digest = Blake20.(to_raw_string (digest_string pk)) in
      print_endline (encode ("\x06\xa1\xa1" ^ digest))
