(* The walk kernel (gen/gen_walk.ml) on the Native backend against the host
   reference, for one scheme: points enumerated incrementally with Curve_ref,
   hashed with Blake2b-20, filtered with Target.top64_of and
   Target.in_intervals. Every case prints a WALK-CHECK line with the number
   of offsets compared and of hits. Instantiated by walk_tz2 and walk_tz3. *)

open Octez_vanity

module type Scheme = sig
  val scheme : Address.scheme
  val curve : Curve_ref.curve
  val kernel : Walk_run.kernel
  val suite : string
end

module Make (S : Scheme) = struct
let curve = S.curve

let generator = Curve_ref.generator curve

(* A fixed test scalar, not a real key. *)
let k0 = Z.of_string_base 16 "1d9c5f0b7a3e48126c0f6e9ab2d4713ef05a8c64b91e2d37a6f4c8105be39d27"

let p0 = Curve_ref.scalar_mul curve k0 generator

let kind = Address.target_kind S.scheme

let target name =
  match Target.make ~kind name with Ok t -> t | Error e -> failwith e

let z_be32 z =
  String.init 32 (fun i -> Char.chr (Z.to_int (Z.logand (Z.shift_right z (8 * (31 - i))) (Z.of_int 255))))

let top64 point =
  let x, y = match Curve_ref.affine point with Ok c -> c | Error e -> failwith e in
  let key = String.make 1 (if Z.testbit y 0 then '\x03' else '\x02') ^ z_be32 x in
  Target.top64_of kind (Blake2b.digest ~len:20 key)

(* top64 of P0 + j G for j = from .. from + count - 1 *)
let reference_tops ~from ~count =
  let first = Curve_ref.add_points curve p0 (Curve_ref.scalar_mul curve (Z.of_int from) generator) in
  let tops = Array.make count 0L in
  let point = ref first in
  for i = 0 to count - 1 do
    tops.(i) <- top64 !point ;
    point := Curve_ref.add_points curve !point generator
  done ;
  tops

let reference_hits tops target =
  let hits = ref [] in
  Array.iteri (fun i t -> if Target.in_intervals target t then hits := i :: !hits) tops ;
  List.rev !hits

let device = lazy (Device_search.cpu_device ())

let walker ?cap ~threads ~batch ~chunk target =
  Walk_run.create ?cap (Lazy.force device) S.kernel target ~threads ~batch ~p0 ~chunk

let report name ~offsets ~hits = Printf.printf "WALK-CHECK %s offsets=%d hits=%d\n%!" name offsets hits

let check_hits name expected actual =
  let show l = String.concat " " (List.map string_of_int l) in
  let minus a b = List.filter (fun x -> not (List.mem x b)) a in
  if expected <> actual then
    Printf.printf "%s: missing [%s] extra [%s]\n%!" name (show (minus expected actual))
      (show (minus actual expected)) ;
  Alcotest.(check (list int)) name expected actual

let point_of (x, y) = Curve_ref.Affine (x, y)

let expected_state ~threads ~batch ~chunk t =
  let offset = Z.of_int ((chunk * threads * batch) + (t * batch)) in
  Curve_ref.add_points curve p0 (Curve_ref.scalar_mul curve offset generator)

let check_state name ~threads ~batch ~chunk w which sample =
  let states = which w in
  List.iter
    (fun t ->
      let ok = point_of states.(t) = expected_state ~threads ~batch ~chunk t in
      Alcotest.(check bool) (Printf.sprintf "%s thread %d" name t) true ok)
    sample

(* Full chunk of 2^20 offsets, two targets, then the state. *)
let full_chunk () =
  let threads = 1024 and batch = 1024 in
  let size = threads * batch in
  let tops = reference_tops ~from:0 ~count:size in
  let sample = [0; 1; 17; threads - 1] in
  let check name =
    let tgt = target name in
    let w = walker ~threads ~batch ~chunk:0 tgt in
    let hits = Walk_run.run w in
    check_hits name (reference_hits tops tgt) hits ;
    report ("chunk 0 target " ^ name) ~offsets:size ~hits:(List.length hits) ;
    w
  in
  ignore (check "w") ;
  let w = check "wa" in
  check_state "next state" ~threads ~batch ~chunk:1 w Walk_run.next_state sample ;
  report "next state of chunk 0, threads 0 1 17 1023" ~offsets:(List.length sample) ~hits:0

(* Small geometry: size 2^16. *)
let threads = 256

let batch = 256

let size = threads * batch

let nonzero_chunk () =
  let chunk = 5 in
  let tops = reference_tops ~from:(chunk * size) ~count:size in
  let tgt = target "wa" in
  let hits = Walk_run.run (walker ~threads ~batch ~chunk tgt) in
  check_hits "chunk 5" (reference_hits tops tgt) hits ;
  report "chunk 5 target wa" ~offsets:size ~hits:(List.length hits)

let advancing () =
  let tgt = target "w" in
  let w = walker ~threads ~batch ~chunk:0 tgt in
  let first = Walk_run.run w in
  Walk_run.advance w ;
  Alcotest.(check int) "chunk number" 1 (Walk_run.chunk w) ;
  check_state "advanced state" ~threads ~batch ~chunk:1 w Walk_run.state [0; 5; threads - 1] ;
  let second = Walk_run.run w in
  let tops = reference_tops ~from:0 ~count:(2 * size) in
  let expected n = reference_hits (Array.sub tops (n * size) size) tgt in
  check_hits "chunk 0" (expected 0) first ;
  check_hits "chunk 1 after advance" (expected 1) second ;
  report "chunks 0 and 1 target w" ~offsets:(2 * size) ~hits:(List.length first + List.length second)

let tiny_capacity () =
  let tgt = target "wa" in
  let tops = reference_tops ~from:0 ~count:size in
  let expected = reference_hits tops tgt in
  (* 4096 threads of 16 offsets: no thread has more hits than the capacity *)
  let w = walker ~threads:4096 ~batch:16 ~chunk:0 tgt in
  let hits = Walk_run.run ~cap:2 w in
  check_hits "cap 2" expected hits ;
  check_hits "repeat launch" expected (Walk_run.run ~cap:2 w) ;
  Alcotest.(check bool) "more hits than the capacity" true (List.length hits > 2) ;
  report "capacity 2 (re-run in halves) target wa" ~offsets:size ~hits:(List.length hits)

let run () =
  Alcotest.run ~verbose:true S.suite
    [
      ( S.suite,
        [
          Alcotest.test_case "chunk 2^20, 1 and 2 characters, next state" `Slow full_chunk;
          Alcotest.test_case "non-zero chunk index" `Quick nonzero_chunk;
          Alcotest.test_case "advance to the next chunk" `Quick advancing;
          Alcotest.test_case "tiny hit buffer" `Quick tiny_capacity;
        ] );
    ]
end
