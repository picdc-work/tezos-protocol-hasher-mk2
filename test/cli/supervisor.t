The supervisor uses controlled workers to cover errors and signals without
requiring multiple GPUs. Each probe interrupts itself after two seconds if
the supervisor fails to stop its peers.

  $ supervisor-probe completed 2>err.txt
  $ tail -1 err.txt
  stopped reason=completed tested=200000000 matches=0

Fewer chunks than devices must not start a worker with --count 0.

  $ supervisor-probe empty-slice 2>err.txt
  $ cat err.txt
  stopped device=1 slice=1000+1 reason=completed next_chunk=1001 tested=100000000 matches=0
  stopped reason=completed tested=100000000 matches=0
  $ supervisor-probe empty-range 2>err.txt
  $ cat err.txt
  stopped reason=completed tested=0 matches=0

A reported device error stops the peer and retains exit code 3, even when
the peer's receipt says interrupted. Its resume position remains visible.

  $ supervisor-probe reported-failure 2>err.txt
  [3]
  $ tail -1 err.txt
  stopped reason=device-error tested=0 matches=0
  $ grep -c '^stopped device=0 ' err.txt
  1
  $ grep '^stopped device=1 ' err.txt
  stopped device=1 slice=1001+1 reason=interrupted next_chunk=1001 tested=0 matches=0

Abnormal exits and a missing receipt must also stop peers promptly.

  $ supervisor-probe silent-failure 2>err.txt
  [3]
  $ tail -1 err.txt
  stopped reason=device-error tested=0 matches=0
  $ supervisor-probe missing-receipt 2>err.txt
  [3]
  $ tail -1 err.txt
  stopped reason=device-error tested=0 matches=0
  $ supervisor-probe bad-exit-after-receipt 2>err.txt
  [3]
  $ tail -1 err.txt
  stopped reason=device-error tested=0 matches=0

Intentional stops keep their original result despite signalling peers.

  $ supervisor-probe max-matches 2>err.txt
  match
  $ tail -1 err.txt
  stopped reason=max-matches tested=0 matches=1
  $ supervisor-probe interrupted 2>err.txt
  [130]
  $ tail -1 err.txt
  stopped reason=interrupted tested=0 matches=0
