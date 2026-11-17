# GPU protocol hasher — Sarek prototype

Throughput prototype for `specs/001-gpu-protocol-hasher`. Not the product:
one Blake2b compression per nonce, so it requires the 16 nonce digits to sit
in the final 128-byte block of the dump (true for `proto_to_hash.txt` and
`proto.txt` of the C hasher; `load_dump` refuses otherwise).

## How it works

- Host (`src/ref.ml`): Blake2b-256 chaining value over every block but the
  last, computed once; base58 intervals on the top 64 bits of
  `0x02aa || digest` for the target name (case-insensitive from the 3rd
  character, any 2nd character, as the C hasher).
- Device (`gen/gen_kernel.ml` → `src/blake_kernel.ml`, Sarek `[%kernel]`):
  nonce = 8 high digits (per launch, in the block template) + 6 middle
  digits (thread id, precomputed word patches) + 2 low digits (loops).
  Fully unrolled 12-round compression, binary search in the intervals,
  hits appended through a global atomic counter.
- Every device hit is re-hashed on the CPU with digestif on the full dump
  before being printed.

## Build & run

    opam switch create . ocaml-base-compiler.5.4.0     # local switch
    opam install dune ppxlib ctypes ctypes-foreign js_of_ocaml js_of_ocaml-ppx zarith digestif
    S=git+https://github.com/mathiasbourgoin/Sarek.git                # or the path of a local clone
    opam pin add -n spoc $S && opam pin add -n sarek $S && opam pin add -n sarek-cuda $S
    opam install spoc sarek sarek-cuda
    dune build

    P=./_build/default/bin/proto_bench.exe
    $P devices
    $P hash  <dump> <16-digit nonce>                       # protocol hash
    $P check <dump> <name> <CUDA/PTX|CUDA/C|Native> <high> <nthreads>
    $P bench <dump> <name> <framework> <seconds> [nthreads]

`check` runs one launch and compares the raw device hits with the OCaml
reference over the same nonces (must be identical).

## Results (2026-11-17, RTX 5070 Ti, Ryzen 7 5700X3D 8C/16T)

| Implementation | Mnonces/s |
|---|---|
| C hasher, 16 processes | 3.76 |
| OCaml reference, 1 thread | 0.42 |
| Sarek Native (CPU, 16 threads) | 14.9 |
| Sarek CUDA/C (NVRTC) | 4 984 |
| Sarek CUDA/PTX | 5 091 |

Correctness: hashes match the C hasher on 5 reference pairs (2 dumps);
`check` agrees with the reference on 10^6 nonces for CUDA/PTX, CUDA/C (both
dumps) and 10^5 for Native; all hits confirmed by digestif.
