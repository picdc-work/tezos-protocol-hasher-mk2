# octez-vanity-gpu

GPU vanity nonce search for Tezos protocol hashes. It is a drop-in replacement for the CPU [tezos-protocol-hasher](https://github.com/mathiasbourgoin/tezos-protocol-hasher) used during protocol releases. It is written in OCaml, and its GPU kernels use the [Sarek](https://github.com/mathiasbourgoin/Sarek) DSL.

Given the dump produced by `octez-protocol-compiler -dump-only`, it searches the 10^16 values of the 16-digit `(* Vanity nonce: … *)` for protocol hashes whose characters, from the 3rd on, spell a name. Every result is checked on the host before it is printed.

## Use in a protocol release

`scripts/proto_manager.sh` dumps the protocol to `proto_to_hash.txt` and suggests a command for the C hasher. Use this instead:

```sh
octez-vanity-gpu proto_to_hash.txt <label>
# PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY 0822971470637657
```

The output format is the C hasher's: `<hash> <16 digits>`, one line per match. Paste a nonce back into the script, which recomputes the hash with `octez-protocol-compiler -hash-only`. The suggested `seq 1 8 | parallel … <hasher> proto_to_hash.txt <label>` form also works, with each SEED selecting a different starting chunk, but a single process is enough on one GPU.

## Modes and options

| Command | Effect |
|---|---|
| `octez-vanity-gpu DUMP NAME [SEED]` | Search, on the best GPU by default. |
| `--case-sensitive` | Exact comparison. The default is case-insensitive, as in the C hasher. |
| `--max-matches K`, `--timeout S` | Stop conditions. |
| `--start C --count N`, `--instance I/N` | Search the chunks `[C, C+N)`, or slice `I` of `N`. A chunk is 10^8 nonces. |
| `--progress[=S]` | Progress records on stderr. |
| `--device D` (repeatable), `all-gpus`, `--cpu`, `--list-devices` | Device selection. Several devices run one process each. |
| `--verify NONCE DUMP` | Prints the hash for that nonce (digestif over the full dump). |
| `--bench S DUMP` | Nonces/s on the GPU and on the CPU backend. |

Diagnostics go to stderr. The last line is always `stopped reason=… next_chunk=… tested=… matches=…`. To resume a stopped search, use `--start <next_chunk>` with the remaining `--count`.

Exit status: 0 on success, 2 for invalid input, 3 for no device or a device error, 130 when interrupted.

The full contract is in [specs/001-gpu-protocol-hasher/contracts/cli.md](specs/001-gpu-protocol-hasher/contracts/cli.md).

## Performance

Measured on 2026-11-17 with an RTX 5070 Ti and a Ryzen 7 5700X3D (8 cores, 16 threads):

| Implementation | nonces/s | vs C hasher |
|---|---|---|
| C hasher, 16 processes | 3.75·10^6 | 1× |
| `--cpu` (Sarek Native backend, 16 threads) | 2.2·10^7 | 6× |
| GPU, dump layout case A (85 % of dumps) | 5.18·10^9 | 1,380× |
| GPU, case B (11 %) | 4.80–4.83·10^9 | 1,280× |
| GPU, case C (4 %, two compressions per nonce) | 2.41·10^9 | 640× |

A 7-character target (`ushuaia`) gives its first match in 2.5–10.5 s. A 9-character target takes about an hour and a half, against about three months with the C hasher on this machine.

The layout case depends on where the nonce falls relative to Blake2b's 128-byte blocks. See [research.md](specs/001-gpu-protocol-hasher/research.md), decision R2.

## Build

Sarek is not in the opam repository, so the build pins it from a clone at `~/dev/Sarek`:

```sh
opam switch create . ocaml-base-compiler.5.4.0 --no-install
eval $(opam env --switch=. --set-switch)
for p in spoc sarek sarek-cuda; do opam pin add -n -y $p ~/dev/Sarek; done
opam install . --deps-only --with-test -y
dune build            # binary: _build/default/bin/main.exe (installed as octez-vanity-gpu)
```

On the development machine, the root `_opam` is a link to the switch of `prototype/` (`opam switch link`).

## Tests

```sh
dune test                                      # unit, layouts 1..128, CLI cram tests (~2 min)
dune exec test/equivalence.exe                 # device == reference, every kernel and backend
dune exec test/equivalence.exe -- --whole-chunks 2      # CUDA == Native on 2·10^8 nonces
dune exec test/equivalence.exe -- --reference-chunk     # CUDA == reference on 10^8 nonces (~2 min)
```

Some ground truth lives outside the repository: the C hasher dumps and pairs (`$HASHER_REF_DIR`, default `~/dev/tezos-protocol-hasher`), and the released protocols dumped by `octez-protocol-compiler` (`$TEZOS_DIR`, default `~/dev/tezos`). Tests that need these files skip when they are missing.

## Layout

- `gen/gen_kernel.ml` generates `src/kernels.ml`: three fully unrolled Blake2b kernels.
- `src/`: library `octez_vanity` (`dump`, `blake2b`, `protocol_hash`, `target`, `nonce_space`, `device_search`, `search`, `multi_device`, `verify`, `bench`).
- `bin/main.ml`: the command-line interface.
- `specs/001-gpu-protocol-hasher/`: spec, plan, research, data model, contract, tasks.
- `prototype/`: the throughput prototype that validated the approach ([prototype/README.md](prototype/README.md)).
