#!/bin/bash
# board-mixed.sh LOAD ROUNDS RAW [VARIANTS]: bench/mixed at 60k, 100k, 120k
# over 5,000 idle connections; LOAD quiet or spin (8 spinning threads,
# ended with the board).
S=/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/f68c938c-4593-4da6-8285-b3d41b0720f5/scratchpad/pollers
cd /Users/shreeve/Data/Code/worktrees/rig/poller-spread
LOAD=$1; N=$2; RAW=$3; V=${4:-base,base2,own,spread}
P=
if [[ $LOAD == spin ]]; then $S/spin 8 1180 & P=$!; sleep 1; fi
bench/mixed/bench-mixed --out $S/mixed --time-only --variants $V --rates 60000,100000,120000 --rounds $N --raw $RAW
[[ -n $P ]] && { kill $P; wait $P 2>/dev/null; }
echo board-done
