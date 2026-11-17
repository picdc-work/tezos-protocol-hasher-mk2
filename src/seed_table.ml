let window_bits = 8

let entry_size = 30

let windows ~window_bits = 256 / window_bits

let p = Curve_ref.ed25519_prime

let ( %% ) a b = Z.erem a b

(* The three field elements of the entry of the point (x, y). *)
let entry_elements (x, y) =
  [|Z.add y x %% p; Z.sub y x %% p; Z.mul (Z.mul (Z.of_int 2) Curve_ref.ed25519_d) (Z.mul x y) %% p|]

let build ~window_bits =
  let spec = List.find (fun s -> s.Field_run.name = "ed25519") Field_run.specs in
  let mont = Field_run.to_mont spec in
  let per_window = 1 lsl window_bits in
  let elements = Array.make (windows ~window_bits * per_window * 3) Z.zero in
  let base = ref Curve_ref.ed25519_base in
  for i = 0 to windows ~window_bits - 1 do
    let point = ref (Z.zero, Z.one) in
    for d = 0 to per_window - 1 do
      Array.iteri
        (fun c e -> elements.((((i * per_window) + d) * 3) + c) <- mont e)
        (entry_elements !point) ;
      point := Curve_ref.ed25519_add !point !base
    done ;
    base := !point
  done ;
  Field_run.pack spec elements
