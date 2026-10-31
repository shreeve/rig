# std.file's layer of operations: append, rename, mkdir, remove, unlink,
# rmdir, exists,
# open and create giving a File read and written as a net.Stream is,
# an open of a FIFO that does not wait for its writer (`wait: false`),
# missing parents made only with `parents: true`, each failure a
# FileError; and every call a fallible waiting point, failing in a
# task past its deadline or canceled. In debug (sanitized) and --release.
# timeout: 300
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >ops.rig <<'EOF2'
use std.file

sub copy(from: ?String, to: ?String)!
  if file.open(from)! as src
    dst = file.create(to, parents: true)!
    buf = String()
    while (!src).read(!buf, 3)! > 0
      (!dst).write(buf)!
      buf = String()

sub main()!
  file.mkdir("d")!
  file.write("d/a.txt", "hello")!
  file.append("d/a.txt", " world")!
  file.append("d/new/b.txt", "b") catch |e|
    print("append with no parent", e)
  file.append("d/new/b.txt", "b", parents: true)!
  print(file.read("d/a.txt")! ?? String("none"), file.read("d/new/b.txt")! ?? String("none"))
  file.mkdir("d/x/y/z") catch |e|
    print("mkdir with no parent", e)
  file.mkdir("d/x/y/z", parents: true)!
  file.mkdir("d/x/y")!
  file.mkdir("d/x/y", parents: true)!
  file.mkdir("d/a.txt") catch |e|
    print("mkdir on a file", e)
  file.mkdir("d/a.txt", parents: true) catch |e|
    print("mkdir parents on a file", e)
  _ = file.create("d/q/f.txt") catch |e|
    print("create with no parent", e)
  print(file.exists("d/a.txt")!, file.exists("d/x")!, file.exists("d/none")!, file.exists("d/link")!, file.exists("d/a.txt/x")!)
  file.rename("d/a.txt", "d/c.txt")!
  print(file.read("d/a.txt")! == none, file.read("d/c.txt")! ?? String("none"))
  file.rename("d/nothing", "d/c2.txt") catch |e|
    print("rename nothing", e)
  _ = file.remove("d/x") catch |e|
    print("remove a full directory", e)
    false
  print(file.remove("d/x/y/z")!, file.remove("d/x/y/z")!, file.remove("d/c.txt")!)
  copy("d/new/b.txt", "d/copy/b2.txt")!
  file.write("d/long.txt", "0123456789abcdef")!
  copy("d/long.txt", "d/long2.txt")!
  print(file.read("d/copy/b2.txt")! ?? String("none"), file.read("d/long2.txt")! ?? String("none"))
  print(file.open("d/none.txt")! == none)
  if file.open("d")! as dir
    got = String()
    _ = (!dir).read(!got, 10) catch |e|
      print("read a directory", e)
      0
  file.remove("d/link")!
  if file.read_dir("d")! as es
    for e in es
      print(" ", e.name, e.kind)
EOF2

# `unlink` removes anything but a directory, a link itself and not what
# it names; `rmdir` only an empty directory. Each is one system call, so
# where the systems differ (a trailing `/`), each gives its own answer.
cat >rm.rig <<'EOF2'
use std.file

sub main()!
  print(file.unlink("u/f")!, file.unlink("u/link")!, file.unlink("u/fifo")!, file.unlink("u/none")!)
  print(file.exists("u/d")!, file.exists("u/link")!)
  _ = file.rmdir("u/full") catch |e|
    print("rmdir a full directory", e)
    false
  _ = file.rmdir("u/elink") catch |e|
    print("rmdir a link to a directory", e)
    false
  slash = file.rmdir("u/elink/") catch |e|
    print("rmdir link/", e)
    false
  print("rmdir link/", slash, file.exists("u/e")!)
  dir = file.unlink("u/d/") catch |e|
    print("unlink dir/", e)
    false
  print("unlink dir/", dir)
  print(file.rmdir("u/d")!, file.rmdir("u/d")!, file.rmdir("u/none")!, file.exists("u/full/x")!)
EOF2

# Past a deadline, or canceled, a call fails before it reaches the pool;
# and a call already waiting on the pool, here opening a FIFO no one
# writes, ends its wait at the deadline or the cancel. Writing the FIFO
# at the end lets those calls finish, and their results are dropped.
cat >stop.rig <<'EOF2'
use std.file
use std.task
use std.time

fun late() -> Int!
  time.sleep(10 * time.MS) catch |e|
    print("sleep", e)
  _ = file.read("f.txt")!
  0

