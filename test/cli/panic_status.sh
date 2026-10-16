# timeout: 900
# A runtime panic aborts the program in every build mode: exit status
# 134 (SIGABRT), what `print` buffered written out first, then the panic
# message and the trace on stderr: its first frame is where the check
# failed, and a debug build's trace holds the program's own line (an
# optimized build may inline that frame away, or call a check that never
# returns without keeping its return address).
# The program runs on the stack the runtime maps (docs/INTERNALS.md,
# "The program's stack"), and the trace's walk must not fault at its
# top, which the outermost frame there reaches: a List index (a runtime
# function's check) and a fixed array's index (an inline one) both run
# from it. Each program is built with `rig build` and its executable run,
# so the status is the program's own. Checks that `--release=fast` drops
# (overflow, conversion, division) are run in the modes that keep them.
source "$ROOT/test/cli/_lib.sh"

# <name> <modes> <message>: build <name>.rig in each mode, run it with
# stdout to a file, and expect 134, stdout "before", and the message.
check() {
    local name=$1 modes=$2 msg=$3 mode flag exe rc
    for mode in $modes; do
        flag=""; [[ $mode == debug ]] || flag=--$mode
        exe=$name-${mode//=/-}
        rig build $flag -o "$exe" "$name.rig" >build.log 2>&1 || fail "build $name $mode: $(cat build.log)"
        "./$exe" >out.txt 2>err.txt; rc=$?
        expect_rc $rc 134 "$name in $mode ($(head -c 300 err.txt))"
        expect_eq "$(cat out.txt)" "before" "stdout of $name in $mode"
        expect_has "$(cat err.txt)" "$msg" "the message of $name in $mode"
        [[ $msg == *"stack overflow"* ]] && continue
        grep -qE '\.zig:[0-9]+:[0-9]+: 0x[0-9a-f]+ in ' err.txt || fail "no location in the trace of $name in $mode: $(cat err.txt)"
        if [[ $mode == debug ]]; then
            expect_has "$(cat err.txt)" "__rig_main.zig:" "the program's line in the trace of $name in $mode"
        fi
    done
}

all="debug release release=fast"
safe="debug release"

# The reviewer's program: a constant distance past a List's end.
cat >list_past.rig <<'EOF'
obj Res
  name: ?String
  drop(!self)
    print("dropping", self.name)

sub main()
  r = Res(name: "r")
  defer print("deferred")
  v: List[Int] = List()
  !v.push(1)
  print("before")
  i = v.len + 3
  print(v[i])
  print("after")
EOF
check list_past "$all" "panic: index out of bounds"

cat >list_index.rig <<'EOF'
use std.os

sub main()
  v: List[Int] = List()
  !v.push(1)
  print("before")
  print(v[v.len + os.args().len + 2])
  print("after")
EOF
check list_index "$all" "panic: index out of bounds"

cat >array_index.rig <<'EOF'
use std.os

sub main()
  a = [1, 2, 3]
  print("before")
  print(a[os.args().len + 2])
EOF
check array_index "$all" "panic: index out of bounds"

cat >slice.rig <<'EOF'
use std.os

sub main()
  s = "abc"
  print("before")
  print(s[0..os.args().len + 3])
EOF
check slice "$all" "panic: slice bounds out of range"

cat >filled.rig <<'EOF'
use std.os

sub main()
  print("before")
  v = List.filled(0 - os.args().len, 0)
  print(v.len)
EOF
check filled "$all" "panic: negative size"

cat >status.rig <<'EOF'
use std.os

fun main() -> Int
  print("before")
  300 + os.args().len
EOF
check status "$all" "panic: exit status 301 is not in 0..255"

cat >oom.rig <<'EOF'
use std.os

sub main()
  print("before")
  v = List.filled(os.args().len << 60, 0)
  print(v.len)
EOF
check oom "$all" "panic: out of memory"

cat >overflow.rig <<'EOF'
use std.os

sub main()
  print("before")
  n: I8 = 120
  n += I8(os.args().len * 10)
  print(n)
EOF
check overflow "$safe" "panic: integer overflow"

cat >convert.rig <<'EOF'
use std.os

sub main()
  print("before")
  print(U8(os.args().len * 1000))
EOF
check convert "$safe" "panic: integer does not fit in destination type"

cat >divide.rig <<'EOF'
use std.os

sub main()
  print("before")
  print(10 / (os.args().len - 1))
EOF
check divide "$safe" "panic: division by zero"

# Recursion that runs into the guard below the stack.
cat >recurse.rig <<'EOF'
use std.os

fun down(n: Int) -> Int
  a = [64 of n]
  if n == 0
    return a[3]
  down(n - 1) + a[os.args().len]

sub main()
  print("before")
  print(down(100000000))
EOF
check recurse "$all" "error: rig: stack overflow"
exit 0
