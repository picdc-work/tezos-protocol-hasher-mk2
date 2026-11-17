let () =
  Alcotest.run "octez-vanity-gpu"
    [
      Test_blake2b.tests;
      Test_address.tests;
      Test_protocol_hash.tests;
      Test_dump.tests;
      Test_target.tests;
      Test_target_golden.tests;
      Test_target_address.tests;
      Test_curve_ref.tests;
      Test_nonce_space.tests;
      Test_verify.tests;
      Test_overflow.tests;
      Test_devices.tests;
    ]