fun waits() -> Int!
  time.sleep(time.SECOND)!
  file.write("never.txt", "x")!
  0

fun slow() -> Int!
  (file.read("fifo")! ?? String()).len

# A File read a few bytes at a time on the pool, from a task.
fun reads() -> String!
  got = String()
  if file.open("h.txt")! as f
    while (!f).read(!got, 4)! > 0
      pass
  got

fun slow_within() -> Int!
  time.within(50 * time.MS, slow)!

sub main()!
  file.write("f.txt", "x")!
  file.write("h.txt", "hello world")!
  h = reads()&
  print(>h!)
  print(time.within(time.MS, late) catch |e| -1)
  t = waits()&
  print(<t.cancel() catch |e| -2)
  print(file.read("never.txt")! == none)
  t0 = time.now()
  print(slow_within() catch |e| -3)
  r = slow()&
  time.sleep(50 * time.MS)!
  print(<r.cancel() catch |e| -4)
  print(t0.elapsed() < 5 * time.SECOND)
  file.append("fifo", "x")!
  time.sleep(300 * time.MS)!
EOF2

# A FIFO opened with `wait: false`, which no writer has opened: the open
# returns at once and reads its end. Then a writer opens it and waits
# before writing: a read waits for the bytes, since the File is not left
# nonblocking (a nonblocking read would fail). An open that waits for a
# writer that never comes is stopped by its deadline, and the writer the
# program opens then lets the abandoned open end.
cat >fifo.rig <<'EOF2'
use std.file
use std.time

fun opens() -> Int!
  if file.open("p")! as f
    return 1
  0

fun opens_within() -> Int!
  time.within(100 * time.MS, opens)!

sub main()!
  f = file.open("p", wait: false)! ?? return
  buf = String()
  print((!f).read(!buf, 10)!)
  file.write("opened", "")!
  while not file.exists("ready")!
    time.sleep(10 * time.MS)!
  print((!f).read(!buf, 10)!, buf)
  print((!f).read(!buf, 10)!)
  # From a task, so the scheduler runs the open on its pool.
  t = opens_within()&
  _ = >t catch |e|
    print(e)
    -1
  file.append("p", "x")!
  time.sleep(300 * time.MS)!
EOF2

# In a directory the program may not write; root may, so it is left out
# then.
cat >denied.rig <<'EOF2'
use std.file

sub make()!
  f = file.create("ro/g.txt")!
  (!f).write("x")!

sub main()
  file.append("ro/f.txt", "x") catch |e|
    print("append", e)
  _ = file.remove("ro/f.txt") catch |e|
    print("remove", e)
    false
  _ = file.unlink("ro/f.txt") catch |e|
    print("unlink", e)
    false
  _ = file.rmdir("ro/sub") catch |e|
    print("rmdir", e)
    false
  file.rename("ro/f.txt", "g.txt") catch |e|
    print("rename", e)
  make() catch |e|
    print("create", e)
  _ = file.exists("shut/f.txt") catch |e|
    print("exists", e)
    false
EOF2

# Many reads canceled, before their calls on the pool run and wherever
# they are, leave no descriptor open: the count of open descriptors is the
# same after as before. Release only: in debug, Zig's stat of a poller's
# entry in /dev/fd panics (EBADF) where release reports it.
cat >fds.rig <<'EOF2'
use std.file
use std.time

# How many descriptors the process has open: the entries of
# /proc/self/fd (Linux) or /dev/fd (macOS).
fun count() -> Int!
  path = "/proc/self/fd" if file.exists("/proc/self/fd")! else "/dev/fd"
  if file.read_dir(path)! as es
    return es.len
  -1

# Sleep a second: false when canceled first.
fun napped() -> Bool
  time.sleep(time.SECOND) catch return false
  true

# A read whose task is canceled first: the stop comes before the call on
# the pool runs, so it never runs.
fun first() -> Int!
  if file.open("h.txt")! as f
    _ = napped()
    got = String()
    return (!f).read(!got, 4) catch |e| -1
  0

# Reads a byte at a time until canceled, wherever that finds it.
fun many() -> Int!
  n = 0
  while n >= 0
    if file.open("h.txt")! as f
      got = String()
      while (!f).read(!got, 1)! > 0
        n += 1
  n

# `n` reads canceled before they run, then `n` canceled wherever they are.
sub stress(n: Int)!
  for _ in 0..n
    t = first()&
    time.sleep(time.MS)!
    _ = <t.cancel() catch |e| -2
  for i in 0..n
    t = many()&
    time.sleep((i % 3) * 100 * time.US)!
    _ = <t.cancel() catch |e| -2
  # Calls the canceled tasks left running finish, and close what they hold.
  time.sleep(200 * time.MS)!

