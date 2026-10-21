# io.copy between files and sockets: a file copied to a new one byte for
# byte, in 64 KiB blocks and a short last one, an empty file, a file
# served on a socket, and a socket read into a file; in debug
# (sanitized) and --release, and under 20 seeds. Between sockets:
# test/rig/std-io.rig.test.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

cat >cp.rig <<'EOF2'
use std.file
use std.io
use std.net

fun serve_file(l: net.Listener) -> Int!
  c = l.accept()!
  if file.open("big.txt")! as f
    return io.copy(!f, !c)!
  0

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
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = serve_file(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  got = file.create("out/got.txt")!
  print(io.copy(!c, !got)!, >t!)
  print((file.read("out/got.txt")! ?? String()) == data)
EOF2

for mode in debug release; do
    flag=; [[ $mode == release ]] && flag=--release
    rm -rf out big.txt empty.txt
    out=$(RIG_SANITIZE=1 rig run $flag cp.rig 2>&1); expect_rc $? 0 "$mode cp: $out"
    want=$'588890\ntrue\n0\n0\n588890 588890\ntrue'
    expect_eq "$out" "$want" "$mode: file to file, an empty one, file to socket, socket to file"
    out=$(rig build $flag cp.rig 2>&1); expect_rc $? 0 "$mode build: $out"
    for run in $(seq 1 20); do
        rm -rf out
        out=$("$TIMEOUT_CMD" 20 ./cp 2>&1); expect_rc $? 0 "$mode run $run: $out"
        expect_eq "$out" "$want" "$mode: run $run"
        out=$(RIG_SEED=$run ./cp 2>&1); expect_rc $? 0 "$mode seed $run: $out"
        expect_eq "$out" "$want" "$mode: seed $run"
    done
done
exit 0
