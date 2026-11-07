# A large embedded run added to an empty List: mapped from the program's
# own file in a Linux or macOS release build (`alloc.mapRun`), copied
# elsewhere, with the same results. Each List owns its elements: a write
# to one, before and after it grows, is its own, and a List made from the
# same bytes again reads them as they are. On Linux, the release build
# opens its own file (`/proc/self/exe`) to map the run; strace shows it.
# On macOS, vmmap shows the run's pages as a mapping of the program's
# file while it waits.
# timeout: 300
source "$ROOT/test/cli/_lib.sh"

python3 -c "
import struct
open('recs.bin', 'wb').write(b''.join(struct.pack('<II', i, i * 3) for i in range(32768)))" || fail "write recs.bin"
cat >main.rig <<'R'
obj Rec exact
  a: U32
  b: U32

sub main()
  xs: List[Rec] = List()
  !xs.extend_from_bytes($embed("recs.bin"))
  ys: List[Rec] = List()
  !ys.extend_from_bytes($embed("recs.bin"))
  xs[5].a = 99
  !xs.push(Rec(a: 1, b: 2))
  xs[6].b = 7
  zs: List[Rec] = List()
  !zs.extend_from_bytes($embed("recs.bin"))
  print(xs.len, xs[5].a, xs[6].b, ys[5].a, ys[6].b, ys.len, zs[5].a, xs[xs.len - 1].a)
R
want="32769 99 7 5 18 32768 5 1"
expect_eq "$(rig run main.rig 2>&1)" "$want" "a debug build, which copies"
(rig build --release -o rel main.rig) || fail "a release build"
expect_eq "$(./rel)" "$want" "a release build"
if [[ $(uname) == Linux ]] && command -v strace >/dev/null; then
    calls=$(strace -f -e trace=open,openat ./rel 2>&1 >/dev/null)
    expect_has "$calls" "/proc/self/exe" "the release build maps its run"
fi
if [[ $(uname) == Darwin ]]; then
    cat >wait.rig <<'R'
use std.file
use std.time

obj Rec exact
  a: U32
  b: U32

sub main()
  xs: List[Rec] = List()
  !xs.extend_from_bytes($embed("recs.bin"))
  file.write("ready", "") catch return
  while (file.stat("ready") catch none) != none
    time.sleep(ms: 5) catch return
  print(xs.len, xs[5].b)
R
    (rig build --release -o waiter wait.rig) || fail "a release build that waits"
    ./waiter >waited.out &
    pid=$!
    for _ in $(seq 1 400); do [[ -f ready ]] && break; sleep 0.05; done
    [[ -f ready ]] || { kill $pid; fail "the waiting build never got ready"; }
    regions=$(vmmap -interleaved $pid 2>/dev/null)
    rm -f ready
    wait $pid
    expect_eq "$(cat waited.out)" "32768 15" "the waiting release build"
    # The run's own mapping: of the program's file, at least the run's 256 KiB.
    big=$(grep '^mapped file' <<<"$regions" | grep -F '/waiter' | grep -oE '\[ *[0-9.]+[KM]' | tr -d '[ ' |
        awk '/M$/ { n = $0 + 0; if (n >= 0.25) print "yes" } /K$/ { n = $0 + 0; if (n >= 256) print "yes" }' | head -1)
    expect_eq "$big" "yes" "the release build maps its run from its own file"
fi
