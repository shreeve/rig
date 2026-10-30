# timeout: 300
# A read makes room for `max` bytes, no more, and keeps what comes. The
# runtime grows a String through the allocator's raw calls, never Zig's
# `Allocator.alloc` and `free`, which in a safe build write 0xAA over
# the whole block, and to the length it asks for, never half as much
# again: room for 64 MiB that five bytes fill stays untouched, so the
# program never holds it, and a socket read of 16 KiB into an empty
# String takes a block of 16 KiB. A program without tasks, so each read
# goes into the String itself, built --release (Zig's safe mode); its
# peak resident memory stays below 32 MiB.
source "$ROOT/test/cli/_lib.sh"

cat >room.rig <<'EOF'
use std.file
use std.net
use std.os

sub main()!
  file.write("small.txt", "hello")!
  new f = file.open("small.txt")! ?? return
  a = String()
  n = (!f).read(!a, 64 * 1024 * 1024)!
  l = net.listen("127.0.0.1:0")!
  c = net.connect(String("127.0.0.1:", l.port()))!
  s = l.accept()!
  (!c).write("hello")!
  b = String()
  before = os.memory().live
  m = (!s).read(!b, 16384)!
  grew = os.memory().live - before
  (!c).write("hello")!
  big = String()
  k = (!s).read(!big, 64 * 1024 * 1024)!
  print(n, m, k, a, b, big, grew)
EOF

rig build --release -o room room.rig >build.log 2>&1 || fail "build: $(cat build.log)"
out=$(python3 -I -c '
import resource, subprocess, sys
out = subprocess.run(["./room"], capture_output=True, text=True, check=True).stdout.strip()
peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
if sys.platform != "darwin": peak *= 1024
print(out, peak >> 20)') || fail "run: $out"
read -r n m k a b big grew mib <<<"$out"
expect_eq "$n $m $k $a $b $big" "5 5 5 hello hello hello" "what was read"
expect_eq "$grew" 16384 "the bytes a read of 16 KiB into an empty String took"
(( mib < 32 )) || fail "peak resident memory $mib MiB after reads of 64 MiB that five bytes filled"
