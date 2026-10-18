# The evidence that a program ran cannot be faked by what sits at a path,
# shared by another run, or lost to a nested run; and a matrix program
# that never ran, or that a signal killed, never passes.
source "$ROOT/test/cli/_lib.sh"
ZIG_REAL=$(command -v "${ZIG:-zig}")
printf 'sub main()\n  print("ran")\n' >ok.rig
: >afile
bad=$PWD/afile/store
printf '#!/bin/sh\necho "zig: boom" >&2\nexit 1\n' >failzig
# A Zig that fails once the run sharing its path has made the file.
printf '#!/bin/sh\n: >"%s/ready"\nn=0\nwhile [ ! -e "%s/shared" ] && [ $n -lt 600 ]; do sleep 0.1; n=$((n + 1)); done\necho "zig: boom" >&2\nexit 1\n' "$PWD" "$PWD" >slowzig
chmod +x failzig slowzig

# rig clears the caller's file first, fails when it cannot, and creates it
# only once the program has started.
mkdir sdir
out=$(RIG_RUN_STARTED=$PWD/sdir ZIG=$PWD/failzig "$RIG" run ok.rig 2>&1); expect_rc $? 125 "a directory at RIG_RUN_STARTED"
expect_has "$out" "rig: the program did not run" "a directory at RIG_RUN_STARTED"
: >stale
out=$(RIG_RUN_STARTED=$PWD/stale RIG_BUILD_STORE=$bad "$RIG" run ok.rig 2>&1); expect_rc $? 125 "a stale file, then a failure"
[[ -e stale ]] && fail "a stale RIG_RUN_STARTED file outlived a run that failed"

# Two runs sharing one path: the one that fails says so, though the other
# made the file. The one that runs is a program that never sees
# RIG_RUN_STARTED, so a `rig run` it starts cannot touch the caller's
# file, and whose own status, above 128, is not a signal's.
printf 'use std.os\n\nfun main() -> Int\n  print(os.env("RIG_RUN_STARTED") ?? "unset")\n  137\n' >env.rig
RIG_RUN_STARTED=$PWD/shared ZIG=$PWD/slowzig "$RIG" run ok.rig >a.out 2>&1 &
a=$!
n=0
while [[ ! -e ready && $n -lt 600 ]]; do sleep 0.1; n=$((n + 1)); done
out=$(RIG_RUN_STARTED=$PWD/shared "$RIG" run env.rig 2>err.txt); expect_rc $? 137 "a program's own 137"
expect_eq "$out" "unset" "RIG_RUN_STARTED in the program's environment"
expect_eq "$(cat err.txt)" "" "a program's own 137 says nothing"
[[ -f shared ]] || fail "rig did not create RIG_RUN_STARTED for a program that ran"
wait $a; expect_rc $? 125 "the failing one of two runs sharing a path"

# A store entry whose `o/` holds no binary for its manifests heals.
store=$PWD/store
out=$(RIG_BUILD_STORE=$store "$RIG" run ok.rig 2>&1); expect_eq "$out" "ran" "first build"
find "$store" -path '*/o/*' -name __rig_main -type f | while IFS= read -r b; do rm -rf "$(dirname "$b")"; done
out=$(RIG_BUILD_STORE=$store "$RIG" run ok.rig 2>/dev/null); expect_eq "$out" "ran" "an entry whose binary is gone"

# A program a signal kills after it started, with nothing on stderr, fails
# in the matrix.
printf '#!/bin/sh\nif [ "$1" = run ]; then "%s" "$@"; kill -KILL $$; fi\nexec "%s" "$@"\n' "$ZIG_REAL" "$ZIG_REAL" >killzig
chmod +x killzig
o=$(ZIG=$PWD/killzig RIG_BUILD_STORE= python3 "$ROOT/test/matrix.py" -k int.print.place 2>&1); expect_rc $? 1 "a matrix program killed by a signal"
expect_has "$o" "killed by signal 9" "a matrix program killed by a signal"

# matrix.py --keep DIR runs one at a time in DIR: a run waits for the one
# holding DIR, here a lock held until the run says it waits.
mkdir kept
python3 -c '
import fcntl, os, sys, time
f = open(sys.argv[1] + "/.matrix.lock", "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[1] + "/held", "w").close()
for _ in range(600):
    if os.path.exists(sys.argv[2]) and "waiting for the matrix run in" in open(sys.argv[2]).read():
        break
    time.sleep(0.05)
' kept "$PWD/kept.out" &
n=0
while [[ ! -e kept/held && $n -lt 600 ]]; do sleep 0.1; n=$((n + 1)); done
python3 "$ROOT/test/matrix.py" --keep "$PWD/kept" -k int.print.place >kept.out 2>&1; expect_rc $? 0 "a kept matrix run after another: $(cat kept.out)"
expect_has "$(cat kept.out)" "waiting for the matrix run in" "a kept matrix run waits for the one holding DIR"
wait

exit 0