sub main()!
  file.write("h.txt", "hello world")!
  # A first round makes what the runtime keeps open: workers' pollers.
  stress(20)!
  before = count()!
  stress(200)!
  after = count()!
  print(before == after, before > 2)
EOF2

want_ops='append with no parent FileError.not_found
hello world b
mkdir with no parent FileError.not_found
mkdir on a file FileError.exists
mkdir parents on a file FileError.exists
create with no parent FileError.not_found
true true false false false
true hello world
rename nothing FileError.not_found
remove a full directory FileError.not_empty
true false true
b 0123456789abcdef
true
read a directory FileError.is_directory
  copy .directory
  long.txt .file
  long2.txt .file
  new .directory
  x .directory'
# macOS follows the link in `link/` and removes the directory it names,
# where Linux will not; and `unlink` of a directory fails with each
# system's reason.
if [[ $(uname -s) == Darwin ]]; then
    want_slash='rmdir link/ true false'
    want_dir=$'unlink dir/ FileError.not_permitted\nunlink dir/ false'
else
    want_slash=$'rmdir link/ FileError.not_directory\nrmdir link/ false true'
    want_dir=$'unlink dir/ FileError.is_directory\nunlink dir/ false'
fi
want_rm="true true true false
true false
rmdir a full directory FileError.not_empty
rmdir a link to a directory FileError.not_directory
$want_slash
$want_dir
true false false true"
out=$(rig run --release fds.rig 2>&1); expect_rc $? 0 "fds: $out"
expect_eq "$out" "true true" "canceled reads leave no descriptor open"

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf d f.txt h.txt never.txt fifo; mkfifo fifo
    # A link that names nothing, made before `ops.rig` makes `d`: `mkdir`
    # of a directory there already is fine.
    mkdir d; ln -s nowhere d/link
    out=$(RIG_SANITIZE=1 rig run $flag ops.rig 2>&1); expect_rc $? 0 "$mode ops: $out"
    expect_eq "$out" "$want_ops" "$mode: append, mkdir, rename, remove, open, create"
    rm -rf u; mkdir -p u/d u/e u/full; printf 'f' >u/f; printf 'x' >u/full/x
    ln -s d u/link; ln -s e u/elink; mkfifo u/fifo
    out=$(RIG_SANITIZE=1 rig run $flag rm.rig 2>&1); expect_rc $? 0 "$mode rm: $out"
    expect_eq "$out" "$want_rm" "$mode: unlink and rmdir"
    out=$(RIG_SANITIZE=1 rig run $flag stop.rig 2>&1); expect_rc $? 0 "$mode stop: $out"
    expect_eq "$out" $'hello world\nsleep Stop.timeout\n-1\n-2\ntrue\n-3\n-4\ntrue' "$mode: past a deadline, and canceled, before and on the pool"
    rig build $flag -o nowait fifo.rig >build.log 2>&1 || fail "$mode build fifo: $(cat build.log)"
    rm -f p opened ready; mkfifo p
    RIG_SANITIZE=1 "$TIMEOUT_CMD" 20 ./nowait >fifo.out 2>&1 &
    pid=$!
    while [[ ! -e opened ]] && kill -0 $pid 2>/dev/null; do sleep 0.02; done
    [[ -e opened ]] && "$TIMEOUT_CMD" 10 bash -c 'exec 3>p; touch ready; sleep 0.3; printf hi >&3'
    wait $pid; rc=$?
    out=$(cat fifo.out); expect_rc $rc 0 "$mode fifo: $out"
    expect_eq "$out" $'0\n2 hi\n0\nStop.timeout' "$mode: a FIFO opened without waiting, then read waiting"
    if [[ $(id -u) -ne 0 ]]; then
        rm -rf ro shut; mkdir ro ro/sub shut; printf 'f' >ro/f.txt; chmod 400 ro/f.txt; chmod 500 ro; chmod 000 shut
        out=$(RIG_SANITIZE=1 rig run $flag denied.rig 2>&1); rc=$?
        chmod 700 ro shut
        expect_rc $rc 0 "$mode denied: $out"
        expect_eq "$out" $'append FileError.denied\nremove FileError.denied\nunlink FileError.denied\nrmdir FileError.denied\nrename FileError.denied\ncreate FileError.denied\nexists FileError.denied' "$mode: denied"
    fi
done
exit 0
