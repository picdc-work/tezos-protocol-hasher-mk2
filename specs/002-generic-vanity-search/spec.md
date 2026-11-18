# Feature Specification: Generic Vanity Search on GPU

**Feature Branch**: `002-generic-vanity-search`

**Created**: 2026-11-18

**Status**: Draft

**Input**: User description: "Réétudions la possibilité de hasher de manière générique."

## Context *(background from feature 001 and from the earlier discussion)*

Feature 001 delivered a GPU vanity search for Tezos protocol hashes. Its device code is specialised for one input format:

- the input is a protocol dump whose last line holds a 16-digit decimal nonce at a fixed place;
- the target is a base58check protocol hash compared from its 3rd character;
- the digest size is fixed at 32 bytes.

What makes the GPU worthwhile is more general than protocols. Every candidate shares a long fixed prefix, which is hashed once, and only the last few blocks change from one candidate to the next. Any input of the form "fixed part, then a variable field, then a fixed suffix" has the same property.

"Hashing generically" could also mean computing full Blake2b digests of large batches of independent messages. That reading was considered and left out of this version (clarification of 2026-11-18). A single large message gains nothing on a GPU anyway, since Blake2b is sequential.

## Clarifications

### Session 2026-11-18

- Q: Which generalisation is in scope? → A: The generalised search only. Batch hashing of independent messages is out of scope.
- Q: Up to which size must the hashed data be supported? → A: A few kilobytes for the part that changes with the candidate (the variable field and everything after it). The fixed prefix may be of any size, like a protocol dump.
- Q: Through which interface? → A: Both a library, for other programs, and a command that is a thin layer over it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Search a vanity value for any fixed-prefix input (Priority: P1)

An engineer wants a vanity hash for an input other than a protocol dump: any input made of a fixed part, a variable field, and an optional fixed suffix. They describe where the variable field is, how long it is, which characters it may contain, how the digest is encoded (base58check with a given prefix, or raw bytes), and the target. The tool searches the space of values of the variable field on the GPU, and prints each match together with the value that produced it.

**Why this priority**: It is the generalisation that keeps the GPU's advantage, and the reason for this feature. On its own, it covers every vanity search, including the protocol one.

**Independent Test**: Express the protocol search of feature 001 in this generic form. Over the same range, it must report exactly the same matches as the dedicated protocol search. Then run it on a synthetic input with a hexadecimal field in the middle of the input and a raw-digest target, and confirm every match by hashing the full input with the reference implementation.

**Acceptance Scenarios**:

1. **Given** an input file, the position and length of the variable field, its alphabet and a target, **When** the engineer starts the search, **Then** each match is printed with the encoded hash and the value, and recomputing the digest of the full input with that value gives the printed hash.
2. **Given** the description that reproduces the protocol case, **When** the search runs over the same range as the protocol search, **Then** both report the same set of matches.
3. **Given** a target on the raw digest (a byte prefix written in hexadecimal), **When** the search runs, **Then** it reports exactly the values whose digest starts with those bytes.
4. **Given** a search stopped by a timeout or an interruption, **When** it is restarted from its reported position, **Then** it neither re-tests nor skips any value of the range.

---

### User Story 2 - Use the search from another program (Priority: P2)

A developer writes a tool that needs a vanity value, for example as one step of a release or code-generation script. They call the search as a library: they give the input, the description of the variable field and the target, choose the device and the range, and receive the matches as values, without going through text output.

**Why this priority**: It lets other tools reuse the search without parsing command-line output. The command of Story 1 is built on this library, so the library comes with it, but calling it directly is a secondary use.

**Independent Test**: A small test program calls the library on the synthetic input of Story 1 and on the protocol case, and receives the same matches as the command over the same range.

**Acceptance Scenarios**:

1. **Given** a search description and a range, **When** a program calls the library, **Then** it receives every match of the range, with its value and digest, and the position up to which the range is covered.
2. **Given** an invalid description, **When** a program calls the library, **Then** it receives an error that names the problem, before any device is used.

---

### User Story 3 - Know what to expect before a long search (Priority: P3)

Before launching a long search, the engineer wants to know the throughput for their input and the expected time per match. A benchmark reports candidates per second on each selected device and on the CPU path, and the start-up summary gives the expected number of candidates and the estimated time per match.

**Why this priority**: The throughput depends on the input: the more blocks change with the candidate, the slower the search. The engineer must see it to choose the target length, but the search works without it.

**Independent Test**: Run the benchmark on three inputs where the varying part spans one, two and about thirty blocks. It must finish in bounded time and report lower throughput for more varying blocks.

**Acceptance Scenarios**:

1. **Given** a search description, **When** the engineer runs the benchmark, **Then** the tool prints candidates per second for each selected device and for the CPU path.
2. **Given** a target that is practically unreachable at the measured throughput, **When** the search starts, **Then** the tool warns with the expected number of candidates per match and the estimated time.

---

### Edge Cases

