# tz1 vanity keys on GPU — Sarek prototype

Throughput prototype for a GPU replacement of `octez-client gen vanity keys`
(Ed25519 / tz1 only). Not a product: no wallet integration, no encryption
of the found key, no ranges or resumption.

## Pipeline (one GPU thread = `kper` keys)

- seed = 32 random bytes from `/dev/urandom` per launch, word 0 xored with
  `gid lor (k lsl 32)`;
- SHA-512 of the seed (one block), clamping → scalar `a`;
- `A = aB` with a fixed-base table: entry `(pos, v) = v·256^pos·B` in Niels
  form, 32 × 256 entries (1.9 MB in global memory), so 32 mixed additions and
  no doubling;
- `1/Z` by ref10's addition chain, compressed point = public key;
- Blake2b-160 of the public key, base58 prefilter on the top 64 bits of
  `0x06a19f ‖ pkh` (intervals as in feature 001), hits confirmed on the host.

Field arithmetic is ref10's radix 2^25.5 on `int64` scalars, emitted as
straight-line code by `gen/gen_vk.ml` (3,850 lines of `[%kernel]`).

## Build & run

    dune build --root . ./vk/vk_bench.exe
    B=./_build/default/vk/vk_bench.exe
    $B ref   <seed hex>                         # reference pk / tz1 / edsk
    $B check <CUDA/PTX|Native> <nthreads> <kper> # device == reference
    $B dump  <framework> <nthreads> <kper>        # seed pk pkh, for PyNaCl
    $B bench <framework> <seconds> <nthreads> <kper> <word> [ci]

`bench` prints `<tz1 address> <edsk secret key>` for each match.

## Results (2026-11-18, RTX 5070 Ti, Ryzen 7 5700X3D 8C/16T)

| Implementation | keys/s |
|---|---|
| `octez-client gen vanity keys`, 1 process | 34,000 |
| `octez-client`, 16 processes | 242,000 |
| libsodium (PyNaCl), 1 thread | 52,000 |
| this kernel, Sarek Native backend (CPU) | 106,000 |
| this kernel, CUDA/PTX | **44,500,000** |

Correctness:
- the host reference (Zarith) matches the RFC 8032 vector, PyNaCl and
  `octez-client import secret key`;
- 1,048,576 GPU keys match PyNaCl and `hashlib.blake2b` (pk and pkh);
- `check` passes on CUDA/PTX and Native;
- a 30 s search for `tz1Tezos` found 6 addresses (about 5 expected), and
  `octez-client` gives the same address for the imported key.

Expected time per match, case-sensitive, `n` characters after `tz1` (about
`24·58^(n-1)` keys):

| n | GPU | octez-client × 16 | octez-client × 1 |
|---|---|---|---|
| 5 | 6 s | 19 min | 2.2 h |
| 6 | 6 min | 18 h | 5.3 days |
| 7 | 5.7 h | 43 days | 10 months |

## Sarek pitfall found

`int64` literals outside `[-2^62, 2^62)` are folded through a 63-bit OCaml
`int` and come out wrong, on PTX and Native alike
(`z lor 4611686018427387904L` gives `0xc000000000000000`). The generator
builds such constants as `(hi lsl 32L) lor lo`. Feature 001's kernels contain
no such literal.
