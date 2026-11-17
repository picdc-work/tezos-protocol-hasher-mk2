# Quickstart & Validation: GPU-Accelerated Tezos Protocol Vanity Hasher

**Feature**: `specs/001-gpu-protocol-hasher` | **Date**: 2026-11-17

This guide proves the feature end to end. The interface is in [contracts/cli.md](contracts/cli.md) and the entities in [data-model.md](data-model.md).

## Prerequisites

- Linux, an NVIDIA GPU with a CUDA driver. The reference machine has an RTX 5070 Ti, driver 620, and CUDA in `/opt/cuda`.
- opam. The project uses a **local switch** at the repository root (OCaml 5.4.0).
- A clone of Sarek at `~/dev/Sarek`.
- Ground-truth sources; tests skip cleanly without them:
  - `~/dev/tezos-protocol-hasher`: the C hasher, `proto.txt`, `proto_to_hash.txt`;
  - `~/dev/tezos`: a built `octez-protocol-compiler` and released protocols such as `src/proto_025_PsUshuai`.

## Setup

```sh
opam switch create . ocaml-base-compiler.5.4.0 --no-install
eval $(opam env --switch=. --set-switch)
for p in spoc sarek sarek-cuda; do opam pin add -n -y $p ~/dev/Sarek; done
opam install . --deps-only --with-test -y
dune build
```

## V1: hash correctness against Tezos (FR-005, FR-006, SC-001)

```sh
cd ~/dev/tezos
./octez-protocol-compiler -dump-only src/proto_025_PsUshuai/lib_protocol > /tmp/ushuaia.dump
octez-vanity-gpu --verify 0822971470637657 /tmp/ushuaia.dump
```

**Expected**: `PsUshuai9QapM5TGj1JpuVGkdxz5GykdnEvS6Rh8SUVrARvZLCY`, the value in that protocol's `TEZOS_PROTOCOL`. Repeat with `proto_023_PtSeouLo` and nonce `7130263421897740`; expect `PtSeouLouXkxhg39oWzjxDWaCydNfR3RxCUrNe4Q9Ro8BTehcbh`. (Both were checked with the prototype.)

## V2: the release workflow, drop-in (US1, FR-003, FR-004, SC-005)

```sh
cd ~/dev/tezos
sed -i 's/Vanity nonce: .* \*)/Vanity nonce: 0000000000000000 *)/' src/proto_alpha/lib_protocol/main.ml   # on a scratch branch
./octez-protocol-compiler -dump-only src/proto_alpha/lib_protocol > proto_to_hash.txt
octez-vanity-gpu proto_to_hash.txt alpha --max-matches 3
```

**Expected**: 3 lines `P?alpha… <16 digits>` within seconds. For one of them, put the nonce in `main.ml` and run `./octez-protocol-compiler -hash-only src/proto_alpha/lib_protocol`. The printed hash must be identical. Then restore `main.ml`.

## V3: GPU and CPU agree with the reference (FR-007, FR-012, SC-002)

```sh
dune test                                   # unit, synthetic layouts, cram
dune exec test/equivalence.exe -- --target pa
```

**Expected**:
- Synthetic dumps with every final-block length from 1 to 128 (cases A, B, C) hash identically through the host reference and digestif.
- For one dump of each case A, B and C, the device backend (CUDA when present) and the CPU backend (`Native`) report exactly the same raw hits as the pure-OCaml reference on 10^6 nonces. That is as much as the reference can check in a few seconds.
- On 2 whole chunks (2·10^8 nonces), the CUDA and `Native` backends report the same hits. This is the same kernel source compiled by different compilers.
- `dune exec test/equivalence.exe -- --reference-chunk`: on one whole chunk (10^8 consecutive nonces, SC-002), CUDA reports exactly the hits of the pure-OCaml reference, which is spread over 16 domains (about 15 s).
- The C hasher's pairs (`test/vectors/c_hasher_pairs.txt`) are reproduced by `--verify`.

## V4: throughput (FR-018, SC-003, SC-004)

```sh
octez-vanity-gpu --bench 20 ~/dev/tezos-protocol-hasher/proto_to_hash.txt
for s in $(seq 1 16); do timeout 10 ~/dev/tezos-protocol-hasher/hasher \
  ~/dev/tezos-protocol-hasher/proto_to_hash.txt 1 $s | wc -l; done | awk '{s+=$1} END {print s*58/10}'
time octez-vanity-gpu ~/dev/tezos-protocol-hasher/proto_to_hash.txt ushuaia --max-matches 1
```

**Expected**:
- The GPU rate is at least 100 × the C hasher rate. The prototype measured 5.09·10^9 against 3.76·10^6 nonces/s.
- The 7-character search ends in under 5 minutes. The prototype found 3 or 4 matches in 20 s.

## V5: ranges, resumption, interruption (US3, FR-013–FR-016, FR-019, SC-006)

```sh
D=~/dev/tezos-protocol-hasher/proto_to_hash.txt
octez-vanity-gpu $D pa --start 1000 --count 4 > all.txt
octez-vanity-gpu $D pa --start 1000 --count 4 --instance 0/2 >  split.txt
octez-vanity-gpu $D pa --start 1000 --count 4 --instance 1/2 >> split.txt
diff <(sort all.txt) <(sort split.txt)

octez-vanity-gpu $D pa --start 1000 --count 4 --timeout 0.05 > part1.txt   # stops early
# read next_chunk=<c> from stderr, then:
octez-vanity-gpu $D pa --start <c> --count $((1004 - c)) > part2.txt
diff <(sort all.txt) <(sort part1.txt part2.txt)
```

**Expected**:
- Both `diff` commands print nothing: no overlap and no gap.
- Ctrl-C during a search prints `stopped reason=interrupted next_chunk=…` and exits with status 130.

## V6: input errors (FR-010, FR-020, edge cases)

```sh
octez-vanity-gpu $D paris0          # invalid character → exit 2, names '0'
octez-vanity-gpu $D abcdefghij      # longer than 9 characters → exit 2
octez-vanity-gpu /etc/hostname pa   # no nonce line → exit 2, names the expected marker
```
