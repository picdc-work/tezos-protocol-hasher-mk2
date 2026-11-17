(* octez-vanity-gpu: see specs/001-gpu-protocol-hasher/contracts/cli.md *)

open Octez_vanity
open Cmdliner

let error fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s)) fmt

let fail code fmt = Printf.ksprintf (fun s -> error "%s" s ; Error code) fmt

let ( let* ) = Result.bind

let load_dump path =
  match Dump.load path with Ok d -> Ok d | Error e -> fail 2 "%s" e

let gpu_or_cpu ~cpu =
  if cpu then Ok (Device_search.cpu_device ())
  else match Device_search.best_gpu () with Ok d -> Ok d | Error e -> fail 3 "%s" e

(* --- modes --- *)

let verify nonce = function
  | [dump] -> (
      let* dump = load_dump dump in
      match Verify.hash dump nonce with
      | Ok h ->
          print_endline h ;
          Ok 0
      | Error e -> fail 2 "%s" e)
  | _ -> fail 2 "usage: octez-vanity-gpu --verify NONCE DUMP"

let bench seconds ~cpu = function
  | [dump] ->
      let* dump = load_dump dump in
      let gpus =
        if cpu then []
        else match Device_search.best_gpu () with Ok d -> [d] | Error _ -> []
      in
      let devices = gpus @ [Device_search.cpu_device ()] in
      List.iter
        (fun (fw, name, rate) -> Printf.printf "%s %s %.0f\n%!" fw name rate)
        (Bench.run ~dump ~seconds devices) ;
      Ok 0
  | _ -> fail 2 "usage: octez-vanity-gpu --bench SECONDS DUMP"

let search ~case_sensitive ~cpu ~max_matches ~timeout args =
  let* dump, name, seed =
    match args with
    | [dump; name] -> Ok (dump, name, None)
    | [dump; name; seed] -> (
        match int_of_string_opt seed with
        | Some s when s >= 0 -> Ok (dump, name, Some s)
        | _ -> fail 2 "SEED %S: expected a non-negative integer" seed)
    | _ -> fail 2 "usage: octez-vanity-gpu [OPTIONS] DUMP NAME [SEED]"
  in
  let case_mode = if case_sensitive then Target.Sensitive else Target.Insensitive in
  let* target = match Target.make ~case_mode name with Ok t -> Ok t | Error e -> fail 2 "%s" e in
  let* dump = load_dump dump in
  let* device = gpu_or_cpu ~cpu in
  let first_chunk = match seed with Some s -> Nonce_space.start_of_seed s | None -> 0 in
  let range = Nonce_space.full ~first_chunk in
  Search.install_signal_handlers () ;
  let o =
    Search.run ?max_matches ?timeout ~dump ~target ~device ~range ~out:stdout ~err:stderr ()
  in
  Ok (Search.exit_code o.reason)

let main args verify_nonce bench_seconds case_sensitive cpu max_matches timeout =
  let r =
    match (verify_nonce, bench_seconds) with
    | Some n, _ -> verify n args
    | None, Some s -> bench s ~cpu args
    | None, None -> search ~case_sensitive ~cpu ~max_matches ~timeout args
  in
  match r with Ok c | Error c -> c

(* --- arguments --- *)

let args =
  Arg.(value & pos_all string [] & info [] ~docv:"DUMP NAME [SEED]"
         ~doc:"Protocol dump (octez-protocol-compiler -dump-only), target name (1 to 9 base58 characters), optional seed selecting the starting chunk.")

let verify_nonce =
  Arg.(value & opt (some string) None & info ["verify"] ~docv:"NONCE"
         ~doc:"Print the protocol hash of DUMP with this 16-digit nonce.")

let bench_seconds =
  Arg.(value & opt (some float) None & info ["bench"] ~docv:"SECONDS"
         ~doc:"Measure nonces/s on the GPU and on the CPU backend.")

let case_sensitive =
  Arg.(value & flag & info ["case-sensitive"] ~doc:"Exact comparison instead of case-insensitive.")

let cpu = Arg.(value & flag & info ["cpu"] ~doc:"Use the CPU backend (Native).")

let max_matches =
  Arg.(value & opt (some int) None & info ["max-matches"] ~docv:"K" ~doc:"Stop after K matches.")

let timeout =
  Arg.(value & opt (some float) None & info ["timeout"] ~docv:"SECONDS" ~doc:"Stop after SECONDS.")

let cmd =
  let doc = "GPU vanity nonce search for Tezos protocol hashes" in
  Cmd.v
    (Cmd.info "octez-vanity-gpu" ~doc ~exits:[])
    Term.(
      const main $ args $ verify_nonce $ bench_seconds $ case_sensitive $ cpu $ max_matches
      $ timeout)

let () =
  let c = Cmd.eval' cmd in
  exit (if c = Cmd.Exit.cli_error then 2 else c)
