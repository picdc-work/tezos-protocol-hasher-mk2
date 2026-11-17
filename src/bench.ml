let run ~dump ~seconds devices =
  let target =
    match Target.make ~case_mode:Target.Sensitive "zzzzzzzzz" with
    | Ok t -> t
    | Error e -> failwith e
  in
  List.map
    (fun dev ->
      let ctx = Device_search.prepare dev dump target in
      ignore (Device_search.run_chunk ctx ~chunk:0) ;
      let t0 = Unix.gettimeofday () in
      let n = ref 0 in
      while !n = 0 || Unix.gettimeofday () -. t0 < seconds do
        incr n ;
        ignore (Device_search.run_chunk ctx ~chunk:!n)
      done ;
      let dt = Unix.gettimeofday () -. t0 in
      ( Device_search.framework dev,
        Device_search.name dev,
        float (!n * Nonce_space.chunk_size) /. dt ))
    devices
