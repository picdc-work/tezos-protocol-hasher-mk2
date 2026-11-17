Ranges, instances, resumption and progress, on the CPU backend (one chunk
of 10^8 nonces takes a few seconds). Reference: one uninterrupted run over
3 chunks, with progress records.

  $ mkdump 46 3 dump.txt
  $ octez-vanity-gpu --cpu dump.txt pa --start 1000 --count 3 --progress=1 > all.txt 2> all.err; echo $?
  0
  $ sort all.txt > all.sorted
  $ [ -s all.txt ] && echo nonempty
  nonempty
  $ grep -qvE '^P[1-9A-HJ-NP-Za-km-z]{50} [0-9]{16}$' all.txt || echo all-valid
  all-valid
  $ grep -qE '^progress elapsed=[0-9]+ rate=[0-9]+ tested=[0-9]+ next_chunk=[0-9]+ matches=[0-9]+$' all.err && echo progress
  progress
  $ tail -1 all.err
  stopped reason=completed next_chunk=1003 tested=300000000 matches=366306
  $ cut -c53-60 all.txt | sort -u
  00001000
  00001001
  00001002

Two instances cover the range exactly once.

  $ octez-vanity-gpu --cpu dump.txt pa --start 1000 --count 3 --instance 0/2 > split.txt 2>/dev/null
  $ octez-vanity-gpu --cpu dump.txt pa --start 1000 --count 3 --instance 1/2 >> split.txt 2>/dev/null
  $ sort split.txt | cmp - all.sorted && echo same
  same

A run stopped by --timeout resumes from its next_chunk with no gap and
no overlap.

  $ octez-vanity-gpu --cpu dump.txt pa --start 1000 --count 3 --timeout 1 > p1.txt 2> p1.err; echo $?
  0
  $ grep '^stopped' p1.err | cut -d' ' -f1-3
  stopped reason=timeout next_chunk=1001
  $ octez-vanity-gpu --cpu dump.txt pa --start 1001 --count 2 > p2.txt 2>/dev/null
  $ sort p1.txt p2.txt | cmp - all.sorted && echo same
  same

An interrupted run (SIGINT) exits with 130 and reports where to resume.

  $ octez-vanity-gpu --cpu dump.txt pa --start 1000 --count 3 > i1.txt 2> i1.err & pid=$!; sleep 3; kill -INT $pid; wait $pid; echo $?
  130
  $ grep '^stopped' i1.err | cut -d' ' -f1-2
  stopped reason=interrupted
  $ c=$(grep '^stopped' i1.err | sed 's/.*next_chunk=\([0-9]*\).*/\1/')
  $ octez-vanity-gpu --cpu dump.txt pa --start $c --count $((1003 - c)) > i2.txt 2>/dev/null
  $ sort i1.txt i2.txt | cmp - all.sorted && echo same
  same
