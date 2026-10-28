#!/bin/sh
set -u
R=${1:-5}
S=/zfs/worktrees/rig/tsrs-standing-2
TRIG=$S/packs/773978d1d-pgo/bin
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
D=/tmp/panel-trig
cd $D/tp
mk() {
  cat > tsconfig.$1.json <<J
{ "compilerOptions": { "module": "ESNext", "target": "ESNext", "moduleResolution": "bundler", "strict": true, "skipLibCheck": true, "esModuleInterop": true, "noEmit": true },
  "files": ["src/index.ts"$2] }
J
}
mk g0 ', "tests/large-exhaustive.test.ts", "tests/real-world.test.ts", "tests/distribute-unions.test.ts", "tests/find-selected.test.ts"'
mk g0b ', "tests/large-exhaustive.test.ts", "tests/real-world.test.ts"'
for v in trig tsrs; do for r in 1 2 3; do
  if [ $v = trig ]; then c="$TRIG -p tsconfig.base.json --singleThreaded --extendedDiagnostics"; else c="env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.base.json --singleThreaded --checkerAssignment go --noLazyMembers --extendedDiagnostics"; fi
  echo "basediag $v $(taskset -c 3 $c | grep -E 'Parse time|Bind time|Check time|Total time' | tr -s ' ' | tr '\n' ' ')"
done; done
r=1
while [ $r -le $R ]; do
  for f in base g0 g0b large-exhaustive real-world exhaustive-match; do
    for v in trig tsrs; do
      if [ $v = trig ]; then c="$TRIG -p tsconfig.$f.json --singleThreaded"; else c="env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.$f.json --singleThreaded --checkerAssignment go --noLazyMembers"; fi
      perf stat -x, -e duration_time,cpu_core/instructions/u,cpu_core/dTLB-load-misses/u -o $D/st -- taskset -c 3 $c > $D/out.$v.$f 2>&1
      echo "f=$f v=$v $(awk -F, '/^[0-9]/ { printf "%s=%s ", $3, $1 }' $D/st)r=$r"
    done
  done
  r=$((r + 1))
done
for f in g0 g0b; do cmp -s $D/out.trig.$f $D/out.tsrs.$f && echo "same $f" || echo "DIFF $f"; done
