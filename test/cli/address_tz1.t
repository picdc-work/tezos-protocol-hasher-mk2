Address vanity, tz1 (Ed25519), on the CPU backend, as address_tz4.t. The key is
the 32-byte seed (edsk, 54 characters), enumerated on the device: a chunk of
2^20 seeds takes a few seconds on the CPU, so the range tests use 2 chunks.
The independent helper derives the public key with mirage-crypto-ec
(tz2_check --scheme tz1). Addresses and keys differ at each run: the checks
are on shapes, modes and relations, never on values, and nothing prints a key
file.

Input errors are reported before any device is used, with exit status 2 and
nothing on stdout.

  $ octez-vanity-gpu --cpu --address tz1 0
  error: target "0": character '0' cannot appear in a base58 address (valid: 1-9, A-H, J-N, P-Z, a-k, m-z)
  [2]
  $ octez-vanity-gpu --cpu --case-sensitive --address tz1 Ab
  error: target "Ab": the first character 'A' cannot follow tz1 (reachable: KLMNPQRSTUVWXYZabcdefghi)
  [2]
  $ octez-vanity-gpu --cpu --address tz1 tz1ab
  error: target "tz1ab": give only the part after tz1
  [2]
  $ octez-vanity-gpu --cpu --address tz1 abcdefghi
  error: target "abcdefghi": the name must have 1 to 8 characters
  [2]
  $ octez-vanity-gpu --cpu --address tz1
  error: usage: octez-vanity-gpu --address tz1 [OPTIONS] NAME
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --start 3
  error: --start, --count and --instance need --base-key-file (without it every run draws a fresh base key, so a range means nothing)
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --count 2
  error: --start, --count and --instance need --base-key-file (without it every run draws a fresh base key, so a range means nothing)
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --instance 0/2
  error: --start, --count and --instance need --base-key-file (without it every run draws a fresh base key, so a range means nothing)
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --verify 1 dump.txt
  error: --verify works on protocol hashes only: it cannot be used with --address
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --bench 1 dump.txt
  error: --bench works on protocol hashes only: it cannot be used with --address
  [2]
  $ octez-vanity-gpu --cpu --address tz1 ab --key-dir no-such-dir
  error: --key-dir "no-such-dir": not a directory
  [2]
  $ octez-vanity-gpu --cpu ab dump.txt --key-dir .
  error: --key-dir only applies with --address
  [2]
  $ octez-vanity-gpu --cpu ab dump.txt --base-key-file b.key
  error: --base-key-file only applies with --address
  [2]
  $ ls | wc -l
  0

A 1-character search: exactly one line "<address> <path>", a key file of mode
600 with one line starting with edsk, the key on neither stdout nor stderr,
and the same address recomputed independently from the key file.

  $ mkdir keys
  $ octez-vanity-gpu --cpu --address tz1 a --max-matches 1 --key-dir keys > out.txt 2> err.txt; echo $?
  0
  $ wc -l < out.txt
  1
  $ read addr path < out.txt
  $ echo "$addr" | grep -cE '^tz1[1-9A-HJ-NP-Za-km-z]{33}$'
  1
  $ echo "$addr" | cut -c4 | tr A-Z a-z
  a
  $ [ "$path" = "keys/$addr.key" ] && echo path-ok
  path-ok
  $ ls keys | wc -l
  1
  $ stat -c %a "$path"
  600
  $ wc -l < "$path"
  1
  $ grep -cE '^edsk[1-9A-HJ-NP-Za-km-z]{50}$' "$path"
  1
  $ grep -F -q -f "$path" out.txt err.txt || echo absent
  absent
  $ [ "$(tz2_check --scheme tz1 "$path")" = "$addr" ] && echo recomputed
  recomputed
  $ tail -1 err.txt | cut -d' ' -f1-2
  stopped reason=max-matches
  $ grep -c '^stopped' err.txt
  1

