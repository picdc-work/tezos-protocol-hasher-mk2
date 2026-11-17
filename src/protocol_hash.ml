let prefix = "\002\170"

let alphabet = Base58.alphabet

let b58_encode_z = Base58.encode_z

let of_digest digest = Base58.check_encode (prefix ^ digest)
