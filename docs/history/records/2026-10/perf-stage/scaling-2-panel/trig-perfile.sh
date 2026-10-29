#!/bin/sh
# perfile.sh R: per-file single-thread time, Trig against tsrs, on P-core 3:
# each test file checked with src/index.ts alone, less src/index.ts alone.
set -u
R=${1:-5}
S=/zfs/worktrees/rig/tsrs-standing-2
TRIG=$S/packs/773978d1d-pgo/bin
TSRS=/zfs/trig-pup/tsrs-shipped/package/tsrs
D=/tmp/panel-trig
rm -rf $D; mkdir -p $D; cp -r $S/trig/misc/projects/ts-pattern $D/tp
cd $D/tp
mk() { # name, extra files (json list tail)
  cat > tsconfig.$1.json <<J
{ "compilerOptions": { "module": "ESNext", "target": "ESNext", "moduleResolution": "bundler", "strict": true, "skipLibCheck": true, "esModuleInterop": true, "noEmit": true },
  "files": ["src/index.ts"$2] }
J
}
mk base ""
FILES="large-exhaustive real-world distribute-unions find-selected exhaustive-match intersection-and-union deep-exclude select record variadic-tuples"
for f in $FILES; do mk $f ", \"tests/$f.test.ts\""; done
# libs: an empty file with esnext (no dom) and the default (esnext.full)
mkdir -p $D/e; cd $D/e; echo 'export const x = 1' > a.ts
echo '{ "compilerOptions": { "target": "ESNext", "lib": ["esnext"], "noEmit": true, "skipLibCheck": true }, "files": ["a.ts"] }' > tsconfig.nodom.json
echo '{ "compilerOptions": { "target": "ESNext", "noEmit": true, "skipLibCheck": true }, "files": ["a.ts"] }' > tsconfig.full.json
for c in nodom full; do for r in 1 2 3; do
  echo "lib $c trig $(taskset -c 3 $TRIG -p tsconfig.$c.json --singleThreaded --extendedDiagnostics | grep -E 'Parse time|Bind time|^Files' | tr -s ' ' | tr '\n' ' ')"
  echo "lib $c tsrs $(RAYON_NUM_THREADS=1 taskset -c 3 $TSRS -p tsconfig.$c.json --singleThreaded --extendedDiagnostics | grep -E 'Parse time|Bind time|^Files' | tr -s ' ' | tr '\n' ' ')"
done; done
cd $D/tp
r=1
while [ $r -le $R ]; do
  for f in base $FILES; do
    for v in trig tsrs; do
      if [ $v = trig ]; then c="$TRIG -p tsconfig.$f.json --singleThreaded"; else c="env RAYON_NUM_THREADS=1 $TSRS -p tsconfig.$f.json --singleThreaded --checkerAssignment go --noLazyMembers"; fi
      perf stat -x, -e duration_time,instructions:u -o $D/st -- taskset -c 3 $c > $D/out.$v.$f 2>&1
      echo "f=$f v=$v $(awk -F, '/^[0-9]/ { printf "%s=%s ", $3, $1 }' $D/st)r=$r"
    done
  done
  r=$((r + 1))
done
for f in base $FILES; do cmp -s $D/out.trig.$f $D/out.tsrs.$f && echo "same $f" || echo "DIFF $f"; done
