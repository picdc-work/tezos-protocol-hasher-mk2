(* Generated field kernels (gen/gen_field.ml) on the Native backend against
   Zarith: for each of the four fields, multiplication (Montgomery product),
   addition, subtraction, inversion and batched inversion. Each case prints
   "FIELD-CHECK field operation count" once it passes. *)

open Octez_vanity

let random_count = 10_000

let inversion_count = 1_000

let batch_size = 16

let state = Random.State.make [|2026; 11; 17|]

let random_below p =
  Z.erem (Z.of_bits (String.init 56 (fun _ -> Char.chr (Random.State.int state 256)))) p

let random_nonzero p =
  let rec go () = match random_below p with x when Z.equal x Z.zero -> go () | x -> x in
  go ()

let edges (spec : Field_run.spec) =
  let p = spec.prime in
  let half = Z.shift_right p 1 in
  [Z.zero; Z.one; Z.of_int 2; Z.sub p Z.one; Z.sub p (Z.of_int 2); half; Z.succ half;
   Z.pred (Z.shift_left Z.one (28 * (spec.n - 1)));
   Z.shift_left Z.one (28 * (spec.n - 1))]

let pairs_of l = List.concat_map (fun a -> List.map (fun b -> (a, b)) l) l

(* Pre-subtraction value of the Montgomery product: (ab + m p) / R. *)
let montgomery_raw (spec : Field_run.spec) a b =
  let r = Field_run.radix spec in
  let pinv = Z.erem (Z.neg (Z.invert spec.prime r)) r in
  let ab = Z.mul a b in
  Z.div (Z.add ab (Z.mul (Z.erem (Z.mul ab pinv) r) spec.prime)) r

(* Operand pairs whose Montgomery product needs the final subtraction.
   Such pairs are rare (about 2^-24 of random pairs): for a fixed a, the
   denominators of the continued-fraction convergents of (a / p^-1 mod R) / R
   are the b for which b*J mod R is tiny, which makes m close to R. *)
let subtraction_pairs (spec : Field_run.spec) =
  let r = Field_run.radix spec in
  let p = spec.prime in
  let found = ref [] in
  for t = 0 to 63 do
    let a = Z.sub p (Z.of_int (1 + t)) in
    let j = Z.erem (Z.mul a (Z.invert p r)) r in
    let rec convergents (num, den) (k0, k1) =
      if Z.equal den Z.zero || Z.geq k1 p then ()
      else begin
        let q = Z.div num den in
        let k2 = Z.add k0 (Z.mul q k1) in
        if Z.lt k2 p then begin
          List.iter
            (fun c ->
              let b = Z.mul c k2 in
              if Z.lt b p && Z.geq (montgomery_raw spec a b) p then found := (a, b) :: !found)
            (List.map Z.of_int [1; 2; 3; 4; 5; 6; 7; 8]) ;
          convergents (den, Z.sub num (Z.mul q den)) (k1, k2)
        end
      end
    in
    (* the first quotient is 0: continue with r / j and denominators 0, 1 *)
    convergents (r, j) (Z.zero, Z.one)
  done ;
  !found

let report field op count = Printf.printf "FIELD-CHECK %s %s %d\n%!" field op count

let check_equal what expected actual =
  Array.iteri
    (fun i e ->
      if not (Z.equal e actual.(i)) then
        Alcotest.failf "%s: element %d: expected %s, got %s" what i (Z.to_string e)
          (Z.to_string actual.(i)))
    expected

let binary_case ~name (spec : Field_run.spec) ~ir ~reference extra =
  let p = spec.prime in
  let all =
    Array.of_list
      (pairs_of (edges spec) @ extra
      @ List.init random_count (fun _ -> (random_below p, random_below p)))
  in
  let xs = Array.map fst all and ys = Array.map snd all in
  let actual = Field_run.binary spec ~ir xs ys in
  check_equal (spec.name ^ " " ^ name) (Array.map (fun (a, b) -> reference a b) all) actual ;
  report spec.name name (Array.length all)

