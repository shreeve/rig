#!/bin/bash
# model2.sh: the floors' offline model (floors.py model) on the cen4 runs of four projects, into floors-model2.txt.
cd ~/cpuq/tmp/lastread/runs
for p in typeorm nuxt webpack supabase-studio; do
  python3 ../floors.py model base1-$p-c1.out cen4r1-$p-c1.err cen4r1-$p-c4.err cen4r2-$p-c4.err cen4r3-$p-c4.err cen4r1-$p-c8.err cen4r2-$p-c8.err cen4r3-$p-c8.err
done > ../floors-model2.txt 2>&1
