# Research: GPU-Accelerated Tezos Protocol Vanity Hasher

**Feature**: `specs/001-gpu-protocol-hasher` | **Date**: 2026-11-17

The sources for this research are the C hasher (`~/dev/tezos-protocol-hasher`), the tezos/tezos release tooling (`~/dev/tezos`: `scripts/proto_manager.sh`, `src/lib_protocol_compiler/compiler.ml`, `src/lib_base/protocol.ml`) and Sarek (`~/dev/Sarek`). They were checked with the throughput prototype in `prototype/`. Every decision below is settled; nothing is left as NEEDS CLARIFICATION.

## R1. What exactly is hashed

- **Decision**: the protocol hash is `base58check(0x02aa ‖ Blake2b-256(dump))`. The `dump` is the output of `octez-protocol-compiler -dump-only <dir>` (`Protocol.to_bytes`, i.e. the `Data_encoding` binary of the expected environment plus the list of components). The checksum is the first 4 bytes of `SHA-256(SHA-256(0x02aa ‖ digest))`. The nonce is the 16 digits that sit 20 bytes before the end of the dump (`… nonce: DDDDDDDDDDDDDDDD *)\n`).
- **Rationale**: this is `Protocol.hash = Protocol_hash.hash_bytes [to_bytes proto]` with the prefix `"\002\170"` (`src/lib_crypto/base58.ml`). `main.ml` is the last component and its last line is the nonce. Because the nonce has a fixed width, the length prefixes of the encoding do not depend on its value.
- **Verified**: the prototype reproduces the official hashes of `proto_023_PtSeouLo` and `proto_025_PsUshuai` from their dumps and real nonces. It also reproduces 5 (hash, nonce) pairs produced by the C hasher on 2 other dumps.

## R2. Cost per candidate: one compression, two in a few cases

- **Decision**: the host computes the Blake2b chaining value once, over all bytes that no candidate can change. The device then runs only the compressions that touch nonce digits. The 16 digits get three roles:
  - **launch digits**: the 8 most significant, fixed for one launch;
  - **thread digits**: the next 6, one value per thread;
  - **loop digits**: the last 2, iterated inside a thread.

  The bytes that come after the digits are always ` *)\n`. The final Blake2b block is the last `((L-1) mod 128) + 1` bytes. That gives three cases:

  | Case | When (final block length F) | Frequency (uniform L) | Device work per nonce |
  |---|---|---|---|
  | **A** | F ≥ 20: all 16 digits in the final block | 109/128 ≈ 85 % | 1 compression |
  | **B** | 6 ≤ F < 20: the boundary falls inside the launch or thread digits | 14/128 ≈ 11 % | 1 compression, plus 1 per thread for the next-to-last block (≈ 1.01 per nonce) |
  | **C** | F < 6: the loop digits are in the next-to-last block | 5/128 ≈ 4 % | 2 compressions |

  In case B, when every varying digit of the next-to-last block is a launch digit, the host compresses that block once per launch and the device falls back to case A.
- **Rationale**: Blake2b compresses 128-byte blocks, and the final block is the only one with the "last" flag. Sharing work at the thread and launch levels keeps case B at case A's speed. Case C runs at about half speed (≈ 2.5 G/s), which still meets SC-003 and SC-004.
- **Alternatives considered**:
  - A single generic kernel that always does two compressions: rejected, because it halves throughput in 85 % of cases.
  - Refusing dumps that are not in case A, as the prototype does: rejected, because FR-001 requires accepting any dump from the compiler.

## R3. GPU programming model with Sarek

- **Decision**:
  - Write the kernels with Sarek `[%kernel]`.
  - Generate their source at build time with an OCaml generator (`gen/`), one kernel per case of R2: fully unrolled straight-line code on `mut` int64 scalars.
  - Pass 64-bit constants (IV, folded `t0` and `f0`) through vectors.
  - Have the host precompute the byte patches of the thread digits, two `int64` words per thread id.
  - Collect hits with `atomic_add_global_int32`.
- **Rationale** (each point checked in the prototype):
  - The PTX emitter (the default CUDA path) drops `unroll` pragmas.
  - Indexing a private array at run time would spill to local memory.
  - The kernel language has no int32→int64 conversion.
  - `atomic_add_int32` only accepts shared or local arrays.
- **Measured**: 5.09 G nonces/s (CUDA/PTX) and 4.98 G nonces/s (CUDA/C) on an RTX 5070 Ti, against 3.76 M/s for the C hasher on 16 threads. That covers about 65 % of the device's 32-bit integer peak, so a hand-written CUDA kernel could gain about 1.3× at most. This is not worth leaving Sarek.
- **Alternatives considered**: hand-written CUDA or OpenCL via ctypes was rejected because the stakeholder requires Sarek and the gain would be marginal.

## R4. Matching on the device

- **Decision**: the host turns the target into a sorted, merged list of intervals on `top64 = (0x02aa ‖ digest ‖ checksum) >> 240`. It enumerates the 58 possible second characters and every upper/lower-case variant of the target in case-insensitive mode, or only the target itself in case-sensitive mode (FR-009). Each interval is clipped to the range reachable with prefix `0x02aa`. The device builds `top64` from the first 6 digest bytes and binary-searches the intervals. Every hit is then confirmed on the host with the exact rule.
- **Rationale**: the leading base58 characters depend only on the most significant bits, so the device needs neither SHA-256 nor base58 arithmetic. `top64` stays below 2^63, so signed int64 comparisons are exact. With up to 9 characters (about 64.4 bits) the filter is a superset of the exact rule; the extra candidates sit only at interval edges and are removed on the host (FR-007: zero false positives).
- **Measured**: 128 intervals for a 7-character target. The interval search costs little, since the device reached 5.09 G nonces/s with it.

