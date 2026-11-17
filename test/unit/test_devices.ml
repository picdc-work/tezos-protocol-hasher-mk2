open Octez_vanity

let hip_selection () =
  let all = Array.to_list (Device_search.devices ()) in
  let hips = List.filter (fun d -> Device_search.framework d = "HIP") all in
  match hips with
  | [] -> Alcotest.skip ()
  | first :: _ ->
      List.iter
        (fun d ->
          Alcotest.(check bool)
            "HIP is a GPU backend" true (Device_search.is_gpu d))
        hips;
      let selected = Result.get_ok (Device_search.select "HIP") in
      Alcotest.(check bool)
        "framework selection returns first HIP device" true
        (match selected with [ (_, d) ] -> d == first | _ -> false);
      let gpus =
        Result.get_ok (Device_search.select "all-gpus") |> List.map snd
      in
      List.iter
        (fun d ->
          Alcotest.(check bool)
            "all-gpus includes each HIP device" true
            (List.exists (fun gpu -> gpu == d) gpus))
        hips;
      Alcotest.(check bool)
        "all-gpus excludes CPU and CUDA/C aliases" true
        (List.for_all
           (fun d -> List.mem (Device_search.framework d) [ "HIP"; "CUDA/PTX" ])
           gpus)

let priority () =
  let all = Array.to_list (Device_search.devices ()) in
  let expected =
    List.find_map
      (fun fw -> List.find_opt (fun d -> Device_search.framework d = fw) all)
      [ "CUDA/PTX"; "CUDA/C"; "HIP" ]
  in
  match (expected, Device_search.best_gpu ()) with
  | None, Error _ -> ()
  | Some expected, Ok got ->
      Alcotest.(check bool) "GPU preference" true (got == expected)
  | _ ->
      Alcotest.fail
        "GPU selection did not follow CUDA/PTX, CUDA/C, HIP preference"

let tests =
  ( "devices",
    [
      Alcotest.test_case "HIP selection and all-gpus" `Quick hip_selection;
      Alcotest.test_case "GPU backend preference" `Quick priority;
    ] )
