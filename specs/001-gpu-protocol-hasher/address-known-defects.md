# Address search: known minor defects

Defects of `octez-vanity-gpu --address` found by the independent review of 2026-11-17 and left open. None produces a wrong key or exposes a secret: every reported address is derived on the host from the key that is written. Each entry says what was observed, what it costs, and a possible fix.

"Confirmed" means the reviewer reproduced it; "plausible" means it follows from the code and was not reproduced.

## Search

1. **A hand-chosen base key near 0 or near the group order loses batches** (tz2, tz3, tz4). Confirmed. A base-key file accepts any scalar in `[1, n-1]`. The walk adds table points `i·G` to the thread base points; when a base point equals plus or minus a table point, the batched inversion meets a zero and the whole batch of 256 offsets is wrong. Its hits fail the host confirmation, so the batch is missed silently. With a base drawn from `/dev/urandom` the probability is about 2^-240 per batch; with base `1`, the first batch of chunk 0 is always missed. Fix: refuse a base within 2^64 of 0 or of `n`, or print a warning.

2. **In a multi-device search, a key-file error in a child is reported as a device error.** Read in the code (`src/multi_device.ml`), never run: no machine with two GPUs was available. A child that stops with exit status 4 (a file named `<address>.key` holds something else) counts as a failed child, so the parent prints `stopped reason=device-error` and exits with status 3, not 4. The child's own message on stderr is correct.

## Files

3. **The base-key file is not created atomically.** Confirmed. The file is opened with `O_EXCL`, then written. Of four processes started together on a missing file, two read it empty and stopped with exit status 2 (`expected 64 hexadecimal characters`), without printing any secret. A crash between the two steps leaves an empty file that later runs refuse. Fix: write a temporary file in the same directory, then `link` it to the final name.

4. **An existing key file is accepted whatever its mode.** Confirmed. When `<address>.key` already holds the same key, the match is reported as `already found` and the file is left as it is: a file that someone made `0644` stays `0644`, with no warning. Fix: warn, or refuse, when the mode is wider than `0600`.

5. **`already found` goes to stderr only.** Plausible. A consumer that read stdout and died after the key file was written does not see that address again when the search is resumed. The name of the file still gives it.

6. **The writability probe can collide with a leftover.** Plausible. The probe file is `.octez-vanity-probe-<pid>`. A leftover from a killed process with the same PID makes the directory look not writable (exit status 2). The probe does not detect a full disk or a quota; a write that fails later stops the search with exit status 4 and removes the partial file.

7. **The default key directory is the current directory.** By design, but a search with a 1 or 2 character name writes one key file per match, possibly thousands, where the command was started. Use `--key-dir`.

## Code and tests

8. **The field primes are written in three places** (`src/curve_ref.ml`, `src/field_run.ml`, `gen/field_emit.ml`) and no test compares them directly. A mismatch would fail the kernel tests against the host reference, so it would not go unnoticed, but a direct equality test would say where.

9. **`Multi_device.run` is long** (over 130 lines), above the 50-line limit used elsewhere in the project.

## Not verified

- A search on several devices at once.
- Address kernels on the CUDA/C and HIP backends; only Native and CUDA/PTX were run.
- An import of a generated key by `octez-client`. Keys and addresses are checked against independent libraries (`mirage-crypto-ec`, `secp256k1-internal`, `bls12-381`) and against encodings taken from Octez.
- Mutation testing of the test suite.
