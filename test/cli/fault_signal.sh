# timeout: 300
# A SIGSEGV or SIGBUS that another process sends, or the program sends
# itself, ends the program by that signal, as its default action does: a
# shell sees 128 and the signal's number (139; 138 on macOS and 135 on
# Linux for SIGBUS), and the program writes nothing more. The handlers
# that catch a real fault, the stack guard's in every build mode and the
# sanitizer's under RIG_SANITIZE=1, tell such a signal from a fault
# (docs/internals/INTERNALS.md, "The message"). A real fault is
# unchanged: a stack overflow still says `error: rig: stack overflow`,
# and a use of freed memory `error: rig: use of freed memory`, each
# ending the program by SIGABRT (134).
source "$ROOT/test/cli/_lib.sh"

segv=$((128 + $(kill -l SEGV)))
bus=$((128 + $(kill -l BUS)))

# Each program writes its process id on stderr once its handlers are in
# place, and the script waits for that before it sends the signal there.
cat >sleeps.rig <<'EOF2'
use std.time

extern fun getpid() -> I32

sub main()!
  raw
    warn(getpid())
  time.sleep(10 * time.SECOND)!
  print("survived")
EOF2

# A program that touches pages it has not touched before, again and
# again, so the signal arrives while the thread takes ordinary page
# faults: on macOS the thread's last exception, which the handler reads,
# is then such a fault, at an address that is mapped.
cat >touches.rig <<'EOF2'
extern fun getpid() -> I32

sub main()
  raw
    warn(getpid())
  total = 0
  for round in 0..100000
    xs: List[Int] = List()
    for i in 0..1000000
      !xs.push(i + round)
    total += xs[round % 1000]
  print("survived", total)
EOF2

# A program that sends itself SIGSEGV.
cat >raises.rig <<'EOF2'
extern fun kill(pid: I32, sig: I32) -> I32
extern fun getpid() -> I32

sub main()
  raw
    kill(getpid(), 11)
  print("survived")
EOF2

# A real stack overflow, as `stack overflow recursion` in
# test/rig/runtime-misc.rig.test.
cat >dives.rig <<'EOF2'
fun dive(depth: Int, prev: ?[1000]Int) -> Int
  a = [1000 of depth]
  a[depth % 1000] = prev[0]
  a[0] + dive(depth + 1, ?a)

sub main()
  print("before")
  first = [1000 of 0]
  print(dive(0, ?first))
EOF2

# run <program> [args...]: the program under `quiet`, its stderr in
# err.txt. It runs in place of a shell (exec), so the report a shell
# writes of the signal that ended a child (bash's "Segmentation fault" on
# Linux) goes to the caller's stderr, not into err.txt.
run() { quiet bash -c 'exec "$@" 2>err.txt' _ "$@"; }

# send <program> <signal> <what>: run the program, send it the signal
# once it has started, and check that the signal ended it.
send() {
    local prog=$1 sig=$2 what=$3 want job pid i
    want=$segv; [[ $sig == BUS ]] && want=$bus
    rm -f out.txt err.txt
    run ./$prog >out.txt 2>/dev/null &
    job=$!
    for ((i = 0; i < 200; i++)); do
        [[ -s err.txt ]] && break
        sleep 0.05
    done
    pid=$(cat err.txt)
    [[ $pid =~ ^[0-9]+$ ]] || fail "$prog did not start, $what: [$pid]"
    sleep 0.2
    kill -$sig $pid
    for ((i = 0; i < 100; i++)); do
        kill -0 $pid 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 $pid 2>/dev/null; then
        kill -KILL $pid
        wait $job 2>/dev/null
        fail "$prog survived SIG$sig, $what"
    fi
    wait $job 2>/dev/null
    expect_rc $? $want "$prog sent SIG$sig, $what"
    expect_eq "$(cat out.txt)" "" "stdout of $prog sent SIG$sig, $what"
    expect_eq "$(cat err.txt)" "$pid" "stderr of $prog sent SIG$sig, $what"
}

for how in debug release fast sanitized; do
    mode=""; san=0
    case $how in
        release) mode=--release ;;
        fast) mode=--release=fast ;;
        sanitized) san=1 ;;
    esac
    for prog in sleeps touches raises dives; do
        RIG_SANITIZE=$san rig build $mode -o $prog-$how $prog.rig >build.log 2>&1 || fail "build $prog.rig $how: $(cat build.log)"
    done
    send sleeps-$how SEGV $how
    send sleeps-$how BUS $how
    send touches-$how SEGV $how
    send touches-$how BUS $how
    out=$(run ./raises-$how 2>/dev/null); expect_rc $? $segv "a program that sends itself SIGSEGV, $how"
    expect_eq "$out" "" "stdout of a program that sends itself SIGSEGV, $how"
    expect_eq "$(cat err.txt)" "" "stderr of a program that sends itself SIGSEGV, $how"
    # `--release=fast` folds the recursion into a loop that never ends.
    if [[ $how != fast ]]; then
        out=$(run ./dives-$how 2>/dev/null); expect_rc $? 134 "a stack overflow, $how ($(head -c 300 err.txt))"
        expect_eq "$out" "before" "stdout of a stack overflow, $how"
        expect_has "$(cat err.txt)" "error: rig: stack overflow" "a stack overflow, $how"
    fi
done

# A use of freed memory in a sanitized build, written by hand into the
# emitted package, as safe Rig has none to write.
cat >freed.rig <<'EOF2'
called fun freed(i: Int) -> Int
  i + 1

sub main()
  print("before")
  print(freed(1))
EOF2
RIG_SANITIZE=1 rig emit freed.rig >/dev/null 2>&1 || fail "emit freed.rig"
pkg=$RIG_OUT_DIR/programs/freed+RIG_SANITIZE=1
perl -0pi -e 's/(pub noinline fn freed\(i: i64\) i64 \{).*?\n\}/$1\n    const a = rig.defaultAllocator();\n    const b = a.alloc(i64, 4) catch unreachable;\n    a.free(b);\n    return \@as(*volatile i64, \&b[\@intCast(i)]).*;\n}/s' "$pkg/__rig_main.zig"
grep -q 'a.free(b)' "$pkg/__rig_main.zig" || fail "the use of freed memory was not written into the package"
(cd "$pkg" && zig_once "$PWD/../freed-debug" -- . -- "${ZIG:-zig}" build-exe -O Debug -femit-bin="$PWD/../freed-debug" __rig_main.zig) >build.log 2>&1 || fail "build freed: $(cat build.log)"
out=$(run "$RIG_OUT_DIR/programs/freed-debug" 2>/dev/null); rc=$?
expect_rc $rc 134 "a use of freed memory ($(head -c 300 err.txt))"
expect_eq "$out" "before" "stdout of a use of freed memory"
expect_has "$(cat err.txt)" "error: rig: use of freed memory at address 0x" "a use of freed memory"
exit 0
