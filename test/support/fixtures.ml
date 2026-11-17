(* Locating external ground truth for tests. Every test that needs a file
   outside the repository skips cleanly when it is absent. *)

let home () = Option.value (Sys.getenv_opt "HOME") ~default:"/nonexistent"

let env_or var default =
  match Sys.getenv_opt var with Some v when v <> "" -> v | _ -> default

let ref_dir () =
  env_or "HASHER_REF_DIR" (Filename.concat (home ()) "dev/tezos-protocol-hasher")

let tezos_dir () = env_or "TEZOS_DIR" (Filename.concat (home ()) "dev/tezos")

let skip_unless_exists path = if not (Sys.file_exists path) then Alcotest.skip ()

let cache_dir () =
  let d = Filename.concat (Filename.get_temp_dir_name ()) "octez-vanity-fixtures" in
  if not (Sys.file_exists d) then Sys.mkdir d 0o755 ;
  d

(* Dump [src/<name>/lib_protocol] of the tezos checkout with the protocol
   compiler, once, and return the cached path. Skips when unavailable. *)
let protocol_dump name =
  let compiler = Filename.concat (tezos_dir ()) "octez-protocol-compiler" in
  let dir = Filename.concat (tezos_dir ()) ("src/" ^ name ^ "/lib_protocol") in
  skip_unless_exists compiler ;
  skip_unless_exists dir ;
  let out = Filename.concat (cache_dir ()) (name ^ ".dump") in
  if not (Sys.file_exists out) then begin
    let tmp = out ^ ".tmp" in
    let cmd =
      Printf.sprintf "%s -dump-only %s > %s 2>/dev/null"
        (Filename.quote compiler) (Filename.quote dir) (Filename.quote tmp)
    in
    if Sys.command cmd <> 0 then Alcotest.skip () ;
    Sys.rename tmp out
  end ;
  out

(* (dump path, nonce, expected hash) from test/vectors/c_hasher_pairs.txt;
   dump names are resolved in [ref_dir ()]. *)
let c_hasher_pairs vectors_file =
  let ic = open_in vectors_file in
  let rec loop acc =
    match input_line ic with
    | line -> (
        match String.split_on_char ' ' (String.trim line) with
        | [dump; nonce; hash] ->
            loop ((Filename.concat (ref_dir ()) dump, nonce, hash) :: acc)
        | _ -> loop acc)
    | exception End_of_file ->
        close_in ic ;
        List.rev acc
  in
  loop []

(* Official hashes of released protocols, reproduced from their dumps. *)
let released =
  [
    ( "proto_023_PtSeouLo",
      "7130263421897740",
      "PtSeouLouXkxhg39oWzjxDWaCydNfR3RxCUrNe4Q9Ro8BTehcbh" );
    ( "proto_025_PsUshuai",
      "0822971470637657",
      "PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY" );
  ]