A 2-character search (case-insensitive Ab, then case-sensitive Lb: after tz1
the first character is limited to K-Z and a-i), same checks.

  $ octez-vanity-gpu --cpu --address tz1 Ab --max-matches 1 --key-dir keys > out2.txt 2> err2.txt; echo $?
  0
  $ read addr2 path2 < out2.txt
  $ wc -l < out2.txt
  1
  $ echo "$addr2" | cut -c4-5 | tr A-Z a-z
  ab
  $ stat -c %a "$path2"
  600
  $ grep -F -q -f "$path2" out2.txt err2.txt || echo absent
  absent
  $ [ "$(tz2_check --scheme tz1 "$path2")" = "$addr2" ] && echo recomputed
  recomputed
  $ octez-vanity-gpu --cpu --case-sensitive --address tz1 Lb --max-matches 1 --key-dir keys > out3.txt 2> err3.txt; echo $?
  0
  $ read addr3 path3 < out3.txt
  $ echo "$addr3" | cut -c4-5
  Lb
  $ [ "$(tz2_check --scheme tz1 "$path3")" = "$addr3" ] && echo recomputed
  recomputed
  $ ls keys | wc -l
  3

Start-up and rate diagnostics are on stderr and name no key.

  $ grep -c '^device: ' err2.txt
  1
  $ grep -c '^target: tz1"ab", case-insensitive' err2.txt
  1
  $ grep -c '^kernel: seeds tz1 (ed25519, 8-bit windows), 4096 threads x 16 seeds per launch, 16 launches per chunk$' err2.txt
  1

Without --base-key-file two runs draw different keys.

  $ octez-vanity-gpu --cpu --address tz1 a --max-matches 1 --key-dir keys 2>/dev/null | cut -d' ' -f1 > a1.txt
  $ octez-vanity-gpu --cpu --address tz1 a --max-matches 1 --key-dir keys 2>/dev/null | cut -d' ' -f1 > a2.txt
  $ cmp -s a1.txt a2.txt || echo different
  different

