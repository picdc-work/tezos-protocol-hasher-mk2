let base_length = 32

let random_base () =
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> really_input_string ic base_length)

let prefix_words base = Array.init 3 (fun i -> String.get_int64_be base (8 * i))

let counter base = String.get_int64_be base 24

let counter_of_offset ~base j = Int64.add (counter base) j

let seed_of_offset ~base j =
  let tail = Bytes.create 8 in
  Bytes.set_int64_be tail 0 (counter_of_offset ~base j) ;
  String.sub base 0 24 ^ Bytes.to_string tail

let confirm target ~base j =
  let seed = seed_of_offset ~base j in
  match Curve_ref.address Address.Tz1 seed with
  | Ok address when Target.matches target address -> Some (address, seed)
  | _ -> None
