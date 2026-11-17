open Octez_vanity

let error fmt = Printf.ksprintf (fun s -> prerr_endline ("error: " ^ s)) fmt

let fail code fmt = Printf.ksprintf (fun s -> error "%s" s ; Error code) fmt

let ( let* ) = Result.bind

let select_devices ~cpu ~device =
  if cpu then Ok [(-1, Device_search.cpu_device ())]
  else
    match device with
    | [] -> (
        match Device_search.best_gpu () with Ok d -> Ok [(-1, d)] | Error e -> fail 3 "%s" e)
    | specs ->
        List.fold_left
          (fun acc spec ->
            let* acc = acc in
            match Device_search.select spec with
            | Ok l -> Ok (acc @ List.filter (fun (i, _) -> not (List.mem_assoc i acc)) l)
            | Error e -> fail 3 "%s" e)
          (Ok []) specs
