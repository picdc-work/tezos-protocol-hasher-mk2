module Device = Spoc_core.Device
module Vector = Spoc_core.Vector
module Transfer = Spoc_core.Transfer
module Execute = Sarek.Execute
let k =
  [%kernel
    fun (inp : int64 vector) (out : int64 vector) ->
      let open Sarek_stdlib.Std in
      let x = inp.(0) in
      let z = x - x in
      out.(0) <- z lor 0x3FFFFFFFFFFFFFFFL ;
      out.(1) <- z lor 4611686018427387904L ;
      out.(2) <- z lor 0x02aa000000000000L ;
      out.(3) <- z + 4294967296L ;
      out.(4) <- z + 0x123456789L ;
      out.(5) <- z lor (-4294967296L) ;
      out.(6) <- 0x02aa000000000000L]
let () =
  Sarek_native.Native_plugin.init () ; Sarek_cuda.Cuda_plugin.init () ;
  let devs = Device.init () in
  let _, kirc = k in
  let ir = match kirc.Sarek.Kirc_types.body_ir with Some ir -> ir | None -> assert false in
  let x = 0xF123456789ABCDEFL in
  Array.iter (fun d ->
    if d.Device.framework = "Native" || d.Device.framework = "CUDA/PTX" then begin
      let inp = Vector.create Vector.int64 1 and out = Vector.create Vector.int64 7 in
      Vector.set inp 0 x;
      Execute.run_vectors ~device:d ~ir ~args:Execute.[Vec inp; Vec out] ~block:(Execute.dims1d 1) ~grid:(Execute.dims1d 1) ();
      Transfer.flush d;
      Printf.printf "%-9s" d.Device.framework;
      for i = 0 to 6 do Printf.printf " %016Lx" (Vector.get out i) done; print_newline () end) devs;
  print_endline "expected  3fffffffffffffff 4000000000000000 02aa000000000000 0000000100000000 0000000123456789 ffffffff00000000 02aa000000000000"
