Input errors are reported before any device is used, with exit status 2
and nothing on stdout.

  $ mkdump 46 1 dump.txt
  $ octez-vanity-gpu dump.txt paris0
  error: target "paris0": character '0' cannot appear in a base58 hash (valid: 1-9, A-H, J-N, P-Z, a-k, m-z)
  [2]
  $ octez-vanity-gpu dump.txt abcdefghij
  error: target "abcdefghij": the name must have 1 to 9 characters
  [2]
  $ printf 'hello\n' > bad.txt
  $ octez-vanity-gpu bad.txt pa
  error: bad.txt: expected the dump to end with "(* Vanity nonce: <16 digits> *)\n" (found "hello\n"); set the nonce to 0000000000000000 before dumping
  [2]
  $ printf '%2000s(* Vanity nonce: TBD *)\n' x > tbd.txt
  $ octez-vanity-gpu tbd.txt pa
  error: tbd.txt: expected the dump to end with "(* Vanity nonce: <16 digits> *)\n" (found "...                                   x(* Vanity nonce: TBD *)\n"); set the nonce to 0000000000000000 before dumping
  [2]
  $ octez-vanity-gpu --case-sensitive dump.txt Ix
  error: target "Ix": character 'I' cannot appear in a base58 hash (valid: 1-9, A-H, J-N, P-Z, a-k, m-z)
  [2]

A CPU search prints exactly K lines in the C hasher format, each one
confirmed by the independent digestif oracle.

  $ octez-vanity-gpu --cpu dump.txt pa --max-matches 2 > out.txt 2> err.txt; echo $?
  0
  $ wc -l < out.txt
  2
  $ grep -cE '^P[1-9A-HJ-NP-Za-km-z]{50} [0-9]{16}$' out.txt
  2
  $ while read h n; do [ "$(mkdump --hash dump.txt $n)" = "$h" ] && echo confirmed; done < out.txt
  confirmed
  confirmed
  $ tail -1 err.txt | cut -d' ' -f1-2
  stopped reason=max-matches
