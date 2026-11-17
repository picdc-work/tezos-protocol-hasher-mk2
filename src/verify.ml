let hash dump nonce =
  if String.length nonce <> 16 || not (String.for_all (fun c -> c >= '0' && c <= '9') nonce)
  then Error (Printf.sprintf "nonce %S: expected exactly 16 decimal digits" nonce)
  else Ok (Protocol_hash.of_digest (Dump.digest_full dump (Int64.of_string nonce)))
