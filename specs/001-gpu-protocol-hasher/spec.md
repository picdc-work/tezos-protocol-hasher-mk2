# Feature Specification: GPU-Accelerated Tezos Protocol Vanity Hasher

**Feature Branch**: `001-gpu-protocol-hasher`

**Created**: 2026-11-17

**Status**: Draft

**Input**: User description: "On cherche à implémenter une version du protocol hasher des protocoles Tezos qui tournerait sur GPU, et donc profiterait d'une acceleration du GPU. Pour ça, il existe deux implémentations CPU : https://github.com/mathiasbourgoin/tezos-protocol-hasher (qu'il faut lire avec mon compte picdc, mais un clone est déjà dans ~/dev) et celui intégré à tezos/tezos (tu peux trouver l'implémentation dans ~/dev/tezos). L'idéal serait d'en avoir une implémentation en OCaml qui utiliserait https://github.com/mathiasbourgoin/Sarek. Il faut donc lire la doc et le code des deux projets pour comprendre comment implémenter la version GPU."

## Context *(background from reading the existing implementations)*

Every Tezos protocol is identified by a **protocol hash** (e.g. `PtParis4SPSRnc…`). Before a protocol is released, its developers search for a **vanity hash**: a hash whose leading characters spell (part of) the protocol name. The protocol's `main.ml` ends with a comment line `(* Vanity nonce: NNNNNNNNNNNNNNNN *)`; changing the 16 digits changes the hash without changing behaviour. Finding a good nonce is a brute-force search.

Today's workflow, as implemented by the two existing CPU tools:

1. **tezos/tezos side** (`scripts/proto_manager.sh`, `octez-protocol-compiler`): the release script sets the nonce to `0000000000000000`, runs `octez-protocol-compiler -dump-only <proto dir>` to produce `proto_to_hash.txt` (the exact binary serialisation of the protocol whose hash is the protocol hash), prints a suggested hasher command (`seq 1 8 | parallel --line-buffer <hasher> proto_to_hash.txt <label>`), then waits for a human to paste a nonce, re-checks it with `octez-protocol-compiler -hash-only`, and commits it.
2. **Stand-alone hasher** (`tezos-protocol-hasher`, C): reads the dump, takes everything up to the start of the last line as a fixed prefix, then for pseudo-random 16-digit nonces hashes `prefix + "(* Vanity nonce: " + digits + " *)\n"`, computes the protocol hash (32-byte digest, Tezos protocol-hash prefix, base58check with a double-digest checksum), and prints `<hash> <nonce>` for every hash whose characters from the 3rd onward match the requested name case-insensitively (name ≤ 9 characters). Parallelism is obtained by launching one process per CPU core (or per remote machine) with different seeds.

Each candidate costs only the last one or two blocks of hashing, because the multi-megabyte prefix is identical for all candidates. That makes the search embarrassingly parallel and a natural fit for a GPU, where the expected gain is orders of magnitude over a CPU core count. The desired implementation language and GPU framework are stated as constraints in the Assumptions section.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find a vanity nonce on a GPU (Priority: P1)

A protocol release engineer has just produced `proto_to_hash.txt` with the release script. They run the GPU hasher on that file with the target name (e.g. `paris`). The tool uses the machine's GPU, continuously prints every matching protocol hash together with its nonce, in the same `<hash> <nonce>` line format as the existing hasher, and keeps searching until stopped. The engineer pastes one of the printed nonces into the release script, which confirms the hash.

**Why this priority**: This is the whole purpose of the feature; on its own it replaces the current CPU farm (GNU parallel over many cores or cloud machines) with a single workstation GPU.

