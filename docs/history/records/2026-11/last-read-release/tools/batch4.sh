#!/bin/bash
# batch4.sh: the cen4 census build (include reasons, per-thread reads) on six projects: c1 one round, c4 and c8
# three rounds each, on three disjoint 6-core sets; then main at c8 (reference stdout). Output in runs/ as
# cen4r{1,2,3}-PROJECT-MODE.
cd ~/cpuq/tmp/lastread
R=~/cpuq/tmp/lastread/runs
B=~/cpuq/tmp/lastread/cen4/trig
PROJS="typeorm nuxt webpack supabase-studio Compiler Compiler-Unions"
( for p in $PROJS; do ./run-lr.sh $B $R cen4r1 $p c1; ./run-lr.sh $B $R cen4r1 $p c4; ./run-lr.sh $B $R cen4r1 $p c8; done ) &
( for p in $PROJS; do CPUS=24-29,72-77 ./run-lr.sh $B $R cen4r2 $p c4; CPUS=24-29,72-77 ./run-lr.sh $B $R cen4r2 $p c8; done ) &
( for p in $PROJS; do CPUS=12-17,60-65 ./run-lr.sh $B $R cen4r3 $p c4; CPUS=12-17,60-65 ./run-lr.sh $B $R cen4r3 $p c8; CPUS=12-17,60-65 ./run-lr.sh ~/cpuq/tmp/lastread/base/trig $R base1 $p c8; done ) &
wait