A base-key file: created on first use with mode 600 and 64 hexadecimal
characters, reused afterwards. Ranges are reproducible: the same range gives
the same addresses (in another key directory, because a key file is never
overwritten), and two instances cover the same matches as the whole range.

  $ mkdir k1 k2 k3 k4 k5
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --key-dir k1 > r1.txt 2> r1.err; echo $?
  0
  $ stat -c %a base.key
  600
  $ wc -c < base.key
  65
  $ grep -cE '^[0-9a-f]{64}$' base.key
  1
  $ cp base.key base.copy
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --key-dir k2 > r2.txt 2> r2.err; echo $?
  0
  $ cmp base.key base.copy && echo base-key-unchanged
  base-key-unchanged
  $ [ -s r1.txt ] && echo nonempty
  nonempty
  $ cut -d' ' -f1 r1.txt | sort > r1.sorted
  $ cut -d' ' -f1 r2.txt | sort | cmp - r1.sorted && echo reproducible
  reproducible
  $ ls k1 | wc -l | tr -d ' ' > n1
  $ wc -l < r1.txt | tr -d ' ' | cmp - n1 && echo one-file-per-match
  one-file-per-match
  $ tail -1 r1.err | sed 's/matches=[0-9]*$/matches=M/'
  stopped reason=completed next_chunk=2 tested=2097152 matches=M
  $ stat -c %a k1/*.key | sort -u
  600
  $ [ "$(cat k1/*.key | grep -c '^edsk')" = "$(wc -l < r1.txt | tr -d ' ')" ] && echo all-edsk
  all-edsk
  $ for f in $(cut -d' ' -f2 r1.txt | head -3); do a=$(basename $f .key); [ "$(tz2_check --scheme tz1 $f)" = "$a" ] && echo recomputed; done
  recomputed
  recomputed
  recomputed
  $ cat k1/*.key | grep -F -q -f /dev/stdin r1.txt r1.err; echo $?
  1
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --instance 0/2 --key-dir k3 > s0.txt 2> s0.err; echo $?
  0
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --instance 1/2 --key-dir k4 > s1.txt 2> s1.err; echo $?
  0
  $ cat s0.txt s1.txt | cut -d' ' -f1 | sort | cmp - r1.sorted && echo same-matches
  same-matches
  $ tail -1 s0.err | cut -d' ' -f1-3
  stopped reason=completed next_chunk=1
  $ tail -1 s1.err | cut -d' ' -f1-3
  stopped reason=completed next_chunk=2

A base-key file is a different key space: another file gives other addresses.

  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file other.key --start 0 --count 1 --key-dir k5 2>/dev/null | cut -d' ' -f1 | sort > o.sorted
  $ [ -s o.sorted ] && ! cmp -s o.sorted r1.sorted && echo different-space
  different-space

The same range into the same directory finds the keys already written: they
are reported on stderr, not printed again, not counted, and the files are
left unchanged.

  $ f=$(head -1 r1.txt | cut -d' ' -f2); cp $f before.key
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --key-dir k1 > e.txt 2> e.err; echo $?
  0
  $ wc -l < e.txt | tr -d ' '
  0
  $ grep -c '^already found: tz1' e.err | cmp - n1 && echo all-already-found
  all-already-found
  $ tail -1 e.err
  stopped reason=completed next_chunk=2 tested=2097152 matches=0
  $ cmp $f before.key && echo untouched
  untouched
  $ ls k1 | wc -l | tr -d ' ' | cmp - n1 && echo no-new-file
  no-new-file

Resuming after --max-matches gives the next match, not the same one again.

  $ mkdir k6
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --max-matches 1 --key-dir k6 2>/dev/null | cut -d' ' -f1 > m1.txt
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --max-matches 1 --key-dir k6 2>/dev/null | cut -d' ' -f1 > m2.txt
  $ wc -l < m1.txt | tr -d ' '; wc -l < m2.txt | tr -d ' '
  1
  1
  $ cmp -s m1.txt m2.txt || echo next-match
  next-match
  $ ls k6 | wc -l | tr -d ' '
  2

A file with that name holding something else is never overwritten: the
search stops with exit status 4 and leaves it unchanged.

  $ mkdir k7; g=k7/$(head -1 r1.txt | cut -d' ' -f1).key; printf 'precious\n' > $g
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 0 --count 2 --key-dir k7 > e.txt 2> e.err; echo $?
  4
  $ grep -c '^error: key file: k7/tz1.*\.key: File exists$' e.err
  1
  $ tail -1 e.err | cut -d' ' -f1-2
  stopped reason=key-file-error
  $ cat $g
  precious

A key directory that is not writable is refused before the search starts.

  $ mkdir ro; chmod 555 ro
  $ octez-vanity-gpu --cpu --address tz1 abc --key-dir ro > ro.out 2> ro.err; echo $?
  2
  $ sed 's/probe-[0-9]*/probe-PID/' ro.err
  error: key directory "ro" is not writable: ro/.octez-vanity-probe-PID: Permission denied
  $ wc -c < ro.out | tr -d ' '
  0
  $ chmod 755 ro

A base-key file with a mode wider than 600, or a malformed one, is refused.

  $ cp base.key wide.key; chmod 644 wide.key
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file wide.key --start 0 --count 1
  error: --base-key-file: wide.key: mode 0644 is wider than 0600 (run chmod 600)
  [2]
  $ printf 'zz\n' > bad.key; chmod 600 bad.key
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file bad.key --start 0 --count 1
  error: --base-key-file: bad.key: expected 64 hexadecimal characters
  [2]
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file base.key --start 17592186044416 --count 1
  error: --start 17592186044416: expected a chunk in [0, 2^44)
  [2]

Every 32-byte value is a valid tz1 base: there is no range check, unlike the
walk schemes (all zero and all ones are accepted; a stop on timeout 0 starts
no launch).

  $ printf '%064d\n' 0 > zero.key; chmod 600 zero.key
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file zero.key --timeout 0 --key-dir k5 2>&1 >/dev/null | tail -1 | cut -d' ' -f1-2
  stopped reason=timeout
  $ printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n' > ones.key; chmod 600 ones.key
  $ octez-vanity-gpu --cpu --address tz1 abc --base-key-file ones.key --timeout 0 --key-dir k5 2>&1 >/dev/null | tail -1 | cut -d' ' -f1-2
  stopped reason=timeout