- The variable field extends past the end of the input, or has length 0: rejected.
- The alphabet is empty or has a single value: rejected, as there is nothing to search.
- The varying part (from the variable field to the end of the input) exceeds the supported size: rejected, with the limit.
- The value space of the field is smaller than the requested range, or smaller than one unit of work: the search covers exactly the existing values and reports completion.
- The value space is larger than the tool can enumerate: the tool searches a prefix of that space and says which part is covered.
- The target contains characters that cannot appear in the chosen encoding, or is longer than the encoded hash allows: rejected, with the offending characters.
- The base58 prefix fixes the first characters of the hash: a target compared from a position that the prefix fixes either never matches or always does. The tool warns before starting.
- The field's content in the input file differs from every value of the alphabet: ignored, since every candidate overwrites the field.
- No GPU available: same behaviour as feature 001. The tool says so, and uses the CPU path only if the user explicitly asks.

## Requirements *(mandatory)*

### Functional Requirements

**Search description**

- **FR-001**: The user MUST be able to describe a search input as a fixed prefix, a variable field of fixed length at a given position, and an optional fixed suffix, all taken from one input file.
- **FR-002**: The fixed prefix MUST be accepted at any size up to at least 10 MB. The varying part, from the start of the variable field to the end of the input, MUST be accepted up to at least 4 KB.
- **FR-003**: The user MUST be able to choose the alphabet of the variable field: decimal digits, lowercase hexadecimal, uppercase hexadecimal, all 256 byte values, or an explicit list of characters.
- **FR-004**: The user MUST be able to choose the digest size, from 1 to 64 bytes, with a default of 32 bytes.
- **FR-005**: The user MUST be able to choose the target encoding:
  - base58check of a user-given byte prefix followed by the digest, compared from a given character position, case-sensitive or not;
  - or a prefix of the raw digest, given in hexadecimal, possibly with a final half-byte.

**Search behaviour**

- **FR-006**: The search MUST hash the fixed prefix only once, and evaluate the candidates in parallel on the GPU.
- **FR-007**: The search MUST enumerate the values of the field deterministically, so that ranges, instance slices, multi-device splitting and resumption work as in feature 001.
- **FR-008**: The search MUST report zero false positives, and miss zero matches over the range it reports as covered.
- **FR-009**: The same search MUST be available on the CPU path, with identical matches over the same range.
- **FR-010**: The protocol search of feature 001 MUST be expressible in the generic form and give the same matches. The existing protocol command, its options, its output and its exit codes MUST remain unchanged.

**Interfaces**

- **FR-011**: The search MUST be available as a library that takes a search description, a device choice and a range, and returns the matches with their values and digests, plus the covered position.
- **FR-012**: The search MUST be available as a command built on that library. It prints one match per line on standard output, as `<encoded hash> <value>`, with the value written in its alphabet (hexadecimal for raw bytes). Progress and diagnostics go to standard error, as in feature 001.
- **FR-013**: The command MUST offer the controls of feature 001: device listing and selection, range, instance slice, progress, maximum number of matches, timeout, verification of one value, and benchmark.

**Errors and observability**

- **FR-014**: Invalid descriptions and targets MUST be rejected before any device is used, with a message that names the problem and the accepted values.
- **FR-015**: At start-up, the tool MUST report the expected number of candidates per match and the estimated time per match, and warn when the target is practically unreachable.

### Key Entities

- **Search template**: the input file split into a fixed prefix, a variable field (position, length, alphabet) and a fixed suffix. The protocol dump of feature 001 is one instance of it.
- **Value**: one possible content of the variable field, identified by its position in a deterministic enumeration of the field's value space.
- **Value space**: all values of the field, with size `|alphabet|^length`, split into units of work for ranges and resumption.
- **Target**: the encoding (base58check with a byte prefix, or raw digest), the digest size, the expected string or bytes, the comparison position, and the case mode.
- **Match**: a value and its encoded hash satisfying the target.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the matches reported over at least 3 different templates are confirmed by an independent reference implementation hashing the full input. The 3 templates differ in alphabet, field position, digest size and target encoding.
- **SC-002**: Over at least 10^8 consecutive values, the generic form of the protocol search and the dedicated protocol search report exactly the same matches.
- **SC-003**: On the reference workstation, the generic form of the protocol search reaches at least 80% of the throughput of the dedicated protocol search.
- **SC-004**: The dedicated protocol search keeps its interface, its output, and at least 95% of its current throughput.
- **SC-005**: For a template whose varying part fits in the last block, the generic search tests at least 1 billion candidates per second on the reference workstation.
- **SC-006**: A search interrupted and resumed from its reported position re-tests 0 values and misses 0 values of the range.

## Assumptions

- The constraints of feature 001 still apply: OCaml, GPU code written with Sarek, the CUDA and HIP backends, and the Native backend as the CPU path.
- The reference workstation and the throughput figures of feature 001 serve as the baseline (RTX 5070 Ti, about 5·10⁹ candidates per second for the dedicated protocol kernel).
- Only sequential Blake2b is targeted, without key, salt or personalisation, since Tezos hashes use none. Blake2s, Blake2bp and Blake3 are out of scope.
- Batch hashing of independent messages is out of scope (clarification of 2026-11-18).
- The variable field has a fixed length, so the suffix and the total input length do not depend on the value.
- The enumeration covers at least 10^16 values, the size of the protocol nonce space; larger value spaces are searched only partially (see edge cases).
- The base58check prefix is given by the user as bytes. The tool does not need to ship the list of Tezos prefixes, although it may name some common ones for convenience.
- The reference implementation for correctness is digestif, already used by the host code and by the tests of feature 001.
- No concrete use case outside protocol hashes has been named yet (discussion of 2026-11-17). The feature is a generalisation whose value depends on such a use case appearing.
