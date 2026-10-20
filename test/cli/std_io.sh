# io.copy between files: a file copied to a new one byte for byte, in
# 64 KiB blocks and a short last one, and an empty file; in debug
# (sanitized) and --release. Between sockets: test/rig/std-io.rig.test.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >cp.rig <<'EOF2'
use std.file
use std.io

sub copy(from: ?String, to: ?String)!
  if file.open(from)! as src
    dst = file.create(to)!
    print(io.copy(!src, !dst)!)

sub main()!
  data = String()
  for i in 0..100000
    !data.add(i, "\n")
  file.write("big.txt", data)!
  copy("big.txt", "out/copy.txt")!
  print((file.read("out/copy.txt")! ?? String()) == data)
  file.write("empty.txt", "")!
  copy("empty.txt", "out/empty.txt")!
  print((file.read("out/empty.txt")! ?? String("none")).len)
EOF2

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf out big.txt empty.txt
    out=$(RIG_SANITIZE=1 rig run $flag cp.rig 2>&1); expect_rc $? 0 "$mode cp: $out"
    expect_eq "$out" $'588890\ntrue\n0\n0' "$mode: a file to a file, and an empty one"
done
exit 0
