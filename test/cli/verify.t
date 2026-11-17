--verify prints the protocol hash over the full dump, identical to the
independent digestif oracle.

  $ mkdump 46 2 dump.txt
  $ octez-vanity-gpu --verify 0123456789012345 dump.txt > got.txt; echo $?
  0
  $ mkdump --hash dump.txt 0123456789012345 > expected.txt
  $ cmp got.txt expected.txt && echo identical
  identical
  $ mkdump 3 5 c.txt
  $ [ "$(octez-vanity-gpu --verify 9999999999999999 c.txt)" = "$(mkdump --hash c.txt 9999999999999999)" ] && echo identical
  identical

The nonce must have exactly 16 digits.

  $ octez-vanity-gpu --verify 12345 dump.txt
  error: nonce "12345": expected exactly 16 decimal digits
  [2]
  $ octez-vanity-gpu --verify 01234567890123x5 dump.txt
  error: nonce "01234567890123x5": expected exactly 16 decimal digits
  [2]

An empty dump returns an input error, including in verification mode.

  $ touch empty.txt
  $ octez-vanity-gpu --verify 0000000000000000 empty.txt
  error: empty.txt: expected the dump to end with "(* Vanity nonce: <16 digits> *)\n" (found ""); set the nonce to 0000000000000000 before dumping
  [2]
