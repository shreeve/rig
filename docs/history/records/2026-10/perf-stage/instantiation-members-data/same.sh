#!/bin/sh
# same.sh A B: stdout and exit of binaries A and B agree on 7 projects at 1 and 4 checkers
W=$(cd "$(dirname "$0")" && pwd); P=/Users/shreeve/Data/Code/trig/misc/projects
for p in immer mitt neverthrow superstruct tiny-invariant ts-pattern zod3; do
  for c in 1 4; do
    r=""
    for v in $1 $2; do
      ( cd $P/$p && $W/$v/bin -p $([ -f tsconfig.trig.json ] && echo tsconfig.trig.json || echo tsconfig.json) --noEmit --checkers $c > $W/out.$v.$p.$c 2>&1; echo "exit $?" >> $W/out.$v.$p.$c )
    done
    if cmp -s $W/out.$1.$p.$c $W/out.$2.$p.$c; then r=same; else r=DIFFER; fi
    echo "$p checkers=$c $r ($(wc -l < $W/out.$1.$p.$c) lines, $(tail -1 $W/out.$1.$p.$c))"
  done
done
