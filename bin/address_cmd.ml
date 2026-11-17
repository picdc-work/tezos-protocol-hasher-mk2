(* octez-vanity-gpu --address SCHEME NAME: see contracts/cli.md *)

open Octez_vanity
open Cli_common

type options = {
  scheme : string;
  case_sensitive : bool;
  cpu : bool;
  max_matches : int option;
  timeout : float option;
  device : string list;
  start : int option;
  count : int option;
  instance : string option;
  progress : float option;
  key_dir : string option;
  base_key_file : string option;
}

let parse_scheme = function
  | "tz2" -> Ok Address.Tz2
  | "tz3" -> Ok Address.Tz3
  | "tz4" -> Ok Address.Tz4
  | s -> fail 2 "--address %S: unsupported scheme (supported: tz2, tz3, tz4)" s

let check_ranges_allowed o =
  if o.base_key_file <> None || (o.start = None && o.count = None && o.instance = None) then Ok ()
  else
    fail 2
      "--start, --count and --instance need --base-key-file (without it every run draws a fresh \
       base key, so a range means nothing)"

let range_of o =
  let n = Offset_space.n_chunks in
  let* first_chunk =
    match o.start with
    | Some s when s < 0 || s >= n -> fail 2 "--start %d: expected a chunk in [0, 2^44)" s
    | Some s -> Ok s
    | None -> Ok 0
  in
  let* count =
    match o.count with
    | Some c when c < 1 || c > n -> fail 2 "--count %d: expected 1 to 2^44 chunks" c
    | Some c -> Ok c
    | None -> Ok n
  in
  let range = {Offset_space.first_chunk; count} in
  match o.instance with
  | None -> Ok range
  | Some s -> (
      match Nonce_space.parse_instance s with
      | Ok (i, k) -> Ok (Offset_space.slice range ~instance:i ~of_:k)
      | Error e -> fail 2 "%s" e)

let check_key_dir key_dir =
  let dir = Option.value key_dir ~default:"." in
  if not (try Sys.is_directory dir with Sys_error _ -> false) then
    fail 2 "--key-dir %S: not a directory" dir
  else
    match Octez_vanity.Key_files.check_writable_dir dir with
    | Ok () -> Ok dir
    | Error e -> fail 2 "key directory %S is not writable: %s" dir e

(* The base scalar: from the file (created on first use), or fresh. *)
let base_scalar scheme o =
  let* curve = Result.map_error (fun e -> error "%s" e ; 2) (Walk_keys.curve_of scheme) in
  match o.base_key_file with
  | None -> Ok (Walk_keys.random_scalar curve)
  | Some path -> (
      match Key_files.load_or_create_base curve path with
      | Ok k0 -> Ok k0
      | Error e -> fail 2 "--base-key-file: %s" e)

let child_args ~name ~key_dir o =
  let opt flag = function Some v -> [flag; v] | None -> [] in
  [name; "--address"; o.scheme; "--key-dir"; key_dir]
  @ opt "--base-key-file" o.base_key_file
  @ (if o.case_sensitive then ["--case-sensitive"] else [])
  @ opt "--timeout" (Option.map string_of_float o.timeout)
  @ opt "--max-matches" (Option.map string_of_int o.max_matches)
  @ match o.progress with Some p -> ["--progress=" ^ string_of_float p] | None -> []

let run o args =
  let* scheme = parse_scheme o.scheme in
  let* name =
    match args with
    | [name] -> Ok name
    | _ -> fail 2 "usage: octez-vanity-gpu --address %s [OPTIONS] NAME" o.scheme
  in
  let case_mode = if o.case_sensitive then Target.Sensitive else Target.Insensitive in
  let* target =
    match Target.make ~kind:(Address.target_kind scheme) ~case_mode name with
    | Ok t -> Ok t
    | Error e -> fail 2 "%s" e
  in
  let* () = check_ranges_allowed o in
  let* range = range_of o in
  let* key_dir = check_key_dir o.key_dir in
  let* devices = select_devices ~cpu:o.cpu ~device:o.device in
  let* k0 = base_scalar scheme o in
  match devices with
  | [(_, device)] ->
      Search.install_signal_handlers () ;
      let outcome =
        Address_search.run ?max_matches:o.max_matches ?timeout:o.timeout ?progress:o.progress ~scheme
          ~target ~device ~k0 ~range ~key_dir ~out:stdout ~err:stderr ()
      in
      Ok (Address_search.exit_code outcome.reason)
  | devices ->
      Ok
        (Multi_device.run ~slice:Offset_space.slice ~slices:(o.base_key_file <> None)
           ~exe:Sys.executable_name ~common_args:(child_args ~name ~key_dir o) ~devices ~range
           ~max_matches:o.max_matches ())
