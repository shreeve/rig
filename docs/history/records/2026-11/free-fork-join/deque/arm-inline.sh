#!/bin/bash
# The measuring arm "fast": a fork's push and its join inlined into the
# program's code in a build preempted by signal, as a build with yield
# checks has them. UNSOUND (see deque.md): measuring only.
set -e
f=${1:?}/src/sched.zig
sed -i '' 's/^    if (preempt) mustNotBeInCode(@returnAddress());$/    \/\/ (arm: no check)/' $f
sed -i '' 's/^    const waitEnd = if (preempt) waitEndApart else waitEndIn;$/    const waitEnd = waitEndIn;/' $f
sed -i '' 's/^pub const startAt = if (preempt) startAtApart else startAtIn;$/pub const startAt = startAtIn;/' $f
grep -c 'arm: no check\|const waitEnd = waitEndIn;\|pub const startAt = startAtIn;' $f
