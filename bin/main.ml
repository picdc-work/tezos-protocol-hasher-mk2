(* octez-vanity-gpu: see specs/001-gpu-protocol-hasher/contracts/cli.md *)

open Octez_vanity
open Cmdliner

open Cli_common

let load_dump path =
  match Dump.load path with Ok d -> Ok d | Error e -> fail 2 "%s" e

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

let range_of ~seed ~start ~count ~instance =
  let n = Nonce_space.n_chunks in
  let* first_chunk =
    match start with
    | Some s when s < 0 || s >= n -> fail 2 "--start %d: expected a chunk in [0, 10^8)" s
    | Some s -> Ok s
    | None -> Ok (match seed with Some s -> Nonce_space.start_of_seed s | None -> 0)
  in
  let* count =
    match count with
    | Some c when c < 1 || c > n -> fail 2 "--count %d: expected 1 to 10^8 chunks" c
    | Some c -> Ok c
    | None -> Ok n
  in
  let range = {Nonce_space.first_chunk; count} in
  match instance with
  | None -> Ok range
  | Some s -> (
      match Nonce_space.parse_instance s with
      | Ok (i, k) -> Ok (Nonce_space.slice range ~instance:i ~of_:k)
      | Error e -> fail 2 "%s" e)

let bench seconds ~cpu ~device = function
  | [dump] ->
      let* dump = load_dump dump in
      let* selected =
        match (cpu, device) with
        | false, [] ->
            (* Preserve the CPU-only benchmark when no GPU is available. *)
            Ok (match Device_search.best_gpu () with Ok d -> [d] | Error _ -> [])
        | _ ->
            let* selected = select_devices ~cpu ~device in
            Ok (List.map snd selected)
      in
      let cpu_device = Device_search.cpu_device () in
      let devices =
        if List.exists (fun d -> Device_search.framework d = "Native") selected
        then selected
        else selected @ [cpu_device]
      in
      List.iter
        (fun (fw, name, rate) -> Printf.printf "%s %s %.0f\n%!" fw name rate)
        (Bench.run ~dump ~seconds devices) ;
      Ok 0
  | _ -> fail 2 "usage: octez-vanity-gpu --bench SECONDS DUMP"

let search ~case_sensitive ~cpu ~max_matches ~timeout ~device ~start ~count ~instance ~progress args =
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
  let* dump_t = load_dump dump in
  let* range = range_of ~seed ~start ~count ~instance in
  let* devices = select_devices ~cpu ~device in
  match devices with
  | [(_, device)] ->
      Search.install_signal_handlers () ;
      let o =
        Search.run ?max_matches ?timeout ?progress ~dump:dump_t ~target ~device ~range
          ~out:stdout ~err:stderr ()
      in
      Ok (Search.exit_code o.reason)
  | devices ->
      let opt name = function Some v -> [name; v] | None -> [] in
      let common_args =
        [dump; name]
        @ (if case_sensitive then ["--case-sensitive"] else [])
        @ opt "--timeout" (Option.map string_of_float timeout)
        @ opt "--max-matches" (Option.map string_of_int max_matches)
        @ match progress with Some p -> ["--progress=" ^ string_of_float p] | None -> []
      in
      Ok
        (Multi_device.run ~exe:Sys.executable_name ~common_args ~devices ~range ~max_matches ())

let list_devices () =
  List.iter (fun (i, fw, name) -> Printf.printf "%d %s %s\n" i fw name) (Device_search.list_devices ()) ;
  Ok 0

let address_only_options ~key_dir ~base_key_file =
  match (key_dir, base_key_file) with
  | Some _, _ -> fail 2 "--key-dir only applies with --address"
  | _, Some _ -> fail 2 "--base-key-file only applies with --address"
  | None, None -> Ok ()

