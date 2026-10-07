# The evidence that a program ran cannot be faked by what sits at a path,
# shared by another run, or lost to a nested run; and a test that never
# ran, or a program a signal killed, never passes, is never reported as
# the known bug, and never holds a pending example.
source "$ROOT/test/cli/_lib.sh"
ZIG_REAL=$(command -v "${ZIG:-zig}")
printf 'sub main()\n  print("ran")\n' >ok.rig
: >afile
bad=$PWD/afile/store
printf '#!/bin/sh\necho "zig: boom" >&2\nexit 1\n' >failzig
printf '#!/bin/sh\n[ "$1" = run ] && sleep 2\necho "zig: boom" >&2\nexit 1\n' >slowzig
chmod +x failzig slowzig

# rig clears the caller's file first, fails when it cannot, and creates it
# only once the program has started.
mkdir sdir
out=$(RIG_RUN_STARTED=$PWD/sdir ZIG=$PWD/failzig "$RIG" run ok.rig 2>&1); expect_rc $? 125 "a directory at RIG_RUN_STARTED"
expect_has "$out" "rig: the program did not run" "a directory at RIG_RUN_STARTED"
: >stale
out=$(RIG_RUN_STARTED=$PWD/stale RIG_BUILD_STORE=$bad "$RIG" run ok.rig 2>&1); expect_rc $? 125 "a stale file, then a failure"
[[ -e stale ]] && fail "a stale RIG_RUN_STARTED file outlived a run that failed"

# Two runs sharing one path: the one that fails says so.
RIG_RUN_STARTED=$PWD/shared ZIG=$PWD/slowzig "$RIG" run ok.rig >a.out 2>&1 &
a=$!
sleep 1
RIG_RUN_STARTED=$PWD/shared "$RIG" run ok.rig >/dev/null 2>&1
wait $a; expect_rc $? 125 "the failing one of two runs sharing a path"

# The program never sees RIG_RUN_STARTED, so a `rig run` it starts cannot
# touch the caller's file.
printf 'use std.os\n\nsub main()\n  print(os.env("RIG_RUN_STARTED") ?? "unset")\n' >env.rig
out=$(RIG_RUN_STARTED=$PWD/e1 "$RIG" run env.rig 2>&1); expect_eq "$out" "unset" "RIG_RUN_STARTED in the program's environment"
[[ -f e1 ]] || fail "rig did not create RIG_RUN_STARTED for a program that ran"

# A store entry whose `o/` holds no binary for its manifests heals.
store=$PWD/store
out=$(RIG_BUILD_STORE=$store "$RIG" run ok.rig 2>&1); expect_eq "$out" "ran" "first build"
find "$store" -path '*/o/*' -name __rig_main -type f | while IFS= read -r b; do rm -rf "$(dirname "$b")"; done
out=$(RIG_BUILD_STORE=$store "$RIG" run ok.rig 2>/dev/null); expect_eq "$out" "ran" "an entry whose binary is gone"

# test/run: a directory where the started file used to go fools nothing.
mkdir -p out/corpus/R11a-d1s.started/.zig-cache && : >out/.rig-test
o=$(RIG_BUILD_STORE=$bad RIG_TEST_OUT=$PWD/out "$ROOT/test/run" corpus/R11a-d1s 2>&1); expect_rc $? 1 "a corpus program behind a directory"
expect_has "$o" "FAIL   corpus/R11a-d1s — the program did not run" "a corpus program behind a directory"

# A program a signal kills after it started, with nothing on stderr, fails
# in the corpus and the matrix.
printf '#!/bin/sh\nif [ "$1" = run ]; then "%s" "$@"; kill -KILL $$; fi\nexec "%s" "$@"\n' "$ZIG_REAL" "$ZIG_REAL" >killzig
chmod +x killzig
o=$(ZIG=$PWD/killzig RIG_BUILD_STORE= RIG_TEST_OUT=$PWD/out2 "$ROOT/test/run" corpus/R11a-d1s 2>&1); expect_rc $? 1 "a corpus program killed by a signal"
expect_has "$o" "killed by signal 9" "a corpus program killed by a signal"
o=$(ZIG=$PWD/killzig RIG_BUILD_STORE= python3 "$ROOT/test/matrix.py" -k int.print.place 2>&1); expect_rc $? 1 "a matrix program killed by a signal"
expect_has "$o" "killed by signal 9" "a matrix program killed by a signal"
# A program's own status above 128 is not a signal.
printf 'fun main() -> Int\n  137\n' >own137.rig
out=$("$RIG" run own137.rig 2>&1); expect_rc $? 137 "a program's own 137"
expect_eq "$out" "" "a program's own 137 says nothing"

# matrix.py --keep DIR runs one at a time in DIR.
mkdir kept
python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(3)' kept/.matrix.lock &
sleep 1
o=$(python3 "$ROOT/test/matrix.py" --keep "$PWD/kept" -k int.print.place 2>&1); expect_rc $? 0 "a kept matrix run after another: $o"
expect_has "$o" "waiting for the matrix run in" "a kept matrix run waits for the one holding DIR"
wait

# A known bug or a pending example whose program never ran fails: it is
# neither the known failure nor the rule still missing. A checkout of its
# own holds one of each; its Zig builds nothing and runs nothing, and says
# so in words that look like a rejection.
mkdir -p fake/test/known/x fake/bin
cp "$ROOT/test/run" fake/test/run
ln -s "$RIG" fake/bin/rig
printf 'sub main()\n  print(1)\n\n# expect:\n# 2\n' >fake/test/known/x/k.rig
printf '# Doc\n\n```rig pending\nsub main()\n  print(1)\n```\n\n```output\n2\n```\n' >fake/README.md
printf '#!/bin/sh\n[ "$1" = build ] && exit 0\necho "error: unexpected errno 5" >&2\nexit 1\n' >fakezig
chmod +x fakezig
o=$(ZIG=$PWD/fakezig RIG_BUILD_STORE= RIG_TEST_OUT=$PWD/out3 fake/test/run known doc 2>&1); expect_rc $? 1 "a known bug and a pending example that never ran: $o"
expect_has "$o" "FAIL   known/x/k — the program did not run" "a known bug that never ran"
expect_has "$o" "FAIL   doc/README/L3 — pending example: the program did not run" "a pending example that never ran"
exit 0
