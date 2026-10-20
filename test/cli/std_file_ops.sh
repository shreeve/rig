# std.file's layer of operations: append, rename, mkdir, remove, open and
# create giving a File read and written as a net.Stream is, each failure
# a FileError; and every call a fallible waiting point, failing in a
# task past its deadline or canceled. In debug (sanitized) and --release.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >ops.rig <<'EOF2'
use std.file

sub copy(from: ?String, to: ?String)!
  if file.open(from)! as src
    dst = file.create(to)!
    buf = String()
    while (!src).read(!buf, 3)! > 0
      (!dst).write(buf)!
      buf = String()

sub main()!
  file.write("d/a.txt", "hello")!
  file.append("d/a.txt", " world")!
  file.append("d/new/b.txt", "b")!
  print(file.read("d/a.txt")! ?? String("none"), file.read("d/new/b.txt")! ?? String("none"))
  file.mkdir("d/x/y/z")!
  file.mkdir("d/x/y")!
  file.mkdir("d/a.txt") catch |e|
    print("mkdir on a file", e)
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
  if file.read_dir("d")! as es
    for e in es
      print(" ", e.name, e.kind)
EOF2

# Past a deadline, or canceled, a call fails before it reaches the pool.
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

sub main()!
  file.write("f.txt", "x")!
  print(time.within(time.MS, late) catch |e| -1)
  t = waits()&
  print(<t.cancel() catch |e| -2)
  print(file.read("never.txt")! == none)
EOF2

# In a directory the program may not write; root may, so it is left out
# then.
cat >denied.rig <<'EOF2'
use std.file

sub main()
  file.append("ro/f.txt", "x") catch |e|
    print("append", e)
  _ = file.remove("ro/f.txt") catch |e|
    print("remove", e)
    false
  file.rename("ro/f.txt", "g.txt") catch |e|
    print("rename", e)
  _ = file.create("ro/g.txt") catch |e|
    print("create", e)
    return
EOF2

want_ops='hello world b
mkdir on a file FileError.exists
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
    rm -rf d f.txt never.txt
    out=$(RIG_SANITIZE=1 rig run $flag ops.rig 2>&1); expect_rc $? 0 "$mode ops: $out"
    expect_eq "$out" "$want_ops" "$mode: append, mkdir, rename, remove, open, create"
    out=$(RIG_SANITIZE=1 rig run $flag stop.rig 2>&1); expect_rc $? 0 "$mode stop: $out"
    expect_eq "$out" $'sleep Stop.timeout\n-1\n-2\ntrue' "$mode: past a deadline, and canceled"
    if [[ $(id -u) -ne 0 ]]; then
        rm -rf ro; mkdir ro; printf 'f' >ro/f.txt; chmod 400 ro/f.txt; chmod 500 ro
        out=$(RIG_SANITIZE=1 rig run $flag denied.rig 2>&1); rc=$?
        chmod 700 ro
        expect_rc $rc 0 "$mode denied: $out"
        expect_eq "$out" $'append FileError.denied\nremove FileError.denied\nrename FileError.denied\ncreate FileError.denied' "$mode: denied"
    fi
done
exit 0
