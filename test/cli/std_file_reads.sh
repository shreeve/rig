# std.file's reads at their edges: `file.read` of a pipe larger than
# its probe, read to its end; `read_dir` of a directory larger than a
# listing buffer, sorted, links and kinds as before; `File.read` small
# and large, into an empty String and onto one holding bytes, and 0 at
# the end. In debug (sanitized) and --release.
# timeout: 300
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >pipe.rig <<'EOF2'
use std.file

sub main()!
  s = file.read("/dev/stdin")! ?? String()
  sum = 0
  for b in ?s[..]
    sum += Int(b)
  print(s.len, sum)
EOF2

cat >dir.rig <<'EOF2'
use std.file
use std.text

sub main()!
  es = file.read_dir("many")! ?? List[file.Entry]()
  sorted = true
  for i in 1..es.len
    sorted = false if not (es[i - 1].name < es[i].name)
  print(es.len, sorted)
  for e in ?es
    if not text.starts_with(e.name, "f")
      print(e.name, e.kind, e.link)
EOF2

cat >file.rig <<'EOF2'
use std.file

sub main()!
  whole = file.read("big.dat")! ?? String()
  if file.open("big.dat")! as f
    got = String()
    reads = 0
    size = 70
    while (!f).read(!got, size)! > 0
      reads += 1
      size = 100000 if size == 70 else 70
    at_end = (!f).read(!got, 70)!
    print(got.len, got == whole, reads, at_end)
    empty = String()
    print((!f).read(!empty, 100000)!, empty.len)
EOF2

mkdir many
python3 - <<'EOF2'
import os
for i in range(3000):
    open("many/f%04d-%s" % (i, "x" * 40), "w").close()
os.mkdir("many/sub")
os.symlink("f0001-" + "x" * 40, "many/zlink")
os.symlink("nowhere", "many/zbroken")
open("big.dat", "wb").write(bytes(i % 251 for i in range(250000)))
EOF2
want_dir=$'3003 true\nsub .directory false\nzbroken .other true\nzlink .file true'

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    # A pipe reports no size: read past the 4 KiB probe to its end.
    out=$(python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 7 for i in range(100000)))" | RIG_SANITIZE=1 rig run $flag pipe.rig 2>&1); expect_rc $? 0 "$mode pipe: $out"
    expect_eq "$out" "100000 299995" "$mode: a 100 KB pipe"
    out=$(RIG_SANITIZE=1 rig run $flag dir.rig 2>&1); expect_rc $? 0 "$mode dir: $out"
    expect_eq "$out" "$want_dir" "$mode: 3,003 entries, sorted, links and kinds"
    out=$(RIG_SANITIZE=1 rig run $flag file.rig 2>&1); expect_rc $? 0 "$mode file: $out"
    expect_eq "$out" $'250000 true 6 0\n0 0' "$mode: small and large reads, into empty and onto bytes"
done
exit 0
