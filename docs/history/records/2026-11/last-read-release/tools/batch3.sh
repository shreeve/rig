#!/bin/bash
# batch3.sh: the per-thread census build (cen3) on six projects: c4 three rounds (on two disjoint 6-core sets, so two
# runs at a time), c1 one round. Output in ~/cpuq/tmp/lastread/runs as cen3r{1,2,3}-PROJECT-MODE.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
B=~/cpuq/tmp/lastread/cen3/trig
PROJS="typeorm nuxt webpack supabase-studio Compiler Compiler-Unions"
( for p in $PROJS; do ./run-lr.sh $B $R cen3r1 $p c4; ./run-lr.sh $B $R cen3r3 $p c4; done ) &
( for p in $PROJS; do CPUS=24-29,72-77 ./run-lr.sh $B $R cen3r2 $p c4; done ) &
( for p in $PROJS; do ./run-lr.sh $B $R cen3r1 $p c1; done ) &
wait
