# timeout: 120
# A runtime panic aborts the program in every build mode: exit status
# 134 (SIGABRT), what `print` buffered written out first, then the panic
# message on stderr. A debug build adds Zig's trace: its first frame is
# where the check failed, and it holds the program's own line. An
# optimized build prints the message alone. Each program is built with
# `rig build` and its executable run, so the status is the program's own.
# test/rig/runtime-panic-status.rig.test holds every program as a case,
# which checks the status, the output, and the message in debug and
# with --release; this script checks what a case cannot see: the trace,
# and --release=fast.
#
# The program runs on the stack the runtime maps (docs/INTERNALS.md,
# "The program's stack"), and the trace's walk must not fault at its
# top, which the outermost frame there reaches: a List index (a runtime
# function's check) and a fixed array's index (an inline one) both run
# from it, and on aarch64 macOS a frame whose values live across calls
# saves all five register pairs, the most the walk reads above it. Each
# is a program of its own, built in debug; the List index is also built
# in each optimized mode. One program then runs every panic, chosen by
# its argument, in each mode; checks that `--release=fast` drops
# (overflow, conversion, division) are run in the modes that keep them.
# PANIC_STATUS_FULL=1 also builds each of the three in every mode.
source "$ROOT/test/cli/_lib.sh"

# <exe> <what> <mode> <message> [stdout] [arg]: run a built program with
# stdout to a file, and expect 134, the stdout ("before" unless given),
# the message, and the trace the mode gives.
expect_panic() {
    local exe=$1 what=$2 mode=$3 msg=$4 want=${5:-before} rc
    quiet "./$exe" ${6:+"$6"} >out.txt 2>err.txt; rc=$?
    expect_rc $rc 134 "$what in $mode ($(head -c 300 err.txt))"
    expect_eq "$(cat out.txt)" "$want" "stdout of $what in $mode"
    expect_has "$(cat err.txt)" "$msg" "the message of $what in $mode"
    [[ $msg == *"stack overflow"* ]] && return
    if [[ $mode == debug ]]; then
        grep -qE '\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in ' err.txt || fail "no location in the trace of $what in $mode: $(cat err.txt)"
        expect_has "$(cat err.txt)" "__rig_main.zig:" "the program's line in the trace of $what in $mode"
    else
        ! grep -qE '\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in ' err.txt || fail "a trace in $mode for $what: $(cat err.txt)"
    fi
}

# build <name> <mode>: build <name>.rig in a mode, as <name>-<mode>.
build() {
    local flag=""
    [[ $2 == debug ]] || flag=--$2
    rig build $flag -o "$1-${2//=/-}" "$1.rig" >build.log 2>&1 || fail "build $1 $2: $(cat build.log)"
}

cat >list_index.rig <<'EOF2'
use std.os

sub main()
  v: List[Int] = List()
  !v.push(1)
  print("before")
  print(v[v.len + os.args().len + 2])
  print("after")
EOF2

cat >live_values.rig <<'EOF2'
use std.os

sub main()
  n = os.args().len
  a = n * 3
  b = n * 5
  v: List[Int] = List()
  !v.push(a)
  print("before")
  print(a, b)
  i = v.len + 3
  print(a + b + v[i])
EOF2

cat >array_index.rig <<'EOF2'
use std.os

sub main()
  a = [1, 2, 3]
  print("before")
  print(a[os.args().len + 2])
EOF2

all="debug release release=fast"
for name in list_index live_values array_index; do
    modes=debug
    [[ $name == list_index || -n "${PANIC_STATUS_FULL:-}" ]] && modes=$all
    want=before
    [[ $name == live_values ]] && want=$'before\n3 5'
    for mode in $modes; do
        build $name "$mode"
        expect_panic "$name-${mode//=/-}" $name "$mode" "panic: index out of bounds" "$want"
    done
done

# Every panic, chosen by the program's argument, each where the program
# that has it alone panics: in `main`, with "before" printed.
cat >every.rig <<'EOF2'
use std.os

obj Res
  name: ?String
  drop(!@)
    print("dropping", @name)

fun down(n: Int) -> Int
  a = [64 of n]
  if n == 0
    return a[3]
  down(n - 1) + a[os.args().len]

fun main() -> Int
  what = os.args()[1]
  k = os.args().len - 1
  if what == "list_past"
    r = Res(name: "r")
    defer print("deferred")
    v: List[Int] = List()
    !v.push(1)
    print("before")
    i = v.len + 3
    print(v[i])
  else if what == "slice"
    s = "abc"
    print("before")
    print(s[0..k + 3])
  else if what == "filled"
    print("before")
    v = List.filled(0 - k, 0)
    print(v.len)
  else if what == "status"
    print("before")
    return 300 + k
  else if what == "oom"
    print("before")
    v = List.filled(k << 60, 0)
    print(v.len)
  else if what == "overflow"
    print("before")
    n: I8 = 120
    n += I8(k * 10)
    print(n)
  else if what == "convert"
    print("before")
    print(U8(k * 1000))
  else if what == "divide"
    print("before")
    print(10 / (k - 1))
  else if what == "recurse"
    print("before")
    print(down(100000000))
  print("after")
  0
EOF2
for mode in $all; do
    build every "$mode"
    exe=every-${mode//=/-}
    expect_panic "$exe" list_past "$mode" "panic: index out of bounds" before list_past
    expect_panic "$exe" slice "$mode" "panic: slice bounds out of range" before slice
    expect_panic "$exe" filled "$mode" "panic: negative size" before filled
    expect_panic "$exe" status "$mode" "panic: exit status 301 is not in 0..255" before status
    expect_panic "$exe" oom "$mode" "panic: out of memory" before oom
    expect_panic "$exe" recurse "$mode" "error: rig: stack overflow" before recurse
    [[ $mode == release=fast ]] && continue
    expect_panic "$exe" overflow "$mode" "panic: integer overflow" before overflow
    expect_panic "$exe" convert "$mode" "panic: integer does not fit in destination type" before convert
    expect_panic "$exe" divide "$mode" "panic: division by zero" before divide
done

# A test that panics under `rig test`, which runs the tests on the same
# stack: the run ends with the program's 134, naming the test.
cat >tpanic.rig <<'EOF2'
use std.os

fun pick(v: ?List[Int]) -> Int
  v[v.len + os.args().len + 2]

test "index past the end"
  v: List[Int] = List()
  !v.push(1)
  print(pick(?v))
EOF2
modes=debug
[[ -n "${PANIC_STATUS_FULL:-}" ]] && modes=$all
for mode in $modes; do
    flag=""; [[ $mode == debug ]] || flag=--$mode
    RIG_NO_CRASH_REPORT=1 rig test $flag tpanic.rig >out.txt 2>err.txt; rc=$?
    expect_rc $rc 134 "a panicking test in $mode ($(head -c 300 err.txt))"
    expect_has "$(cat out.txt)" "index past the end" "the panicking test named in $mode"
    expect_has "$(cat err.txt)" "panic: index out of bounds" "a panicking test's message in $mode"
    expect_has "$(cat err.txt)" "killed by signal 6" "a panicking test's signal in $mode"
done
exit 0
