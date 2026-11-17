(* octez-vanity-gpu: see specs/001-gpu-protocol-hasher/contracts/cli.md *)

open Octez_vanity
open Cmdliner

let error fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s)) fmt

let load_dump path =
  match Dump.load path with
  | Ok d -> Ok d
  | Error e ->
      error "%s" e ;
      Error 2

let ( let* ) = Result.bind

let search ~dump ~name ~seed ~case_sensitive ~cpu ~max_matches ~timeout =
  let case_mode = if case_sensitive then Target.Sensitive else Target.Insensitive in
  let* target =
    match Target.make ~case_mode name with
    | Ok t -> Ok t
    | Error e ->
        error "%s" e ;
        Error 2
  in
  let* dump = load_dump dump in
  let* device =
    if cpu then Ok (Device_search.cpu_device ())
    else
      match Device_search.best_gpu () with
      | Ok d -> Ok d
      | Error e ->
          error "%s" e ;
          Error 3
  in
  let first_chunk = match seed with Some s -> Nonce_space.start_of_seed s | None -> 0 in
  let range = Nonce_space.full ~first_chunk in
  Search.install_signal_handlers () ;
  let o =
    Search.run ?max_matches ?timeout ~dump ~target ~device ~range ~out:stdout ~err:stderr ()
  in
  Ok (Search.exit_code o.reason)

let main dump name seed case_sensitive cpu max_matches timeout =
  let r =
    match (dump, name) with
    | Some dump, Some name ->
        search ~dump ~name ~seed ~case_sensitive ~cpu ~max_matches ~timeout
    | _ ->
        error "expected DUMP NAME [SEED]" ;
        Error 2
  in
  match r with Ok c | Error c -> c

let dump_arg =
  Arg.(value & pos 0 (some string) None & info [] ~docv:"DUMP" ~doc:"Protocol dump (octez-protocol-compiler -dump-only).")

let name_arg =
  Arg.(value & pos 1 (some string) None & info [] ~docv:"NAME" ~doc:"Target, 1 to 9 base58 characters.")

let seed_arg =
  Arg.(value & pos 2 (some int) None & info [] ~docv:"SEED" ~doc:"Selects the starting chunk.")

let case_sensitive =
  Arg.(value & flag & info ["case-sensitive"] ~doc:"Exact comparison instead of case-insensitive.")

let cpu = Arg.(value & flag & info ["cpu"] ~doc:"Search on the CPU backend (Native).")

let max_matches =
  Arg.(value & opt (some int) None & info ["max-matches"] ~docv:"K" ~doc:"Stop after K matches.")

let timeout =
  Arg.(value & opt (some float) None & info ["timeout"] ~docv:"SECONDS" ~doc:"Stop after SECONDS.")

let cmd =
  let doc = "GPU vanity nonce search for Tezos protocol hashes" in
  Cmd.v
    (Cmd.info "octez-vanity-gpu" ~doc ~exits:[])
    Term.(const main $ dump_arg $ name_arg $ seed_arg $ case_sensitive $ cpu $ max_matches $ timeout)

let () =
  let c = Cmd.eval' cmd in
  exit (if c = Cmd.Exit.cli_error then 2 else c)
