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

## Address search (`--address`)

```
octez-vanity-gpu --address tz2 [OPTIONS] NAME
```

Finds a secret key whose address is `tz1` (Ed25519, key `edsk...`, the 32-byte seed), `tz2` (secp256k1, key `spsk...`), `tz3` (P-256, key `p2sk...`) or `tz4` (BLS12-381 G1, minimal public key variant, key `BLsk...`) followed by `NAME`; the synopsis is the same with the other schemes. For tz1 the candidates are seeds enumerated on the device: the seed of offset `j` is the first 24 bytes of a 32-byte base followed by the 64-bit big-endian value `u + j mod 2^64` (`u`: the last 8 bytes of the base, big-endian); the base-key file holds the base as 64 hexadecimal characters and any value is valid. The rate on the Native backend is about 0.25 to 0.32 million seeds/s (32 cores), a chunk being 16 launches of 65 536 seeds, with interruption, timeout and `--max-matches` checked between launches. For tz4 the secret scalar is in `[1, r-1]` with `r` the group order of G1, encoded little-endian in the 32 secret bytes (big-endian for tz2 and tz3); the base-key file keeps the same format (64 hexadecimal characters, the scalar as a number) and is range-checked against `r`. The rate on the Native backend is about 25 to 35 % below tz2 (2.9 to 3.7 million offsets/s against 4.5 to 4.9 on 32 cores). It is a separate mode: protocol-hash search above is unchanged. `NAME` is the only positional argument.

| Argument / option | Meaning | Default |
|---|---|---|
| `--address SCHEME` | Selects this mode. `tz1`, `tz2`, `tz3` and `tz4` are accepted; another value is an error listing the supported schemes. | — |
| `NAME` | 1 to 8 base58 characters, matched right after the scheme prefix. Giving the prefix (`tz1`, `tz2`, `tz3` or `tz4`), or a first character no address of the scheme can have, is an error. | required |
| `--key-dir DIR` | Directory of the key files; it must exist. | current directory |
| `--base-key-file FILE` | File holding the base scalar `k0`: 64 hexadecimal characters on one line, mode 0600 at most. Created with a fresh `k0` (mode 0600) if it does not exist; refused if its mode is wider than 0600, if it is not a regular file, or if its content is not a scalar in `[1, n-1]`. | fresh `k0` per process |
| `--start CHUNK`, `--count CHUNKS`, `--instance I/N` | As for protocol hashes, over `2^44` chunks of `2^20` key offsets (`CHUNK` in `[0, 2^44)`; the default is chunk 0 and all chunks). Rejected without `--base-key-file`. | — |
| `--case-sensitive`, `--max-matches`, `--timeout`, `--progress`, `--device`, `--cpu`, `--list-devices` | As for protocol hashes. | |

`--verify` and `--bench` are protocol-hash modes: with `--address` they are rejected (exit status 2). `--key-dir` and `--base-key-file` are rejected without `--address`. `--device` can be repeated: each device runs one child process; with `--base-key-file` the children get the path of the file (never `k0`) and their slice of the range, without it each child draws its own `k0` and gets no range.

### Secret handling

The base scalar comes from `/dev/urandom` (redrawn until in `[1, n-1]`) and stays in the process. For tz2, tz3 and tz4 the device receives public points only. For tz1 the device receives the base and so computes every candidate seed (accepted by the owner, 2026-11-17); the base is still never printed or passed on a command line or in the environment. No secret appears on standard output or standard error, in a command line, in an environment variable or in an error message. Every device hit is confirmed on the host (key `k0 + offset mod n`, address from the host reference, exact target match; the offset giving key 0 is skipped) before anything is written or printed.

### Standard output

One line per confirmed match, flushed at once:

```
<36-character address> <path of the key file>
```

The path is `DIR/<address>.key` (`DIR` as given, `.` by default). The file holds the secret key in the Octez form (`spsk…`, 54 characters) on one line, and is created with `O_CREAT | O_EXCL` and mode 0600. An existing file is never overwritten: if it is a regular file holding exactly this key, the match is reported on stderr as `already found: <address> <path>` and is neither printed on stdout nor counted; otherwise it is an error (exit status 4).

### Standard error

Same style as protocol-hash search: start-up summary (device, target, kernel geometry), the rate in offsets/s with the estimated time per match, `progress` records with `--progress`, and always the last line

`stopped reason=<completed|max-matches|timeout|interrupted|device-error|key-file-error> next_chunk=<c> tested=<n> matches=<m>`

`next_chunk` is the first chunk not fully covered. After `reason=max-matches`, resuming from it searches that chunk again and finds the matches already written. With the same key directory their key files hold the same keys: each is reported on stderr as `already found: <address> <path>`, is not printed on stdout and is not counted, and the search goes on. With several devices, the per-device and total `stopped` lines have the format of protocol-hash search (without `slice=` when there is no base-key file).

### Exit status

As for protocol hashes, plus:

| Code | Meaning |
|---|---|
| 4 | A key file could not be created: a file with that name exists and holds something else, or the write failed. The `stopped` line has `reason=key-file-error`. A key directory that is not writable at start is an input error (exit status 2). With several devices, a child stopping this way makes the total `reason=device-error` and the exit status 3. |

Input errors (exit status 2) include: unsupported scheme, invalid name, `--start`/`--count`/`--instance` without `--base-key-file`, `--verify` or `--bench` with `--address`, a missing `--key-dir`, a base-key file with a mode wider than 0600 or a bad content.

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
