# A worker that computes keeps its timers and its sockets going: its
# yield checks wake the tasks whose timers come due and whose sockets
# become ready (`sched.serviceBusy`), and a timer it sets wakes a worker
# that sleeps (`sched.kickForTimer`). Each program below sleeps or makes
# a round trip on a socket while `main` spins on the worker holding the
# timer or the socket, and must be done long before the spin is.
# Built with --release=fast, as the timings mean nothing otherwise.
# timeout: 300
# builds: shared
source "$ROOT/test/cli/_lib.sh"

cat >timers.rig <<'EOF'
use std.time

obj Node
  v: Int

fun nap(n: ?*Node, ms: Int) -> Int!
  t = time.now()
  time.sleep(ms * time.MS)!
  t.elapsed() / 1000000

fun napfree(ms: Int) -> Int!
  t = time.now()
  time.sleep(ms * time.MS)!
  t.elapsed() / 1000000

fun one() -> Int
  1

fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

sub main()
  w = one()&
  _ = >w
  time.sleep(20 * time.MS) catch print("x")
  n = *Node(v: 1)
  t = nap(?n, 10)&
  s = time.now()
  x = spin(150000000)
  print("local", s.elapsed() / 1000000, >t catch -1, x)
  u = napfree(10)&
  s2 = time.now()
  y = spin(150000000)
  print("free", s2.elapsed() / 1000000, >u catch -1, y)
EOF

cat >sockets.rig <<'EOF'
use std.net
use std.time

fun echo(l: net.Listener) -> Int!
  c = l.accept()!
  buf = String()
  total = 0
  while true
    n = (!c).read(!buf, 4096)!
    if n == 0
      break
    total += n
    (!c).write(?buf)!
    buf = String()
  total

fun driver(c: net.Stream) -> Int!
  new s = <c
  worst = 0
  for 0..3
    t = time.now()
    (!s).write("ping")!
    got = String()
    while got.len < 4
      _ = (!s).read(!got, 100)!
    us = t.elapsed() / 1000
    if us > worst
      worst = us
  worst

fun spin(n: Int) -> Int
  total = 0
  for i in 0..n
    total = (total + i * 7) % 1000003
  total

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  e = echo(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  d = driver(<c)&
  s = time.now()
  x = spin(150000000)
  spun = s.elapsed() / 1000
  print("sockets", spun, >d!, x)
  _ = >e!
EOF

rig build --release=fast -o timers timers.rig >build.log 2>&1 || fail "build timers: $(cat build.log)"
rig build --release=fast -o sockets sockets.rig >build.log 2>&1 || fail "build sockets: $(cat build.log)"

# done_before <what> <spin> <took>: what took `took` was done in under
# half the time the spin took.
done_before() {
    (( $3 * 2 < $2 )) || fail "$1 took $3 while main spun $2: it waited for the spin"
}

for workers in 1 4; do
    out=$(RIG_WORKERS=$workers ./timers) || fail "timers, $workers workers: exit $?"
    read -r _ spin nap _ <<<"$(grep '^local' <<<"$out")"
    done_before "a local task's 10 ms sleep, $workers workers" "$spin" "$nap"
    read -r _ spin nap _ <<<"$(grep '^free' <<<"$out")"
    done_before "a free task's 10 ms sleep, $workers workers" "$spin" "$nap"
    out=$(RIG_WORKERS=$workers ./sockets) || fail "sockets, $workers workers: exit $?"
    read -r _ spin trip _ <<<"$out"
    done_before "a round trip on a socket (us), $workers workers" "$spin" "$trip"
done
exit 0
