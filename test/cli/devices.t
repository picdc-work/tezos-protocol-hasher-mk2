  $ octez-vanity-gpu --list-devices | grep -cE '^[0-9]+ Native '
  1
  $ mkdump 46 1 dump.txt
  $ octez-vanity-gpu --device 99 dump.txt pa
  error: device "99": no such device index (see --list-devices)
  [3]
  $ octez-vanity-gpu --device Nope dump.txt pa
  error: device "Nope": no such device or framework (see --list-devices)
  [3]
  $ octez-vanity-gpu --start 100000000 dump.txt pa
  error: --start 100000000: expected a chunk in [0, 10^8)
  [2]
  $ octez-vanity-gpu --instance 2/2 dump.txt pa
  error: --instance "2/2": expected I/N with 0 <= I < N
  [2]
