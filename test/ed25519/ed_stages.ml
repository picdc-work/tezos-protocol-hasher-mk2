(* The Ed25519 probe kernel (gen/gen_ed25519.ml) against the host, one stage
   after the other, on 1200 seeds of one base: (a) SHA-512 of the seed
   against Digestif, (b) the clamped scalar against Curve_ref, (c) the affine
   point of the table-based multiplication against Curve_ref, (d) the encoded
   public key and its Blake2b-20 digest. The counters of the seeds include a
   carry of the counter into its upper bytes. Prints one ED-STAGE line per
   stage. ED_STAGE=n (1 to 4) limits the checks to the stages the kernel
   was generated with. *)

open Octez_vanity
module Vector = Spoc_core.Vector

let stage_limit = match Sys.getenv_opt "ED_STAGE" with Some s -> int_of_string s | None -> 4

let seeds = 1200

(* A throwaway base; its counter ends with 0xffffff00, so that the 1200
   offsets cross a carry into byte 3 of the counter. *)
let base = String.init 24 (fun i -> Char.chr ((i * 37 + 11) land 255)) ^ "\x00\x00\x00\x00\xff\xff\xff\x00"

let offsets = Array.init seeds Int64.of_int

let seed_of j = Seed_keys.seed_of_offset ~base j

let width = 39

let run_probe () =
  let spec = List.find (fun s -> s.Field_run.name = "ed25519") Field_run.specs in
  ignore spec ;
  let vec64 a =
    let v = Vector.create Vector.int64 (max 1 (Array.length a)) in
    Array.iteri (Vector.set v) a ;
    v
  in
  let ctrs = vec64 (Array.map (fun j -> Seed_keys.counter_of_offset ~base j) offsets) in
  let seedw = vec64 (Seed_keys.prefix_words base) in
  let tab = if stage_limit >= 3 then Seed_table.build ~window_bits:8 else vec64 [|0L|] in
  let ebits, nbits = Field_run.exponent_bits spec in
  let h, vinit = Walk_run.blake_constants 32 in
  let dbg = Vector.create Vector.int64 (seeds * width) in
  let ir = Field_run.ir_of Ed_probe.probe in
  Field_run.launch ~ir
    Sarek.Execute.
      [
        Vec ctrs; Vec seedw; Vec tab; Vec ebits; Int32 (Int32.of_int nbits); Vec h; Vec vinit;
        Vec dbg; Int32 (Int32.of_int seeds);
      ]
    ~count:seeds ;
  dbg

let field e dbg first count =
  Array.init count (fun i -> Vector.get dbg ((e * width) + first + i))

let z_of_limbs limbs =
  Array.fold_right (fun l acc -> Z.logor (Z.shift_left acc 28) (Z.of_int64 l)) limbs Z.zero

(* Little-endian bytes of words *)
let le_bytes words =
  String.init (8 * Array.length words) (fun i ->
      Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical words.(i / 8) (8 * (i mod 8))) 255L)))

let be_bytes words =
  String.init (8 * Array.length words) (fun i ->
      Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical words.(i / 8) (56 - (8 * (i mod 8)))) 255L)))

let check_stage name f =
  let bad = ref 0 in
  Array.iteri (fun e j -> if not (f e (seed_of j)) then incr bad) offsets ;
  Printf.printf "ED-STAGE %s seeds=%d mismatches=%d\n%!" name seeds !bad ;
  Alcotest.(check int) (name ^ ": mismatches") 0 !bad

let test () =
  let dbg = run_probe () in
  if stage_limit >= 1 then
    check_stage "a: SHA-512 of the seed" (fun e seed ->
        let expected = Digestif.SHA512.(to_raw_string (digest_string seed)) in
        String.equal expected (be_bytes (field e dbg 0 8))) ;
  let scalar seed = Curve_ref.ed25519_scalar_of_seed seed in
  if stage_limit >= 2 then
    check_stage "b: clamped scalar" (fun e seed ->
        let words = field e dbg 8 4 in
        Z.equal (scalar seed) (Z.of_bits (le_bytes words)));
  let point seed = Curve_ref.ed25519_scalar_mul (scalar seed) Curve_ref.ed25519_base in
  let expected_points = Hashtbl.create 16 in
  let memo_point e seed =
    match Hashtbl.find_opt expected_points e with
    | Some p -> p
    | None ->
        let p = point seed in
        Hashtbl.replace expected_points e p ;
        p
  in
  if stage_limit >= 3 then
    check_stage "c: affine x, y = a B" (fun e seed ->
        let x, y = memo_point e seed in
        Z.equal x (z_of_limbs (field e dbg 12 10)) && Z.equal y (z_of_limbs (field e dbg 22 10))) ;
  if stage_limit >= 4 then begin
    check_stage "d1: encoded public key" (fun e seed ->
        String.equal (Curve_ref.ed25519_encode (memo_point e seed)) (le_bytes (field e dbg 32 4))) ;
    check_stage "d2: Blake2b-20 of the key" (fun e seed ->
        let digest = Blake2b.digest ~len:20 (Curve_ref.ed25519_encode (memo_point e seed)) in
        String.equal digest (String.sub (le_bytes (field e dbg 36 3)) 0 20))
  end

let () =
  Alcotest.run "ed_stages"
    [("ed_stages", [Alcotest.test_case "stages a to d on 1200 seeds" `Slow test])]
