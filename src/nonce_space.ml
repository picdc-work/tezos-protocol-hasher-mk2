let chunk_size = 100_000_000

let n_chunks = 100_000_000

let text n = Printf.sprintf "%016Ld" n

let chunk n = Int64.to_int (Int64.div n 100_000_000L)

let thread n = Int64.to_int (Int64.rem (Int64.div n 100L) 1_000_000L)

let loop n = Int64.to_int (Int64.rem n 100L)

let make ~chunk ~thread ~loop =
  Int64.(add (mul (of_int chunk) 100_000_000L) (of_int ((thread * 100) + loop)))

let start_of_seed seed =
  let d = Blake2b.digest (string_of_int seed) in
  let x = Int64.logand (String.get_int64_le d 0) Int64.max_int in
  Int64.to_int (Int64.rem x (Int64.of_int n_chunks))

type range = {first_chunk : int; count : int}

let full ~first_chunk = {first_chunk; count = n_chunks}

let nth_chunk r i = (r.first_chunk + i) mod n_chunks

let chunks r = Seq.init r.count (nth_chunk r)

let slice r ~instance ~of_ =
  let start i = r.count * i / of_ in
  let a = start instance and b = start (instance + 1) in
  {first_chunk = nth_chunk r a; count = b - a}

let resume r ~next_chunk =
  let done_ = (next_chunk - r.first_chunk + n_chunks) mod n_chunks in
  let done_ = if done_ > r.count then r.count else done_ in
  {first_chunk = next_chunk; count = r.count - done_}

let parse_instance s =
  match String.split_on_char '/' s with
  | [i; n] -> (
      match (int_of_string_opt i, int_of_string_opt n) with
      | Some i, Some n when n >= 1 && i >= 0 && i < n -> Ok (i, n)
      | _ -> Error (Printf.sprintf "--instance %S: expected I/N with 0 <= I < N" s))
  | _ -> Error (Printf.sprintf "--instance %S: expected I/N with 0 <= I < N" s)
