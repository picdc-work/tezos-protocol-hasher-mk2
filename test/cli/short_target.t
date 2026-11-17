Very short targets produce a very large output: the tool warns.

  $ mkdump 46 4 dump.txt
  $ octez-vanity-gpu --cpu dump.txt p --max-matches 5 2> err.txt | wc -l
  5
  $ grep -c 'warning: target shorter than 3 characters' err.txt
  1

An effectively unreachable target is announced with its expected cost.

  $ octez-vanity-gpu --cpu --case-sensitive dump.txt zzzzzzzzz --timeout 1 2> err.txt; echo $?
  0
  $ grep -c 'warning: target effectively unreachable' err.txt
  1
  $ tail -1 err.txt | cut -d' ' -f1-2
  stopped reason=timeout
