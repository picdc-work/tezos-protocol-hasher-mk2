---

description: "Task list for the GPU-accelerated Tezos protocol vanity hasher"
---

# Tasks: GPU-Accelerated Tezos Protocol Vanity Hasher

**Input**: Design documents from `specs/001-gpu-protocol-hasher/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, quickstart.md

**Tests**: Included. The spec makes correctness a success criterion: SC-001 and SC-002 require zero false positives and zero false negatives (FR-007), and the plan defines four test layers. In each phase, write the tests first and check that they fail before implementing.

**Organization**: Tasks are grouped by user story (US1 = GPU search, US2 = verification and benchmark, US3 = devices, ranges and resumption).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: user story the task belongs to (US1, US2, US3)

## Conventions for every task

- **Paths** are relative to the repository root `/home/picdc/dev/tezos-protocol-hasher-mk2`. Build with `eval $(opam env --switch=. --set-switch) && dune build`.
- **Reference code** to port from, already validated:
  - `prototype/src/ref.ml`: host Blake2b, base58, intervals;
  - `prototype/gen/gen_kernel.ml`: Sarek kernel generator, case A;
  - `prototype/bin/proto_bench.ml`: launch code, check mode.
- **Sarek gotchas**, checked in the prototype:
  - write `[%kernel …]`;
  - use `atomic_add_global_int32` on a global vector (`atomic_add_int32` only accepts local or shared arrays);
  - the kernel language has no int32→int64 conversion, so pass 64-bit values through `int64 vector`s or `Execute.Int64` arguments;
  - pass large 64-bit constants (IV) through vectors rather than literals;
  - shift counts on `int64` are `int64` (`x lsr 32L`);
  - bind operands to a `let` before `lsr`;
  - the PTX path ignores `pragma ["unroll"]`, so generate fully unrolled code;
  - call `Sarek_native.Native_plugin.init ()`, `Sarek_cuda.Cuda_plugin.init ()` and `Sarek_cuda.Cuda_c_plugin.init ()` before `Device.init ()`;
  - add `-w -33` to the flags of any library that uses `sarek.ppx`.
- **Blake2b sigma**, last row: `10 2 8 4 7 6 1 5 15 11 9 14 3 12 13 0`. Transposing `9 14` was a real bug in the prototype.
- **Ground truth** for tests:
  - C hasher pairs (T006);
  - official hashes: `proto_023_PtSeouLo` with nonce `7130263421897740` → `PtSeouLouXkxhg39oWzjxDWaCydNfR3RxCUrNe4Q9Ro8BTehcbh`, and `proto_025_PsUshuai` with nonce `0822971470637657` → `PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: project skeleton, toolchain, test fixtures.

- [ ] T001 Create the root `dune-project`. Use `(lang dune 3.15)` and `(generate_opam_files true)`, and declare package `octez-vanity-gpu` with these dependencies: `ocaml >= 5.4.0`, `spoc`, `sarek`, `sarek-cuda`, `digestif`, `zarith`, `cmdliner`, plus `alcotest`, `qcheck-core` and `qcheck-alcotest` `{with-test}`. Create the root `dune` with `(dirs :standard \ prototype specs)` and `.gitignore` with `_build/` and `_opam/`.
- [ ] T002 Create the local opam switch at the repository root: `opam switch create . ocaml-base-compiler.5.4.0 --no-install`. Pin `spoc`, `sarek` and `sarek-cuda` from `~/dev/Sarek` (`opam pin add -n -y <pkg> ~/dev/Sarek`), then run `opam install . --deps-only --with-test -y`. Check that `dune build` succeeds on the empty skeleton.
- [ ] T003 [P] Create the dune stanzas:
  - `src/dune`: library `octez_vanity`, `(preprocess (pps sarek.ppx))`, `(flags (:standard -w -33))`, libraries `sarek sarek.core sarek.stdlib sarek.native sarek-cuda.plugin digestif zarith unix`, plus a rule that generates `kernels.ml` with `(with-stdout-to kernels.ml (run ../gen/gen_kernel.exe))`;
  - `gen/dune`: executable `gen_kernel`;
  - `bin/dune`: executable `main` with `(public_name octez-vanity-gpu)` and libraries `octez_vanity cmdliner`;
  - `test/unit/dune` and `test/layouts/dune`: alcotest test stanzas;
  - `test/dune`: executable `equivalence`;
  - `test/cli/dune`: `(cram (deps %{bin:octez-vanity-gpu} ../support/mkdump.exe))`.
