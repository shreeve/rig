# `rig build --strip` builds without debug information: every Zig command
# of the build takes `-fstrip`, one unit or several, and a build without
# it takes none. The stripped program prints what the plain one does and
# panics as it does, with the message and status 134; a stripped debug
# build's panic prints its message and no trace. A stripped release
# build keeps its dense stacks: the guard below them is sized from the
# functions its unwind tables tell apart, as the plain build's is from
# its symbols, and is no larger (Zig leaves the code that reads debug
# information out of a stripped program, and its frames with it).
# A stripped release build says that it warns of no frame larger than a
# page, which is read by the names it leaves out.
# `--strip` applies to build alone, and not with `--bolt`.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >p.rig <<'EOF2'
use std.os

fun one(n: Int) -> Int
  n + 1

fun at(xs: [3]Int, i: Int) -> Int
  xs[i]

sub main()
  t = one(1)&
  print(>t)
  xs = [10, 20, 30]
  print(at(xs, os.args().len))
EOF2

out=$("$RIG" run --strip p.rig 2>&1); expect_rc $? 2 "--strip on run"
expect_has "$out" "\`--strip\` applies to build" "--strip on run"
out=$("$RIG" build --release --strip --bolt -o prog p.rig -- ./prog 2>&1); expect_rc $? 2 "--strip with --bolt"
expect_has "$out" "which \`--strip\` leaves out" "--strip with --bolt"

# A Zig that lists what it is asked to build.
zig=$(command -v "${ZIG:-zig}")
cat >zig-listed <<EOF2
#!/bin/sh
case "\$1" in build-exe | build-obj) echo "\$*" >>"$PWD/zig.log" ;; esac
exec "$zig" "\$@"
EOF2
chmod +x zig-listed
export ZIG=$PWD/zig-listed
compiles() { grep -c . zig.log; }
stripped() { grep -c -- ' -fstrip ' zig.log; }

"$RIG" emit p.rig 2>&1 | grep -q 'spawnDense(one' || fail "p.rig: one is not on a dense stack"
guard() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"rig-dense-guard!")
print(int.from_bytes(d[i + 16:i + 24], "little") if i >= 0 else -1)
PY
}
debug_info() {
    case $(uname -s) in
    Linux) readelf -S "$1" | grep -c '\.debug_info' ;;
    Darwin) nm -ap "$1" | grep -c ' OSO ' ;;
    *) echo 0 ;;
    esac
}

: >zig.log
out=$(rig build --release -o plain p.rig 2>&1); expect_rc $? 0 "build --release: $out"
[[ $(compiles) -gt 0 ]] || fail "the build ran no Zig"
expect_eq "$(stripped)" 0 "Zig commands with -fstrip in a plain build"
want=$(./plain) || fail "the plain program: $want"
expect_eq "$want" "2
20" "the plain program"
want_panic=$(quiet ./plain a b c 2>&1); expect_rc $? 134 "the plain program's panic"

: >zig.log
out=$(rig build --release --strip -o lean p.rig 2>&1); expect_rc $? 0 "build --release --strip: $out"
[[ $(compiles) -gt 0 ]] || fail "the stripped build ran no Zig: it took the plain build's executable"
expect_has "$out" "note: \`--strip\` leaves out the names of the program's functions, so this build warns of no frame larger than a page" "a stripped release build"
expect_eq "$(stripped)" "$(compiles)" "Zig commands with -fstrip in a stripped build, of $(compiles)"
expect_eq "$(./lean)" "$want" "the stripped program"
got=$(quiet ./lean a b c 2>&1); expect_rc $? 134 "the stripped program's panic"
expect_eq "$got" "$want_panic" "the stripped program's panic"
case $(uname -s) in Linux | Darwin)
    [[ $(debug_info plain) -gt 0 ]] || fail "the plain program has no debug information to tell a stripped one by"
    expect_eq "$(debug_info lean)" 0 "debug information in the stripped program" ;;
esac
[[ $(guard plain) -gt 0 ]] || fail "the plain program has no dense guard: $(guard plain)"
[[ $(guard lean) -gt 0 && $(guard lean) -le $(guard plain) ]] || fail "the stripped program's dense guard is $(guard lean), the plain one's $(guard plain)"

# Several units: each unit's compile and the entry's.
: >zig.log
out=$(rig build --release --strip --units=2 -o lean2 p.rig 2>&1); expect_rc $? 0 "build --release --strip --units=2: $out"
expect_eq "$(compiles)" 3 "Zig commands of a build of two units"
expect_eq "$(stripped)" 3 "Zig commands with -fstrip in a stripped build of two units"
expect_eq "$(./lean2)" "$want" "the stripped program of two units"

# A debug build: the panic's message, and no trace.
out=$(rig build --strip -o leand p.rig 2>&1); expect_rc $? 0 "build --strip: $out"
expect_eq "$out" "" "what a stripped debug build says, which reads no frames"
expect_eq "$(./leand)" "$want" "the stripped debug program"
got=$(quiet ./leand a b c 2>&1); expect_rc $? 134 "the stripped debug program's panic"
expect_eq "$got" "2
panic: index out of bounds" "the stripped debug program's panic"
exit 0
