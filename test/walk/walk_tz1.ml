(* The tz1 seed-search kernel (gen/gen_ed25519.ml, run by Seed_run) on the
   Native backend against the host reference: for each seed of a range the
   public key is derived with Curve_ref (RFC 8032), hashed with Blake2b-20
   and filtered with Target.top64_of and Target.in_intervals. Two ranges of
   2^14 seeds (a launch of 128 threads x 8 seeds, run 16 times), two targets:
   - one whose counter crosses a carry into its upper bytes (u ends with
     0xffffff00, so the carry runs into byte 3 at offset 256 and the counter
     passes 2^32);
   - one whose base has u = 2^64 - 5000, so that the counter wraps to 0.
   Every case prints a WALK-CHECK line with the number of seeds compared and
   of hits, then the hits by parity of x (the top bit of the last public
   key byte); the test fails if either count is zero. The bases are
   throwaway test values. *)

open Octez_vanity

let kind = Address.target_kind Address.Tz1

let target name = match Target.make ~kind name with Ok t -> t | Error e -> failwith e

let seeds_per_range = 1 lsl 14

let threads = 128

let batch = 8

let with_counter counter =
  let tail = Bytes.create 8 in
  Bytes.set_int64_be tail 0 counter ;
  String.init 24 (fun i -> Char.chr ((i * 53 + 7) land 255)) ^ Bytes.to_string tail

let carry_base = with_counter 0x0000_0000_ffff_ff00L

let wrap_base = with_counter (Int64.neg 5000L)

(* top64 and the parity of x of the seed of every offset of the range *)
let reference base =
  let tops = Array.make seeds_per_range 0L and odd = Array.make seeds_per_range false in
  for j = 0 to seeds_per_range - 1 do
    let seed = Seed_keys.seed_of_offset ~base (Int64.of_int j) in
    match Curve_ref.public_key Address.Tz1 seed with
    | Error e -> failwith e
    | Ok pk ->
        tops.(j) <- Target.top64_of kind (Blake2b.digest ~len:20 pk) ;
        odd.(j) <- Char.code pk.[31] land 0x80 <> 0
  done ;
  (tops, odd)

let reference_hits tops target =
  let hits = ref [] in
  Array.iteri (fun i t -> if Target.in_intervals target t then hits := i :: !hits) tops ;
  List.rev !hits

(* OCTEZ_VANITY_TEST_DEVICE (a device index or a framework name, as --device)
   runs the check on another device; the default is the Native backend. *)
let device =
  lazy
    (match Sys.getenv_opt "OCTEZ_VANITY_TEST_DEVICE" with
     | None | Some "" -> Device_search.cpu_device ()
     | Some spec -> (
         match Device_search.select spec with
         | Ok ((_, d) :: _) ->
             Printf.printf "TEST-DEVICE %s %s\n%!" (Device_search.framework d) (Device_search.name d) ;
             d
         | Ok [] -> failwith ("OCTEZ_VANITY_TEST_DEVICE: no device for " ^ spec)
         | Error e -> failwith ("OCTEZ_VANITY_TEST_DEVICE: " ^ e)))

(* The hits of the whole range through consecutive launches. *)
let device_hits ?cap ~base target =
  let runner = Seed_run.create ?cap (Lazy.force device) target ~base ~threads ~batch in
  let size = Seed_run.launch_size runner in
  List.concat
    (List.init (seeds_per_range / size) (fun launch ->
         let start = Int64.of_int (launch * size) in
         List.map (fun i -> (launch * size) + i) (Seed_run.run ?cap runner ~start)))

let check_range label base tops odd names =
  List.map
    (fun name ->
      let tgt = target name in
      let expected = reference_hits tops tgt in
      let actual = device_hits ~base tgt in
      Alcotest.(check (list int)) (label ^ " target " ^ name) expected actual ;
      Printf.printf "WALK-CHECK %s target %s seeds=%d hits=%d\n%!" label name seeds_per_range
        (List.length actual) ;
      (name, actual))
    names
  |> List.map (fun (name, hits) ->
         ( name,
           List.length (List.filter (fun i -> odd.(i)) hits),
           List.length (List.filter (fun i -> not odd.(i)) hits) ))

let equivalence () =
  let totals = Hashtbl.create 2 in
  let add = List.iter (fun (name, set, clear) ->
        let s, c = Option.value (Hashtbl.find_opt totals name) ~default:(0, 0) in
        Hashtbl.replace totals name (s + set, c + clear))
  in
  let names = ["a"; "Dd"] in
  let run label base =
    let tops, odd = reference base in
    add (check_range label base tops odd names) ;
    if label = "counter carry" then begin
      (* a hit buffer of 4 forces the re-run of the threads in halves *)
      let tgt = target "a" in
      let expected = reference_hits tops tgt in
      Alcotest.(check (list int)) "capacity 4" expected (device_hits ~cap:4 ~base tgt) ;
      Printf.printf "WALK-CHECK capacity 4 (re-run in halves) target a seeds=%d hits=%d\n%!"
        seeds_per_range (List.length expected)
    end
  in
  run "counter carry" carry_base ;
  run "counter wrap" wrap_base ;
  List.iter
    (fun name ->
      let set, clear = Hashtbl.find totals name in
      Printf.printf "WALK-CHECK target %s hits with x odd=%d, x even=%d\n%!" name set clear ;
      Alcotest.(check bool) (name ^ ": hits with x odd") true (set > 0) ;
      Alcotest.(check bool) (name ^ ": hits with x even") true (clear > 0))
    names

let () =
  (* Before Alcotest captures the output: the device line must be visible. *)
  ignore (Lazy.force device) ;
  Alcotest.run "walk_tz1"
    [("walk_tz1", [Alcotest.test_case "seeds against Curve_ref, carry and wrap" `Slow equivalence])]
