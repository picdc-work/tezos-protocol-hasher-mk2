open Octez_vanity

(* --- pure selection rules, with fake devices --- *)

let c ?(integrated = false) item framework = {Gpu_choice.item; framework; integrated}

let items l = List.map (fun c -> c.Gpu_choice.item) l

let item = Option.map (fun c -> c.Gpu_choice.item)

let check_item msg expected got = Alcotest.(check (option string)) msg expected (item got)

(* The RX 7900 XTX machine of the AMD report: discrete HIP device 0,
   integrated Ryzen GPU as HIP device 1, Native CPU. *)
let amd_box = [c "xtx" "HIP"; c ~integrated:true "igpu" "HIP"; c "cpu" "Native"]

let pure_best () =
  check_item "discrete HIP" (Some "xtx") (Gpu_choice.best amd_box) ;
  check_item "discrete HIP even when listed after the integrated one" (Some "xtx")
    (Gpu_choice.best [c ~integrated:true "igpu" "HIP"; c "xtx" "HIP"]) ;
  check_item "integrated GPU when it is the only one" (Some "igpu")
    (Gpu_choice.best [c ~integrated:true "igpu" "HIP"; c "cpu" "Native"]) ;
  check_item "CUDA/PTX before HIP" (Some "ptx")
    (Gpu_choice.best [c "xtx" "HIP"; c "cudac" "CUDA/C"; c "ptx" "CUDA/PTX"]) ;
  check_item "discrete HIP before integrated CUDA" (Some "xtx")
    (Gpu_choice.best [c ~integrated:true "tegra" "CUDA/PTX"; c "xtx" "HIP"]) ;
  check_item "no GPU" None (Gpu_choice.best [c "cpu" "Native"])

let pure_all_gpus () =
  Alcotest.(check (list string)) "integrated GPU left out" ["xtx"] (items (Gpu_choice.all_gpus amd_box)) ;
  Alcotest.(check (list string))
    "CUDA/C aliases left out, list order kept" ["ptx"; "xtx"]
    (items (Gpu_choice.all_gpus [c "ptx" "CUDA/PTX"; c "cudac" "CUDA/C"; c "xtx" "HIP"])) ;
  Alcotest.(check (list string))
    "only integrated GPUs: all of them" ["igpu"]
    (items (Gpu_choice.all_gpus [c ~integrated:true "igpu" "HIP"; c "cpu" "Native"])) ;
  Alcotest.(check (list string)) "no GPU" [] (items (Gpu_choice.all_gpus [c "cpu" "Native"]))

let pure_framework () =
  check_item "first discrete HIP" (Some "xtx")
    (Gpu_choice.first_of_framework "HIP" [c ~integrated:true "igpu" "HIP"; c "xtx" "HIP"]) ;
  check_item "first device otherwise" (Some "igpu")
    (Gpu_choice.first_of_framework "HIP" [c ~integrated:true "igpu" "HIP"]) ;
  check_item "unknown framework" None (Gpu_choice.first_of_framework "Metal" amd_box)

(* --- the same rules on the devices of this machine --- *)

let devices () = Array.to_list (Device_search.devices ())

let hip_selection () =
  let hips = List.filter (fun d -> Device_search.framework d = "HIP") (devices ()) in
  if hips = [] then Alcotest.skip () ;
  List.iter (fun d -> Alcotest.(check bool) "HIP is a GPU backend" true (Device_search.is_gpu d)) hips ;
  let discrete = List.filter (fun d -> not (Device_search.is_integrated d)) hips in
  let expected = match discrete with d :: _ -> d | [] -> List.hd hips in
  Alcotest.(check bool)
    "framework selection returns the first discrete HIP device" true
    (match Device_search.select "HIP" with Ok [(_, d)] -> d == expected | _ -> false) ;
  let gpus = Result.get_ok (Device_search.select "all-gpus") |> List.map snd in
  Alcotest.(check bool)
    "all-gpus has only CUDA/PTX and HIP devices" true
    (List.for_all (fun d -> List.mem (Device_search.framework d) ["HIP"; "CUDA/PTX"]) gpus) ;
  List.iter
    (fun d ->
      let in_all = List.exists (fun g -> g == d) gpus in
      if Device_search.is_integrated d && discrete <> [] then
        Alcotest.(check bool) "integrated HIP device left out" false in_all
      else Alcotest.(check bool) "HIP device included" true in_all)
    hips

let priority () =
  let expected =
    Gpu_choice.best
      (List.map
         (fun d ->
           {Gpu_choice.item = d; framework = Device_search.framework d;
            integrated = Device_search.is_integrated d})
         (devices ()))
  in
  match (expected, Device_search.best_gpu ()) with
  | None, Error _ -> ()
  | Some e, Ok got -> Alcotest.(check bool) "GPU preference" true (got == e.item)
  | _ -> Alcotest.fail "best_gpu disagrees with Gpu_choice.best"

let tests =
  ( "devices",
    [
      Alcotest.test_case "best GPU rule" `Quick pure_best;
      Alcotest.test_case "all-gpus rule" `Quick pure_all_gpus;
      Alcotest.test_case "framework rule" `Quick pure_framework;
      Alcotest.test_case "HIP selection and all-gpus" `Quick hip_selection;
      Alcotest.test_case "GPU backend preference" `Quick priority;
    ] )