- [ ] T004 [P] Add `.ocamlformat` (`profile = default`, `version` set to the installed ocamlformat if present, otherwise just the profile).
- [ ] T005 [P] Create `test/support/fixtures.ml` (library `fixtures`). It provides:
  - `ref_dir ()`: `$HASHER_REF_DIR`, defaulting to `~/dev/tezos-protocol-hasher`;
  - `tezos_dir ()`: `$TEZOS_DIR`, defaulting to `~/dev/tezos`;
  - `skip_unless_exists path`, which calls `Alcotest.skip ()`;
  - `protocol_dump name`, which runs `<tezos_dir>/octez-protocol-compiler -dump-only src/<name>/lib_protocol` once into `_build`'s temporary directory and returns the cached path (skip when the compiler or the directory is missing).
- [ ] T006 [P] Create `test/vectors/c_hasher_pairs.txt`, one `<dump file name> <nonce> <hash>` per line, from the C hasher outputs collected while the prototype was validated:
  ```
  proto_to_hash.txt 1424981856756554 PsPAcJ9YB5LfW38eK1KxyTEYzJTNG52CEAbVmoHMH1qgPVjsRub
  proto_to_hash.txt 3195302746556451 PtPAUdsTY4dw2BmagkJ95pLjfL8bNUZ1X7GTgQDSE9vk5TfqcQe
  proto_to_hash.txt 5476645407262663 PspafFhcuaXCXKrkHEdtTba5hLNak7GKNVPooShig36nq9nYrgM
  proto.txt 9034190808231397 PrxyAcsJ4NKQt6Wvwp26Xqf3qykezAdBVLYtEgmD3zShz3i5ems
  proto.txt 8713589731839219 PtXYAA5C8YJVcf95CssqRFqaspvBZntg717YEUu6b7o3YnsJQZZ
  ```
  Dump files are resolved relative to `Fixtures.ref_dir ()`.
- [ ] T007 [P] Create `test/support/mkdump.ml` (executable `mkdump`). Usage: `mkdump <final-block-length F in 1..128> <seed> <out>`. It writes a deterministic synthetic dump: pseudo-random bytes followed by `(* Vanity nonce: 0000000000000000 *)\n`, with total length `L ≡ F (mod 128)` (taking 128 for F = 128) and `L ≥ 1024`. `mkdump --size L <seed> <out>` writes a dump of exactly `L` bytes ending with the same nonce line. Also add `mkdump --hash <dump> <nonce>`, which prints the protocol hash computed **only** with digestif on the full dump plus its own base58 code. It is the independent oracle for cram tests.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: host modules that every story needs: hashing reference, dump parsing, target and intervals, nonce arithmetic.

**⚠️ CRITICAL**: no user-story work can start until this phase is complete.

### Tests (write first, they must fail)

- [ ] T008 [P] Create `test/unit/test_blake2b.ml`:
  - known vector: `Blake2b.digest "abc"` = hex `bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319`;
  - qcheck property: for random strings of length 0–1000, `Blake2b.digest s` = `Digestif.Make_BLAKE2B(struct let digest_size = 32 end).digest_string s`;
  - for random lengths, chaining value over the first full blocks followed by the final compression = the full digest.
- [ ] T009 [P] Create `test/unit/test_protocol_hash.ml`:
  - every line of `test/vectors/c_hasher_pairs.txt` (skip when the dump is missing): `Protocol_hash.of_digest (Dump.digest dump nonce)` = the expected hash;
  - Seoul and Ushuaia through `Fixtures.protocol_dump` reproduce the official hashes listed under Conventions;
  - output length is 51 characters and the first character is `P`.
- [ ] T010 [P] Create `test/unit/test_dump.ml`. Validation (data-model "Dump"):
  - "the last 4 bytes are ` *)\n`";
  - "the 17 bytes before the digits are `(* Vanity nonce: `";
  - "the 16 bytes at `digits_offset` are ASCII digits";
  - a dump with `TBD` is rejected with a message naming the expected marker;
  - an unreadable file is rejected.

  `final_block_length` = `((L - 1) mod 128) + 1`; layout case is A for F ≥ 20, B for 6 ≤ F < 20 and C for F < 6 (research R2). Use dumps written by `mkdump`.

  Size limits (spec edge case, "1 KB to 10 MB"): dumps of 1,024 bytes and of 10,485,760 bytes, written with `mkdump --size`, both load. For nonce `0000000000000000`, their `Dump.digest` gives the hash printed by `mkdump --hash`.
