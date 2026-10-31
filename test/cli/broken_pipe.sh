# A reader that closes stdout's pipe early (`prog | head -1`) ends the
# program quietly with status 0, unless it calls
# `os.on_broken_pipe(.die)`: then it dies by SIGPIPE, as a C program
# does, and a shell sees status 141. `.exit` puts the default back. A
# lost stderr is unchanged either way: `warn` writes nothing, and the
# program goes on. A write or flush of `io.stdout()` dies the same way
# once `.die` is set, and otherwise fails with `FileError.broken_pipe`.
# One program does each, chosen by its argument, in every build mode.
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >pipe.rig <<'EOF2'
use std.os

sub main()
  what = os.args()[1]
  if what == "die"
    os.on_broken_pipe(.die)
  else if what == "back"
    os.on_broken_pipe(.die)
    os.on_broken_pipe(.exit)
  else if what == "warn"
    os.on_broken_pipe(.die)
    warn("lost")
    print("after")
    return
  for i in 0..200000
    print("line", i)
EOF2
cat >file.rig <<'EOF2'
use std.io
use std.os

sub main()!
  what = os.args()[1]
  if what != "caught"
    os.on_broken_pipe(.die)
  out = io.stdout()
  line = String("y\n")
  for _ in 0..1000000
    if what == "flush"
      print("y")
      !out.flush() catch |e|
        warn("caught", e)
        return
    else
      !out.write(line) catch |e|
        warn("caught", e)
        return
EOF2
for mode in "" "--release" "--release=fast"; do
  how=${mode:-debug}
  rig build $mode -o pipe pipe.rig >build.log 2>&1 || fail "build pipe.rig $how: $(cat build.log)"
  for what in plain back die; do
    want=0; [[ $what == die ]] && want=141
    first=$( (./pipe $what 2>err.txt; echo "rc=$?" >rc.txt) | head -1)
    expect_eq "$first" "line 0" "first line $what $how"
    expect_eq "$(cat rc.txt)" "rc=$want" "closed pipe exit status $what $how"
    expect_eq "$(cat err.txt)" "" "closed pipe writes no error $what $how"
  done
  rig build $mode -o file file.rig >build.log 2>&1 || fail "build file.rig $how: $(cat build.log)"
  for what in write flush caught; do
    want=141; err=""
    [[ $what == caught ]] && { want=0; err="caught FileError.broken_pipe"; }
    first=$( (./file $what 2>err.txt; echo "rc=$?" >rc.txt) | head -1)
    expect_eq "$first" "y" "first line io.stdout $what $how"
    expect_eq "$(cat rc.txt)" "rc=$want" "closed pipe exit status io.stdout $what $how"
    expect_eq "$(cat err.txt)" "$err" "closed pipe stderr io.stdout $what $how"
  done
  out=$(./pipe warn 2>&-); expect_rc $? 0 "closed stderr exit status $how"
  expect_eq "$out" "after" "warn with stderr closed after .die $how"
done
exit 0
