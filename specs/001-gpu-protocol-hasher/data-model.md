# Data Model: GPU-Accelerated Tezos Protocol Vanity Hasher

**Feature**: `specs/001-gpu-protocol-hasher` | **Date**: 2026-11-17

There is no persistent storage: every entity lives in memory for the duration of one run. The resume position is printed and passed back on the command line.

## Dump

The binary protocol serialisation produced by `octez-protocol-compiler -dump-only`.

| Field | Description |
|---|---|
| `bytes` | Whole file contents. |
| `length` (L) | Size in bytes. The reference tool accepts 1 KB to 10 MB; this tool accepts at least that range. |
| `digits_offset` | `L - 20`: the 16 nonce digits start there. |
| `final_block_length` (F) | `((L - 1) mod 128) + 1`. |
| `final_block_offset` | `L - F`. |
| `layout_case` | A, B or C (research R2), derived from F. |
| `chaining_value` | Blake2b-256 state (8 × int64) after every block that no candidate can change, i.e. before the first block that contains a varying digit. |

**Validation** (FR-002, FR-020; reported before any device is initialised):
- the last 4 bytes are ` *)\n`;
- the 17 bytes before the digits are `(* Vanity nonce: `;
- the 16 bytes at `digits_offset` are ASCII digits;
- the file is readable, and its size is within the bounds above.

The digit values in the input file do not matter, because every nonce overwrites them.

## Nonce

| Field | Description |
|---|---|
| `value` | Integer in `[0, 10^16)`. It is also the nonce's **position** in the search space. |
| `text` | `value` written as exactly 16 decimal digits, zero-padded. |
| `chunk` | `value / 10^8`: the launch digits (8 most significant). |
| `thread` | `(value / 100) mod 10^6`: the thread digits. |
| `loop` | `value mod 100`: the loop digits. |

## Chunk

The unit of work, progress and resumption: the 10^8 consecutive nonces sharing the same launch digits. One device launch covers one chunk, or a chunk split into sub-launches after a hit-buffer overflow (research R9). The space holds 10^8 chunks.

## Search range

| Field | Description |
|---|---|
| `first_chunk` | In `[0, 10^8)`. |
| `count` | Number of chunks, in `[1, 10^8]`. Default: all of them. |
| `instance` | Optional `(i, N)` with `0 ≤ i < N`. It restricts the range to its contiguous slice `i` of `N`. |
| `seed` | Optional. When given, it sets `first_chunk` through a fixed hash; it has no other effect. |

**Rules**:
- chunks are visited in increasing order, modulo 10^8;
- for any `N`, the slices of instances `0..N-1` are pairwise disjoint and together cover the range exactly (FR-014);
- with several devices, the range is split the same way, one slice per device (FR-015).

**State transitions** of a range during a run:

```
pending ──launch──▶ in flight ──hits confirmed──▶ covered
                        │
                        └──device error / interrupt──▶ not covered
                           (reported "next chunk" = this chunk)
```

The resume position is the first chunk that is not covered. Restarting with `first_chunk = resume position` and the remaining `count` re-tests no covered chunk and skips nothing (SC-006).

With several devices, the range is split into one slice per device (`Nonce_space.slice`); each slice has its own resume position. There is no single resume position for the whole run: resuming means restarting each slice `[next_chunk_i, first_i + count_i)`.

## Target

| Field | Description |
|---|---|
| `name` | 1 to 9 characters, each mapping to at least one base58 character. In case-insensitive mode, the name is given in lowercase, as with the reference tool; an uppercase letter is first converted to lowercase. |
| `case_mode` | `insensitive` (default, the reference rule) or `sensitive` (FR-008, FR-009). |
| `intervals` | Sorted, disjoint `(lo, hi)` int64 pairs on `top64` (research R4). Derived, not given by the user. |
| `expected_rate` | Expected number of candidates per match. Derived from the intervals, it is used for the hit-buffer size (R9) and for the warning about unreachable targets. |

**Matching rule** (exact, applied on the host):
- *insensitive*: `lowercase(hash[2 .. 2+len)) = name`;
- *sensitive*: `hash[2 .. 2+len) = name`.

**Validation**: a character that cannot appear in base58 is rejected, and the error lists the offending characters. These are `0`, `O`, `I` and `l` in sensitive mode; in insensitive mode, only characters with no base58 form in either case are rejected.

## Match

| Field | Description |
|---|---|
| `nonce` | The nonce (see above). |
| `hash` | 51-character base58check protocol hash. |

**Invariants**:
- `hash = protocol_hash(dump with nonce)` (FR-005);
- `hash` satisfies the target's matching rule (FR-007);
- each nonce is reported at most once.

## Device

| Field | Description |
|---|---|
| `index` | Position in the device listing. |
| `framework` | `CUDA/PTX`, `CUDA/C`, `HIP` or `Native`. |
| `name` | Device name. |
| `integrated` | The GPU shares host memory (APU), as its backend reports it through Sarek's `Shared_memory_query`; unknown counts as discrete. |

Selection: by index or by framework name. The default is the best GPU: the first discrete GPU in the order CUDA/PTX, CUDA/C, HIP, and an integrated GPU only when there is no discrete one. An integrated GPU is much slower, and multi-device slices are equal, so `all-gpus` leaves integrated GPUs out unless no discrete GPU exists; when no GPU is found, the tool reports it and runs on `Native` only if the user explicitly asks (spec edge case: never fall back silently).

## Progress record

Written to stderr at a fixed interval (FR-017):

| Field | Description |
|---|---|
| `elapsed` | Seconds since the search started. |
| `rate` | Nonces per second over the last interval. |
| `tested` | Total nonces tested. |
| `next_chunk` | Resume position. |
| `matches` | Number of matches so far. |
