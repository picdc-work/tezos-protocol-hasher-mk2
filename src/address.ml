type scheme = Tz1 | Tz2 | Tz3 | Tz4

let schemes = [Tz1; Tz2; Tz3; Tz4]

let name = function Tz1 -> "tz1" | Tz2 -> "tz2" | Tz3 -> "tz3" | Tz4 -> "tz4"

let public_key_length = function Tz1 -> 32 | Tz2 | Tz3 -> 33 | Tz4 -> 48

let secret_length = 32

let address_prefix = function
  | Tz1 -> "\x06\xa1\x9f"
  | Tz2 -> "\x06\xa1\xa1"
  | Tz3 -> "\x06\xa1\xa4"
  | Tz4 -> "\x06\xa1\xa6"

let secret_prefix = function
  | Tz1 -> "\x0d\x0f\x3a\x07"
  | Tz2 -> "\x11\xa2\xe0\xc9"
  | Tz3 -> "\x10\x51\xee\xbd"
  | Tz4 -> "\x03\x96\xc0\x28"

let digest_length = 20

let address_of_digest scheme digest =
  if String.length digest <> digest_length then
    invalid_arg "Address.address_of_digest: expected a 20-byte digest" ;
  Base58.check_encode (address_prefix scheme ^ digest)

let address scheme public_key =
  let expected = public_key_length scheme in
  if String.length public_key <> expected then
    Error
      (Printf.sprintf "%s public key must have %d bytes, got %d" (name scheme) expected
         (String.length public_key))
  else Ok (address_of_digest scheme (Blake2b.digest ~len:digest_length public_key))

let secret_key scheme secret =
  if String.length secret <> secret_length then
    Error
      (Printf.sprintf "%s secret key must have %d bytes, got %d" (name scheme) secret_length
         (String.length secret))
  else Ok (Base58.check_encode (secret_prefix scheme ^ secret))

let max_name = 8

let target_kind scheme =
  Target.make_kind ~fixed:(name scheme) ~free:0 ~prefix:(address_prefix scheme)
    ~digest_length ~max_name ~noun:"address" ~strict:true
