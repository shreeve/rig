# timeout: 600
# The program runs on a stack the runtime maps itself, 64 MiB over a
# guard of 64 GiB (docs/INTERNALS.md, "The program's stack"). This checks what reaches the program through
# it: the exit status, a failure out of `main`, and `rig test`'s tests,
# which run there too; that a frame of 100 MiB, larger than the whole
# stack, stops with a stack-overflow error in every build mode;
# and, on Linux, that a program that cannot reserve its stack stops before
# it runs.
source "$ROOT/test/cli/_lib.sh"

# The exit status and a failure pass through unchanged.
printf 'fun main() -> Int\n  7\n' >status.rig
cat >fails.rig <<'EOF2'
error Bad
  broken

sub main()!
  print("before")
  return Bad.broken
EOF2
for mode in "" --release; do
    rig run $mode status.rig >/dev/null 2>&1; expect_rc $? 7 "the exit status $mode"
    out=$(rig run $mode fails.rig 2>err.txt); expect_rc $? 1 "a failure out of main $mode"
    expect_eq "$out" "before" "stdout of a failing main $mode"
    expect_has "$(cat err.txt)" "error: Bad.broken" "the failure $mode"
done

# A test runs on the program's stack: this one goes 20 MB deep, more than
# the 16 MiB a thread's stack holds by default.
cat >deep.rig <<'EOF2'
fun deep(n: Int, prev: ?[1000]Int) -> Int
  a = [1000 of n]
  a[1] = prev[1] + 1
  if n == 0
    return a[1]
  deep(n - 1, ?a)

test "deep"
  first = [1000 of 0]
  print(deep(2500, ?first))
EOF2
out=$(rig test deep.rig 2>&1) || fail "rig test on the program's stack: $out"
expect_has "$out" '2501' "a test on the program's stack"
expect_has "$out" '1 passed, 0 failed' "rig test on the program's stack"

# A frame of 100 MiB, written by hand into the emitted package, so it
# is as large in a release build as in a debug one: a debug build of an
# accepted program reaches that size
# (test/behavior/runtime/stack_overflow_frame.rig), but a release build
# shares one slot among values that are never live together.
cat >big.rig <<'EOF2'
called fun big(i: Int) -> Int
  i + 1

sub main()
  print("before")
  print(big(1))
EOF2
rig emit big.rig >/dev/null 2>&1 || fail "emit big.rig"
pkg=$RIG_OUT_DIR/programs/big
perl -0pi -e 's/(pub noinline fn big\(i: i64\) i64 \{).*?\n\}/$1\n    var a: [13107200]i64 = undefined;\n    a[\@intCast(i)] = i;\n    std.mem.doNotOptimizeAway(&a);\n    return a[\@intCast(i)];\n}/s' "$pkg/__rig_main.zig"
grep -q '13107200' "$pkg/__rig_main.zig" || fail "the 100 MiB frame was not written into the package"
for mode in Debug ReleaseSafe ReleaseFast; do
    (cd "$pkg" && "${ZIG:-zig}" build-exe -O $mode -femit-bin="$PWD/../big-$mode" __rig_main.zig) >build.log 2>&1 || fail "build big $mode: $(cat build.log)"
    out=$("$RIG_OUT_DIR/programs/big-$mode" 2>err.txt); rc=$?
    [[ $rc -ne 0 ]] || fail "a 100 MiB frame in $mode exited 0"
    expect_eq "$out" "before" "stdout of a 100 MiB frame in $mode"
    expect_has "$(cat err.txt)" "error: rig: stack overflow" "a 100 MiB frame in $mode"
done

# A program that cannot reserve its stack and the guard below it stops
# before it runs. Only Linux holds a process to an address-space limit.
if [[ $(uname -s) == Linux ]]; then
    printf 'sub main()\n  print(42)\n' >hi.rig
    RIG_SANITIZE=0 rig build -o hi hi.rig || fail "build hi"
    expect_eq "$(./hi)" "42" "a program with room for its stack"
    (ulimit -v 900000; ./hi >out.txt 2>err.txt); expect_rc $? 1 "a program with no room for its stack"
    expect_eq "$(cat out.txt)" "" "stdout of a program with no room for its stack"
    expect_eq "$(cat err.txt)" "rig: cannot reserve the program's stack and the guard below it" "its message"
fi
exit 0
