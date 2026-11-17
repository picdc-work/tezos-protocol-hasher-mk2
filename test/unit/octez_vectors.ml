(* Octez key encodings, from test/vectors/octez_key_encodings.txt. *)

type t = {
  scheme : string;  (* "tz1" .. "tz4" *)
  address : string;
  public_key : string;  (* base58 *)
  secret_key : string;  (* base58 *)
}

(* [dune test] runs in _build/default/test/unit; [dune exec] in the root. *)
let path = Fixtures.vector_path "octez_key_encodings.txt"

let load () =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | exception End_of_file -> close_in ic ; List.rev acc
    | line when line = "" || line.[0] = '#' -> go acc
    | line -> (
        match String.split_on_char ' ' line with
        | [scheme; address; public_key; secret_key] ->
            go ({scheme; address; public_key; secret_key} :: acc)
        | _ -> failwith ("bad vector line: " ^ line))
  in
  go []

let of_scheme scheme = List.filter (fun v -> v.scheme = scheme) (load ())

let hex s =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let of_hex h = String.init (String.length h / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

(* Decode [s] and check it starts with [prefix]; return what follows. *)
let strip ~prefix s =
  let raw = B58_decode.decode s in
  let n = String.length prefix in
  if String.sub raw 0 n <> prefix then failwith ("unexpected prefix in " ^ s) ;
  String.sub raw n (String.length raw - n)
