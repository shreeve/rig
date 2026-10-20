# std.file.stat, read_dir, and realpath, and std.os.cwd: what is at a
# path, a directory's entries sorted, links followed and marked, and the
# working directory; in debug (sanitized) and --release, and from tasks.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >paths.rig <<'EOF2'
use std.file
use std.os

sub show(path: ?String)
  if file.stat(path) as s
    print(path, s.kind, s.link, s.size)
  else
    print(path, "none")

sub main()
  for p in ["d", "d/a.txt", "d/link", "d/broken", "d/sublink", "d/missing"]
    show(p)
  if file.read_dir("d") as es
    for e in es
      print(" ", e.name, e.kind, e.link)
  print(file.read_dir("d/a.txt") == none, file.read_dir("d/missing") == none)
  real = file.realpath("d/link") ?? String("none")
  base = os.cwd()
  print(real == String(base, "/d/a.txt"), file.realpath("d/broken") ?? String("none"))
EOF2

# The same calls from tasks, waited for with `>`.
cat >tasks.rig <<'EOF2'
use std.file

fun size(path: String) -> Int
  if file.stat(?path) as s
    return s.size
  -1

fun count(path: String) -> Int
  if file.read_dir(?path) as es
    return es.len
  -1

sub main()
  a = size(String("d/a.txt"))&
  b = count(String("d"))&
  c = size(String("d/missing"))&
  print(>a, >b, >c)
EOF2

mkdir -p d/sub
printf 'hello' >d/a.txt
ln -s a.txt d/link
ln -s nowhere d/broken
ln -s sub d/sublink
cd "$(pwd -P)"
want_paths='d .directory false
d/a.txt .file false 5
d/link .file true 5
d/broken .other true 0
d/sublink .directory true
d/missing none
  a.txt .file false
  broken .other true
  link .file true
  sub .directory false
  sublink .directory true
true true
true none'

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    out=$(RIG_SANITIZE=1 rig run $flag paths.rig 2>&1); expect_rc $? 0 "$mode paths: $out"
    # A directory's size is the file system's own, so it is left out.
    got=$(sed -E 's/^(d|d\/sublink) (\.directory) (true|false) [0-9]+$/\1 \2 \3/' <<<"$out")
    expect_eq "$got" "$want_paths" "$mode: stat, read_dir, realpath, cwd"
    out=$(RIG_SANITIZE=1 rig run $flag tasks.rig 2>&1); expect_rc $? 0 "$mode tasks: $out"
    expect_eq "$out" "5 5 -1" "$mode: from tasks"
done
exit 0
