#!/bin/bash
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
ulimit -n 20000; O=$S/raw/usersys.txt
for r in 1 2 3; do
  echo "# quiet" >> $O
  python3 $S/usersys.py $O 120000 base=$S/mixed/base tokio=$S/mixed/tokio
  $S/spin 8 60 & P=$!; sleep 1
  echo "# spin" >> $O
  python3 $S/usersys.py $O 120000 base=$S/mixed/base tokio=$S/mixed/tokio
  kill $P; wait $P 2>/dev/null
done
echo done
