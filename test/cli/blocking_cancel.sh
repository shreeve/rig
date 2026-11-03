# A blocking call ends when its task stops, with or without tasks: a
# FIFO's open waiting for a writer, a read of a pipe with nothing in
# it (by a File and by io.copy), a write to a full one (whole, and by a
# File), an accept no client answers; and a File's call queued behind a
# busy pool, which a deadline ends before it starts. SIGTERM cancels `main` there, its
# defers run, and the program ends by the signal (143); a deadline
# (`time.within`) ends the call with `task.Stop.timeout`. A program that
# makes no task runs the call on its own thread, where the signal and an
# alarm at the deadline end the system call; one that makes tasks runs
# it on the blocking pool, and the waiting task stops waiting.
source "$ROOT/test/cli/_lib.sh"

# Job control: each program runs in a process group of its own.
set -m

cat >opens.rig <<'EOF2'
use std.file

sub main()!
  defer print("defer ran")
  warn("started")
  if file.open("fifo")! as f
    print("opened")
EOF2

cat >task_opens.rig <<'EOF2'
use std.file

sub work()!
  defer print("task defer ran")
  if file.open("fifo")! as f
    print("opened")

sub main()!
  defer print("main defer ran")
  t = work()&
  warn("started")
  >t!
EOF2

cat >opens_within.rig <<'EOF2'
use std.file
use std.time

fun opened() -> Bool!
  if file.open("fifo")! as f
    return true
  return false

sub main()!
  ok = time.within(100 * time.MS, || opened()!) catch |e|
    print("stopped:", e)
    false
  print("opened:", ok)
EOF2

cat >task_opens_within.rig <<'EOF2'
use std.file
use std.time

fun opened() -> Bool!
  if file.open("fifo")! as f
    return true
  return false

fun work() -> Bool!
  return time.within(100 * time.MS, || opened()!) catch |e|
    print("stopped:", e)
    false

sub main()!
  t = work()&
  print("opened:", >t!)
EOF2

cat >reads_within.rig <<'EOF2'
use std.file
use std.time

fun got() -> Int!
  if file.open("fifo")! as f
    s = String()
    return (!f).read(!s, 4096)!
  return -1

sub main()!
  n = time.within(100 * time.MS, || got()!) catch |e|
    print("stopped:", e)
    -2
  print("read:", n)
EOF2

cat >task_reads_within.rig <<'EOF2'
use std.file
use std.time

fun got() -> Int!
  if file.open("fifo")! as f
    s = String()
    return (!f).read(!s, 4096)!
  return -1

fun work() -> Int!
  return time.within(100 * time.MS, || got()!) catch |e|
    print("stopped:", e)
    -2

sub main()!
  t = work()&
  print("read:", >t!)
EOF2

cat >writes_within.rig <<'EOF2'
use std.file
use std.time

fun big() -> String
  s = String()
  for _ in 0..100000
    !s.add("0123456789")
  <s

sub main()!
  data = big()
  time.within(100 * time.MS, |?data| file.write("fifo", data)!) catch |e|
    print("stopped:", e)
  print("wrote")
EOF2

cat >task_writes_within.rig <<'EOF2'
use std.file
use std.time

fun big() -> String
  s = String()
  for _ in 0..100000
    !s.add("0123456789")
  <s

sub work()!
  data = big()
  time.within(100 * time.MS, |?data| file.write("fifo", data)!) catch |e|
    print("stopped:", e)
  print("wrote")

sub main()!
  t = work()&
  >t!
EOF2

cat >copies_within.rig <<'EOF2'
use std.file
use std.io
use std.time

fun copied() -> Int!
  if file.open("fifo")! as f
    out = file.create("out/copied")!
    return io.copy(!f, !out)!
  return -1

sub work()!
  n = time.within(100 * time.MS, || copied()!) catch |e|
    print("stopped:", e)
    -2
  print("copied:", n)

sub main()!
  t = work()&
  >t!
EOF2

cat >task_file_writes_within.rig <<'EOF2'
use std.file
use std.time

fun big() -> String
  s = String()
  for _ in 0..100000
    !s.add("0123456789")
  <s

sub put(data: ?String)!
  f = file.create("fifo")!
  (!f).write(data)!

sub work()!
  data = big()
  time.within(100 * time.MS, |?data| put(data)!) catch |e|
    print("stopped:", e)
  print("wrote")

sub main()!
  t = work()&
  >t!
EOF2

cat >queued_write.rig <<'EOF2'
use std.file
use std.time

fun held() -> Int!
  if file.open("held")! as f
    s = String()
    return (!f).read(!s, 16)!
  return -1

sub occupy()!
  print("occupied:", held()!)

sub put(f: !file.File)!
  !f.write("hello")!

sub writer()!
  f = file.create("kept")!
  time.sleep(150 * time.MS)!
  time.within(20 * time.MS, |!f| put(!f)!) catch |e|
    print("stopped:", e)
  <f
  print("closed")

sub main()!
  w = writer()&
  time.sleep(50 * time.MS)!
  o = occupy()&
  >w!
  >o!
EOF2

cat >queued_read.rig <<'EOF2'
use std.file
use std.time

fun held() -> Int!
  if file.open("held")! as f
    s = String()
    return (!f).read(!s, 16)!
  return -1

sub occupy()!
  _ = time.within(500 * time.MS, || held()!) catch |e|
    -1

fun rd(f: !file.File, s: !String) -> Int!
  return !f.read(!s, 100)!

