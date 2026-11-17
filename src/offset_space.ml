let chunk_bits = 20

let chunk_size = 1 lsl chunk_bits

let n_chunks = 1 lsl 44

type range = Nonce_space.range = {first_chunk : int; count : int}

let full ~first_chunk = {first_chunk; count = n_chunks}

let nth_chunk r i = (r.first_chunk + i) mod n_chunks

let slice r ~instance ~of_ =
  let start i = r.count * i / of_ in
  let a = start instance and b = start (instance + 1) in
  {first_chunk = nth_chunk r a; count = b - a}

let offset ~chunk ~index = Int64.add (Int64.shift_left (Int64.of_int chunk) chunk_bits) (Int64.of_int index)
