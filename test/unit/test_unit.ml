let () =
  Alcotest.run "octez-vanity-gpu"
    [
      Test_blake2b.tests;
      Test_protocol_hash.tests;
      Test_dump.tests;
      Test_target.tests;
      Test_nonce_space.tests;
    ]