sub reader()!
  if file.open("reg")! as f
    time.sleep(100 * time.MS)!
    s = String()
    !s.add("twelve bytes")
    time.within(20 * time.MS, |!f, !s| rd(!f, !s)!) catch |e|
      print("stopped:", e)
    print("kept:", s)

sub main()!
  r = reader()&
  time.sleep(30 * time.MS)!
  o = occupy()&
  >r!
  >o!
EOF2

cat >accepts_within.rig <<'EOF2'
use std.net
use std.time

fun waits() -> Bool!
  l = net.listen("127.0.0.1:0")!
  c = l.accept()!
  return true

sub main()!
  ok = time.within(100 * time.MS, || waits()!) catch |e|
    print("stopped:", e)
    false
  print("accepted:", ok)
EOF2

progs="opens task_opens opens_within task_opens_within reads_within task_reads_within copies_within writes_within task_writes_within task_file_writes_within queued_write queued_read accepts_within"
for p in $progs; do
  rig build -o $p $p.rig >/dev/null 2>&1 || fail "build $p.rig: $(rig build -o $p $p.rig 2>&1 | head -5)"
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

# A FIFO no one writes: its open waits for a writer.
mkfifo fifo

start ./opens
sleep 0.2
kill -TERM $pid
ends "SIGTERM ends a FIFO's open in a program with no task" 143
expect_eq "$(cat out.txt)" "defer ran" "its defer runs"
expect_eq "$(cat err.txt)" "started" "it shows no error"

start ./task_opens
sleep 0.2
kill -TERM $pid
ends "SIGTERM ends a FIFO's open in a task" 143
expect_eq "$(cat out.txt)" $'task defer ran\nmain defer ran' "the task's defer, then main's"

out=$("$TIMEOUT_CMD" -s KILL 10 ./opens_within 2>&1); expect_rc $? 0 "a deadline ends a FIFO's open with no task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nopened: false' "the open fails with the deadline's error"

out=$("$TIMEOUT_CMD" -s KILL 10 ./task_opens_within 2>&1); expect_rc $? 0 "a deadline ends a FIFO's open in a task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nopened: false' "the task's open fails with the deadline's error"

# The same FIFO held open to write by this script, which writes nothing:
# the open returns, and the read waits for bytes.
exec 3<>fifo
out=$("$TIMEOUT_CMD" -s KILL 10 ./reads_within 2>&1); expect_rc $? 0 "a deadline ends a pipe's read with no task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nread: -2' "the read fails with the deadline's error"

out=$("$TIMEOUT_CMD" -s KILL 10 ./task_reads_within 2>&1); expect_rc $? 0 "a deadline ends a pipe's read in a task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nread: -2' "the task's read fails with the deadline's error"

mkdir -p out
out=$("$TIMEOUT_CMD" -s KILL 10 ./copies_within 2>&1); expect_rc $? 0 "a deadline ends io.copy from a pipe in a task: $out"
expect_eq "$out" $'stopped: Stop.timeout\ncopied: -2' "the task's copy fails with the deadline's error"

# A megabyte written to it, more than the pipe holds: the write waits
# for a reader to take some.
out=$("$TIMEOUT_CMD" -s KILL 10 ./writes_within 2>&1); expect_rc $? 0 "a deadline ends a full pipe's write with no task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nwrote' "the write fails with the deadline's error"

out=$("$TIMEOUT_CMD" -s KILL 10 ./task_writes_within 2>&1); expect_rc $? 0 "a deadline ends a full pipe's write in a task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nwrote' "the task's write fails with the deadline's error"

out=$("$TIMEOUT_CMD" -s KILL 10 ./task_file_writes_within 2>&1); expect_rc $? 0 "a deadline ends a File's write to a full pipe in a task: $out"
expect_eq "$out" $'stopped: Stop.timeout\nwrote' "the task's File write fails with the deadline's error"
exec 3>&-

out=$("$TIMEOUT_CMD" -s KILL 10 ./accepts_within 2>&1); expect_rc $? 0 "a deadline ends an accept with no task: $out"
expect_eq "$out" $'stopped: Stop.timeout\naccepted: false' "the accept fails with the deadline's error"
# One pool thread, held by a read of a FIFO no one writes. A File's
# write queued behind it, which a deadline ends before it starts, holds
# nothing: the writer's close is the pipe's last, so its reader sees the
# end at once, and only then does this script let the held read go. A
# read queued so leaves its String as it was.
mkfifo held kept
echo "abc" >reg
exec 4<>held
("$TIMEOUT_CMD" -s KILL 5 cat kept >/dev/null) & cpid=$!
RIG_BLOCKING_THREADS=1 "$TIMEOUT_CMD" -s KILL 10 ./queued_write >out.txt 2>&1 & pid=$!
wait $cpid; crc=$?
echo x >&4
wait $pid; rc=$?
expect_rc $crc 0 "an abandoned write that never started closes its descriptor at once"
expect_rc $rc 0 "queued_write: $(cat out.txt)"
expect_eq "$(cat out.txt)" $'stopped: Stop.timeout\nclosed\noccupied: 2' "the queued write stops, and the held read goes on"

out=$(RIG_BLOCKING_THREADS=1 "$TIMEOUT_CMD" -s KILL 10 ./queued_read 2>&1); expect_rc $? 0 "queued_read: $out"
expect_eq "$out" $'stopped: Stop.timeout\nkept: twelve bytes' "a read that never started leaves its String as it was"
exec 4>&-
true
