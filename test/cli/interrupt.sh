# An interrupt (SIGINT) or a request to end (SIGTERM) cancels a `main`
# that can fail: it fails with `task.Stop.canceled` at its next waiting
# point, its drops and defers run, and the program ends as the signal
# ends it (130, 143), showing no error. A second interrupt ends it at
# once; a `main` that cannot fail keeps the signals' default; a signal
# the program started with ignored stays ignored. `rig run` waits for a
# program that a Ctrl-C at the terminal cancels.
source "$ROOT/test/cli/_lib.sh"

# Job control: each program runs in a process group of its own, as a
# shell's job does, and a background job does not start with SIGINT
# ignored.
set -m

cat >sleeps.rig <<'EOF2'
use std.time

sub main()!
  defer print("defer ran")
  warn("started")
  while true
    time.sleep(10 * time.SECOND)!
EOF2

cat >tasks.rig <<'EOF2'
use std.time

sub work()!
  defer print("task defer ran")
  while true
    time.sleep(10 * time.SECOND)!

sub main()!
  defer print("main defer ran")
  t = work()&
  warn("started")
  >t!
EOF2

cat >accepts.rig <<'EOF2'
use std.net

sub main()!
  defer print("defer ran")
  l = net.listen("127.0.0.1:0")!
  warn("started")
  c = l.accept()!
  print("accepted")
EOF2

cat >catches.rig <<'EOF2'
use std.time

sub main()!
  warn("started")
  time.sleep(10 * time.SECOND) catch print("caught the cancel")
  print("returns")
EOF2

cat >plain.rig <<'EOF2'
use std.time

sub main()
  defer print("defer ran")
  warn("started")
  time.sleep(10 * time.SECOND) catch print("woke")
EOF2

cat >reads.rig <<'EOF2'
use std.file

sub main()!
  defer print("defer ran")
  if file.open("fifo")! as f
    warn("started")
    s = String()
    n = (!f).read(!s, 4096)!
    print("read", n)
EOF2

cat >spins.rig <<'EOF2'
sub main()!
  warn("started")
  n = 0
  while n >= 0
    n = (n + 1) % 1000
  check()!

sub check()!
  return
EOF2

for p in sleeps tasks accepts reads catches plain spins; do
  rig build -o $p $p.rig >/dev/null 2>&1 || fail "build $p.rig"
done

pid=
trap 'kill -9 $pid 2>/dev/null' EXIT

# start <command...>: run it in the background, its output in out.txt
# and err.txt, and wait for it to say it started.
start() {
  rm -f out.txt err.txt
  "$@" >out.txt 2>err.txt &
  pid=$!
  for _ in $(seq 1 600); do grep -q started err.txt 2>/dev/null && return; sleep 0.05; done
  fail "$*: never started: $(head -3 err.txt)"
}

# ends <what> <status>: the program ends with <status> within 5 s.
ends() {
  for _ in $(seq 1 100); do kill -0 $pid 2>/dev/null || break; sleep 0.05; done
  kill -0 $pid 2>/dev/null && fail "$1: still running"
  wait $pid
  expect_rc $? "$2" "$1"
}

start ./sleeps
kill -INT $pid
ends "an interrupt cancels a sleeping main" 130
expect_eq "$(cat out.txt)" "defer ran" "its defer runs"
expect_eq "$(cat err.txt)" "started" "it shows no error"

start ./sleeps
kill -TERM $pid
ends "SIGTERM cancels main" 143
expect_eq "$(cat out.txt)" "defer ran" "its defer runs on SIGTERM"

start ./tasks
kill -INT $pid
ends "an interrupt cancels main and the task it waits on" 130
expect_eq "$(cat out.txt)" $'task defer ran\nmain defer ran' "the task's defer, then main's"

start ./accepts
kill -INT $pid
ends "an interrupt cancels an accept" 130
expect_eq "$(cat out.txt)" "defer ran" "its defer runs after accept"

# A read of a file that has nothing to give: a FIFO this script holds
# open to write, so the program's open does not wait for a writer.
mkfifo fifo
exec 3<>fifo
start ./reads
kill -INT $pid
ends "an interrupt cancels a blocked file read" 130
expect_eq "$(cat out.txt)" "defer ran" "its defer runs after the read"
expect_eq "$(cat err.txt)" "started" "a canceled read shows no error"
exec 3>&-

start ./catches
kill -INT $pid
ends "a main that catches the cancel keeps its status" 0
expect_eq "$(cat out.txt)" $'caught the cancel\nreturns' "it goes on after the catch"

start ./plain
kill -INT $pid
ends "a main that cannot fail ends by the signal" 130
expect_eq "$(cat out.txt)" "" "and runs nothing more"

start ./spins
kill -INT $pid
sleep 0.3
kill -0 $pid 2>/dev/null || fail "a cancel ended a main that reached no waiting point"
kill -INT $pid
ends "a second interrupt ends the program at once" 130

# Started with SIGINT ignored, as `nohup` starts a program.
start bash -c 'trap "" INT; exec ./sleeps'
kill -INT $pid
sleep 0.3
kill -0 $pid 2>/dev/null || fail "an ignored SIGINT ended the program"
kill -TERM $pid
ends "SIGTERM still cancels it" 143

# `rig run`, sent the interrupt with its program as a terminal sends it:
# to the whole process group. `rig` waits for the program and ends as it
# does.
start env RIG_OUT_DIR="$RIG_OUT_DIR/programs/interrupt_run" "$RIG" run sleeps.rig
kill -INT -- -$pid
ends "rig run of an interrupted program" 130
expect_eq "$(cat out.txt)" "defer ran" "rig run: the program's defer runs"
grep -q 'killed by signal' err.txt && fail "rig run reports an interrupt: $(cat err.txt)"
true