let test_mul (spec, (k : Field_set.kernels)) () =
  let rinv = Z.invert (Field_run.radix spec) spec.prime in
  let subs = subtraction_pairs spec in
  if subs = [] then Alcotest.failf "%s: no operand pair needing the final subtraction" spec.name ;
  Printf.printf "  %s: %d mul operand pairs need the final subtraction\n%!" spec.name (List.length subs) ;
  binary_case ~name:"mul" spec ~ir:k.mul
    ~reference:(fun a b -> Z.erem (Z.mul (Z.mul a b) rinv) spec.prime)
    subs

let test_add (spec, (k : Field_set.kernels)) () =
  let p = spec.Field_run.prime in
  binary_case ~name:"add" spec ~ir:k.add
    ~reference:(fun a b -> Z.erem (Z.add a b) p)
    [(Z.sub p Z.one, Z.sub p Z.one); (Z.sub p Z.one, Z.one)]

let test_sub (spec, (k : Field_set.kernels)) () =
  let p = spec.Field_run.prime in
  binary_case ~name:"sub" spec ~ir:k.sub
    ~reference:(fun a b -> Z.erem (Z.sub a b) p)
    [(Z.zero, Z.sub p Z.one); (Z.zero, Z.one)]

(* Montgomery-form inputs; the device result, taken out of Montgomery
   form, must be the modular inverse (and 0 for 0). *)
let reference_inverse p x = if Z.equal x Z.zero then Z.zero else Z.invert x p

let test_inv (spec, (k : Field_set.kernels)) () =
  let p = spec.Field_run.prime in
  let xs =
    Array.of_list (edges spec @ List.init inversion_count (fun _ -> random_below p))
  in
  let actual =
    Field_run.inverse spec ~ir:k.inv (Array.map (Field_run.to_mont spec) xs)
    |> Array.map (Field_run.of_mont spec)
  in
  check_equal (spec.name ^ " inv") (Array.map (reference_inverse p) xs) actual ;
  report spec.name "inv" (Array.length xs)

let test_batch_inv (spec, (k : Field_set.kernels)) () =
  let p = spec.Field_run.prime in
  let nonzero = List.filter (fun x -> not (Z.equal x Z.zero)) (edges spec) in
  (* the first batch contains 1 and p - 1 *)
  let first = Z.one :: Z.sub p Z.one :: nonzero in
  let first = List.filteri (fun i _ -> i < batch_size) (first @ List.init batch_size (fun _ -> random_nonzero p)) in
  let rest = List.init (inversion_count - batch_size) (fun _ -> random_nonzero p) in
  let rest = rest @ List.init (batch_size - (List.length rest mod batch_size)) (fun _ -> random_nonzero p) in
  let xs = Array.of_list (first @ rest) in
  let run ~batch xs =
    Field_run.batch_inverse spec ~ir:k.batch_inv ~batch (Array.map (Field_run.to_mont spec) xs)
    |> Array.map (Field_run.of_mont spec)
  in
  check_equal (spec.name ^ " batch_inv") (Array.map (reference_inverse p) xs) (run ~batch:batch_size xs) ;
  report spec.name (Printf.sprintf "batch_inv(batch=%d)" batch_size) (Array.length xs) ;
  (* other batch sizes: 1 and 17 *)
  let odd = Array.init 34 (fun i -> if i = 0 then Z.one else if i = 1 then Z.sub p Z.one else random_nonzero p) in
  check_equal (spec.name ^ " batch_inv 17") (Array.map (reference_inverse p) odd) (run ~batch:17 odd) ;
  check_equal (spec.name ^ " batch_inv 1") (Array.map (reference_inverse p) odd) (run ~batch:1 odd) ;
  report spec.name "batch_inv(batch=17 and batch=1)" (2 * Array.length odd)

let tests =
  ( "field kernels (Native vs Zarith)",
    List.concat_map
      (fun ((spec : Field_run.spec), _ as field) ->
        let case op f = Alcotest.test_case (spec.name ^ " " ^ op) `Quick (f field) in
        (* test names stay fixed; the counts are printed as FIELD-CHECK lines, shown with ALCOTEST_VERBOSE=1 *)
        [case "mul" test_mul; case "add" test_add; case "sub" test_sub; case "inv" test_inv;
         case "batch_inv" test_batch_inv])
      Field_set.all )
