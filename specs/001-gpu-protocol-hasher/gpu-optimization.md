# GPU optimization assessment

Keep the integer Blake2b kernels. The next experiments should target rotations,
register allocation and launch size; the cooperative-matrix operations available
in Sarek do not directly implement this workload. No GPU speedup is claimed by
this assessment, and this PR does not change the search kernels.

## Why tensor cores are a poor fit

Blake2b's G function combines addition modulo 2^64, XOR and rotations by
32, 24, 16 and 63 bits. The 12 rounds of a compression contain 96 G calls,
or 384 rotations. These are exact bit operations, with carry propagation in
the additions. See [RFC 7693, sections 2 and 3.1](https://www.rfc-editor.org/rfc/rfc7693.html#section-3.1)
and this project's [kernel generator](../../gen/gen_kernel.ml).

Sarek **does** have cooperative matrices. In the inspected revision
[`a16fa1f7`](https://github.com/mathiasbourgoin/Sarek/tree/a16fa1f7bc7f86b9a2ccf18439eefddf8369d6ab),
the [CUDA/PTX lowering](https://github.com/mathiasbourgoin/Sarek/blob/a16fa1f7bc7f86b9a2ccf18439eefddf8369d6ab/sarek/codegen/Sarek_ir_ptx_coopmat.ml)
supports warp-scoped 16x16x16 WMMA: f16 operands/f32 accumulation and
same-signedness int8 operands/int32 accumulation. Neither is a 64-bit
add/XOR/rotate primitive. Repacking the state into matrices would introduce
extra operations and communication, without a demonstrated way to accelerate
the dependent rounds. This is an algorithmic inference, not a benchmark.

The NVIDIA ISA also defines binary matrix XOR/AND followed by population count;
that operation is not a lane-wise XOR producing a 64-bit Blake2b state. It is
not a shortcut around this mismatch. See
[NVIDIA WMMA semantics](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#warp-level-matrix-instructions-wmma-mma).

Batching independent hashes does not change these operations: every state still
needs its own carries, XORs and rotations at every step. Encoding element-wise
work as diagonal matrix products would spend matrix operations on off-diagonal
zeros and still leave the bit operations to scalar code. A useful tensor-core
formulation would have to demonstrate both exact equivalence and lower total
cost, including packing, carries, bit operations and fragment transfers. None
was identified in this assessment. Independent hashes are already parallel
across GPU threads; interleaving them within a thread is a separate scheduling
experiment below.

## Experiments worth running

| Priority | Experiment | Sarek support and decision criterion |
|---|---|---|
| 1 | Inspect native rotation instructions | Current kernels spell rotations as shifts plus OR. Sarek's inspected PTX emitter preserves that spelling. Check the assembled SASS first: NVIDIA's compiler may already recognize rotations. A missed rotate optimization belongs upstream in Sarek, with exact tests and portable lowering. |
| 1 | Sweep blocks of 64, 128, 256 and 512 threads | The launch API accepts block dimensions; current search fixes 256. Record registers, spills, occupancy and throughput separately for A, B and C. Test `sarek.max_threads` only with matching launch sizes; Sarek exposes this pragma as a launch-bound hint. |
| 2 | Specialize the message-word patch positions | `wa`, `wl1`, `wl2`, `sl1` and `sl2` are constant for a loaded dump but runtime parameters today. Baking them into a per-layout kernel could remove uniform conditionals and masks. Compare compilation cost and native code, rather than assuming a gain. |
| 2 | Interleave two independent nonces per thread | Alternate operations from two states to expose instruction-level parallelism, instead of completing the current 100 nonces sequentially. This needs no matrix extension, but doubles much of the live state; measure whether dependency hiding outweighs occupancy loss and spills. |
| 3 | Split a state across lanes with warp shuffles | Sarek provides typed `warp_shuffle*` operations. This could reduce per-thread state if spills are measured, but consumes multiple lanes per nonce and adds communication between rounds. Keep the one-thread baseline unless the full search is faster. |
| 3 | Aggregate hit-buffer atomics within a warp | Sarek provides warp votes/shuffles. Relevant mainly for very short targets with frequent hits; for long names atomics are already rare. Any collective must run with the required participating lanes, including partial launch blocks, and retain overflow subdivision semantics. |

The backend sources inspected for these capabilities are
[launch bounds](https://github.com/mathiasbourgoin/Sarek/blob/a16fa1f7bc7f86b9a2ccf18439eefddf8369d6ab/sarek/tests/unit/test_launch_bounds.ml),
[warp shuffles](https://github.com/mathiasbourgoin/Sarek/blob/a16fa1f7bc7f86b9a2ccf18439eefddf8369d6ab/spoc/ir/Sarek_warp.ml)
and [PTX expression generation](https://github.com/mathiasbourgoin/Sarek/blob/a16fa1f7bc7f86b9a2ccf18439eefddf8369d6ab/sarek/codegen/Sarek_ir_ptx_expr.ml).
NVIDIA's [`shf`](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#logic-and-shift-instructions-shf)
and [`lop3`](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#logic-and-shift-instructions-lop3)
operate on 32-bit words: using them for Blake2b requires correct treatment of
both halves of a 64-bit word. They are not exposed as dedicated rotate/lop3
intrinsics in the inspected Sarek Int64 standard library.

## Reproducible source inspection

On 2026-11-17, generated source was inspected locally using OCaml 5.4.0 and
the Sarek revision above. No NVIDIA GPU or CUDA assembler was available.
The project's pinned revision, `d65ed53e`, has identical OCaml/C library sources;
the intervening changes affect workflows and contributor documentation.

```sh
dune exec test/kernel_source.exe -- a ptx > /tmp/search-a.ptx
dune exec test/kernel_source.exe -- b ptx > /tmp/search-b.ptx
dune exec test/kernel_source.exe -- c ptx > /tmp/search-c.ptx
dune exec test/kernel_source.exe -- a cuda > /tmp/search-a.cu
```

The exporter does not initialise a device. It uses a 256-thread block and the
PTX emitter's default `sm_86` target. On that Sarek revision, the three PTX
sources contain respectively 389/773/773 `shr.b64` instructions and
392/776/776 `shl.b64` instructions, with no explicit `shf` or `lop3`.
These are static source counts, including setup and filtering, not dynamic
instruction counts or evidence that the final machine code is inefficient.
PTX register declarations are virtual and do not establish hardware register
pressure or spills.

For each proposed variant, compare warmed runs on the same NVIDIA GPU, driver,
dump and target. Measure kernel time and end-to-end nonces/s separately, with
repeated runs for layouts A, host-penultimate B, kernel B and C. Record compiler
register/spill reports and SASS. Gate every variant on `dune test`, device vs
reference equivalence and whole-chunk comparisons. Any required Sarek feature
or codegen fix must go through its own repository's roster intake/run pipeline;
do not introduce a private backend workaround here.
