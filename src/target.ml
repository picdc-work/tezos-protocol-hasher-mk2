type case_mode = Insensitive | Sensitive

type t = {
  name : string;
  case_mode : case_mode;
  intervals : (int64 * int64) array;
}

let name t = t.name

let case_mode t = t.case_mode

let intervals t = t.intervals

let alphabet = Protocol_hash.alphabet

let alphabet_chars = List.init (String.length alphabet) (String.get alphabet)

let variants case_mode c =
  match case_mode with
  | Sensitive -> if String.contains alphabet c then [c] else []
  | Insensitive -> List.filter (fun a -> Char.lowercase_ascii a = c) alphabet_chars

let valid_set = "1-9, A-H, J-N, P-Z, a-k, m-z"

(* Interval arithmetic on N = 0x02aa ‖ digest ‖ checksum (38 bytes). *)
let total_bits = 38 * 8

let nmin = Z.shift_left (Z.of_int 0x02aa) (total_bits - 16)

let nmax = Z.pred (Z.shift_left (Z.of_int 0x02ab) (total_bits - 16))

let ndigits = String.length (Protocol_hash.b58_encode_z nmin)

let () = assert (ndigits = String.length (Protocol_hash.b58_encode_z nmax))

let p58 k = Z.pow (Z.of_int 58) k

let index c = String.index alphabet c

let compute_intervals case_mode name =
  let rec combos = function
    | [] -> [""]
    | c :: rest ->
        let tails = combos rest in
        List.concat_map
          (fun v -> List.map (fun t -> String.make 1 v ^ t) tails)
          (variants case_mode c)
  in
  let names = combos (List.init (String.length name) (String.get name)) in
  let acc = ref [] in
  List.iter
    (fun second ->
      List.iter
        (fun v ->
          let pre = "P" ^ String.make 1 second ^ v in
          let k = String.length pre in
          let lo = ref Z.zero in
          String.iteri
            (fun i c ->
              lo := Z.add !lo (Z.mul (Z.of_int (index c)) (p58 (ndigits - 1 - i))))
            pre ;
          let hi = Z.pred (Z.add !lo (p58 (ndigits - k))) in
          let lo = Z.max !lo nmin and hi = Z.min hi nmax in
          if Z.leq lo hi then
            acc :=
              ( Z.to_int64 (Z.shift_right lo (total_bits - 64)),
                Z.to_int64 (Z.shift_right hi (total_bits - 64)) )
              :: !acc)
        names)
    alphabet_chars ;
  let rec merge = function
    | (a, b) :: (c, d) :: rest when c <= Int64.succ b ->
        merge ((a, Int64.max b d) :: rest)
    | x :: rest -> x :: merge rest
    | [] -> []
  in
  Array.of_list (merge (List.sort compare !acc))

let make ?(case_mode = Insensitive) raw =
  let name = match case_mode with Insensitive -> String.lowercase_ascii raw | Sensitive -> raw in
  let len = String.length name in
  if len < 1 || len > 9 then
    Error (Printf.sprintf "target %S: the name must have 1 to 9 characters" raw)
  else
    let bad =
      List.sort_uniq compare
        (List.filter
           (fun c -> variants case_mode c = [])
           (List.init len (String.get name)))
    in
    let bad =
      (* report characters as the user typed them *)
      match case_mode with
      | Sensitive -> bad
      | Insensitive ->
          List.sort_uniq compare
            (List.filter
               (fun c -> List.mem (Char.lowercase_ascii c) bad)
               (List.init len (String.get raw)))
    in
    match bad with
    | [] -> Ok {name; case_mode; intervals = compute_intervals case_mode name}
    | _ ->
        let quoted = String.concat ", " (List.map (Printf.sprintf "'%c'") bad) in
        Error
          (Printf.sprintf "target %S: %s %s cannot appear in a base58 hash (valid: %s)"
             raw
             (if List.length bad = 1 then "character" else "characters")
             quoted valid_set)

let matches t hash =
  let n = String.length t.name in
  String.length hash >= n + 2
  &&
  let s = String.sub hash 2 n in
  match t.case_mode with
  | Insensitive -> String.lowercase_ascii s = t.name
  | Sensitive -> s = t.name

let top64 d =
  let b i = Int64.of_int (Char.code d.[i]) in
  let ( |: ) = Int64.logor and ( <<: ) = Int64.shift_left in
  0x02aa000000000000L |: (b 0 <<: 40) |: (b 1 <<: 32) |: (b 2 <<: 24)
  |: (b 3 <<: 16) |: (b 4 <<: 8) |: b 5

let in_intervals t x =
  let iv = t.intervals in
  let rec go lo hi =
    (* first index with fst > x, in [lo, hi) *)
    if lo >= hi then lo
    else
      let mid = (lo + hi) / 2 in
      if fst iv.(mid) <= x then go (mid + 1) hi else go lo mid
  in
  let i = go 0 (Array.length iv) - 1 in
  i >= 0 && x <= snd iv.(i)

let expected_rate t =
  let covered =
    Array.fold_left
      (fun acc (lo, hi) -> acc +. Int64.to_float (Int64.sub hi lo) +. 1.)
      0. t.intervals
  in
  if covered = 0. then infinity else 2. ** 48. /. covered
