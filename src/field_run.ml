(* Host side of the generated field kernels (gen/gen_field.ml): packing of
   field elements into 28-bit limbs, launch on a device, unpacking.

   An element is [n] limbs, least significant first; element [e] of a
   launch occupies vector slots [e*n .. e*n+n-1]. *)

module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute

let limb_bits = 28

let limb_mask = Z.of_int ((1 lsl limb_bits) - 1)

type i64v = (int64, Bigarray.int64_elt) Vector.t

type spec = {name : string; prime : Z.t; n : int}

let hex h = Z.of_string_base 16 h

(* The primes are not exported by Curve_ref; the same values are written in
   gen/gen_field.ml. *)
let specs =
  [
    {name = "ed25519"; prime = Z.sub (Z.shift_left Z.one 255) (Z.of_int 19); n = 10};
    {
      name = "secp256k1";
      prime = hex "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F";
      n = 10;
    };
    {
      name = "p256";
      prime = hex "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF";
      n = 10;
    };
    {
      name = "bls12_381";
      prime =
        hex
          "1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB";
      n = 14;
    };
  ]

let radix spec = Z.shift_left Z.one (limb_bits * spec.n)

let to_mont spec x = Z.erem (Z.mul x (radix spec)) spec.prime

let of_mont spec x = Z.erem (Z.mul x (Z.invert (radix spec) spec.prime)) spec.prime

let pack spec (xs : Z.t array) : i64v =
  let n = spec.n in
  let v = Vector.create Vector.int64 (max 1 (Array.length xs * n)) in
  Array.iteri
    (fun e x ->
      for j = 0 to n - 1 do
        let limb = Z.logand (Z.shift_right x (limb_bits * j)) limb_mask in
        Vector.set v ((e * n) + j) (Int64.of_int (Z.to_int limb))
      done)
    xs ;
  v

let unpack spec (v : i64v) count : Z.t array =
  let n = spec.n in
  Array.init count (fun e ->
      let acc = ref Z.zero in
      for j = n - 1 downto 0 do
        acc := Z.logor (Z.shift_left !acc limb_bits) (Z.of_int (Int64.to_int (Vector.get v ((e * n) + j))))
      done ;
      !acc)

let block = 256

(* The IR of a generated kernel (the value [Field_<name>.mul] etc.). *)
let ir_of (_, kirc) =
  match kirc.Sarek.Kirc_types.body_ir with
  | Some ir -> ir
  | None -> failwith "kernel without IR"

let launch ~ir args ~count =
  let device = Device_search.cpu_device () in
  let grid = (count + block - 1) / block in
  Execute.run_vectors ~device ~ir ~args ~block:(Execute.dims1d block) ~grid:(Execute.dims1d grid) () ;
  Transfer.flush device

let binary spec ~ir xs ys =
  let count = Array.length xs in
  let out = Vector.create Vector.int64 (max 1 (count * spec.n)) in
  launch ~ir
    Execute.[Vec (pack spec xs); Vec (pack spec ys); Vec out; Int32 (Int32.of_int count)]
    ~count ;
  unpack spec out count

(* Bits of p - 2, most significant first, one int64 per bit. *)
let exponent_bits spec =
  let e = Z.sub spec.prime (Z.of_int 2) in
  let nbits = Z.numbits e in
  let v = Vector.create Vector.int64 nbits in
  for k = 0 to nbits - 1 do
    Vector.set v k (if Z.testbit e (nbits - 1 - k) then 1L else 0L)
  done ;
  (v, nbits)

(* x^(p-2) of Montgomery-form inputs (result in Montgomery form). *)
let inverse spec ~ir xs =
  let count = Array.length xs in
  let ebits, nbits = exponent_bits spec in
  let out = Vector.create Vector.int64 (max 1 (count * spec.n)) in
  launch ~ir
    Execute.
      [
        Vec (pack spec xs);
        Vec ebits;
        Vec out;
        Int32 (Int32.of_int nbits);
        Int32 (Int32.of_int count);
      ]
    ~count ;
  unpack spec out count

(* Montgomery batch inversion, one batch of [batch] elements per thread;
   [Array.length xs] must be a multiple of [batch]. *)
let batch_inverse spec ~ir ~batch xs =
  let total = Array.length xs in
  assert (batch >= 1 && total mod batch = 0) ;
  let threads = total / batch in
  let ebits, nbits = exponent_bits spec in
  let scratch = Vector.create Vector.int64 (max 1 (total * spec.n)) in
  let out = Vector.create Vector.int64 (max 1 (total * spec.n)) in
  launch ~ir
    Execute.
      [
        Vec (pack spec xs);
        Vec scratch;
        Vec ebits;
        Vec out;
        Int32 (Int32.of_int nbits);
        Int32 (Int32.of_int batch);
        Int32 (Int32.of_int threads);
      ]
    ~count:threads ;
  unpack spec out total
