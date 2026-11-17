type case_mode = Insensitive | Sensitive

type kind = {
  fixed : string;
  free : int;
  prefix : string;
  digest_length : int;
  max_name : int;
  noun : string;
  strict : bool;
}

type t = {
  kind : kind;
  name : string;
  case_mode : case_mode;
  intervals : (int64 * int64) array;
}

let make_kind ~fixed ~free ~prefix ~digest_length ~max_name ~noun ~strict =
  if String.length prefix >= 8 || digest_length < 8 - String.length prefix then
    invalid_arg "Target.make_kind: top64 must be made of the prefix and the digest" ;
  {fixed; free; prefix; digest_length; max_name; noun; strict}

let protocol_hash =
  make_kind ~fixed:"P" ~free:1 ~prefix:Protocol_hash.prefix ~digest_length:32 ~max_name:9
    ~noun:"hash" ~strict:false

let kind t = t.kind

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

(* Interval arithmetic on N = prefix ‖ digest ‖ checksum, as an integer of
   [total_bits] bits; for a protocol hash 0x02aa ‖ digest ‖ checksum. *)
let total_bits k = (String.length k.prefix + k.digest_length + 4) * 8

let prefix_bits k = 8 * String.length k.prefix

let prefix_z k = Base58.z_of_be k.prefix

let nmin k = Z.shift_left (prefix_z k) (total_bits k - prefix_bits k)

let nmax k = Z.pred (Z.shift_left (Z.succ (prefix_z k)) (total_bits k - prefix_bits k))

let ndigits k =
  let n = String.length (Base58.encode_z (nmin k)) in
  assert (n = String.length (Base58.encode_z (nmax k))) ;
  n

(* Position of the first character of the name. *)
let name_start k = String.length k.fixed + k.free

let p58 k = Z.pow (Z.of_int 58) k

let index c = String.index alphabet c

(* Every string of [n] characters of the alphabet. *)
let rec free_strings n =
  if n = 0 then [""]
  else
    let tails = free_strings (n - 1) in
    List.concat_map (fun c -> List.map (fun t -> String.make 1 c ^ t) tails) alphabet_chars

let compute_intervals k case_mode name =
  let rec combos = function
    | [] -> [""]
    | c :: rest ->
        let tails = combos rest in
        List.concat_map
          (fun v -> List.map (fun t -> String.make 1 v ^ t) tails)
          (variants case_mode c)
  in
  let names = combos (List.init (String.length name) (String.get name)) in
  let digits = ndigits k and nmin = nmin k and nmax = nmax k in
  let shift = total_bits k - 64 in
  let acc = ref [] in
  List.iter
    (fun free ->
      List.iter
        (fun v ->
          let pre = k.fixed ^ free ^ v in
          let len = String.length pre in
          let lo = ref Z.zero in
          String.iteri
            (fun i c -> lo := Z.add !lo (Z.mul (Z.of_int (index c)) (p58 (digits - 1 - i))))
            pre ;
          let hi = Z.pred (Z.add !lo (p58 (digits - len))) in
          let lo = Z.max !lo nmin and hi = Z.min hi nmax in
          if Z.leq lo hi then
            acc :=
              (Z.to_int64 (Z.shift_right lo shift), Z.to_int64 (Z.shift_right hi shift))
              :: !acc)
        names)
    (free_strings k.free) ;
  let rec merge = function
    | (a, b) :: (c, d) :: rest when c <= Int64.succ b ->
        merge ((a, Int64.max b d) :: rest)
    | x :: rest -> x :: merge rest
    | [] -> []
  in
  Array.of_list (merge (List.sort compare !acc))

let first_chars kind =
  String.concat ""
    (List.filter_map
       (fun c ->
         let s = String.make 1 c in
         if compute_intervals kind Sensitive s <> [||] then Some s else None)
       alphabet_chars)

let starts_with ~prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

(* Characters of [name] that no string of the kind can carry, as typed. *)
let invalid_chars case_mode name raw =
  let bad =
    List.sort_uniq compare
      (List.filter (fun c -> variants case_mode c = []) (List.init (String.length name) (String.get name)))
  in
  match case_mode with
  | Sensitive -> bad
  | Insensitive ->
      (* report characters as the user typed them *)
      List.sort_uniq compare
        (List.filter
           (fun c -> List.mem (Char.lowercase_ascii c) bad)
           (List.init (String.length raw) (String.get raw)))

let unreachable kind case_mode raw name =
  let reachable = first_chars kind in
  let first_ok = List.exists (String.contains reachable) (variants case_mode name.[0]) in
  if first_ok then
    Printf.sprintf "target %S: no %s with this name exists after %s (reachable first characters: %s)"
      raw kind.noun kind.fixed reachable
  else
    Printf.sprintf "target %S: the first character '%c' cannot follow %s (reachable: %s)" raw
      raw.[0] kind.fixed reachable

let make ?(kind = protocol_hash) ?(case_mode = Insensitive) raw =
  let name = match case_mode with Insensitive -> String.lowercase_ascii raw | Sensitive -> raw in
  let len = String.length name in
  if len < 1 || len > kind.max_name then
    Error
      (Printf.sprintf "target %S: the name must have 1 to %d characters" raw kind.max_name)
  else
    match invalid_chars case_mode name raw with
    | _ :: _ as bad ->
        let quoted = String.concat ", " (List.map (Printf.sprintf "'%c'") bad) in
        Error
          (Printf.sprintf "target %S: %s %s cannot appear in a base58 %s (valid: %s)" raw
             (if List.length bad = 1 then "character" else "characters")
             quoted kind.noun valid_set)
    | [] when kind.strict && starts_with ~prefix:kind.fixed name ->
        Error
          (Printf.sprintf "target %S: give only the part after %s" raw kind.fixed)
    | [] -> (
        let intervals = compute_intervals kind case_mode name in
        if kind.strict && intervals = [||] then Error (unreachable kind case_mode raw name)
        else Ok {kind; name; case_mode; intervals})

let matches t hash =
  let n = String.length t.name in
  let start = name_start t.kind in
  String.length hash >= n + start
  &&
  let s = String.sub hash start n in
  match t.case_mode with
  | Insensitive -> String.lowercase_ascii s = t.name
  | Sensitive -> s = t.name

(* [prefix ‖ digest] truncated to 64 bits. *)
let top64_of kind d =
  if String.length d <> kind.digest_length then
    invalid_arg
      (Printf.sprintf "Target.top64_of: expected a %d-byte digest, got %d" kind.digest_length
         (String.length d)) ;
  let plen = String.length kind.prefix in
  let head = kind.prefix ^ String.sub d 0 (8 - plen) in
  String.fold_left
    (fun acc c -> Int64.logor (Int64.shift_left acc 8) (Int64.of_int (Char.code c)))
    0L head

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
  if covered = 0. then infinity else 2. ** float_of_int (64 - prefix_bits t.kind) /. covered
