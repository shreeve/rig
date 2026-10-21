# std.file's layer of operations: append, rename, mkdir, remove, exists,
# open and create giving a File read and written as a net.Stream is,
# missing parents made only with `parents: true`, each failure a
# FileError; and every call a fallible waiting point, failing in a
# task past its deadline or canceled. In debug (sanitized) and --release.
# timeout: 300
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
  file.rename("ro/f.txt", "g.txt") catch |e|
    print("rename", e)
  make() catch |e|
    print("create", e)
  _ = file.exists("shut/f.txt") catch |e|
    print("exists", e)
    false
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
for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf d f.txt h.txt never.txt fifo; mkfifo fifo
    # A link that names nothing, made before `ops.rig` makes `d`: `mkdir`
    # of a directory there already is fine.
    mkdir d; ln -s nowhere d/link
    out=$(RIG_SANITIZE=1 rig run $flag ops.rig 2>&1); expect_rc $? 0 "$mode ops: $out"
    expect_eq "$out" "$want_ops" "$mode: append, mkdir, rename, remove, open, create"
    out=$(RIG_SANITIZE=1 rig run $flag stop.rig 2>&1); expect_rc $? 0 "$mode stop: $out"
    expect_eq "$out" $'hello world\nsleep Stop.timeout\n-1\n-2\ntrue\n-3\n-4\ntrue' "$mode: past a deadline, and canceled, before and on the pool"
    if [[ $(id -u) -ne 0 ]]; then
        rm -rf ro shut; mkdir ro shut; printf 'f' >ro/f.txt; chmod 400 ro/f.txt; chmod 500 ro; chmod 000 shut
        out=$(RIG_SANITIZE=1 rig run $flag denied.rig 2>&1); rc=$?
        chmod 700 ro shut
        expect_rc $rc 0 "$mode denied: $out"
        expect_eq "$out" $'append FileError.denied\nremove FileError.denied\nrename FileError.denied\ncreate FileError.denied\nexists FileError.denied' "$mode: denied"
    fi
done
exit 0
