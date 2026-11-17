let ( let* ) = Result.bind

let describe_unix = function
  | Unix.Unix_error (e, _, _) -> Unix.error_message e
  | e -> Printexc.to_string e

(* Creates [path] (it must not exist) with mode 0600 and writes [line]. *)
let create_private path line =
  match Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 with
  | exception e -> Error (Printf.sprintf "%s: %s" path (describe_unix e))
  | fd -> (
      let result =
        try
          let bytes = Bytes.of_string line in
          if Unix.write fd bytes 0 (Bytes.length bytes) = Bytes.length bytes then Ok ()
          else Error (Printf.sprintf "%s: short write" path)
        with e -> Error (Printf.sprintf "%s: %s" path (describe_unix e))
      in
      Unix.close fd ;
      match result with
      | Ok () -> Ok ()
      | Error _ as e ->
          (try Unix.unlink path with Unix.Unix_error _ -> ()) ;
          e)

type written = New of string | Existing of string

(* True if [path] is a regular file whose content is exactly [line]. The
   comparison reads at most one byte more than [line]. *)
let holds path line =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> false
  | {st_kind = Unix.S_REG; _} -> (
      match
        In_channel.with_open_bin path (fun ic ->
            In_channel.really_input_string ic (String.length line)
            |> Option.map (fun s -> (s, In_channel.input_char ic)))
      with
      | exception Sys_error _ -> false
      | Some (s, None) -> String.equal s line
      | _ -> false)
  | _ -> false

let write_key ~dir ~address scheme ~secret =
  let path = Filename.concat dir (address ^ ".key") in
  let* encoded = Address.secret_key scheme secret in
  let line = encoded ^ "\n" in
  match create_private path line with
  | Ok () -> Ok (New path)
  | Error _ when holds path line -> Ok (Existing path)
  | Error e -> Error e

let check_writable_dir dir =
  let probe = Filename.concat dir (Printf.sprintf ".octez-vanity-probe-%d" (Unix.getpid ())) in
  let* () = create_private probe "" in
  (try Unix.unlink probe with Unix.Unix_error _ -> ()) ;
  Ok ()

let is_hex = function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false

let hex_of_bytes s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let hex_to_bytes h =
  String.init (String.length h / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub h (2 * i) 2)))

let parse_base_key (curve : Curve_ref.curve) content =
  let text = String.trim content in
  if String.length text <> 64 || not (String.for_all is_hex text) then
    Error "expected 64 hexadecimal characters"
  else
    let k = Z.of_string_base 16 text in
    if Z.sign k > 0 && Z.lt k curve.n then Ok k else Error "the scalar is not in [1, n-1]"

let check_base_mode mode =
  if mode land lnot 0o600 <> 0 then
    Error (Printf.sprintf "mode %04o is wider than 0600 (run chmod 600)" (mode land 0o7777))
  else Ok ()

let read_base parse path =
  match Unix.stat path with
  | exception e -> Error (Printf.sprintf "%s: %s" path (describe_unix e))
  | {st_kind = Unix.S_REG; st_perm; _} -> (
      let* () = Result.map_error (Printf.sprintf "%s: %s" path) (check_base_mode st_perm) in
      match In_channel.with_open_bin path In_channel.input_all with
      | exception Sys_error e -> Error e
      | content -> Result.map_error (Printf.sprintf "%s: %s" path) (parse content))
  | _ -> Error (Printf.sprintf "%s: not a regular file" path)

(* The base of [path] through [parse]; if the file does not exist, creates it
   with [fresh ()], written as [line]. *)
let load_or_create ~parse ~fresh ~line path =
  if Sys.file_exists path then read_base parse path
  else
    let base = fresh () in
    match create_private path (line base) with
    | Ok () -> Ok base
    | Error _ when Sys.file_exists path -> read_base parse path (* created meanwhile *)
    | Error e -> Error e

let load_or_create_base curve path =
  load_or_create ~parse:(parse_base_key curve)
    ~fresh:(fun () -> Walk_keys.random_scalar curve)
    ~line:(fun k0 -> Z.format "%064x" k0 ^ "\n")
    path

let parse_seed_base content =
  let text = String.trim content in
  if String.length text <> 64 || not (String.for_all is_hex text) then
    Error "expected 64 hexadecimal characters"
  else Ok (hex_to_bytes text)

let load_or_create_seed_base path =
  load_or_create ~parse:parse_seed_base ~fresh:Seed_keys.random_base
    ~line:(fun base -> hex_of_bytes base ^ "\n")
    path