- [ ] T011 [P] Create `test/unit/test_target.ml`:
  - names of "1 to 9 characters" are accepted; 0 or 10 characters are rejected;
  - `paris0` is rejected and the message names `'0'`;
  - in case-sensitive mode, `I`, `O` and `l` are rejected;
  - the intervals are sorted and disjoint, and every `hi < 2^63`;
  - qcheck property, for targets of 1–2 characters in both case modes: draw random 32-byte digests; whenever `Target.matches t (Protocol_hash.of_digest d)` holds, `Target.top64 d` lies in one of `Target.intervals t`. Iterate until at least 200 matches are seen;
  - `expected_rate` for `pa` (insensitive) is within ±20 % of the observed match rate over 10^6 random digests.
- [ ] T012 [P] Create `test/unit/test_nonce_space.ml`:
  - `Nonce_space.text n` is "exactly 16 decimal digits, zero-padded";
  - `chunk`, `thread` and `loop` match data-model "Nonce" (`value / 10^8`, `(value / 100) mod 10^6`, `value mod 100`) and recombine to `value`;
  - `start_of_seed` is deterministic and in `[0, 10^8)`.
- [ ] T013 [P] Create `test/layouts/test_layouts.ml`. For every F in 1..128, build a synthetic dump (as in T007, with a fixed seed). For 20 random nonces each, `Dump.digest` (host mid-state path) = digestif over the full dump with the nonce written in. Also check that the layout case is right.

### Implementation

- [ ] T014 [P] Create `src/blake2b.ml` and `src/blake2b.mli`, ported from `prototype/src/ref.ml` (sigma corrected):
  - `iv : int64 array`;
  - `compress : int64 array -> int64 array -> t0:int64 -> last:bool -> unit`, which mutates the chaining value;
  - `init : unit -> int64 array`, i.e. IV with `h0 ^= 0x01010020`;
  - `words_of_block : Bytes.t -> int -> int -> int64 array`, which zero-pads to 128 bytes;
  - `digest_of_state : int64 array -> string` (32 bytes, little-endian);
  - `digest : string -> string`.
- [ ] T015 [P] Create `src/protocol_hash.ml` and `.mli`:
  - `prefix = "\002\170"`;
  - `of_digest : string -> string`: base58check of `prefix ^ digest ^ first 4 bytes of SHA-256(SHA-256(prefix ^ digest))`, using Zarith for base58 and `Digestif.SHA256`;
  - `alphabet`;
  - `b58_encode_z`.
