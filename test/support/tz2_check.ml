(* Independent recomputation of a tz2 or tz3 address from a key file: base58
   decoding (test-only decoder), public key by secp256k1-internal (tz2) or
   mirage-crypto-ec (tz3), Blake2b-20 by digestif, base58check written here.
   Does not use Octez_vanity. Prints only the address; never the secret.
   Usage: tz2_check KEYFILE          (tz2, as the tz2 cram test calls it)
          tz2_check --scheme tz3 KEYFILE *)
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

type scheme = {
  key_prefix : string;  (* secret key base58 prefix bytes *)
  key_label : string;
  address_prefix : string;
  public_key : string -> string option;  (* compressed SEC1 key of a 32-byte secret *)
}

let tz2 =
  let ctx = lazy (Libsecp256k1.External.Context.create ~sign:true ~verify:false ()) in
  {
    key_prefix = "\x11\xa2\xe0\xc9";
    key_label = "secp256k1 secret key (spsk)";
    address_prefix = "\x06\xa1\xa1";
    public_key =
      (fun secret ->
        let open Libsecp256k1.External in
        let ctx = Lazy.force ctx in
        match Key.read_sk ctx (Bigstring.of_string secret) with
        | Error _ -> None
        | Ok sk -> Some (Bigstring.to_string (Key.to_bytes ~compress:true ctx (Key.neuterize_exn ctx sk))));
  }

let tz3 =
  {
    key_prefix = "\x10\x51\xee\xbd";
    key_label = "P-256 secret key (p2sk)";
    address_prefix = "\x06\xa1\xa4";
    public_key =
      (fun secret ->
        match Mirage_crypto_ec.P256.Dsa.priv_of_octets secret with
        | Error _ -> None
        | Ok priv -> Some Mirage_crypto_ec.P256.Dsa.(pub_to_octets ~compress:true (pub_of_priv priv)));
  }

let read_secret scheme path =
  let line = In_channel.with_open_bin path In_channel.input_all in
  if line = "" || line.[String.length line - 1] <> '\n' || String.contains (String.trim line) '\n' then
    die "the key file must hold exactly one line" ;
  let raw = try B58_decode.decode (String.trim line) with Failure _ -> die "not a base58check string" in
  if String.length raw <> 36 || String.sub raw 0 4 <> scheme.key_prefix then
    die ("not a " ^ scheme.key_label) ;
  String.sub raw 4 32

let usage () = die "usage: tz2_check [--scheme tz2|tz3] KEYFILE"

let () =
  let scheme, path =
    match Array.to_list Sys.argv with
    | [_; path] -> (tz2, path)
    | [_; "--scheme"; "tz2"; path] -> (tz2, path)
    | [_; "--scheme"; "tz3"; path] -> (tz3, path)
    | _ -> usage ()
  in
  let secret = read_secret scheme path in
  match scheme.public_key secret with
  | None -> die "invalid secret scalar"
  | Some pk ->
      let digest = Blake20.(to_raw_string (digest_string pk)) in
      print_endline (encode (scheme.address_prefix ^ digest))
