type layout_case = A | B | C

type t = {
  path : string;
  data : Bytes.t;
  length : int;
  digits_offset : int;
  final_block_length : int;
  final_block_offset : int;
  layout_case : layout_case;
  base_offset : int;
  base_state : int64 array;
}

let marker = "(* Vanity nonce: "

let tail = " *)\n"

let line_length = String.length marker + 16 + String.length tail

let case_name = function A -> "A" | B -> "B" | C -> "C"

let read path =
  match open_in_bin path with
  | exception Sys_error e -> Error e
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          match really_input_string ic (in_channel_length ic) with
          | s -> Ok (Bytes.unsafe_of_string s)
          | exception (Sys_error e | Failure e) -> Error (path ^ ": " ^ e))

(* The last line of the file, at most 60 characters (with "..." before). *)
let found data len =
  let n = min len 200 in
  let s = Bytes.sub_string data (len - n) n in
  let s =
    match String.rindex_from_opt s (max 0 (String.length s - 2)) '\n' with
    | Some i -> String.sub s (i + 1) (String.length s - i - 1)
    | None -> s
  in
  let k = String.length s in
  if k > 60 then "..." ^ String.sub s (k - 60) 60 else s

let is_digit c = c >= '0' && c <= '9'

let validate path data =
  let len = Bytes.length data in
  let ok =
    len >= line_length
    && Bytes.sub_string data (len - 4) 4 = tail
    && Bytes.sub_string data (len - line_length) (String.length marker) = marker
    && Bytes.for_all is_digit (Bytes.sub data (len - 20) 16)
  in
  if ok then Ok ()
  else
    Error
      (Printf.sprintf
         "%s: expected the dump to end with \"(* Vanity nonce: <16 digits> \
          *)\\n\" (found %S); set the nonce to 0000000000000000 before dumping"
         path (found data len))

let load path =
  match read path with
  | Error e -> Error e
  | Ok data -> (
      match validate path data with
      | Error e -> Error e
      | Ok () ->
          let length = Bytes.length data in
          let final_block_length = ((length - 1) mod 128) + 1 in
          let final_block_offset = length - final_block_length in
          let layout_case =
            if final_block_length >= 20 then A
            else if final_block_length >= 6 then B
            else C
          in
          let base_offset =
            match layout_case with
            | A -> final_block_offset
            | B | C -> final_block_offset - 128
          in
          let h = Blake2b.init () in
          for i = 0 to (base_offset / 128) - 1 do
            Blake2b.compress h
              (Blake2b.words_of_block data (i * 128) 128)
              ~t0:(Int64.of_int ((i + 1) * 128))
              ~last:false
          done ;
          Ok
            {
              path;
              data;
              length;
              digits_offset = length - 20;
              final_block_length;
              final_block_offset;
              layout_case;
              base_offset;
              base_state = h;
            })

let nonce_text n = Printf.sprintf "%016Ld" n

let tail_with_nonce d n =
  let b = Bytes.sub d.data d.base_offset (d.length - d.base_offset) in
  Bytes.blit_string (nonce_text n) 0 b (d.digits_offset - d.base_offset) 16 ;
  b

let with_nonce d n =
  let b = Bytes.copy d.data in
  Bytes.blit_string (nonce_text n) 0 b d.digits_offset 16 ;
  b

let blocks_with_nonce d n =
  let b = tail_with_nonce d n in
  let len = Bytes.length b in
  if len <= 128 then [Blake2b.words_of_block b 0 len]
  else [Blake2b.words_of_block b 0 128; Blake2b.words_of_block b 128 (len - 128)]

let digest d n =
  let h = Array.copy d.base_state in
  let blocks = blocks_with_nonce d n in
  let nb = List.length blocks in
  List.iteri
    (fun i m ->
      let last = i = nb - 1 in
      let t0 = if last then d.length else d.base_offset + (128 * (i + 1)) in
      Blake2b.compress h m ~t0:(Int64.of_int t0) ~last)
    blocks ;
  Blake2b.digest_of_state h

module B2 = Digestif.Make_BLAKE2B (struct
  let digest_size = 32
end)

let digest_full d n = B2.(to_raw_string (digest_bytes (with_nonce d n)))
