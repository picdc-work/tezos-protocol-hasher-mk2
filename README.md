# octez-vanity-gpu

GPU vanity nonce search for Tezos protocol hashes on NVIDIA CUDA and AMD HIP. It is a drop-in replacement for the CPU [tezos-protocol-hasher](https://github.com/mathiasbourgoin/tezos-protocol-hasher) used during protocol releases. It is written in OCaml, and its GPU kernels use the [Sarek](https://github.com/mathiasbourgoin/Sarek) DSL.

Given the dump produced by `octez-protocol-compiler -dump-only`, it searches the 10^16 values of the 16-digit `(* Vanity nonce: … *)` for protocol hashes whose characters, from the 3rd on, spell a name. Every result is checked on the host before it is printed.

## Use in a protocol release

`scripts/proto_manager.sh` dumps the protocol to `proto_to_hash.txt` and suggests a command for the C hasher. Use this instead:

```sh
octez-vanity-gpu proto_to_hash.txt <label>
# PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY 0822971470637657
```

The output format is the C hasher's: `<hash> <16 digits>`, one line per match. Paste a nonce back into the script, which recomputes the hash with `octez-protocol-compiler -hash-only`. The suggested `seq 1 8 | parallel … <hasher> proto_to_hash.txt <label>` form also works, with each SEED selecting a different starting chunk, but a single process is enough on one GPU.

## Step by step: dump a protocol, then find a hash prefix

These steps do by hand what `proto_manager.sh` does. They run from the root of a tezos/tezos checkout, with `P` set to the protocol's `lib_protocol` directory, for example `P=src/proto_alpha/lib_protocol`. They modify `main.ml` and `TEZOS_PROTOCOL`, so work on a branch or in a worktree.

**1. Set the nonce to a placeholder.** The last line of `$P/main.ml` is the nonce comment. It must hold exactly 16 digits, because the hash covers the length of the file. Replace whatever is there (`TBD` or an older nonce) with zeros:

```sh
sed -i 's/(\* Vanity nonce: .* \*)/(* Vanity nonce: 0000000000000000 *)/' $P/main.ml
tail -1 $P/main.ml          # (* Vanity nonce: 0000000000000000 *)
```

**2. Dump the protocol.** This writes the exact bytes whose Blake2b digest is the protocol hash. `main.ml` comes last, so the file ends with the nonce line:

```sh
./octez-protocol-compiler -dump-only $P > proto_to_hash.txt
tail -c 38 proto_to_hash.txt    # (* Vanity nonce: 0000000000000000 *)
```

The compiler must be built from the same checkout as the protocol. An older binary fails with `unexpected environment version`; rebuild it with `make octez-protocol-compiler`.

**3. Search.** Every hash starts with `P`, and its second character depends on the hash prefix (`r`, `s`, `t`…), so you cannot choose it. The name is therefore matched from the **3rd character** on. The comparison ignores case unless you pass `--case-sensitive`. The name can have 1 to 9 base58 characters; `0`, `O`, `I` and `l` cannot appear in a hash.

```sh
octez-vanity-gpu proto_to_hash.txt tezos --max-matches 3
# PsteZoSCYmXQSR1bU87CCnPqrx4Yv6tyBKh5tE19c22QQxjvmCC 0000000001738972
# PsTeZossQKNfGdHQhTZRuYTFJZrNaxbvnKh7Y3zNyyvor3cTV4s 0000000113530637
# PrtEZosnBmTP6zgYMewqzjvPQog3cTEbMN6VQrdJqfK7ZonwrYR 0000000148427169
```

At start-up, stderr shows the expected number of candidates per match and, after the first launches, the estimated time per match. Each extra character costs about 29 times more in the default mode. On an RTX 5070 Ti, a 5-character name takes about a second (mostly start-up), 7 characters about 10 seconds, and 9 characters about an hour and a half. For a long search, add `--progress`. If you stop it, restart with `--start <next_chunk>`, where `next_chunk` is given by the last `stopped …` line, to continue where it stopped.

**4. Put the chosen nonce in `main.ml` and check the hash.** `octez-protocol-compiler -hash-only` must print exactly the hash printed by the search:

```sh
nonce=0000000001738972
sed -i "s/(\* Vanity nonce: [0-9]\{16\} \*)/(* Vanity nonce: $nonce *)/" $P/main.ml
./octez-protocol-compiler -hash-only $P
# PsteZoSCYmXQSR1bU87CCnPqrx4Yv6tyBKh5tE19c22QQxjvmCC
```

`octez-vanity-gpu --verify $nonce proto_to_hash.txt` gives the same hash without touching `main.ml`.

**5. Record the hash in `TEZOS_PROTOCOL`.** The protocol does not compile while the stored hash differs from the computed one:

```sh
h=$(./octez-protocol-compiler -hash-only $P)
sed -i "s/\"hash\": \"[^\"]*\"/\"hash\": \"$h\"/" $P/TEZOS_PROTOCOL
```

The rest of a release (renaming `proto_<N>` to `proto_<N>_<short hash>`, updating references) is done by `scripts/proto_manager.sh`.

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
| `--address tz1 NAME`, `--address tz2 NAME`, `--address tz3 NAME`, `--address tz4 NAME` | Address vanity: find an Ed25519 (tz1), secp256k1 (tz2), P-256 (tz3) or BLS12-381 (tz4) key whose address is `tz1NAME`, `tz2NAME`, `tz3NAME` or `tz4NAME` (see [Address vanity](#address-vanity)). `NAME` is the only positional argument. Not with `--verify` or `--bench`. |
| `--key-dir DIR` | With `--address`: where key files go (default: the current directory). |
| `--base-key-file FILE` | With `--address`: file holding the secret base key, created on first use. Needed by `--start`, `--count` and `--instance`, which then count chunks of 2^20 key offsets, in `[0, 2^44)`. |

Diagnostics go to stderr. The last line is always `stopped reason=… next_chunk=… tested=… matches=…`. To resume a stopped search, use `--start <next_chunk>` with the remaining `--count`.

Exit status: 0 on success, 2 for invalid input, 3 for no device or a device error, 4 when a key file cannot be written (address vanity), 130 when interrupted.

On AMD with ROCm/HIP installed, use `--device HIP` (or select an index from
`--list-devices`). Automatic selection prefers CUDA/PTX, then CUDA/C, then HIP,
and discrete GPUs before integrated ones. `--device all-gpus` includes discrete
HIP GPUs as well as CUDA/PTX devices; an integrated GPU (marked `[integrated]`
by `--list-devices`) is only used when selected by its index or when it is the
only GPU. This build
does not register OpenCL, Vulkan or Metal backends.

The full contract is in [specs/001-gpu-protocol-hasher/contracts/cli.md](specs/001-gpu-protocol-hasher/contracts/cli.md).

## Address vanity

```sh
octez-vanity-gpu --address tz1 tezos --max-matches 1
# tz1... ./tz1....key (the secret key starts with edsk: the 32-byte seed)
octez-vanity-gpu --address tz2 tezos --max-matches 1
# tz2... ./tz2....key
octez-vanity-gpu --address tz3 tezos --max-matches 1
# tz3... ./tz3....key (the secret key starts with p2sk)
octez-vanity-gpu --address tz4 tezos --max-matches 1
# tz4... ./tz4....key (the secret key starts with BLsk)
```

This looks for an Ed25519 (`tz1`, secret key `edsk...`, the 32-byte seed Octez stores), secp256k1 (`tz2`, secret key `spsk...`), P-256 (`tz3`, secret key `p2sk...`) or BLS12-381 (`tz4`, secret key `BLsk...`, minimal public key variant: the public key is a point of G1) secret key whose Tezos address is the scheme followed by `NAME` (1 to 8 base58 characters, case-insensitive unless `--case-sensitive`; give only the part after `tz1`, `tz2`, `tz3` or `tz4`). tz2, tz3 and tz4 share one walk, generated for each curve; tz1 works differently (below). For tz4 the field has 14 limbs of 28 bits, the hashed public key is the 48-byte ZCash form (`x` big-endian, flag bit `0x80`, and `0x20` when `y > (p-1)/2`), and the 32 secret bytes are the scalar little-endian (big-endian for tz2 and tz3). The options `--max-matches`, `--timeout`, `--progress`, `--device`, `--cpu` and `--list-devices` work as for protocol hashes.

How it works. The host draws a secret base scalar `k0` and computes `P0 = k0·G`. Offset `j` stands for the key `k0 + j` and the public point `P0 + j·G`. The device walks the points `P0 + j·G` for `2^20` consecutive offsets per launch, hashes each compressed public key and keeps those whose address prefix is in the target's intervals. For each hit, the host computes the key `k0 + j mod n` (`n` is the group order of the curve), derives the address with its own reference code, and checks it against the target. Only then does it write anything.

tz1 (Ed25519). An Octez Ed25519 secret is a seed, from which the signing scalar is derived by SHA-512 and clamping (RFC 8032, 5.1.5), so walking `P0 + j·G` would give scalars with no known seed. Each candidate is therefore a seed. The base is 32 bytes from `/dev/urandom`; the seed of offset `j` is the first 24 bytes of the base followed by the 64-bit big-endian value `u + j mod 2^64`, `u` being the last 8 bytes of the base read big-endian. The device computes, per seed: SHA-512 (one block), the clamped scalar, the public point by a fixed-base multiplication with a precomputed table (windows of 8 bits, 32 windows of 256 entries `(y+x, y-x, 2dxy)` in Montgomery limbs, 1.9 MB, one inlined mixed addition in extended coordinates per window), affine coordinates by one batched inversion per thread, the 32-byte encoding, Blake2b-20 and the prefilter. A hit is confirmed on the host with `Curve_ref` and written as `edsk...`. A launch is 4096 threads times 16 seeds (65 536 seeds); a chunk of `2^20` offsets is 16 launches, with interruption, `--timeout` and `--max-matches` checked between launches (a chunk stopped part-way is not counted as covered). Measured on the Native backend (32 cores): 0.25 to 0.32 million seeds/s (window width 8 is 1.9 times faster than 4; the generated kernel module builds in about 9 s). The base-key file holds the base as 64 hexadecimal characters, any value is valid (no range check).

What the device sees. For tz2, tz3 and tz4 the device only sees public points. For tz1 the device receives the base (the first three words of every seed and the counter), so it computes every candidate seed. This is accepted by the owner (decision of 2026-11-17). The base still never reaches stdout, stderr, a command line or an environment variable.

Where the secret goes:

- `k0` comes from `/dev/urandom` (redrawn until it is in `[1, n-1]`). It stays in the process: it is not passed to the device, printed, or put in a command line or an environment variable. The device sees public points only.
- For each confirmed match, the secret key is written in the Octez form (`spsk…`, one line) to `ADDRESS.key` in `--key-dir`. The file is created with mode 0600 and is never overwritten. If a file with that name already holds the same key (a range searched again), the match is reported on stderr as `already found` and is neither printed nor counted. If it holds anything else, the search stops with exit status 4. The key directory is checked to be writable before the search starts.
- stdout carries one line per match, `<address> <path of the key file>`. No secret appears on stdout or stderr, in any message.
- Encrypted keys and any use of the key (signing, importing) are out of scope: importing the key into a wallet is up to you.

The base-key file. Without `--base-key-file` every process draws its own `k0`, so a range of chunks would mean nothing: `--start`, `--count` and `--instance` are rejected. With `--base-key-file FILE`, `k0` is read from `FILE` (64 hexadecimal characters; refused if its mode is wider than 0600), or `FILE` is created with a fresh `k0` if it does not exist. The file is as secret as a key: anyone who has it and a match line can rebuild the key. With it, `--start`, `--count`, `--instance`, resuming from `next_chunk` and several devices behave as for protocol hashes, over `2^44` chunks of `2^20` offsets, and the same range gives the same addresses. Running a range again into a key directory that already holds its key files writes nothing: each key is reported on stderr as `already found`. With several devices and a base-key file, the child processes receive the path of the file, never its value. Without a base-key file, each child draws its own `k0`.

Caveats (the minor defects left open by the review are listed in [address-known-defects.md](specs/001-gpu-protocol-hasher/address-known-defects.md)):

- The batched point additions break if two points of a batch share an abscissa (the base point equal to plus or minus a table point). For a random `k0` that has a probability of about 2^-240 per batch. A base-key file written by hand with a scalar close to 0 or to the group order makes it certain for the batches that contain the point at infinity: do not choose `k0` by hand. The whole batch is then wrong, and since every hit is confirmed on the host, the effect is a missed batch, never a false result.
- With `--max-matches`, the chunk in progress is searched again on resume, as for protocol hashes. Here the resumed run finds the keys already written again, reports them as `already found` on stderr, and goes on to the next match, provided it uses the same key directory.
- A launch covers 4096 threads times 256 offsets (the best setting measured on the Native backend: 4.5 to 4.9 million offsets/s on 32 cores for tz2; tz4, with its 14-limb field, measured 2.9 to 3.7 million offsets/s with the same geometry, about 25 to 35 % lower). With a 1 or 2 character name, expect a very large output: one key file per match.
- On CUDA, measured on 2026-11-17 with an RTX 2080 Super Max-Q (CUDA/PTX backend, driver 615.71.09), over 30-second searches of a 5-character name, every address found being recomputed from its key file by independent libraries:

  | Scheme | Candidates/s | Against the Native backend above |
  |---|---|---|
  | tz1 | 7.0·10^6 | about 25× |
  | tz2 | 1.35·10^8 | about 28× |
  | tz3 | 1.47·10^8 | about 30× |
  | tz4 | 5.4·10^7 | about 16× |

  The Native figures come from another machine (32 cores), so the ratios are indicative; the tz3 ratio uses the tz2 Native figure, the two curves sharing the same walk and field size. The kernel checks against the host reference pass on that GPU (`OCTEZ_VANITY_TEST_DEVICE=CUDA/PTX dune test test/walk --force`). Nothing was tuned for CUDA: threads and batch are the values chosen on the Native backend.
- Searching on several devices at once has not been run: no machine with two GPUs was available.
- The default key directory is the current directory, and a short name matches very often: a 1-character name gives tens of thousands of key files per chunk. Use `--key-dir` and `--max-matches`.

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

The GPU assessment, including AMD trials that did not justify changing the
production kernels or launch defaults, is documented in
[gpu-optimization.md](specs/001-gpu-protocol-hasher/gpu-optimization.md).

## Build

Sarek is not in the opam repository. The package pins `spoc`, `sarek`, `sarek-cuda` and `sarek-hip` to a fixed commit of [its git repository](https://github.com/mathiasbourgoin/Sarek) (`pin-depends` in `octez-vanity-gpu.opam.template`), so no local clone is needed:

```sh
opam switch create . ocaml-base-compiler.5.4.0 --no-install
eval $(opam env --switch=. --set-switch)
opam install . --deps-only --with-test -y
dune build            # binary: _build/default/bin/main.exe (installed as octez-vanity-gpu)
```

To build against a local Sarek checkout instead, pin it before the `opam install` step: `for p in spoc sarek sarek-cuda sarek-hip; do opam pin add -n -y $p <path to Sarek>; done`.

The test dependency `bls12-381` (an oracle for the host reference, linked by the tests only) requires `zarith < 1.14`, so installing with `--with-test` caps Zarith at 1.13; the library itself uses nothing from a later Zarith.

## Tests

```sh
dune test                                      # unit, layouts 1..128, walk kernel, CLI cram tests (~2 min)
dune exec test/equivalence.exe                 # device == reference, every kernel and backend
dune exec test/equivalence.exe -- --whole-chunks 2      # selected GPU == Native on 2·10^8 nonces
dune exec test/equivalence.exe -- --reference-chunk     # selected GPU == reference on 10^8 nonces (~2 min)
```

Some ground truth lives outside the repository and is found through two environment variables, which have no default:

- `HASHER_REF_DIR`: a checkout of the C hasher, with its `proto.txt` and `proto_to_hash.txt` dumps;
- `TEZOS_DIR`: a tezos/tezos checkout with a built `octez-protocol-compiler`, from which the released protocols are dumped.

Tests that need these files skip when the variable is unset or the files are missing.

## Layout

- `gen/gen_kernel.ml` generates `src/kernels.ml`: three fully unrolled Blake2b kernels.
- `src/`: library `octez_vanity` (`dump`, `blake2b`, `protocol_hash`, `target`, `nonce_space`, `device_search`, `search`, `multi_device`, `verify`, `bench`).
- `gen/gen_ed25519.ml` (with `gen/sha512_emit.ml`) generates the tz1 seed-search kernel `src/seed_ed25519.ml`; `src/seed_run.ml` runs it, `src/seed_table.ml` builds its table, `src/seed_keys.ml` has the seeds and the host confirmation. `src/address_search.ml` runs either engine (walk or seeds).
- `gen/gen_walk.ml` generates the walk kernel of the address search (`src/walk_secp256k1.ml` for tz2, `src/walk_p256.ml` for tz3, `src/walk_bls12_381.ml` for tz4), from the field arithmetic of `gen/gen_field.ml`; `src/walk_run.ml` runs it, `src/address_search.ml` is the search loop, `src/key_files.ml` writes the key files and reads the base-key file, `src/walk_keys.ml` has the key arithmetic and the host confirmation, `src/offset_space.ml` the ranges.
- `bin/main.ml`: the command-line interface; `bin/address_cmd.ml`: its `--address` mode.
- `specs/001-gpu-protocol-hasher/`: spec, plan, research, data model, contract, tasks.
- `prototype/`: the throughput prototype that validated the approach ([prototype/README.md](prototype/README.md)).
