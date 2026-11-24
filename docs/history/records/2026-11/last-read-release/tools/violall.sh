#!/bin/bash
# violall.sh: the read paths of every floor replay's violations (viol.py, symbolized against the cen5 build).
cd ~/cpuq/tmp/lastread/runs
for p in typeorm nuxt webpack supabase-studio; do
  for r in fl1t-$p-c1 fl2t-$p-c1 fl1p-$p-c4 fl2p-$p-c4; do
    [ -f $r.err ] || continue
    echo "== $r: $(grep ^LRFL $r.err | cut -f2-)"
    python3 ../viol.py cen4r1-$p-c1.err $r.err ../cen5/trig | sed -n '/^PATHS/,$p'
  done
done
