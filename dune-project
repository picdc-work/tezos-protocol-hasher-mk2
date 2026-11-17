(lang dune 3.15)

(cram enable)

(generate_opam_files true)

(name octez-vanity-gpu)

(package
 (name octez-vanity-gpu)
 (synopsis "GPU vanity nonce search for Tezos protocol hashes")
 (description
  "Drop-in GPU replacement for the CPU vanity hasher used in Tezos protocol releases, written with the Sarek GPU DSL.")
 (depends
  (ocaml (>= 5.4.0))
  spoc
  sarek
  sarek-cuda
  digestif
  zarith
  cmdliner
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))
