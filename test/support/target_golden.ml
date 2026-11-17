(* Renders the observable behaviour of protocol-hash targets on fixed inputs.
   Its output on the code of [main] is stored in
   test/vectors/target_protocol_golden.txt; the [target_golden] test suite
   compares the two, so that generalising [Target] cannot change
   protocol-hash targets unnoticed. *)

open Octez_vanity

let cases =
  [
    ("pa", Target.Insensitive);
    ("Pa", Target.Sensitive);
    ("ushuaia", Target.Insensitive);
    ("zzzzzzzzz", Target.Insensitive);
    ("zzzzzzzzz", Target.Sensitive);
    ("p", Target.Insensitive);
    ("PaRiS", Target.Insensitive);
    ("paris0", Target.Insensitive);
    ("abcdefghij", Target.Insensitive);
    ("Ix", Target.Sensitive);
    ("", Target.Insensitive);
  ]

(* 400 digests: 200 pseudo-random ones and, so that some match the short
   names, 200 more with small leading bytes. *)
let digests =
  List.init 400 (fun i ->
      let d = Blake2b.digest (string_of_int i) in
      if i < 200 then d
      else String.make 1 (Char.chr (i mod 7)) ^ String.sub d 1 31)

let hashes =
  [
    "PtSeouLouXkxhg39oWzjxDWaCydNfR3RxCUrNe4Q9Ro8BTehcbh";
    "PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY";
    "PsPAcJ9YB5LfW38eK1KxyTEYzJTNG52CEAbVmoHMH1qgPVjsRub";
    "PtPAUdsTY4dw2BmagkJ95pLjfL8bNUZ1X7GTgQDSE9vk5TfqcQe";
    "Pzzzzzzzzzz";
    "Pa";
    "";
  ]
  @ List.map Protocol_hash.of_digest digests

let mode_name = function Target.Insensitive -> "insensitive" | Sensitive -> "sensitive"

let bits f l = String.concat "" (List.map (fun x -> if f x then "1" else "0") l)

let render () =
  let b = Buffer.create 4096 in
  List.iter
    (fun (name, mode) ->
      Printf.bprintf b "case %S %s\n" name (mode_name mode) ;
      match Target.make ~case_mode:mode name with
      | Error e -> Printf.bprintf b "  error %S\n" e
      | Ok t ->
          Printf.bprintf b "  name %S\n" (Target.name t) ;
          Printf.bprintf b "  expected_rate %h\n" (Target.expected_rate t) ;
          Printf.bprintf b "  intervals %d\n" (Array.length (Target.intervals t)) ;
          Array.iter
            (fun (lo, hi) -> Printf.bprintf b "    %Lx %Lx\n" lo hi)
            (Target.intervals t) ;
          Printf.bprintf b "  matches %s\n" (bits (Target.matches t) hashes) ;
          Printf.bprintf b "  in_intervals %s\n"
            (bits (fun d -> Target.in_intervals t (Target.top64 d)) digests))
    cases ;
  Printf.bprintf b "top64 %s\n"
    (String.concat " " (List.map (fun d -> Printf.sprintf "%Lx" (Target.top64 d)) (List.filteri (fun i _ -> i < 8) digests))) ;
  Buffer.contents b