## R5. Host-side confirmation of hits

- **Decision**: in search mode, confirm each hit with the host's mid-state Blake2b (about 2.4 µs) plus the checksum and base58. The full-dump re-hash through `digestif` is kept for the verification mode (FR-006) and for tests.
- **Rationale**: re-hashing 5 MB with digestif takes about 5 ms per hit. That becomes the bottleneck for short targets, which produce thousands of hits per second. The mid-state reference is independent of the device code and is itself checked against digestif in the tests.

## R6. Nonce space, ranges, resumption

- **Decision**:
  - The position of a nonce is its numeric value in `[0, 10^16)`.
  - The unit of work is a **chunk** of 10^8 consecutive nonces, that is one launch with the 8 launch digits fixed, so there are 10^8 chunks.
  - A range is `[first_chunk, first_chunk + count)` and wraps modulo 10^8.
  - `--instance i/N` assigns contiguous slice `i` of N to instance `i`.
  - The optional positional seed, kept for compatibility with the C tool, sets the starting chunk through a fixed hash of the seed. Without a seed, the search starts at chunk 0.
  - Progress and the resume position are reported in whole chunks.
- **Rationale**: this is deterministic and reproducible, the slices cannot overlap, and the resume position is a single integer (FR-013, FR-014, SC-006). A chunk takes about 20 ms on the reference GPU, which is fine-grained enough for stop conditions and progress, while launch overhead stays negligible. Sub-chunk ranges are not needed.
- **Alternatives considered**: a pseudo-random walk (the C tool's xorshift) was rejected because coverage cannot be tracked.

## R7. Several devices

- **Decision**: one OS process per device. In multi-device mode, the main process starts one worker per selected device, each with its own slice of the range (R6) and the device index. It then merges the workers' standard output (match lines) and progress records.
- **Rationale**: Sarek's device and kernel caches are not thread-safe (`kb/backends/README.md`), so OCaml 5 domains sharing one Sarek runtime would be risky. Separate processes are isolated and match the current practice (`parallel`), and a failing device cannot corrupt the others.
- **Alternatives considered**:
  - One domain per device: rejected for the thread-safety reason above.
  - Round-robin launches from one thread: rejected because they serialise the GPUs.

## R8. CPU execution path (FR-012)

- **Decision**: the CPU path is the same Sarek kernel run on the **Native** backend (OCaml 5 domains, 14.9 M nonces/s on 16 threads, about 4× the C hasher). The **Interpreter** backend is available for debugging. A pure-OCaml reference search (single thread, about 0.42 M/s) exists only as a test oracle.
- **Rationale**: the same kernel source on the CPU gives identical results by construction, and it lets the equivalence tests run on machines without a GPU.

## R9. Hit buffer sizing

- **Decision**: the hit buffer capacity is `max(1024, 4 × expected hits per chunk)`. The expected count is the fraction of the `top64` space the intervals cover, times 10^8. If a launch reports more hits than the capacity, the chunk is re-run in sub-launches (fewer threads per launch) until nothing overflows, so no match is ever dropped (FR-007). Below 3 characters, the tool also warns that output will be large.

## R10. Interruption and errors

- **Decision**:
  - SIGINT and SIGTERM set a flag that is checked between launches. After the current launch, which takes about 20 ms, the tool prints its matches and the last fully covered chunk, then exits with status 130.
  - When a device error occurs, the tool reports that chunk and exits with status 3.
  - Errors in the dump or the target are reported before any device is initialised, with exit status 2.

## R11. Command-line interface and compatibility

- **Decision**:
  - A single executable, `octez-vanity-gpu`.
  - The default form is the C hasher's usage, `octez-vanity-gpu DUMP NAME [SEED]`, which writes `<hash> <16 digits>` lines to stdout (FR-003, FR-004).
  - Other modes are options: `--verify NONCE`, `--bench SECONDS`, `--list-devices`.
  - Arguments are parsed with `cmdliner`, which is already in the switch.
- **Rationale**: positional subcommands would break the drop-in form that `proto_manager.sh` suggests.

## R12. Toolchain and testing

- **Decision**:
  - OCaml 5.4 in a local opam switch, with dune ≥ 3.15.
  - Sarek (`spoc`, `sarek`, `sarek-cuda`) pinned from `~/dev/Sarek`, because it is not in the opam repository.
  - Other dependencies: `digestif` (Blake2b and SHA-256 reference), `zarith` (base58 and interval arithmetic), `cmdliner`, and `alcotest` plus `qcheck-core` for tests.
  - The test suite has four layers:
    1. unit tests on the host modules;
    2. synthetic dumps with every final-block length from 1 to 128, so cases A, B and C are all checked against digestif;
    3. device-versus-reference equivalence on whole chunks, which runs on Native always and on CUDA when one is present;
    4. CLI cram tests.
  - Ground-truth fixtures: C-hasher pairs, plus released protocols dumped from `~/dev/tezos`. Tests that need these external files skip cleanly when the files are absent.
