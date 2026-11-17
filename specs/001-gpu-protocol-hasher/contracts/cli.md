# CLI Contract: `octez-vanity-gpu`

**Feature**: `specs/001-gpu-protocol-hasher` | **Date**: 2026-11-17

This is the tool's only external interface. Standard output carries **only** match lines in search mode, or the requested result in the other modes. Everything else goes to standard error.

## Search (default mode)

```
octez-vanity-gpu [OPTIONS] DUMP NAME [SEED]
```

This is a drop-in replacement for `hasher DUMP NAME [SEED]` in the command that `scripts/proto_manager.sh` suggests (FR-003):

```
seq 1 8 | parallel --line-buffer octez-vanity-gpu proto_to_hash.txt <label>
```

That command works, but it is pointless on one GPU. The idiomatic form is `octez-vanity-gpu proto_to_hash.txt <label>`.

| Argument / option | Meaning | Default |
|---|---|---|
| `DUMP` | Path to the protocol dump. | required |
| `NAME` | Target, 1 to 9 base58 characters. | required |
| `SEED` | Non-negative integer that selects the starting chunk (data-model: Search range). | start at chunk 0 |
| `--case-sensitive` | Exact comparison instead of the case-insensitive one. | off |
| `--start CHUNK` | First chunk, in `[0, 10^8)`. Overrides `SEED`. | — |
| `--count CHUNKS` | Number of chunks to search. | all (10^8) |
| `--instance I/N` | Search only slice `I` of `N` of the range. | — |
| `--device D` | Device index or framework name; can be repeated for several devices. `all-gpus` selects the discrete CUDA/PTX and HIP GPUs, omitting CUDA/C aliases and integrated GPUs (included only when there is no discrete GPU). A framework name selects its first discrete device. | best GPU |
| `--cpu` | Use the CPU backend (`Native`), explicitly. | off |
| `--max-matches K` | Stop after K matches: the K-th match is the last line printed, even in the middle of a chunk. | unlimited |
| `--timeout SECONDS` | Stop after the given wall-clock time. | unlimited |
| `--progress[=SECONDS]` | Progress records on stderr every SECONDS seconds. | off (default interval 10 s) |

### Standard output

One line per match, flushed at once, in the same format as the C hasher (FR-004):

```
<51-char protocol hash> <16 digits>
```

Example: `PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY 0822971470637657`

The order of lines is not specified. The same nonce never appears twice.

### Standard error

- Start-up summary: device(s), layout case, number of prefilter intervals, expected candidates per match and estimated time per match (FR-017; spec edge case for unreachable targets).
- With `--progress`, one line per interval:
  `progress elapsed=<s> rate=<nonces/s> tested=<n> next_chunk=<c> matches=<m>`
- At exit, always:
  `stopped reason=<completed|max-matches|timeout|interrupted|device-error> next_chunk=<c> tested=<n> matches=<m>`
- After `reason=max-matches`, `next_chunk` is the chunk in progress. Resuming from it searches that chunk again and may print again matches already printed from it. The guarantee of SC-006 (no nonce tested twice, none skipped) applies to stops by `timeout`, `interrupted`, `device-error` and `completed`.
- With several devices, one `stopped` line per device:
  `stopped device=<i> slice=<first>+<count> reason=… next_chunk=<c> tested=<n> matches=<m>`,
  then a total line `stopped reason=… tested=<n> matches=<m>`. To resume, restart each slice from its own `next_chunk`.
- Empty device slices are not launched. A worker failure stops its peers and
  the supervisor exits with status 3, retaining their available resume records.
  If a worker crashes without a final record, restart its assigned slice from
  the beginning; its exact progress is unknown.

### Exit status

| Code | Meaning |
|---|---|
| 0 | The range was exhausted, or `--max-matches` or `--timeout` was reached. |
| 2 | Invalid input: bad options, unreadable or malformed dump, invalid target. Nothing was searched. |
| 3 | No usable device, or a device error mid-search. The `stopped` line gives the resume chunk. |
| 130 | Interrupted (SIGINT or SIGTERM). The `stopped` line gives the resume chunk. |

## Verification mode (FR-006)

```
octez-vanity-gpu --verify NONCE DUMP
```

Prints the protocol hash of `DUMP` with its digits replaced by `NONCE` (exactly 16 digits). The hash is computed over the full dump, independently of the search path. Exit status 0, or 2 on invalid input.

## Benchmark mode (FR-018)

```
octez-vanity-gpu --bench SECONDS [--device D ...] [--cpu] DUMP
```

Runs a search with a target that cannot match for about SECONDS seconds on each selected device and on the CPU backend. It then prints, per backend, one line on stdout:

```
<framework> <device name> <nonces/s>
```

## Device listing (FR-015)

```
octez-vanity-gpu --list-devices
```

Prints one line per device on stdout: `<index> <framework> <name>`. The name of an integrated GPU (one that shares host memory) ends with ` [integrated]`; select it by its index.

## Error messages (FR-020)

Each error names the problem and what was expected. Examples:

```
error: proto_to_hash.txt: expected the dump to end with "(* Vanity nonce: <16 digits> *)\n" (found "(* Vanity nonce: TBD *)\n"); set the nonce to 0000000000000000 before dumping
error: target "paris0": character '0' cannot appear in a base58 hash (valid: 1-9, A-H, J-N, P-Z, a-k, m-z)
error: no GPU device found (frameworks tried: CUDA/PTX, CUDA/C, HIP); use --cpu to search on the CPU
```
