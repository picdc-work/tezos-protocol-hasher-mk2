let curve_of = function
  | Address.Tz2 -> Ok Curve_ref.secp256k1
  | Address.Tz3 -> Ok Curve_ref.p256
  | Address.Tz4 -> Ok Curve_ref.bls12_381_g1
  | s -> Error (Printf.sprintf "no walk kernel for %s addresses" (Address.name s))

let scalar_of_bytes s = Z.of_bits (String.init (String.length s) (fun i -> s.[String.length s - 1 - i]))

let scalar_to_bytes z =
  String.init 32 (fun i -> Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * (31 - i))) (Z.of_int 255))))

let reverse s = String.init (String.length s) (fun i -> s.[String.length s - 1 - i])

(* The 32 secret bytes Octez stores: big-endian for tz2 and tz3, little-endian
   for tz4. *)
let secret_of_scalar scheme k =
  let be = scalar_to_bytes k in
  if scheme = Address.Tz4 then reverse be else be

let scalar_of_secret scheme s = scalar_of_bytes (if scheme = Address.Tz4 then reverse s else s)

let random_bytes n =
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic n)

let rec random_scalar (curve : Curve_ref.curve) =
  let k = scalar_of_bytes (random_bytes 32) in
  if Z.sign k > 0 && Z.lt k curve.n then k else random_scalar curve

let unsigned_offset j =
  let high = Z.of_int64 (Int64.shift_right_logical j 1) and low = Z.of_int (Int64.to_int (Int64.logand j 1L)) in
  Z.add (Z.shift_left high 1) low

let key_of_offset (curve : Curve_ref.curve) ~k0 j = Z.erem (Z.add k0 (unsigned_offset j)) curve.n

let confirm scheme curve target ~k0 j =
  let k = key_of_offset curve ~k0 j in
  if Z.sign k = 0 then None
  else
    let secret = secret_of_scalar scheme k in
    match Curve_ref.address scheme secret with
    | Ok address when Target.matches target address -> Some (address, secret)
    | _ -> None