- [ ] T016 Create `src/dump.ml` and `.mli` (depends on T014). Type `t` holds:
  - `data`, `length`, `digits_offset = L - 20`, `final_block_length`, `final_block_offset`;
  - ``layout_case : [`A | `B | `C]``;
  - `base_offset`: offset of the first block that contains any nonce digit, i.e. `final_block_offset` in case A and `final_block_offset - 128` in cases B and C;
  - `base_state`: the chaining value after all blocks before `base_offset`.

  Functions:
  - `load : string -> (t, string) result`, with the validation rules and error messages of data-model "Dump" and contracts/cli.md "Error messages", e.g. `expected the dump to end with "(* Vanity nonce: <16 digits> *)\n" (found "…"); set the nonce to 0000000000000000 before dumping`;
  - `blocks_with_nonce : t -> int64 -> int64 array list`: one or two blocks;
  - `digest : t -> int64 -> string`: host mid-state path;
  - `digest_full : t -> int64 -> string`: digestif over a copy of the full dump, the independent path.
- [ ] T017 [P] Create `src/target.ml` and `.mli`, ported from `prototype/src/ref.ml` `intervals`, `top64` and `matches`, and extended with:
  - ``type case_mode = [`Insensitive | `Sensitive]``;
  - `make : ?case_mode -> string -> (t, string) result`, which enforces "1 to 9 characters". In insensitive mode it lowercases the name first and rejects characters with no base58 form in either case; in sensitive mode it rejects characters outside the base58 alphabet. The error lists the offending characters and the valid set `1-9, A-H, J-N, P-Z, a-k, m-z`;
  - `intervals : t -> (int64 * int64) array` (research R4), enumerating every second character and every case variant (insensitive) or only the exact name (sensitive);
  - `top64 : string -> int64`, from the first 6 digest bytes;
  - `matches : t -> string -> bool`: insensitive `lowercase(hash[2..2+len)) = name`, sensitive exact;
  - `expected_rate : t -> float`: candidates per match = 2^48 / Σ(hi - lo + 1), since `top64` spans `[0x02aa·2^48, 0x02ab·2^48)`.
- [ ] T018 [P] Create `src/nonce_space.ml` and `.mli`:
  - constants `chunk_size = 100_000_000` and `n_chunks = 100_000_000`;
  - `text : int64 -> string`, which is "exactly 16 digits";
  - `chunk`, `thread` and `loop` decomposition, and `make ~chunk ~thread ~loop`;
  - `start_of_seed : int -> int`: the first 8 bytes of `Blake2b.digest (string_of_int seed)`, as an unsigned integer, mod `n_chunks`;
  - `type range = { first_chunk : int; count : int }` with `chunks : range -> int Seq.t`, visiting in increasing order modulo 10^8. Instance slicing comes in US3.

**Checkpoint**: `dune test test/unit test/layouts` passes. The host computes correct protocol hashes for any dump layout.

---

## Phase 3: User Story 1 - Find a vanity nonce on a GPU (Priority: P1) 🎯 MVP

**Goal**: `octez-vanity-gpu DUMP NAME [SEED]` searches on the GPU and prints verified `<hash> <nonce>` lines, for every dump layout (cases A, B, C).

**Independent Test**: on `proto_to_hash.txt` with target `pa`, matches appear within seconds. Each printed nonce re-hashed with `test/support/mkdump.exe --hash` (or `octez-protocol-compiler -hash-only`) gives the printed hash. `test/equivalence.exe` shows device == reference.

### Tests for User Story 1 (write first)

- [ ] T019 [P] [US1] Create `test/equivalence.ml`. It covers four dumps:
  - synthetic dumps with F = 46 (case A), F = 15 (case B, launch digits in the next-to-last block), F = 9 (case B, thread digits in the next-to-last block) and F = 3 (case C), built with `mkdump`;
  - `proto_to_hash.txt` when present.

  For each dump and for each available device among `Native`, `CUDA/PTX` and `CUDA/C`, it:
  - runs `Device_search.run_chunk ~nthreads:10_000 ~chunk:12345678` (10^6 nonces) with target `pa`, insensitive;
  - computes the reference: for every nonce of the same 10^6, `Dump.digest`, then keep the nonce if `Target.top64` falls in `Target.intervals`;
  - asserts that both sorted lists are equal and that every device hit satisfies `Target.matches` after `Protocol_hash.of_digest (Dump.digest_full …)`.

  It prints `CHECK OK` or `CHECK FAILED` per (dump, device) and exits 1 on any failure.
- [ ] T020 [P] [US1] Create `test/cli/search.t` (cram). The input-error cases need no device:
  - `octez-vanity-gpu $DUMP paris0` → exit 2, stderr names `'0'`;
  - `octez-vanity-gpu $DUMP abcdefghij` → exit 2;
  - `octez-vanity-gpu /etc/hostname pa` → exit 2, stderr names the expected marker;
  - nothing on stdout in any of them.

  Search case, on a `mkdump 46 1` dump: `octez-vanity-gpu --cpu $DUMP pa --max-matches 2`. Check that:
  - stdout has exactly 2 lines matching `^P[1-9A-HJ-NP-Za-km-z]{50} [0-9]{16}$`;
  - for each line, `mkdump --hash $DUMP <nonce>` prints the same hash;
  - stderr ends with `stopped reason=max-matches`;
  - the exit status is 0.

### Implementation for User Story 1

- [ ] T021 [US1] Rewrite `gen/gen_kernel.ml` from `prototype/gen/gen_kernel.ml` to emit `src/kernels.ml` with three kernels. A shared emitter `compress ~msg:(string array) ~h_in ~v_init ~out` writes one fully unrolled Blake2b compression (12 rounds × 8 G) on `mut` int64 scalars.

  Common parameters of all kernels:
  - `h : int64 vector`: the chaining value `Dump.base_state`;
  - `vinit : int64 vector` (16 values): v8..v15 for the first and the second compressed block, with `t0` and `f0` folded in by the host. For the final block, `t0 = L` and `v14 = lnot iv6`; for the next-to-last block, `t0 = final_block_offset`, not last;
  - `tmpl : int64 vector` (32 words): the base block(s), with launch digits set and thread and loop digit bytes zeroed;
  - `mida`, `midb : int64 vector` (per-thread patches) with `wa : int32`, a word index in 0..31 in the concatenated two-block space;
  - `wl1 : int32`, `sl1 : int64`, `wl2 : int32`, `sl2 : int64`: the loop digits;
  - `lo`, `hi : int64 vector` and `nint : int32`;
  - hit outputs `hit_count`, `hit_thread`, `hit_loop` (int32 vectors) and `cap : int32`;
  - `first_thread : int32` and `nthreads : int32`, where thread digits = `first_thread + global_thread_id`.

  The three kernels:
  - `search_a` (case A): one compression of words 16..31 per nonce, port of the prototype;
  - `search_b` (case B): compress words 0..15 (patched with the thread digits) once per thread, then for each of the 100 loop values compress words 16..31 starting from that state;
  - `search_c` (case C): both compressions inside the loop.

  After the final compression, all three compute `top64` from digest word 0 (bytes 0..5 big-endian, OR `0x02aa000000000000L`), binary-search `lo`/`hi`, and append hits through `atomic_add_global_int32`.
- [ ] T022 [US1] Create `src/device_search.ml` and `.mli` (depends on T016, T017, T018, T021):
  - `init_backends ()` registers Native, CUDA/PTX and CUDA/C;
  - `best_gpu ()` picks the first `CUDA/PTX`, then `CUDA/C` device. It returns `Error "no GPU device found (frameworks tried: CUDA/PTX, CUDA/C); use --cpu to search on the CPU"` when there is none;
  - `cpu_device ()` returns `Native`;
  - `prepare dev dump target` builds once the vectors `h`, `vinit`, the 10^6-entry thread patches `mida`/`midb` (two words each, positions in the concatenated two-block space, as in `prototype/bin/proto_bench.ml` `setup`), and `lo`/`hi`;
  - `run_chunk ?nthreads ?cap ctx ~chunk` writes the 8 launch digits into `tmpl` and returns the `int64` nonces hit (`chunk·10^8 + thread·100 + loop`). `?cap` is for tests only: it overrides the computed hit-buffer capacity, so that sub-launches can be forced.

  Kernel selection in `run_chunk`:
  - case A → `search_a`;
  - case B where no thread digit is in the next-to-last block (F ≥ 12) → the host compresses the next-to-last block once per chunk, then `search_a` runs with that state;
  - case B with F < 12 → `search_b`;
  - case C → `search_c`.

  Hit buffer (research R9): capacity `max 1024 (4 × 10^8 / expected_rate)`. If `hit_count > cap`, re-run the chunk as sub-launches over `[first_thread, first_thread + n)` ranges, halving until no sub-launch overflows. Never drop a hit. Launch geometry: block 256, grid `ceil(nthreads / 256)`, then `Transfer.flush`.
- [ ] T023 [US1] Create `src/search.ml` and `.mli` (depends on T022). `run ~dump ~target ~device ~range ~max_matches ~timeout ~out ~err`:
  - prints the start-up summary on `err`: device, layout case, number of intervals, expected candidates per match, and estimated time per match from the device rate after the first chunk;
  - for each chunk of the range: `Device_search.run_chunk`, then confirm each hit on the host with `Protocol_hash.of_digest (Dump.digest dump n)` and `Target.matches` (research R5; drop non-matches, never print them), de-duplicate, then print `<hash> <16 digits>` on `out` and flush;
  - stops printing as soon as the `max_matches`-th confirmed match is printed, even in the middle of a chunk. The range end, `timeout` and signals are checked between launches. After a `max-matches` stop, `next_chunk` is the chunk in progress (contracts/cli.md);
  - installs SIGINT and SIGTERM handlers that set a flag checked between launches;
  - catches device exceptions;
  - always ends with `stopped reason=<completed|max-matches|timeout|interrupted|device-error> next_chunk=<c> tested=<n> matches=<m>` on `err`, where `next_chunk` is the first chunk not fully covered;
  - returns the exit code from contracts/cli.md: 0, 3, or 130.
- [ ] T024 [US1] Create `bin/main.ml` with cmdliner:
  - default form `octez-vanity-gpu [OPTIONS] DUMP NAME [SEED]`, with options `--case-sensitive`, `--cpu`, `--max-matches K` and `--timeout SECONDS` (contracts/cli.md);
  - validate dump and target (exit 2, message on stderr, nothing searched) **before** device initialisation;
  - range: `{first_chunk = Nonce_space.start_of_seed seed (or 0); count = n_chunks}`;
  - device: `best_gpu`, or `cpu_device` with `--cpu`; when there is no GPU and no `--cpu`, exit 3 with the error message;
  - exit with the code returned by `Search.run`.
- [ ] T025 [US1] Run `dune test`, `dune exec test/equivalence.exe` (on the RTX 5070 Ti: expect `CHECK OK` for every dump and every backend), and quickstart V2, the drop-in run on a scratch `proto_alpha` dump. Fix any mismatch before going on.

**Checkpoint**: US1 is a usable MVP that replaces the C hasher for releases.

---

## Phase 4: User Story 2 - Trust the result: verification and benchmark (Priority: P2)

**Goal**: `--verify NONCE DUMP` prints the hash over the full dump. `--bench SECONDS` reports nonces/s on each GPU and on the CPU backend. Whole-chunk agreement between GPU and CPU backends is checked (SC-002).

**Independent Test**: `--verify` reproduces the Seoul and Ushuaia official hashes and the C-hasher pairs. `--bench 5` prints one rate line per backend.

### Tests for User Story 2 (write first)

- [ ] T026 [P] [US2] Create `test/cli/verify.t` (cram): on a `mkdump 46 2` dump, `octez-vanity-gpu --verify 0123456789012345 $DUMP` prints the same line as `mkdump --hash $DUMP 0123456789012345`, exit 0. `--verify 12345 $DUMP` (not 16 digits) → exit 2.
- [ ] T027 [P] [US2] Create `test/unit/test_verify.ml`: `Verify.hash` on every line of `test/vectors/c_hasher_pairs.txt` and on the Seoul and Ushuaia fixtures (skip when missing) gives the expected hash.

### Implementation for User Story 2

- [ ] T028 [P] [US2] Create `src/verify.ml` and `.mli`: `hash : Dump.t -> string -> (string, string) result`. The nonce must be "exactly 16 digits". Compute `Protocol_hash.of_digest (Dump.digest_full dump nonce)`, the independent digestif path.
- [ ] T029 [P] [US2] Create `src/bench.ml` and `.mli`: `run ~dump ~seconds devices` builds a target that cannot match (a 9-character target, so the filter cost stays realistic), runs `Device_search.run_chunk` on consecutive chunks for `seconds` on each device and on `cpu_device ()`, and returns `(framework, name, nonces_per_s)` per device.
- [ ] T030 [US2] Extend `bin/main.ml` with `--verify NONCE DUMP` (prints the hash, exit 0 or 2) and `--bench SECONDS DUMP` (prints `<framework> <device name> <nonces/s>` per line on stdout) (contracts/cli.md).
- [ ] T031 [US2] Extend `test/equivalence.ml` with two long checks, skipped with a message when no CUDA device is present. Both use `proto_to_hash.txt` (or a `mkdump 46` dump).
  - `--whole-chunks 2`: run 2 whole chunks (2·10^8 nonces) on `CUDA/PTX` and on `Native` and assert identical hit lists.
  - `--reference-chunk` (SC-002): run 1 whole chunk (10^8 consecutive nonces) on `CUDA/PTX` and with the pure-OCaml reference (`Dump.digest`, then `Target.top64` in the intervals). Split the reference across 16 OCaml 5 domains, each scanning a contiguous sixteenth of the chunk, which takes about 15 s. Assert identical hit lists.

**Checkpoint**: US1 and US2 both work. Quickstart V1, V3 and V4 can be run.

---

## Phase 5: User Story 3 - Control the search: devices, ranges, resumption (Priority: P3)

**Goal**: device listing and selection, several GPUs, explicit chunk ranges and instance slices, progress records, and resumption with no overlap and no gap.

**Independent Test**: quickstart V5. Splitting into instances 0/2 and 1/2 gives the same matches as one run. A run stopped by `--timeout` and resumed from its `next_chunk` gives the same matches as an uninterrupted run.

### Tests for User Story 3 (write first)

- [ ] T032 [P] [US3] Extend `test/unit/test_nonce_space.ml` with qcheck properties: for any range and any `N` in 1..64, the slices `Nonce_space.slice range ~instance:i ~of_:N` for `i = 0..N-1` are "pairwise disjoint and together cover the range exactly", including ranges that wrap around 10^8. `resume range ~next_chunk` returns the remaining range. `parse_instance "1/2"` gives `Ok (1, 2)`; `"2/2"` and `"a/b"` give errors.
- [ ] T033 [P] [US3] Create `test/cli/ranges.t` (cram, `--cpu`, so it needs no GPU; one chunk ≈ 7 s on Native) on a `mkdump 46 3` dump with target `pa`:
  - `--start 1000 --count 2` equals, after sorting, the union of `--instance 0/2` and `--instance 1/2`;
  - `--start 1000 --count 2 --timeout 1` stops with `next_chunk=c`; the run resumed with `--start c --count (1002 - c)`, plus the first run's lines, equals the full run after sorting;
  - `--progress=1` writes lines matching `^progress elapsed=.* rate=.* tested=.* next_chunk=.* matches=.*$` to stderr only;
  - interruption (SC-006, US1 scenario 4): start `--start 1000 --count 3` in the background and send `kill -INT` after 3 s. The exit status is 130 and stderr has `stopped reason=interrupted next_chunk=c`. The lines of that run plus those of a run resumed with `--start c --count (1003 - c)` equal, after sorting, the full `--start 1000 --count 3` run.
- [ ] T034 [P] [US3] Create `test/cli/devices.t` (cram): `--list-devices` prints lines `<index> <framework> <name>` and includes a `Native` line; `--device 99` → exit 3 with a message naming the device.

### Implementation for User Story 3

- [ ] T035 [P] [US3] Extend `src/nonce_space.ml` with `slice : range -> instance:int -> of_:int -> range` (contiguous slice `i` of `N`, as in data-model "Search range"), `resume : range -> next_chunk:int -> range` and `parse_instance : string -> (int * int, string) result` (`0 ≤ i < N`).
- [ ] T036 [P] [US3] Extend `src/device_search.ml` with `list_devices () : (int * string * string) list` (index, framework, name) and `select : string -> (device, string) result`. `select` accepts an index, a framework name (`CUDA/PTX`, `CUDA/C`, `Native`, `Interpreter`), or `all-gpus`, which expands to every `CUDA/PTX` device.
- [ ] T037 [US3] Extend `src/search.ml` with an optional `progress : float option` interval. Every interval, print `progress elapsed=<s> rate=<nonces/s> tested=<n> next_chunk=<c> matches=<m>` on `err` only (FR-017).
- [ ] T038 [US3] Create `src/multi_device.ml` and `.mli` (research R7). With D > 1 selected devices:
  - split the range with `Nonce_space.slice` into D slices;
  - start one worker per device by re-executing `Sys.executable_name` with `--device <index> --start <first> --count <count>` and the same target, dump and options, through `Unix.create_process` with pipes;
  - forward the workers' stdout lines (matches) to stdout as they arrive, line-buffered, with no duplicate;
  - relay the progress and `stopped` lines prefixed with `device=<index>`, and print a total progress line;
  - forward SIGINT and SIGTERM to the workers.

  Exit status: 130 if interrupted, 3 if any worker failed, otherwise 0.

  At exit, print one `stopped device=<i> slice=<first>+<count> reason=… next_chunk=<c> tested=<n> matches=<m>` line per device, then the total `stopped reason=… tested=<n> matches=<m>` line (contracts/cli.md, data-model "Search range": each slice resumes from its own `next_chunk`).
- [ ] T039 [US3] Extend `bin/main.ml` with `--list-devices`, repeatable `--device D` (with `all-gpus`), `--start CHUNK` (overrides `SEED`; must be in `[0, 10^8)`), `--count CHUNKS`, `--instance I/N` and `--progress[=SECONDS]` (default 10 s). Dispatch to `Multi_device` when more than one device is selected, otherwise to `Search`.

**Checkpoint**: all three user stories work independently. Quickstart V5 passes.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T040 [P] Create `test/unit/test_overflow.ml` (research R9). On `Native`, with target `p` and 10^6 nonces (`Device_search.run_chunk ~nthreads:10_000`), the hit list with `~cap:64`, which forces sub-launches, is identical to the hit list with the computed capacity. Also create `test/cli/short_target.t` (cram, `--cpu`, `--max-matches 5`): stderr contains the large-output warning for targets shorter than 3 characters.
- [ ] T041 [P] Add the unreachable-target warning to `src/search.ml`: when the estimated time per match at the measured rate exceeds 30 days, print it on stderr with the expected candidates per match (spec edge case). Cover it in `test/cli/search.t` with `--case-sensitive` and a 9-character target, and `--timeout 1`.
- [ ] T042 Measure performance (quickstart V4) on the RTX 5070 Ti. Record the rates of `--bench 20` for dumps of cases A, B (F = 9) and C (F = 3) and the C hasher on 16 processes. Check SC-003 (≥ 100× the C hasher; target ≥ 4·10^9 nonces/s in case A) and SC-004 (`ushuaia`, `--max-matches 1`, under 5 minutes). Record the numbers in `README.md`.
- [ ] T043 [P] Write `README.md` at the repository root: purpose, build (local switch, Sarek pin), usage in the release workflow (`octez-vanity-gpu proto_to_hash.txt <label>` instead of the suggested `parallel` command), modes, exit codes, performance table, and links to `specs/001-gpu-protocol-hasher/` and `prototype/README.md`.
- [ ] T044 Run the whole of `specs/001-gpu-protocol-hasher/quickstart.md` (V1–V6) and fix any divergence. V2 must run on a scratch branch or worktree of `~/dev/tezos`, never on the checked-out `v25.4-shadow-release` tree. Then run `dune build @fmt --auto-promote` if ocamlformat is installed, and `dune test`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 → T002 → T003. T004–T007 can run in parallel with T003.
- **Foundational (Phase 2)**: depends on Setup. Tests T008–T013 run in parallel. Then T014, T015, T017 and T018 in parallel; T016 after T014.
- **US1 (Phase 3)**: depends on Foundational. T019 and T020 in parallel, then T021 → T022 → T023 → T024 → T025.
- **US2 (Phase 4)**: depends on Foundational. T028 needs only Phase 2, so `--verify` can be built before US1. T029 and T031 need T022; T030 needs T024 (US1).
- **US3 (Phase 5)**: depends on US1 (T022–T024). T035 and T036 in parallel, then T037 → T038 → T039.
- **Polish (Phase 6)**: after the desired stories; T042 and T044 come last.

### User Story Dependencies

- **US1 (P1)**: only Foundational.
- **US2 (P2)**: verification needs only Foundational; benchmark and whole-chunk equivalence reuse US1's `Device_search`.
- **US3 (P3)**: extends US1's search driver and CLI; independently testable through its own cram tests.

### Parallel Opportunities

- Phase 1: T004, T005, T006 and T007 together.
- Phase 2: the six test files T008–T013 together; then the four modules T014, T015, T017 and T018 together.
- US1: T019 and T020 together.
- US2: T026 and T027 together; T028 and T029 together.
- US3: T032, T033 and T034 together; T035 and T036 together.
- Polish: T040, T041 and T043 together.

---

## Parallel Example: Foundational phase

```bash
# Tests first, all independent files:
Task: "T008 test/unit/test_blake2b.ml"
Task: "T009 test/unit/test_protocol_hash.ml"
Task: "T010 test/unit/test_dump.ml"
Task: "T011 test/unit/test_target.ml"
Task: "T012 test/unit/test_nonce_space.ml"
Task: "T013 test/layouts/test_layouts.ml"

# Then the independent modules:
Task: "T014 src/blake2b.ml"
Task: "T015 src/protocol_hash.ml"
Task: "T017 src/target.ml"
Task: "T018 src/nonce_space.ml"
```

## Parallel Example: User Story 1

```bash
Task: "T019 test/equivalence.ml (device vs reference, cases A/B/C)"
Task: "T020 test/cli/search.t (output format, errors, --cpu search)"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (Setup), then Phase 2 (Foundational): correct host hashing for every layout.
2. Phase 3 (US1): GPU search for cases A, B and C, drop-in CLI.
3. **Stop and validate**: `test/equivalence.exe` shows `CHECK OK` everywhere; quickstart V2 passes.
4. The tool can already replace the C hasher in the next protocol release.

### Incremental Delivery

1. Setup + Foundational → host reference ready.
2. US1 → MVP (search).
3. US2 → `--verify`, `--bench`, whole-chunk equivalence (trust).
4. US3 → several GPUs, ranges, resumption, progress (long searches).
5. Polish → performance record, README, full quickstart.

---

## Notes

- `prototype/` stays as it is, as a measured reference. Do not add it to the root build.
- Never print a match that has not been confirmed on the host (FR-007). Never drop a device hit (research R9).
- Nonces are always handled as `int64` values in `[0, 10^16)`. Their text form is produced only by `Nonce_space.text`.
- Commit after each task or logical group once the repository is under git.