let main args verify_nonce bench_seconds case_sensitive cpu max_matches timeout list device start
    count instance progress address key_dir base_key_file =
  let r =
    if list then list_devices ()
    else
      match (address, verify_nonce, bench_seconds) with
      | Some _, Some _, _ -> fail 2 "--verify works on protocol hashes only: it cannot be used with --address"
      | Some _, _, Some _ -> fail 2 "--bench works on protocol hashes only: it cannot be used with --address"
      | Some scheme, None, None ->
          Address_cmd.run
            {scheme; case_sensitive; cpu; max_matches; timeout; device; start; count; instance;
             progress; key_dir; base_key_file}
            args
      | None, _, _ -> (
          match address_only_options ~key_dir ~base_key_file with
          | Error _ as e -> e
          | Ok () -> (
              match (verify_nonce, bench_seconds) with
              | Some n, _ -> verify n args
              | None, Some s -> bench s ~cpu ~device args
              | None, None ->
                  search ~case_sensitive ~cpu ~max_matches ~timeout ~device ~start ~count
                    ~instance ~progress args))
  in
  match r with Ok c | Error c -> c

(* --- arguments --- *)

let args =
  Arg.(value & pos_all string [] & info [] ~docv:"DUMP NAME [SEED]"
         ~doc:"Protocol dump (octez-protocol-compiler -dump-only), target name (1 to 9 base58 characters), optional seed selecting the starting chunk. With $(b,--address): the target name alone.")

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

let list = Arg.(value & flag & info ["list-devices"] ~doc:"List the compute devices.")

let device =
  Arg.(value & opt_all string [] & info ["device"] ~docv:"D"
         ~doc:"Device index, framework name, or $(b,all-gpus); repeatable.")

let start =
  Arg.(value & opt (some int) None & info ["start"] ~docv:"CHUNK" ~doc:"First chunk, in [0, 10^8). Overrides SEED.")

let count =
  Arg.(value & opt (some int) None & info ["count"] ~docv:"CHUNKS" ~doc:"Number of chunks to search.")

let instance =
  Arg.(value & opt (some string) None & info ["instance"] ~docv:"I/N" ~doc:"Search only slice I of N of the range.")

let progress =
  Arg.(value & opt ~vopt:(Some 10.) (some float) None & info ["progress"] ~docv:"SECONDS"
         ~doc:"Progress records on stderr every SECONDS seconds (default 10).")

let address =
  Arg.(value & opt (some string) None & info ["address"] ~docv:"SCHEME"
         ~doc:"Search an address vanity key instead of a protocol hash: SCHEME is $(b,tz1) (Ed25519, the key is the 32-byte seed, $(b,edsk...)), $(b,tz2) (secp256k1), $(b,tz3) (P-256) or $(b,tz4) (BLS12-381, minimal public key variant) and the only positional argument is NAME, matched right after the scheme prefix. The secret key goes to $(b,ADDRESS.key) (mode 0600) in $(b,--key-dir); stdout gets $(b,ADDRESS PATH).")

let key_dir =
  Arg.(value & opt (some string) None & info ["key-dir"] ~docv:"DIR"
         ~doc:"With $(b,--address): directory of the key files (default: the current directory).")

let base_key_file =
  Arg.(value & opt (some string) None & info ["base-key-file"] ~docv:"FILE"
         ~doc:"With $(b,--address): file holding the secret base scalar (64 hexadecimal characters, mode 0600), created on first use. Needed by $(b,--start), $(b,--count) and $(b,--instance).")

let cmd =
  let doc = "GPU vanity nonce search for Tezos protocol hashes" in
  Cmd.v
    (Cmd.info "octez-vanity-gpu" ~doc ~exits:[])
    Term.(
      const main $ args $ verify_nonce $ bench_seconds $ case_sensitive $ cpu $ max_matches
      $ timeout $ list $ device $ start $ count $ instance $ progress $ address $ key_dir
      $ base_key_file)

let () =
  let c = Cmd.eval' cmd in
  exit (if c = Cmd.Exit.cli_error then 2 else c)
