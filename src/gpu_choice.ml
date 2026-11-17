type 'a candidate = {item : 'a; framework : string; integrated : bool}

let preference = ["CUDA/PTX"; "CUDA/C"; "HIP"]

let discrete_first l =
  match List.find_opt (fun c -> not c.integrated) l with
  | Some c -> Some c
  | None -> ( match l with c :: _ -> Some c | [] -> None)

let best cands =
  discrete_first
    (List.concat_map (fun fw -> List.filter (fun c -> c.framework = fw) cands) preference)

let first_of_framework fw cands = discrete_first (List.filter (fun c -> c.framework = fw) cands)

let all_gpus cands =
  let gpus = List.filter (fun c -> List.mem c.framework ["CUDA/PTX"; "HIP"]) cands in
  match List.filter (fun c -> not c.integrated) gpus with [] -> gpus | l -> l
