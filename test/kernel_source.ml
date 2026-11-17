(* Export generated source for offline inspection; no device is initialised. *)
open Octez_vanity

let () =
  match Array.to_list Sys.argv with
  | [ _; layout; backend ] ->
      let _, kernel =
        match layout with
        | "a" -> Kernels.search_a
        | "b" -> Kernels.search_b
        | "c" -> Kernels.search_c
        | _ -> invalid_arg "layout must be a, b or c"
      in
      let ir = Option.get kernel.Sarek.Kirc_types.body_ir in
      let source =
        match backend with
        | "ptx" -> Sarek_codegen.Sarek_ir_ptx.generate ~block:(256, 1, 1) ir
        | "cuda" ->
            Sarek_codegen.Sarek_ir_cuda.generate_with_types ~block:(256, 1, 1)
              ~types:ir.kern_types ir
        | _ -> invalid_arg "backend must be ptx or cuda"
      in
      print_string source
  | _ ->
      prerr_endline "usage: kernel_source.exe <a|b|c> <ptx|cuda>";
      exit 2
