#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
ulimit -n 20000; O=$S/raw/syscalls.txt
for r in 1 2; do
python3 $S/mixprof.py $O.quiet 120000 base=$S/mixed/base tokio=$S/mixed/tokio spread=$S/mixed/spread
$S/spin 8 100 & P=$!; sleep 1
python3 $S/mixprof.py $O.spin 120000 base=$S/mixed/base tokio=$S/mixed/tokio spread=$S/mixed/spread
kill $P; wait $P 2>/dev/null
done
echo done
