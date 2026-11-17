(* The generated kernels of the four fields, as IR ready to launch. *)

type kernels = {
  mul : Sarek_ir_types.kernel;
  add : Sarek_ir_types.kernel;
  sub : Sarek_ir_types.kernel;
  inv : Sarek_ir_types.kernel;
  batch_inv : Sarek_ir_types.kernel;
}

let ir = Field_run.ir_of

let spec name = List.find (fun s -> s.Field_run.name = name) Field_run.specs

let all =
  [
    ( spec "ed25519",
      {
        mul = ir Field_ed25519.mul;
        add = ir Field_ed25519.add;
        sub = ir Field_ed25519.sub;
        inv = ir Field_ed25519.inv;
        batch_inv = ir Field_ed25519.batch_inv;
      } );
    ( spec "secp256k1",
      {
        mul = ir Field_secp256k1.mul;
        add = ir Field_secp256k1.add;
        sub = ir Field_secp256k1.sub;
        inv = ir Field_secp256k1.inv;
        batch_inv = ir Field_secp256k1.batch_inv;
      } );
    ( spec "p256",
      {
        mul = ir Field_p256.mul;
        add = ir Field_p256.add;
        sub = ir Field_p256.sub;
        inv = ir Field_p256.inv;
        batch_inv = ir Field_p256.batch_inv;
      } );
    ( spec "bls12_381",
      {
        mul = ir Field_bls12_381.mul;
        add = ir Field_bls12_381.add;
        sub = ir Field_bls12_381.sub;
        inv = ir Field_bls12_381.inv;
        batch_inv = ir Field_bls12_381.batch_inv;
      } );
  ]