**Independent Test**: Run the tool on the reference dump shipped with the C hasher and a short target (3–4 characters). Matches must appear within seconds, and each printed nonce, when substituted into the dump and hashed by the reference tooling (`octez-protocol-compiler -hash-only` or the C hasher's hashing logic), must give exactly the printed hash.

**Acceptance Scenarios**:

1. **Given** a valid protocol dump ending with the vanity nonce line and a target name of up to 9 base58 characters, **When** the engineer starts the tool, **Then** it prints, for each match found, one line `<full protocol hash> <16-digit nonce>` on standard output and flushes it immediately.
2. **Given** a printed line, **When** the nonce is inserted into the protocol's `main.ml` and the protocol hash is recomputed by the Tezos protocol compiler, **Then** the recomputed hash is identical to the printed hash.
3. **Given** the same dump and target, **When** the tool runs alongside the reference CPU hasher, **Then** every hash printed by the GPU tool also satisfies the reference tool's matching rule (no false positives).
4. **Given** the tool is running, **When** the engineer interrupts it, **Then** it stops cleanly, having already flushed every match found so far.

---

### User Story 2 - Trust the result: verification and benchmark (Priority: P2)

Before relying on the GPU for a real release, the engineer wants evidence that the GPU computes exactly the same hashes as Tezos, and how fast it is. They can (a) ask the tool to compute the protocol hash for a given dump and a given nonce, without searching, and compare it with `octez-protocol-compiler -hash-only`; and (b) run a short benchmark that reports throughput (candidates per second) for the GPU and, for comparison, for a CPU execution of the same search.

**Why this priority**: A wrong hash would be discovered only after the release script recomputes it, wasting search time; worse, a subtle bug could make the tool silently miss matches. Verification and throughput numbers are what justify switching from the existing CPU tool.

**Independent Test**: Use known `(dump, nonce, hash)` triples from the C hasher repository (`nonce.txt`, `proto.txt`) and from a freshly dumped protocol; the verification mode must return the expected hash for each. The benchmark mode must complete in bounded time and print a throughput figure.

**Acceptance Scenarios**:

1. **Given** a dump and a 16-digit nonce, **When** the engineer asks for the hash, **Then** the tool prints the protocol hash and it equals the hash computed by the Tezos protocol compiler for the same sources.
2. **Given** a GPU-capable machine, **When** the engineer runs the benchmark, **Then** the tool reports candidates per second on the GPU and on the CPU execution path, measured over the same workload.
3. **Given** a batch of candidate nonces, **When** they are hashed both on the GPU path and on the CPU execution path, **Then** both paths produce bit-identical digests and the same set of matches.

---

### User Story 3 - Control the search: devices, ranges, resumption (Priority: P3)

For long searches (8–9 character targets can take hours), the engineer wants to choose which compute device(s) to use, split the nonce space across several GPUs or machines without overlapping work, see progress (throughput, candidates tried, elapsed time), and resume or extend a search later without re-testing nonces already covered.

**Why this priority**: Improves efficiency for the hardest targets and for teams pooling hardware, but a single-GPU, run-until-stopped search (Story 1) already delivers most of the value.

**Independent Test**: Run two instances with disjoint nonce ranges and verify (via the range bookkeeping printed by each) that their covered ranges do not overlap; stop one and restart it from its reported position and check it continues from there.

**Acceptance Scenarios**:

1. **Given** a machine with several compute devices, **When** the engineer lists devices and selects one or more, **Then** the search runs only on the selected devices.
2. **Given** an explicit nonce range (start and count, or an instance index out of N instances), **When** the search runs, **Then** only nonces in that range are tested, and ranges given to different instances never overlap.
3. **Given** a running search, **When** progress reporting is enabled, **Then** the tool periodically reports on standard error the throughput, the number of candidates tested, and the current position, without mixing with the result lines on standard output.
4. **Given** a search stopped at a reported position, **When** it is restarted from that position, **Then** it continues without re-testing the already covered nonces.

---

### Edge Cases

- The dump does not end with a vanity-nonce line of the expected form (e.g. the nonce was left as `TBD`, or `main.ml` is not the last component): the tool refuses to start and explains which marker it expected.
- The target name contains characters outside the base58 alphabet (`0`, `O`, `I`, `l`) or is longer than the supported maximum: rejected before any search, with the list of offending characters.
- The target is effectively unreachable (e.g. length 9 with case-sensitive matching): the tool warns with the expected number of candidates per match and the corresponding estimated time at the measured throughput.
- No compatible GPU is present or the GPU runtime fails to initialise: the tool reports it clearly and offers to fall back to the CPU execution path (never silently).
- The GPU fails mid-search (driver reset, out of memory): the tool reports the last fully covered position so the search can be resumed (Story 3).
- Dump files at the size limits: the reference tool accepts 1 KB to 10 MB; the new tool must handle at least that range, and the protocol tail (bytes after the last full hashing block) may span one or two final blocks depending on the dump size.
- The whole nonce range is exhausted (10^16 values, or a user-given sub-range): the tool reports completion and the number of matches found.
- Several matches inside the same batch of candidates: all of them are reported, none is lost or duplicated.

## Requirements *(mandatory)*

### Functional Requirements

**Input and compatibility**

- **FR-001**: The tool MUST accept as input the protocol dump produced by the Tezos protocol compiler's dump mode (the same `proto_to_hash.txt` file the existing hasher consumes).
- **FR-002**: The tool MUST validate that the dump ends with the line `(* Vanity nonce: <16 digits> *)` followed by a newline, and treat everything before that line's digits as the fixed part of the input.
- **FR-003**: The tool MUST accept the same positional usage as the existing hasher (`<dump file> <name>`), so that the command suggested by the Tezos release script works by replacing only the executable path.
- **FR-004**: The tool MUST print each match on standard output as `<protocol hash> <16-digit nonce>`, one per line, flushed immediately, identical in format to the existing hasher's output.

**Hashing correctness**

- **FR-005**: For any dump and nonce, the protocol hash computed by the tool MUST be identical to the one the Tezos protocol compiler computes for the corresponding sources (32-byte digest of the dump, protocol-hash prefix, base58check encoding with a 4-byte checksum).
- **FR-006**: The tool MUST provide a verification mode that, given a dump and a nonce, prints the resulting protocol hash without searching.
- **FR-007**: The tool MUST NOT report a hash that does not satisfy the matching rule (zero false positives), and MUST NOT miss a matching nonce within the range it reports as covered (zero false negatives).

**Matching**

- **FR-008**: By default, matching MUST follow the existing hasher's rule: the target name (up to 9 characters, base58 alphabet) is compared case-insensitively with the hash characters starting at the 3rd position.
- **FR-009**: The tool MUST also offer a case-sensitive mode that compares the target exactly.
- **FR-010**: The tool MUST reject target names containing characters that cannot appear in a base58 hash, before starting the search.

**Search and performance**

- **FR-011**: The search MUST run on a GPU when one is available, computing the digest of the fixed part only once and evaluating many nonce candidates in parallel on the device.
- **FR-012**: The tool MUST also be able to run the same search on the CPU (for machines without a GPU, for testing, and for comparison), producing identical results for the same nonce range.
- **FR-013**: The search MUST enumerate nonces deterministically over a defined range so that coverage is reproducible and resumable; by default it covers the full 16-digit decimal space, starting from a position derived from an optional seed (as in the existing tool).
- **FR-014**: The tool MUST allow restricting the search to a sub-range (start and count, or instance i of N), and MUST guarantee that ranges assigned to different instances do not overlap.
- **FR-015**: The tool MUST allow listing available compute devices and selecting the device(s) to use; when several devices are selected, they MUST share the range without overlap.
- **FR-016**: The tool MUST support optional stop conditions: after a given number of matches, after a given duration, or at the end of the range.

**Observability and robustness**

- **FR-017**: The tool MUST optionally report progress on standard error (throughput in candidates per second, candidates tested, current position, elapsed time, matches found), separate from the result output.
- **FR-018**: The tool MUST provide a benchmark mode that measures and prints throughput on the selected device(s) and on the CPU path, over a bounded workload.
- **FR-019**: On any device error or interruption, the tool MUST flush all matches found so far and report the last fully covered position.
- **FR-020**: Error messages MUST name the problem and the expected input (missing file, malformed dump, invalid target, no device available).

### Key Entities

- **Protocol dump**: the exact binary serialisation of a protocol (environment version and list of modules), whose digest defines the protocol hash. Split into a fixed part (identical for all candidates) and a variable tail (the nonce digits and the closing ` *)\n`).
- **Nonce**: a 16-digit decimal string placed in the last line of `main.ml`; the unit of search. The nonce space has 10^16 values.
- **Protocol hash**: the base58check encoding of the protocol-hash prefix followed by the 32-byte digest of the dump, e.g. `PtParis4SPSRncmGAMYDMdsa1TVXrqQhoHRLRCoJP7PTN413Aj5` (51 characters).
- **Target name / matching rule**: the string the engineer wants to see in the hash, plus the comparison mode (case-insensitive from the 3rd character by default, or case-sensitive).
- **Search range**: a contiguous (or deterministically partitioned) set of nonces assigned to an instance or a device, with a current position used for progress and resumption.
- **Match**: a (protocol hash, nonce) pair satisfying the matching rule.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the hashes printed by the tool are confirmed identical by an independent implementation of the protocol hash, over at least 1,000 matches across at least 2 different protocol dumps; that independent implementation reproduces the hashes of at least 2 released protocols exactly as the Tezos protocol compiler computes them, from their dumps and nonces.
- **SC-002**: On the same set of at least 10^8 consecutive nonces, the GPU path and the CPU path report exactly the same matches as an independent reference implementation (no missing, no extra).
- **SC-003**: On the team's reference workstation (one consumer GPU, 16 CPU threads), the GPU search tests at least 100 times more candidates per second than the reference CPU hasher running on all CPU threads of the same machine.
- **SC-004**: A 7-character case-insensitive target yields at least one match in under 5 minutes on the reference workstation.
- **SC-005**: A release engineer who already uses the current workflow can run a GPU search by changing only the executable name in the suggested command, without reading any additional documentation.
- **SC-006**: A search interrupted and resumed from its reported position re-tests 0 already covered nonces and misses 0 nonces of the range.

## Assumptions

- **Stakeholder constraints on the solution** (stated in the request, recorded here rather than in requirements): the tool is implemented in OCaml, and its GPU kernels are written with the Sarek GPU DSL (github.com/mathiasbourgoin/Sarek), which can target several GPU families and also provides CPU execution backends usable for FR-012.
- The reference workstation for performance criteria is the development machine: one NVIDIA GeForce RTX 5070 Ti and an 8-core / 16-thread CPU. Feasibility was measured on it with a throughput prototype (`prototype/README.md`, 2026-11-17): the reference CPU hasher reaches about 3.8 million candidates per second on 16 threads, the GPU prototype about 5.1 billion (about ×1,350), and 3 to 4 matches of a 7-character target were found in 20 seconds. SC-003 and SC-004 keep a wide margin below these figures to absorb the cost of the full feature (two-block tails, progress reporting, multiple devices). Other GPU vendors supported by the chosen framework are expected to work but are not part of the acceptance criteria for this version.
- The input format is the one produced by `octez-protocol-compiler -dump-only`, whose last component is `main.ml` ending with the vanity-nonce comment; the release script already prepares the dump with the nonce set to `0000000000000000`. Changes to the Tezos release script are out of scope; the tool only needs to stay compatible with it.
- The nonce remains exactly 16 decimal digits, so that the serialised size of `main.ml` (and therefore the fixed part of the dump) does not depend on the nonce. Wider or hexadecimal nonces (a TODO of the existing tool) are out of scope.
- The default matching rule reproduces the existing hasher (case-insensitive, from the 3rd character, name ≤ 9 characters); choosing the second character of the hash (e.g. `Pt` vs `Ps`) is not a goal, as it is constrained by the hash prefix.
- The tool is a stand-alone command-line program in this repository; integrating it into `octez-protocol-compiler` or `proto_manager.sh` is out of scope for this version.
- Distributing work across several machines is done by giving each instance its own range (FR-014); no network coordination is provided.
- Reference test vectors come from the existing C hasher repository (`proto.txt`, `proto_to_hash.txt`, `nonce.txt`) and from protocols dumped from the local `tezos/tezos` checkout.
